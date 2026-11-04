//! Local Skills: discover `<root>/<skill>/SKILL.md`, parse front matter and
//! expose the instructions and bundled resources as plain text.
//!
//! A skill is documentation, not executable code. Nothing here runs scripts
//! from a skill directory; any action a skill asks for must still go through
//! the normal Tool Dispatcher and permission checks.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{error_codes, NodeError};

pub const SKILL_FILE: &str = "SKILL.md";
const MAX_RESOURCE_BYTES: u64 = 256 * 1024;
const MAX_INSTRUCTIONS_CHARS: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillSummary {
    pub id: String,
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub version: Option<String>,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillDocument {
    pub id: String,
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub version: Option<String>,
    pub instructions: String,
    pub resources: Vec<String>,
    pub root: String,
}

impl SkillDocument {
    /// Message shape accepted by the Context node.
    pub fn system_message(&self) -> serde_json::Value {
        serde_json::json!({
            "role": "system",
            "content": format!(
                "Skill: {}\n{}\n\n{}",
                self.name, self.description, self.instructions
            )
        })
    }
}

#[derive(Debug, Clone)]
pub struct SkillLibrary {
    root: PathBuf,
}

impl SkillLibrary {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Resolves the configured root, falling back to `$LINGXI_SKILLS_DIR`
    /// and then `~/.lingxi/skills`. Returns `None` when no directory exists.
    pub fn from_environment() -> Option<Self> {
        if let Ok(value) = std::env::var("LINGXI_SKILLS_DIR") {
            if !value.trim().is_empty() {
                return Some(Self::new(value));
            }
        }
        let home = std::env::var_os("HOME")?;
        let root = PathBuf::from(home).join(".lingxi").join("skills");
        if root.is_dir() {
            Some(Self::new(root))
        } else {
            None
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn discover(&self) -> Result<Vec<SkillSummary>, NodeError> {
        let entries = std::fs::read_dir(&self.root).map_err(|error| {
            NodeError::new(
                error_codes::SKILL_NOT_FOUND,
                format!("skills directory {:?} is unavailable: {error}", self.root),
            )
        })?;
        let mut found = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let skill_file = path.join(SKILL_FILE);
            if !skill_file.is_file() {
                continue;
            }
            match read_skill(&path) {
                Ok((meta, _body)) => found.push(SkillSummary {
                    id: path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or_default()
                        .to_string(),
                    name: meta
                        .get("name")
                        .cloned()
                        .unwrap_or_else(|| directory_name(&path)),
                    description: meta.get("description").cloned().unwrap_or_default(),
                    version: meta.get("version").cloned(),
                    path: skill_file.to_string_lossy().to_string(),
                }),
                Err(_) => continue,
            }
        }
        found.sort_by(|left, right| left.id.cmp(&right.id));
        Ok(found)
    }

    pub fn load(&self, id: &str) -> Result<SkillDocument, NodeError> {
        if id.contains('/') || id.contains('\\') || id == "." || id == ".." {
            return Err(NodeError::new(
                error_codes::SKILL_INVALID,
                format!("invalid skill id {id:?}"),
            ));
        }
        let directory = self.root.join(id);
        if !directory.join(SKILL_FILE).is_file() {
            return Err(NodeError::new(
                error_codes::SKILL_NOT_FOUND,
                format!("skill {id:?} was not found under {:?}", self.root),
            ));
        }
        let (meta, instructions) = read_skill(&directory)?;
        if instructions.chars().count() > MAX_INSTRUCTIONS_CHARS {
            return Err(NodeError::new(
                error_codes::SKILL_INVALID,
                format!("skill {id:?} instructions exceed the size limit"),
            ));
        }
        let mut resources = Vec::new();
        collect_resources(&directory, &directory, &mut resources)?;
        resources.sort();
        Ok(SkillDocument {
            id: id.to_string(),
            name: meta.get("name").cloned().unwrap_or_else(|| id.to_string()),
            description: meta.get("description").cloned().unwrap_or_default(),
            version: meta.get("version").cloned(),
            instructions,
            resources,
            root: directory.to_string_lossy().to_string(),
        })
    }

    /// Reads one resource by its path relative to the skill root. Symlinks and
    /// `..` are rejected after canonicalization.
    pub fn read_resource(&self, id: &str, resource: &str) -> Result<String, NodeError> {
        let document = self.load(id)?;
        let directory = PathBuf::from(&document.root);
        let candidate = directory.join(resource);
        validate_relative(resource)?;
        let canonical = candidate.canonicalize().map_err(|error| {
            NodeError::new(
                error_codes::SKILL_NOT_FOUND,
                format!("skill resource {resource:?} was not found: {error}"),
            )
        })?;
        let root = directory
            .canonicalize()
            .map_err(|error| NodeError::new(error_codes::SKILL_NOT_FOUND, error.to_string()))?;
        if !canonical.starts_with(&root) {
            return Err(NodeError::new(
                error_codes::SKILL_INVALID,
                format!("skill resource {resource:?} escapes the skill directory"),
            ));
        }
        if canonical.is_symlink() || !canonical.is_file() {
            return Err(NodeError::new(
                error_codes::SKILL_INVALID,
                format!("skill resource {resource:?} is not a regular file"),
            ));
        }
        let metadata = std::fs::metadata(&canonical)
            .map_err(|error| NodeError::new(error_codes::SKILL_INVALID, error.to_string()))?;
        if metadata.len() > MAX_RESOURCE_BYTES {
            return Err(NodeError::new(
                error_codes::SKILL_INVALID,
                format!(
                    "skill resource {resource:?} is larger than {} bytes",
                    MAX_RESOURCE_BYTES
                ),
            ));
        }
        std::fs::read_to_string(&canonical).map_err(|error| {
            NodeError::new(
                error_codes::SKILL_INVALID,
                format!("skill resource {resource:?} is not UTF-8 text: {error}"),
            )
        })
    }
}

fn directory_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("skill")
        .to_string()
}

fn validate_relative(path: &str) -> Result<(), NodeError> {
    let candidate = Path::new(path);
    if candidate.is_absolute()
        || candidate
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(NodeError::new(
            error_codes::SKILL_INVALID,
            format!("skill resource {path:?} must stay inside the skill directory"),
        ));
    }
    Ok(())
}

fn collect_resources(
    root: &Path,
    directory: &Path,
    out: &mut Vec<String>,
) -> Result<(), NodeError> {
    let entries = std::fs::read_dir(directory)
        .map_err(|error| NodeError::new(error_codes::SKILL_INVALID, error.to_string()))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_symlink() {
            continue;
        }
        if path.is_dir() {
            collect_resources(root, &path, out)?;
            continue;
        }
        if path.file_name().and_then(|name| name.to_str()) == Some(SKILL_FILE) {
            continue;
        }
        if let Ok(relative) = path.strip_prefix(root) {
            out.push(relative.to_string_lossy().replace('\\', "/"));
        }
    }
    Ok(())
}

/// Reads the YAML-ish front matter used by `SKILL.md`. Only flat `key: value`
/// pairs are supported; that is all the skill metadata we consume.
fn read_skill(directory: &Path) -> Result<(BTreeMap<String, String>, String), NodeError> {
    let path = directory.join(SKILL_FILE);
    let raw = std::fs::read_to_string(&path).map_err(|error| {
        NodeError::new(
            error_codes::SKILL_INVALID,
            format!("failed to read {:?}: {error}", path),
        )
    })?;
    parse_skill(&raw)
}

pub fn parse_skill(raw: &str) -> Result<(BTreeMap<String, String>, String), NodeError> {
    let normalized = raw.trim_start_matches('\u{feff}');
    let mut lines = normalized.lines();
    let first = lines.next().unwrap_or_default().trim();
    if first != "---" {
        return Err(NodeError::new(
            error_codes::SKILL_INVALID,
            "SKILL.md must start with a --- front matter block",
        ));
    }
    let mut meta = BTreeMap::new();
    let mut closed = false;
    for line in lines.by_ref() {
        let trimmed = line.trim();
        if trimmed == "---" {
            closed = true;
            break;
        }
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        meta.insert(key.to_string(), value);
    }
    if !closed {
        return Err(NodeError::new(
            error_codes::SKILL_INVALID,
            "SKILL.md front matter is not closed",
        ));
    }
    if !meta.contains_key("name") || !meta.contains_key("description") {
        return Err(NodeError::new(
            error_codes::SKILL_INVALID,
            "SKILL.md front matter needs name and description",
        ));
    }
    let body = lines.collect::<Vec<_>>().join("\n");
    Ok((meta, body.trim().to_string()))
}
