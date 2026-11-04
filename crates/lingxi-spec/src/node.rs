//! Node Specification v1: the declarative contract a node kind exposes to the
//! editor, the validator and the runtime. Executors live in lingxi-runtime and
//! are bound to these specs through the registry.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fmt;

/// Capability names used by the runtime gate. Plugin nodes may declare custom
/// names; the policy layer decides what is allowed.
pub mod capabilities {
    /// The node needs to ask the user a question while the run is live.
    pub const INTERACTION: &str = "interaction";
    /// The node needs outbound network access (reserved).
    pub const NETWORK: &str = "network";
    /// The node needs to read or write files (reserved).
    pub const FILESYSTEM: &str = "filesystem";
    /// The node needs to spawn processes (reserved).
    pub const PROCESS: &str = "process";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataType {
    Text,
    Number,
    Boolean,
    Json,
    /// A binary image or a list of image asset references.
    Image,
    /// A binary audio clip or a list of audio asset references.
    Audio,
    /// A binary video clip or sampled frames.
    Video,
    /// A document asset or its extracted text.
    Document,
    Any,
}

impl DataType {
    /// Returns true when a port of this type accepts a value produced by a
    /// port of the source type. Any is a wildcard on both sides; runtime
    /// values are still checked by the executors.
    pub fn accepts(self, source: DataType) -> bool {
        if self == DataType::Any || source == DataType::Any || self == source {
            return true;
        }
        // Media nodes emit a JSON part envelope, so a json port may consume a
        // media port intentionally (Context collects parts this way).
        self == DataType::Json && source.is_media()
    }

    /// True for the four modality ports introduced with the asset layer.
    pub fn is_media(self) -> bool {
        matches!(
            self,
            DataType::Image | DataType::Audio | DataType::Video | DataType::Document
        )
    }

    /// The wire name used in workflow JSON, asset MIME metadata and logs.
    pub fn as_str(self) -> &'static str {
        match self {
            DataType::Text => "text",
            DataType::Number => "number",
            DataType::Boolean => "boolean",
            DataType::Json => "json",
            DataType::Image => "image",
            DataType::Audio => "audio",
            DataType::Video => "video",
            DataType::Document => "document",
            DataType::Any => "any",
        }
    }
}

impl fmt::Display for DataType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// How the runtime treats a node beyond executing it once.
///
/// `Normal` nodes are ordinary data producers/consumers. `Branch` nodes route
/// exactly one of their control outputs. `LoopGate` nodes are driven by the
/// engine's loop controller and never by a normal executor.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlKind {
    #[default]
    Normal,
    Branch,
    LoopGate,
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ParamKind {
    Text,
    TextArea,
    Number,
    Boolean,
    Select,
    /// An ordered list of asset ids. The editor renders a picker and preview;
    /// the runtime resolves ids through the workflow asset table.
    Asset,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParamOption {
    pub value: String,
    pub label: String,
}

impl ParamOption {
    pub fn new(value: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            label: label.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortSpec {
    pub name: String,
    pub label: String,
    pub data_type: DataType,
    #[serde(default)]
    pub required: bool,
    /// True when this port carries an execution trigger rather than plain data.
    #[serde(default, skip_serializing_if = "is_false")]
    pub control: bool,
}

impl PortSpec {
    pub fn new(name: impl Into<String>, label: impl Into<String>, data_type: DataType) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            data_type,
            required: false,
            control: false,
        }
    }

    pub fn required(mut self) -> Self {
        self.required = true;
        self
    }

    pub fn control(mut self) -> Self {
        self.control = true;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParamSpec {
    pub name: String,
    pub label: String,
    pub kind: ParamKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_value: Option<Value>,
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub options: Vec<ParamOption>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub help: Option<String>,
}

impl ParamSpec {
    pub fn text(name: impl Into<String>, label: impl Into<String>, default: &str) -> Self {
        Self::with_default(
            name,
            label,
            ParamKind::Text,
            Some(Value::String(default.to_string())),
        )
    }

    pub fn text_area(name: impl Into<String>, label: impl Into<String>, default: &str) -> Self {
        Self::with_default(
            name,
            label,
            ParamKind::TextArea,
            Some(Value::String(default.to_string())),
        )
    }

    pub fn number(name: impl Into<String>, label: impl Into<String>, default: f64) -> Self {
        Self::with_default(name, label, ParamKind::Number, Some(Value::from(default)))
    }

    pub fn boolean(name: impl Into<String>, label: impl Into<String>, default: bool) -> Self {
        Self::with_default(name, label, ParamKind::Boolean, Some(Value::Bool(default)))
    }

    /// An ordered asset-id list parameter. The default is always an array so
    /// older documents without the key validate against the same shape.
    pub fn asset(name: impl Into<String>, label: impl Into<String>) -> Self {
        Self::with_default(
            name,
            label,
            ParamKind::Asset,
            Some(Value::Array(Vec::new())),
        )
    }

    pub fn select(
        name: impl Into<String>,
        label: impl Into<String>,
        default: &str,
        options: Vec<ParamOption>,
    ) -> Self {
        let mut spec = Self::with_default(
            name,
            label,
            ParamKind::Select,
            Some(Value::String(default.to_string())),
        );
        spec.options = options;
        spec
    }

    fn with_default(
        name: impl Into<String>,
        label: impl Into<String>,
        kind: ParamKind,
        default_value: Option<Value>,
    ) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            kind,
            default_value,
            required: false,
            options: Vec::new(),
            help: None,
        }
    }

    pub fn required(mut self) -> Self {
        self.required = true;
        self
    }

    pub fn help(mut self, help: impl Into<String>) -> Self {
        self.help = Some(help.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeSpec {
    pub kind: String,
    pub title: String,
    pub category: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub inputs: Vec<PortSpec>,
    #[serde(default)]
    pub outputs: Vec<PortSpec>,
    #[serde(default)]
    pub params: Vec<ParamSpec>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub control: ControlKind,
}

impl NodeSpec {
    pub fn new(kind: &str, title: &str, category: &str) -> Self {
        Self {
            kind: kind.to_string(),
            title: title.to_string(),
            category: category.to_string(),
            description: String::new(),
            inputs: Vec::new(),
            outputs: Vec::new(),
            params: Vec::new(),
            capabilities: Vec::new(),
            control: ControlKind::Normal,
        }
    }

    pub fn control(mut self, control: ControlKind) -> Self {
        self.control = control;
        self
    }

    pub fn description(mut self, description: impl Into<String>) -> Self {
        self.description = description.into();
        self
    }

    pub fn input(mut self, port: PortSpec) -> Self {
        self.inputs.push(port);
        self
    }

    pub fn output(mut self, port: PortSpec) -> Self {
        self.outputs.push(port);
        self
    }

    pub fn param(mut self, param: ParamSpec) -> Self {
        self.params.push(param);
        self
    }

    pub fn capability(mut self, capability: &str) -> Self {
        if !self
            .capabilities
            .iter()
            .any(|existing| existing == capability)
        {
            self.capabilities.push(capability.to_string());
        }
        self
    }

    pub fn input_port(&self, name: &str) -> Option<&PortSpec> {
        self.inputs.iter().find(|port| port.name == name)
    }

    pub fn output_port(&self, name: &str) -> Option<&PortSpec> {
        self.outputs.iter().find(|port| port.name == name)
    }

    pub fn param_spec(&self, name: &str) -> Option<&ParamSpec> {
        self.params.iter().find(|param| param.name == name)
    }
}

/// A simple immutable catalog used by tests and by tooling that only needs
/// validation, not execution.
#[derive(Debug, Clone, Default)]
pub struct StaticCatalog {
    specs: BTreeMap<String, NodeSpec>,
}

impl StaticCatalog {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, spec: NodeSpec) {
        self.specs.insert(spec.kind.clone(), spec);
    }

    pub fn with(specs: impl IntoIterator<Item = NodeSpec>) -> Self {
        let mut catalog = Self::new();
        for spec in specs {
            catalog.insert(spec);
        }
        catalog
    }
}

impl crate::validation::NodeKindResolver for StaticCatalog {
    fn node_spec(&self, kind: &str) -> Option<&NodeSpec> {
        self.specs.get(kind)
    }
}
