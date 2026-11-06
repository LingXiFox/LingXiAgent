//! Controlled workspace files for Agent tools.
//!
//! Every path is resolved inside one root; symlinks that escape the root are
//! rejected. Writes require the version returned by the last read:
//! `read(version) -> write(expectedVersion)`. A stale version fails with a
//! stable error instead of silently overwriting another Agent's work.
//!
//! `open_existing` never creates directories. Project workspaces are opened by
//! the host from an existing folder the user selected; a typo must not leave an
//! empty project behind.

use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{error_codes, NodeError};

pub const ABSENT_VERSION: &str = "absent";
const MAX_READ_BYTES: usize = 4 * 1024 * 1024;
const MAX_SEARCH_BYTES: u64 = 1024 * 1024;
const IGNORED_DIRS: &[&str] = &[
    ".git",
    "node_modules",
    "target",
    "dist",
    "build",
    ".next",
    ".venv",
    "venv",
    "__pycache__",
    "coverage",
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileSnapshot {
    pub path: String,
    pub version: String,
    pub content: String,
    pub bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub size: u64,
    pub version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMatch {
    pub path: String,
    pub line: usize,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitEntry {
    pub path: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommit {
    pub hash: String,
    pub author: String,
    pub timestamp_ms: u64,
    pub subject: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstructionDocument {
    pub path: String,
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct Workspace {
    root: PathBuf,
}

impl Workspace {
    /// Legacy constructor used by tests and by host-owned scratch spaces. It
    /// creates the root; project selection must use `open_existing`.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, NodeError> {
        let root = root.into();
        fs::create_dir_all(&root).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot create workspace {}: {error}", root.display()),
            )
        })?;
        Self::open_existing(&root)
    }

    /// Opens an existing directory without creating or mutating it.
    pub fn open_existing(root: impl AsRef<Path>) -> Result<Self, NodeError> {
        let root = root.as_ref();
        if !root.exists() {
            return Err(NodeError::new(
                error_codes::WORKSPACE_NOT_FOUND,
                format!("project folder {} does not exist", root.display()),
            ));
        }
        if !root.is_dir() {
            return Err(NodeError::new(
                error_codes::WORKSPACE_NOT_FOUND,
                format!("project path {} is not a directory", root.display()),
            ));
        }
        let root = root.canonicalize().map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot resolve workspace {}: {error}", root.display()),
            )
        })?;
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Resolves a workspace-relative path and verifies that neither the path
    /// nor an existing parent escapes the root through `..` or a symlink.
    /// This has no filesystem side effects; callers that write create parents
    /// explicitly after the boundary check.
    pub fn resolve(&self, relative: &str) -> Result<PathBuf, NodeError> {
        let relative = relative.trim().replace('\\', "/");
        let candidate = Path::new(&relative);
        if candidate.is_absolute() {
            return Err(escape(&relative));
        }
        let mut clean = PathBuf::new();
        for component in candidate.components() {
            match component {
                Component::Normal(part) => clean.push(part),
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                    return Err(escape(&relative))
                }
            }
        }
        let joined = self.root.join(&clean);
        if joined.exists() {
            let canonical = joined.canonicalize().map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot resolve {relative:?}: {error}"),
                )
            })?;
            if !canonical.starts_with(&self.root) {
                return Err(escape(&relative));
            }
            return Ok(canonical);
        }
        // A new file may be several levels deep. Canonicalize the deepest
        // existing ancestor so a symlinked directory cannot redirect a write
        // outside the workspace.
        let mut existing = joined.clone();
        while !existing.exists() {
            if !existing.pop() {
                return Err(escape(&relative));
            }
        }
        let canonical = existing.canonicalize().map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot resolve parent of {relative:?}: {error}"),
            )
        })?;
        if !canonical.starts_with(&self.root) {
            return Err(escape(&relative));
        }
        Ok(joined)
    }

    pub fn read(&self, relative: &str) -> Result<FileSnapshot, NodeError> {
        let path = self.resolve(relative)?;
        let bytes = fs::read(&path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                NodeError::new(
                    error_codes::WORKSPACE_NOT_FOUND,
                    format!("{relative:?} does not exist in the workspace"),
                )
            } else {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot read {relative:?}: {error}"),
                )
            }
        })?;
        if bytes.len() > MAX_READ_BYTES {
            return Err(NodeError::new(
                error_codes::WORKSPACE_IO,
                format!(
                    "{relative:?} is {} bytes; limit is {MAX_READ_BYTES}",
                    bytes.len()
                ),
            ));
        }
        let content = String::from_utf8(bytes).map_err(|_| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("{relative:?} is not UTF-8 text"),
            )
        })?;
        let bytes = content.len();
        Ok(FileSnapshot {
            path: normalize(relative),
            version: version_of(content.as_bytes()),
            content,
            bytes,
        })
    }

    /// Writes UTF-8 content. `expected_version` must be the version returned by
    /// a prior read, or `absent` when creating a new file.
    pub fn write(
        &self,
        relative: &str,
        content: &str,
        expected_version: &str,
    ) -> Result<FileSnapshot, NodeError> {
        let path = self.resolve(relative)?;
        self.ensure_parent(&path, relative)?;
        let current = if path.exists() {
            let bytes = fs::read(&path).map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot read current {relative:?}: {error}"),
                )
            })?;
            version_of(&bytes)
        } else {
            ABSENT_VERSION.to_string()
        };
        if current != expected_version {
            return Err(NodeError::new(
                error_codes::WORKSPACE_VERSION_CONFLICT,
                format!(
                    "{relative:?} changed since it was read (expected {expected_version}, found {current}); read it again before writing"
                ),
            ));
        }
        let temp = path.with_extension(format!(
            "{}.tmp-{}",
            path.extension()
                .and_then(|value| value.to_str())
                .unwrap_or("file"),
            uuid::Uuid::new_v4()
        ));
        fs::write(&temp, content.as_bytes()).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot write {relative:?}: {error}"),
            )
        })?;
        fs::rename(&temp, &path).map_err(|error| {
            let _ = fs::remove_file(&temp);
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot commit {relative:?}: {error}"),
            )
        })?;
        Ok(FileSnapshot {
            path: normalize(relative),
            version: version_of(content.as_bytes()),
            content: content.to_string(),
            bytes: content.len(),
        })
    }

    /// Deletes one file (or an empty directory). Recursive deletion is never
    /// performed by this method. For files an optional expected version gives
    /// the same conflict protection as a write.
    pub fn delete(&self, relative: &str, expected_version: Option<&str>) -> Result<(), NodeError> {
        let normalized = normalize(relative);
        if normalized.is_empty() {
            return Err(NodeError::new(
                error_codes::WORKSPACE_PATH_ESCAPE,
                "the workspace root cannot be deleted",
            ));
        }
        let path = self.resolve(relative)?;
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_NOT_FOUND,
                format!("{relative:?} does not exist: {error}"),
            )
        })?;
        if metadata.is_dir() && !metadata.file_type().is_symlink() {
            let mut entries = fs::read_dir(&path).map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot list {relative:?}: {error}"),
                )
            })?;
            if entries.next().is_some() {
                return Err(NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("refusing to delete non-empty directory {relative:?}"),
                ));
            }
            fs::remove_dir(&path).map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot delete {relative:?}: {error}"),
                )
            })?;
            return Ok(());
        }
        if let Some(expected) = expected_version {
            let bytes = fs::read(&path).map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot read {relative:?}: {error}"),
                )
            })?;
            let current = version_of(&bytes);
            if current != expected {
                return Err(NodeError::new(
                    error_codes::WORKSPACE_VERSION_CONFLICT,
                    format!(
                        "{relative:?} changed since it was read (expected {expected}, found {current})"
                    ),
                ));
            }
        }
        fs::remove_file(&path).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot delete {relative:?}: {error}"),
            )
        })
    }

    pub fn list(&self, relative: &str) -> Result<Vec<FileEntry>, NodeError> {
        self.list_inner(relative, true)
    }

    /// Lists one directory level. `show_ignored == false` hides build/VCS
    /// directories but never recurses, so large projects stay lazy.
    pub fn list_filtered(
        &self,
        relative: &str,
        show_ignored: bool,
    ) -> Result<Vec<FileEntry>, NodeError> {
        self.list_inner(relative, show_ignored)
    }

    fn list_inner(&self, relative: &str, show_ignored: bool) -> Result<Vec<FileEntry>, NodeError> {
        let path = self.resolve(relative)?;
        let mut entries = Vec::new();
        let read_dir = fs::read_dir(&path).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot list {relative:?}: {error}"),
            )
        })?;
        for entry in read_dir {
            let entry = entry.map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot list {relative:?}: {error}"),
                )
            })?;
            let file_type = entry.file_type().map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot inspect {:?}: {error}", entry.path()),
                )
            })?;
            let name = entry.file_name().to_string_lossy().to_string();
            if !show_ignored && is_ignored_name(&name, file_type.is_dir()) {
                continue;
            }
            let child = if relative.trim().is_empty() {
                name.clone()
            } else {
                format!("{}/{}", normalize(relative), name)
            };
            if file_type.is_dir() {
                entries.push(FileEntry {
                    path: child,
                    name,
                    kind: "dir".to_string(),
                    size: 0,
                    version: None,
                });
            } else if file_type.is_file() {
                let bytes = fs::read(entry.path()).ok();
                entries.push(FileEntry {
                    path: child,
                    name,
                    kind: "file".to_string(),
                    size: entry.metadata().map(|meta| meta.len()).unwrap_or(0),
                    version: bytes.as_deref().map(version_of),
                });
            }
        }
        entries.sort_by(|a, b| {
            b.kind
                .cmp(&a.kind)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(entries)
    }

    /// Case-insensitive text search under `relative`, skipping VCS/build
    /// folders and binary/large files.
    pub fn search(
        &self,
        relative: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<FileMatch>, NodeError> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let needle = query.to_lowercase();
        let limit = limit.clamp(1, 500);
        let mut matches = Vec::new();
        let start = self.resolve(relative)?;
        self.search_dir(&start, self.root(), &needle, limit, &mut matches)?;
        Ok(matches)
    }

    fn search_dir(
        &self,
        dir: &Path,
        root: &Path,
        needle: &str,
        limit: usize,
        matches: &mut Vec<FileMatch>,
    ) -> Result<(), NodeError> {
        if matches.len() >= limit {
            return Ok(());
        }
        let entries = fs::read_dir(dir).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot search {}: {error}", dir.display()),
            )
        })?;
        for entry in entries {
            let entry = entry.map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot search {}: {error}", dir.display()),
                )
            })?;
            let file_type = entry.file_type().map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot inspect {}: {error}", entry.path().display()),
                )
            })?;
            let name = entry.file_name().to_string_lossy().to_string();
            if file_type.is_dir() {
                if is_ignored_name(&name, true) {
                    continue;
                }
                self.search_dir(&entry.path(), root, needle, limit, matches)?;
            } else if file_type.is_file() {
                if entry.metadata().map(|meta| meta.len()).unwrap_or(0) > MAX_SEARCH_BYTES {
                    continue;
                }
                let Ok(bytes) = fs::read(entry.path()) else {
                    continue;
                };
                let Ok(content) = String::from_utf8(bytes) else {
                    continue;
                };
                for (index, line) in content.lines().enumerate() {
                    if matches.len() >= limit {
                        return Ok(());
                    }
                    if line.to_lowercase().contains(needle) {
                        let path = entry
                            .path()
                            .strip_prefix(root)
                            .unwrap_or(entry.path().as_path())
                            .to_string_lossy()
                            .replace('\\', "/");
                        matches.push(FileMatch {
                            path,
                            line: index + 1,
                            text: line.chars().take(400).collect(),
                        });
                    }
                }
            }
        }
        Ok(())
    }

    /// Loads AGENTS.md from the root down to the directory containing
    /// `relative` (or the directory itself). Files are small and only loaded
    /// when an operation actually touches that scope.
    pub fn agents_md(&self, relative: &str) -> Vec<InstructionDocument> {
        let normalized = normalize(relative);
        let mut current = PathBuf::new();
        let mut paths = vec![PathBuf::from("AGENTS.md")];
        let components: Vec<Component<'_>> = Path::new(&normalized).components().collect();
        let directory_components = if normalized.ends_with('/') {
            components.len()
        } else {
            components.len().saturating_sub(1)
        };
        for component in components.into_iter().take(directory_components) {
            if let Component::Normal(part) = component {
                current.push(part);
                paths.push(current.join("AGENTS.md"));
            }
        }
        let mut documents = Vec::new();
        for path in paths {
            let key = path.to_string_lossy().replace('\\', "/");
            if let Ok(snapshot) = self.read(&key) {
                if snapshot.bytes <= 64 * 1024 {
                    documents.push(InstructionDocument {
                        path: key,
                        content: snapshot.content,
                    });
                }
            }
        }
        documents
    }

    pub fn git_status(&self) -> Result<Vec<GitEntry>, NodeError> {
        let output = self.git(&["status", "--porcelain=v1", "--untracked-files=all"])?;
        let mut entries = Vec::new();
        for line in output.lines() {
            if line.len() < 4 {
                continue;
            }
            let status = line[..2].trim().to_string();
            let path = line[3..].trim().trim_matches('"').to_string();
            entries.push(GitEntry { path, status });
        }
        Ok(entries)
    }

    pub fn git_diff(&self, relative: Option<&str>) -> Result<String, NodeError> {
        let mut args = vec!["diff", "--no-color", "--no-ext-diff"];
        if let Some(relative) = relative.filter(|value| !value.trim().is_empty()) {
            args.push("--");
            args.push(relative);
        }
        self.git(&args)
    }

    pub fn git_log(&self, limit: usize) -> Result<Vec<GitCommit>, NodeError> {
        let limit = limit.clamp(1, 100).to_string();
        let output = self.git(&[
            "log",
            &format!("-n{limit}"),
            "--pretty=format:%h%x1f%an%x1f%at%x1f%s",
        ])?;
        let mut commits = Vec::new();
        for line in output.lines() {
            let parts: Vec<&str> = line.split('\u{1f}').collect();
            if parts.len() != 4 {
                continue;
            }
            commits.push(GitCommit {
                hash: parts[0].to_string(),
                author: parts[1].to_string(),
                timestamp_ms: parts[2].parse::<u64>().unwrap_or(0) * 1000,
                subject: parts[3].to_string(),
            });
        }
        Ok(commits)
    }

    pub fn is_git_repository(&self) -> bool {
        self.root.join(".git").exists()
    }

    fn git(&self, args: &[&str]) -> Result<String, NodeError> {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.root)
            .args(args)
            .output()
            .map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot run git: {error}"),
                )
            })?;
        if !output.status.success() {
            return Err(NodeError::new(
                error_codes::WORKSPACE_IO,
                format!(
                    "git {} failed: {}",
                    args.first().copied().unwrap_or(""),
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn ensure_parent(&self, path: &Path, relative: &str) -> Result<(), NodeError> {
        let Some(parent) = path.parent() else {
            return Ok(());
        };
        fs::create_dir_all(parent).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot create directory for {relative:?}: {error}"),
            )
        })?;
        let canonical = parent.canonicalize().map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot resolve parent of {relative:?}: {error}"),
            )
        })?;
        if !canonical.starts_with(&self.root) {
            return Err(escape(relative));
        }
        Ok(())
    }
}

fn is_ignored_name(name: &str, is_dir: bool) -> bool {
    if name == ".DS_Store" {
        return true;
    }
    is_dir && IGNORED_DIRS.contains(&name)
}

fn escape(relative: &str) -> NodeError {
    NodeError::new(
        error_codes::WORKSPACE_PATH_ESCAPE,
        format!("path {relative:?} escapes the workspace root"),
    )
}

fn normalize(relative: &str) -> String {
    relative
        .replace('\\', "/")
        .trim_start_matches("./")
        .trim_end_matches('/')
        .to_string()
}

fn version_of(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    format!(
        "sha256:{}",
        digest
            .as_slice()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workspace() -> (Workspace, PathBuf) {
        let root = std::env::temp_dir().join(format!("lingxi-ws-{}", uuid::Uuid::new_v4()));
        (Workspace::open(&root).unwrap(), root)
    }

    #[test]
    fn a_read_version_is_required_for_a_write() {
        let (workspace, _root) = workspace();
        let empty = workspace.read("src/main.rs").unwrap_err();
        assert_eq!(empty.code, error_codes::WORKSPACE_NOT_FOUND);
        let created = workspace
            .write("src/main.rs", "fn main() {}\n", ABSENT_VERSION)
            .unwrap();
        let read = workspace.read("src/main.rs").unwrap();
        assert_eq!(read.version, created.version);
        let conflict = workspace
            .write("src/main.rs", "tampered\n", ABSENT_VERSION)
            .unwrap_err();
        assert_eq!(conflict.code, error_codes::WORKSPACE_VERSION_CONFLICT);
        workspace
            .write("src/main.rs", "fn main() {}\n", &read.version)
            .unwrap();
    }

    #[test]
    fn parent_and_symlink_escapes_are_rejected() {
        let (workspace, _root) = workspace();
        assert_eq!(
            workspace.resolve("../outside").unwrap_err().code,
            error_codes::WORKSPACE_PATH_ESCAPE
        );
        assert_eq!(
            workspace.resolve("/tmp/outside").unwrap_err().code,
            error_codes::WORKSPACE_PATH_ESCAPE
        );
        #[cfg(unix)]
        {
            let outside = std::env::temp_dir().join(format!("lingxi-out-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&outside).unwrap();
            std::os::unix::fs::symlink(&outside, _root.join("escape")).unwrap();
            assert_eq!(
                workspace.resolve("escape/file.txt").unwrap_err().code,
                error_codes::WORKSPACE_PATH_ESCAPE
            );
            let _ = fs::remove_dir_all(outside);
        }
    }

    #[test]
    fn listing_reports_versions_for_files() {
        let (workspace, _root) = workspace();
        workspace.write("a.txt", "alpha", ABSENT_VERSION).unwrap();
        fs::create_dir_all(workspace.root().join("nested")).unwrap();
        let entries = workspace.list("").unwrap();
        assert!(entries
            .iter()
            .any(|entry| entry.path == "a.txt" && entry.version.is_some()));
        assert!(entries
            .iter()
            .any(|entry| entry.path == "nested" && entry.kind == "dir"));
    }

    #[test]
    fn opening_a_missing_project_never_creates_it() {
        let root = std::env::temp_dir().join(format!("lingxi-missing-{}", uuid::Uuid::new_v4()));
        let error = Workspace::open_existing(&root).unwrap_err();
        assert_eq!(error.code, error_codes::WORKSPACE_NOT_FOUND);
        assert!(!root.exists());
    }

    #[test]
    fn search_and_delete_are_bounded_to_the_workspace() {
        let (workspace, _root) = workspace();
        workspace
            .write("src/lib.rs", "pub fn needle() {}\n", ABSENT_VERSION)
            .unwrap();
        workspace
            .write("node_modules/pkg/index.js", "needle\n", ABSENT_VERSION)
            .unwrap();
        let matches = workspace.search("", "needle", 20).unwrap();
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].path, "src/lib.rs");
        assert_eq!(matches[0].line, 1);
        let read = workspace.read("src/lib.rs").unwrap();
        assert_eq!(
            workspace
                .delete("src/lib.rs", Some(ABSENT_VERSION))
                .unwrap_err()
                .code,
            error_codes::WORKSPACE_VERSION_CONFLICT
        );
        workspace.delete("src/lib.rs", Some(&read.version)).unwrap();
        assert_eq!(
            workspace.read("src/lib.rs").unwrap_err().code,
            error_codes::WORKSPACE_NOT_FOUND
        );
    }

    #[test]
    fn agents_md_is_scoped_from_root_to_the_operation_directory() {
        let (workspace, _root) = workspace();
        workspace
            .write("AGENTS.md", "root rules\n", ABSENT_VERSION)
            .unwrap();
        workspace
            .write("crates/a/AGENTS.md", "crate rules\n", ABSENT_VERSION)
            .unwrap();
        let documents = workspace.agents_md("crates/a/src/lib.rs");
        let paths: Vec<&str> = documents.iter().map(|doc| doc.path.as_str()).collect();
        assert_eq!(paths, vec!["AGENTS.md", "crates/a/AGENTS.md"]);
    }
}
