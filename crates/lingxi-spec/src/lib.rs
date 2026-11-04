//! Workflow document model, Node Specification v1 and structural validation.
//!
//! This crate is deliberately runtime-free: it can be shared by the desktop
//! shell, the runtime, tests and future tooling. Execution never lives here.

pub mod model;
pub mod node;
pub mod validation;

pub use model::{
    AssetKind, AssetRef, Edge, EdgeKind, PortBinding, Position, Subgraph, SubgraphInput,
    SubgraphOutput, Viewport, Workflow, WorkflowNode, COMPOSITE_NODE_KIND, SCHEMA_VERSION,
    SUBGRAPH_VERSION, SUPPORTED_SCHEMA_VERSIONS,
};
pub use node::{
    capabilities, ControlKind, DataType, NodeSpec, ParamKind, ParamOption, ParamSpec, PortSpec,
    StaticCatalog,
};
pub use validation::{
    codes, composite_specs, validate, NodeKindResolver, Severity, ValidationIssue, ValidationReport,
};
