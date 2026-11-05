//! Controlled workspace files for Agent tools.
//!
//! Every path is resolved inside one root; symlinks that escape the root are
//! rejected. Writes require the version returned by the last read:
//! `read(version) -> write(expectedVersion)`. A stale version fails with a
//! stable error instead of silently overwriting another Agent's work.

use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{error_codes, NodeError};

pub const ABSENT_VERSION: &str = "absent";
const MAX_READ_BYTES: usize = 4 * 1024 * 1024;

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

#[derive(Debug, Clone)]
pub struct Workspace {
    root: PathBuf,
}

impl Workspace {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, NodeError> {
        let root = root.into();
        fs::create_dir_all(&root).map_err(|error| {
            NodeError::new(
                error_codes::WORKSPACE_IO,
                format!("cannot create workspace {}: {error}", root.display()),
            )
        })?;
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
        // The file may not exist yet. Create and canonicalize its parent so a
        // symlinked directory cannot redirect the write outside the workspace.
        if let Some(parent) = joined.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot create directory for {relative:?}: {error}"),
                )
            })?;
            let canonical_parent = parent.canonicalize().map_err(|error| {
                NodeError::new(
                    error_codes::WORKSPACE_IO,
                    format!("cannot resolve parent of {relative:?}: {error}"),
                )
            })?;
            if !canonical_parent.starts_with(&self.root) {
                return Err(escape(&relative));
            }
            if let Some(name) = joined.file_name() {
                return Ok(canonical_parent.join(name));
            }
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

    pub fn list(&self, relative: &str) -> Result<Vec<FileEntry>, NodeError> {
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
            let child = if relative.trim().is_empty() {
                name.clone()
            } else {
                format!("{}/{}", normalize(relative), name)
            };
            if file_type.is_dir() {
                entries.push(FileEntry {
                    path: child,
                    name,
                    kind: "directory".to_string(),
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
        entries.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(entries)
    }
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
        let (workspace, root) = workspace();
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
            std::os::unix::fs::symlink(&outside, root.join("escape")).unwrap();
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
            .any(|entry| entry.path == "nested" && entry.kind == "directory"));
    }
}
