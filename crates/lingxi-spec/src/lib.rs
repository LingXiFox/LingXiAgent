//! Workflow document model, Node Specification v1 and structural validation.
//!
//! This crate is deliberately runtime-free: it can be shared by the desktop
//! shell, the runtime, tests and future tooling. Execution never lives here.

pub mod model;
pub mod node;
pub mod validation;

pub use model::{Edge, Position, Viewport, Workflow, WorkflowNode, SCHEMA_VERSION};
pub use node::{
    capabilities, DataType, NodeSpec, ParamKind, ParamOption, ParamSpec, PortSpec, StaticCatalog,
};
pub use validation::{
    codes, validate, NodeKindResolver, Severity, ValidationIssue, ValidationReport,
};
