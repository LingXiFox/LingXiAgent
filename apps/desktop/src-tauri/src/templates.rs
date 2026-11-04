//! Local composite templates. A template is a dependency closure of subgraph
//! definitions rooted at one definition. Instances copy the closure, so later
//! template edits never mutate workflows that already used it.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use lingxi_spec::{AssetRef, Subgraph, COMPOSITE_NODE_KIND, SUBGRAPH_VERSION};
use serde::{Deserialize, Serialize};

use crate::store::validate_entry_name;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateBundle {
    pub root_id: String,
    pub subgraphs: BTreeMap<String, Subgraph>,
    /// Assets referenced by any node in the closure. Stored next to the
    /// template so an instance can keep using the same immutable blobs.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub assets: BTreeMap<String, AssetRef>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateSummary {
    pub id: String,
    pub name: String,
    pub node_count: usize,
    pub input_count: usize,
    pub output_count: usize,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone)]
pub struct TemplateStore {
    root: PathBuf,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TemplateFile {
    name: String,
    bundle: TemplateBundle,
}

impl TemplateStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Template ids are their validated, trimmed names: saving the same name
    /// replaces the template, and existing instances keep their copied closure.
    pub fn save(&self, name: &str, bundle: &TemplateBundle) -> Result<TemplateSummary, String> {
        let trimmed = name.trim();
        validate_entry_name(trimmed)?;
        validate_bundle(bundle)?;
        fs::create_dir_all(&self.root)
            .map_err(|error| format!("cannot create template directory: {error}"))?;
        let path = self.root.join(format!("{trimmed}.json"));
        let document = TemplateFile {
            name: trimmed.to_string(),
            bundle: bundle.clone(),
        };
        let json = serde_json::to_vec_pretty(&document)
            .map_err(|error| format!("cannot serialize template: {error}"))?;
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, &json).map_err(|error| format!("cannot write template: {error}"))?;
        crate::fsutil::replace_file(&temp_path, &path)
            .map_err(|error| format!("cannot commit template: {error}"))?;
        Ok(summary(trimmed, trimmed, bundle, now_ms()))
    }

    pub fn load(&self, id: &str) -> Result<TemplateBundle, String> {
        let path = self.path_for(id)?;
        let data = fs::read(&path).map_err(|error| format!("cannot read template: {error}"))?;
        let document: TemplateFile = serde_json::from_slice(&data)
            .map_err(|error| format!("template file is not valid JSON: {error}"))?;
        validate_bundle(&document.bundle)?;
        Ok(document.bundle)
    }

    pub fn list(&self) -> Result<Vec<TemplateSummary>, String> {
        if !self.root.exists() {
            return Ok(Vec::new());
        }
        let entries =
            fs::read_dir(&self.root).map_err(|error| format!("cannot list templates: {error}"))?;
        let mut summaries = Vec::new();
        for entry in entries {
            let Ok(entry) = entry else { continue };
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let Ok(data) = fs::read(&path) else { continue };
            let Ok(document) = serde_json::from_slice::<TemplateFile>(&data) else {
                continue;
            };
            if validate_bundle(&document.bundle).is_err() {
                continue;
            }
            let id = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or_default()
                .to_string();
            let updated_at_ms = fs::metadata(&path)
                .and_then(|metadata| metadata.modified())
                .ok()
                .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_millis() as u64)
                .unwrap_or_default();
            summaries.push(summary(
                &id,
                &document.name,
                &document.bundle,
                updated_at_ms,
            ));
        }
        summaries.sort_by_key(|summary| std::cmp::Reverse(summary.updated_at_ms));
        Ok(summaries)
    }

    pub fn delete(&self, id: &str) -> Result<bool, String> {
        let path = self.path_for(id)?;
        if path.exists() {
            fs::remove_file(&path).map_err(|error| format!("cannot delete template: {error}"))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn path_for(&self, id: &str) -> Result<PathBuf, String> {
        let trimmed = id.trim();
        validate_entry_name(trimmed)?;
        Ok(self.root.join(format!("{trimmed}.json")))
    }
}

fn summary(id: &str, name: &str, bundle: &TemplateBundle, updated_at_ms: u64) -> TemplateSummary {
    let root = bundle.subgraphs.get(&bundle.root_id);
    TemplateSummary {
        id: id.to_string(),
        name: name.to_string(),
        node_count: root
            .map(|subgraph| subgraph.workflow.nodes.len())
            .unwrap_or_default(),
        input_count: root
            .map(|subgraph| subgraph.inputs.len())
            .unwrap_or_default(),
        output_count: root
            .map(|subgraph| subgraph.outputs.len())
            .unwrap_or_default(),
        updated_at_ms,
    }
}

fn validate_bundle(bundle: &TemplateBundle) -> Result<(), String> {
    if bundle.root_id.trim().is_empty() {
        return Err("template root id must not be empty".to_string());
    }
    let root = bundle
        .subgraphs
        .get(&bundle.root_id)
        .ok_or_else(|| "template root definition is missing".to_string())?;
    for (key, subgraph) in &bundle.subgraphs {
        if key != &subgraph.id {
            return Err(format!(
                "template subgraph key {key:?} does not match its id"
            ));
        }
        if subgraph.version != SUBGRAPH_VERSION {
            return Err(format!(
                "template subgraph {} uses unsupported version {}",
                subgraph.id, subgraph.version
            ));
        }
    }
    for (key, asset) in &bundle.assets {
        if key != &asset.id {
            return Err(format!("template asset key {key:?} does not match its id"));
        }
        asset.validate()?;
    }
    for subgraph in bundle.subgraphs.values() {
        for node in &subgraph.workflow.nodes {
            if node.kind != COMPOSITE_NODE_KIND {
                continue;
            }
            let referenced = node
                .subgraph_id
                .as_deref()
                .ok_or_else(|| format!("composite node {} has no subgraph id", node.id))?;
            if !bundle.subgraphs.contains_key(referenced) {
                return Err(format!(
                    "composite node {} refers to unknown subgraph {referenced:?}",
                    node.id
                ));
            }
        }
    }
    // The root must be reachable and included by construction; nested
    // references were checked above, so a definition outside the root closure
    // is harmless but is not advertised as part of the template.
    let _ = root;
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
    use lingxi_spec::{Position, Subgraph, Workflow, WorkflowNode};

    fn temp_store() -> (TemplateStore, PathBuf) {
        let root = std::env::temp_dir().join(format!("lingxi-templates-{}", uuid::Uuid::new_v4()));
        (TemplateStore::new(root.clone()), root)
    }

    fn sample_bundle() -> TemplateBundle {
        let mut workflow = Workflow::new("inner");
        workflow.nodes.push(WorkflowNode::new(
            "inner-counter",
            "core.counter",
            Position { x: 0.0, y: 0.0 },
        ));
        let mut subgraphs = BTreeMap::new();
        subgraphs.insert(
            "sg-template".to_string(),
            Subgraph::new("sg-template", "Loop Template", workflow),
        );
        TemplateBundle {
            root_id: "sg-template".to_string(),
            subgraphs,
            assets: BTreeMap::new(),
        }
    }

    #[test]
    fn saves_lists_loads_and_deletes_a_template() {
        let (store, root) = temp_store();
        let saved = store.save("我的组合", &sample_bundle()).unwrap();
        assert_eq!(saved.id, "我的组合");
        assert_eq!(saved.node_count, 1);

        let listed = store.list().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "我的组合");
        assert_eq!(listed[0].input_count, 0);

        let loaded = store.load("我的组合").unwrap();
        assert_eq!(loaded.root_id, "sg-template");
        assert!(loaded.subgraphs.contains_key("sg-template"));

        assert!(store.delete("我的组合").unwrap());
        assert!(store.list().unwrap().is_empty());
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn rejects_unsafe_names_and_broken_closures() {
        let (store, root) = temp_store();
        for name in ["../escape", "a/b", ".hidden", "", "trailing."] {
            assert!(
                store.save(name, &sample_bundle()).is_err(),
                "accepted {name:?}"
            );
        }

        let mut missing_root = sample_bundle();
        missing_root.root_id = "sg-missing".to_string();
        assert!(store.save("broken", &missing_root).is_err());

        let mut dangling = sample_bundle();
        dangling
            .subgraphs
            .get_mut("sg-template")
            .unwrap()
            .workflow
            .nodes
            .push(WorkflowNode {
                subgraph_id: Some("sg-nope".to_string()),
                kind: COMPOSITE_NODE_KIND.to_string(),
                ..WorkflowNode::new("nested", COMPOSITE_NODE_KIND, Position::default())
            });
        assert!(store.save("dangling", &dangling).is_err());
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_saved_name_replaces_the_previous_template() {
        let (store, root) = temp_store();
        store.save("组合", &sample_bundle()).unwrap();
        let mut second = sample_bundle();
        second
            .subgraphs
            .get_mut("sg-template")
            .unwrap()
            .workflow
            .nodes
            .clear();
        store.save("组合", &second).unwrap();
        let listed = store.list().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].node_count, 0);
        fs::remove_dir_all(root).ok();
    }
}
