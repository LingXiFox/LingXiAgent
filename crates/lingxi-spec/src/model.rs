//! Serializable workflow document. The frontend and the runtime exchange only
//! this JSON shape; no editor-specific structure may leak into it.

use crate::node::PortSpec;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Version written by this build. Documents at older supported versions still load.
/// 1.2 adds the optional root `assets` table; no existing field changed shape.
pub const SCHEMA_VERSION: &str = "1.2";

/// Versions this build accepts. Every step only added optional fields.
pub const SUPPORTED_SCHEMA_VERSIONS: &[&str] = &["1.0", "1.1", "1.2"];

/// The only node kind whose ports come from a `Subgraph` definition.
pub const COMPOSITE_NODE_KIND: &str = "core.composite";

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
    /// Composite definitions live only on the root document. Internal workflows
    /// must keep this empty; nested composites reference this same map.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub subgraphs: BTreeMap<String, Subgraph>,
    /// Content-addressed media referenced by node params. Binary content is
    /// never inlined in this document; ids resolve through the local asset store.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub assets: BTreeMap<String, AssetRef>,
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
            subgraphs: BTreeMap::new(),
            assets: BTreeMap::new(),
        }
    }

    pub fn asset(&self, id: &str) -> Option<&AssetRef> {
        self.assets.get(id)
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
    /// Set on `core.composite` nodes; resolves through the root `subgraphs` map.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subgraph_id: Option<String>,
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
            subgraph_id: None,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssetKind {
    Image,
    Audio,
    Video,
    Document,
}

impl AssetKind {
    pub fn as_str(self) -> &'static str {
        match self {
            AssetKind::Image => "image",
            AssetKind::Audio => "audio",
            AssetKind::Video => "video",
            AssetKind::Document => "document",
        }
    }
}

/// A safe reference to one immutable local asset. `sha256` is both the storage
/// key and the integrity check; `id` is derived from it, so two workflows that
/// reference the same bytes share one file. No absolute path is serialized.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetRef {
    pub id: String,
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub sha256: String,
    pub kind: AssetKind,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub metadata: BTreeMap<String, Value>,
}

impl AssetRef {
    pub fn validate(&self) -> Result<(), String> {
        if self.id.trim().is_empty() {
            return Err("asset id must not be empty".to_string());
        }
        if self.sha256.len() != 64 || !self.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("asset {} has an invalid sha256", self.id));
        }
        if self.mime.trim().is_empty() {
            return Err(format!("asset {} has no mime type", self.id));
        }
        if self.size == 0 {
            return Err(format!("asset {} is empty", self.id));
        }
        Ok(())
    }
}

/// A composite definition. Internal node ids are scoped to `workflow`; the
/// definition id is global to the root document.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Subgraph {
    pub id: String,
    #[serde(default = "default_subgraph_version")]
    pub version: u32,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub workflow: Workflow,
    #[serde(default)]
    pub inputs: Vec<SubgraphInput>,
    #[serde(default)]
    pub outputs: Vec<SubgraphOutput>,
}

pub const SUBGRAPH_VERSION: u32 = 1;

fn default_subgraph_version() -> u32 {
    SUBGRAPH_VERSION
}

impl Subgraph {
    pub fn new(id: impl Into<String>, name: impl Into<String>, workflow: Workflow) -> Self {
        Self {
            id: id.into(),
            version: SUBGRAPH_VERSION,
            name: name.into(),
            description: None,
            workflow,
            inputs: Vec::new(),
            outputs: Vec::new(),
        }
    }
}

/// One external input port can feed several internal input ports.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubgraphInput {
    pub port: PortSpec,
    #[serde(default)]
    pub targets: Vec<PortBinding>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubgraphOutput {
    pub port: PortSpec,
    pub source: PortBinding,
}

/// A concrete internal endpoint plus the outer edge id it came from, when known.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortBinding {
    pub node_id: String,
    pub port: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edge_id: Option<String>,
}

impl PortBinding {
    pub fn new(node_id: impl Into<String>, port: impl Into<String>) -> Self {
        Self {
            node_id: node_id.into(),
            port: port.into(),
            edge_id: None,
        }
    }

    pub fn with_edge_id(mut self, edge_id: impl Into<String>) -> Self {
        self.edge_id = Some(edge_id.into());
        self
    }
}
