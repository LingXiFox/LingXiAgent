//! Serializable workflow document. The frontend and the runtime exchange only
//! this JSON shape; no editor-specific structure may leak into it.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Version of the workflow document schema understood by this build.
pub const SCHEMA_VERSION: &str = "1.0";

fn default_schema_version() -> String {
    SCHEMA_VERSION.to_string()
}

fn default_enabled() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workflow {
    #[serde(default = "default_schema_version")]
    pub schema_version: String,
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub nodes: Vec<WorkflowNode>,
    #[serde(default)]
    pub edges: Vec<Edge>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewport: Option<Viewport>,
    #[serde(default)]
    pub metadata: BTreeMap<String, Value>,
}

impl Workflow {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            schema_version: SCHEMA_VERSION.to_string(),
            id: new_document_id(),
            name: name.into(),
            description: String::new(),
            nodes: Vec::new(),
            edges: Vec::new(),
            viewport: None,
            metadata: BTreeMap::new(),
        }
    }

    pub fn node(&self, id: &str) -> Option<&WorkflowNode> {
        self.nodes.iter().find(|node| node.id == id)
    }

    pub fn incoming<'a>(&'a self, node_id: &'a str) -> impl Iterator<Item = &'a Edge> + 'a {
        self.edges.iter().filter(move |edge| edge.target == node_id)
    }

    pub fn outgoing<'a>(&'a self, node_id: &'a str) -> impl Iterator<Item = &'a Edge> + 'a {
        self.edges.iter().filter(move |edge| edge.source == node_id)
    }
}

/// Document ids only need to be unique inside one install; the desktop shell
/// supplies UUIDs for run ids, this keeps the spec crate dependency-free.
fn new_document_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    format!("wf-{nanos:x}-{n:x}")
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowNode {
    pub id: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default)]
    pub position: Position,
    #[serde(default)]
    pub params: BTreeMap<String, Value>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

impl WorkflowNode {
    pub fn new(id: impl Into<String>, kind: impl Into<String>, position: Position) -> Self {
        Self {
            id: id.into(),
            kind: kind.into(),
            label: None,
            position,
            params: BTreeMap::new(),
            enabled: true,
        }
    }

    pub fn display_name(&self, spec: Option<&crate::node::NodeSpec>) -> String {
        self.label
            .clone()
            .filter(|label| !label.trim().is_empty())
            .or_else(|| spec.map(|s| s.title.clone()))
            .unwrap_or_else(|| self.kind.clone())
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Position {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EdgeKind {
    #[default]
    Data,
    Control,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Edge {
    pub id: String,
    pub source: String,
    #[serde(default)]
    pub source_port: String,
    pub target: String,
    #[serde(default)]
    pub target_port: String,
    /// Data edges carry values; control edges additionally trigger execution.
    #[serde(default)]
    pub kind: EdgeKind,
}

impl Edge {
    pub fn new(
        source: impl Into<String>,
        source_port: impl Into<String>,
        target: impl Into<String>,
        target_port: impl Into<String>,
    ) -> Self {
        let source = source.into();
        let source_port = source_port.into();
        let target = target.into();
        let target_port = target_port.into();
        Self {
            id: format!("{source}:{source_port}->{target}:{target_port}"),
            source,
            source_port,
            target,
            target_port,
            kind: EdgeKind::Data,
        }
    }

    pub fn control(
        source: impl Into<String>,
        source_port: impl Into<String>,
        target: impl Into<String>,
        target_port: impl Into<String>,
    ) -> Self {
        Self {
            kind: EdgeKind::Control,
            ..Self::new(source, source_port, target, target_port)
        }
    }

    pub fn with_kind(mut self, kind: EdgeKind) -> Self {
        self.kind = kind;
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Viewport {
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default = "default_zoom")]
    pub zoom: f64,
}

fn default_zoom() -> f64 {
    1.0
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            zoom: 1.0,
        }
    }
}
