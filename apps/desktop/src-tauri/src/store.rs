//! Workflow persistence: one JSON document per workflow inside the app data
//! directory. Names are user facing, so they are validated instead of being
//! used as raw paths.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use lingxi_spec::{Workflow, SCHEMA_VERSION};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowSummary {
    pub name: String,
    pub node_count: usize,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone)]
pub struct WorkflowStore {
    root: PathBuf,
}

impl WorkflowStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn save(&self, name: &str, workflow: &Workflow) -> Result<WorkflowSummary, String> {
        let path = self.path_for(name)?;
        fs::create_dir_all(&self.root)
            .map_err(|error| format!("cannot create workflow directory: {error}"))?;

        let mut document = workflow.clone();
        document.name = name.trim().to_string();
        if document.schema_version.trim().is_empty() {
            document.schema_version = SCHEMA_VERSION.to_string();
        }

        let json = serde_json::to_vec_pretty(&document)
            .map_err(|error| format!("cannot serialize workflow: {error}"))?;
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, &json).map_err(|error| format!("cannot write workflow: {error}"))?;
        fs::rename(&temp_path, &path)
            .map_err(|error| format!("cannot commit workflow: {error}"))?;

        Ok(WorkflowSummary {
            name: document.name,
            node_count: document.nodes.len(),
            updated_at_ms: now_ms(),
        })
    }

    pub fn load(&self, name: &str) -> Result<Workflow, String> {
        let path = self.path_for(name)?;
        let data = fs::read(&path).map_err(|error| format!("cannot read workflow: {error}"))?;
        let mut workflow: Workflow = serde_json::from_slice(&data)
            .map_err(|error| format!("workflow file is not valid JSON: {error}"))?;
        if workflow.name.trim().is_empty() {
            workflow.name = name.trim().to_string();
        }
        Ok(workflow)
    }

    pub fn list(&self) -> Result<Vec<WorkflowSummary>, String> {
        if !self.root.exists() {
            return Ok(Vec::new());
        }
        let entries =
            fs::read_dir(&self.root).map_err(|error| format!("cannot list workflows: {error}"))?;

        let mut summaries = Vec::new();
        for entry in entries {
            let Ok(entry) = entry else { continue };
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let Ok(data) = fs::read(&path) else { continue };
            let Ok(workflow) = serde_json::from_slice::<Workflow>(&data) else {
                continue;
            };
            let fallback_name = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or_default()
                .to_string();
            let name = if workflow.name.trim().is_empty() {
                fallback_name
            } else {
                workflow.name
            };
            let updated_at_ms = fs::metadata(&path)
                .and_then(|metadata| metadata.modified())
                .ok()
                .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_millis() as u64)
                .unwrap_or_default();
            summaries.push(WorkflowSummary {
                name,
                node_count: workflow.nodes.len(),
                updated_at_ms,
            });
        }
        summaries.sort_by_key(|summary| std::cmp::Reverse(summary.updated_at_ms));
        Ok(summaries)
    }

    pub fn delete(&self, name: &str) -> Result<bool, String> {
        let path = self.path_for(name)?;
        if path.exists() {
            fs::remove_file(&path).map_err(|error| format!("cannot delete workflow: {error}"))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn path_for(&self, name: &str) -> Result<PathBuf, String> {
        let trimmed = name.trim();
        validate_entry_name(trimmed)?;
        Ok(self.root.join(format!("{trimmed}.json")))
    }
}

/// Rejects anything that could escape a store directory or produce an
/// unopenable file. Unicode letters are allowed, path separators are not.
pub(crate) fn validate_entry_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("name must not be empty".to_string());
    }
    if name.chars().count() > 64 {
        return Err("name must not exceed 64 characters".to_string());
    }
    if name.starts_with('.') {
        return Err("name must not start with a dot".to_string());
    }
    if name.ends_with('.') || name.ends_with(' ') {
        return Err("name must not end with a dot or a space".to_string());
    }
    for character in name.chars() {
        let allowed = character.is_alphanumeric() || matches!(character, ' ' | '-' | '_' | '.');
        if !allowed {
            return Err(format!(
                "name contains an unsupported character: {character:?}"
            ));
        }
    }
    Ok(())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use lingxi_spec::{Position, WorkflowNode};

    fn temp_store() -> (WorkflowStore, PathBuf) {
        let root = std::env::temp_dir().join(format!("lingxi-store-{}", uuid::Uuid::new_v4()));
        (WorkflowStore::new(root.clone()), root)
    }

    fn sample_workflow() -> Workflow {
        let mut workflow = Workflow::new("sample");
        workflow.nodes.push(WorkflowNode::new(
            "n1",
            "core.text_input",
            Position { x: 10.0, y: 20.0 },
        ));
        workflow
    }

    #[test]
    fn saves_and_loads_a_workflow() {
        let (store, root) = temp_store();
        let saved = store.save("我的流程", &sample_workflow()).unwrap();
        assert_eq!(saved.name, "我的流程");
        assert_eq!(saved.node_count, 1);

        let loaded = store.load("我的流程").unwrap();
        assert_eq!(loaded.name, "我的流程");
        assert_eq!(loaded.nodes.len(), 1);
        assert_eq!(loaded.nodes[0].kind, "core.text_input");

        let listed = store.list().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].node_count, 1);

        assert!(store.delete("我的流程").unwrap());
        assert!(store.list().unwrap().is_empty());
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn rejects_path_traversal_names() {
        let (store, root) = temp_store();
        for name in ["../escape", "a/b", ".hidden", "", "bad\name", "trailing."] {
            assert!(
                store.save(name, &sample_workflow()).is_err(),
                "accepted {name:?}"
            );
        }
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn list_is_empty_before_first_save() {
        let (store, root) = temp_store();
        assert!(store.list().unwrap().is_empty());
        assert!(!store.delete("missing").unwrap());
        fs::remove_dir_all(root).ok();
    }
}
