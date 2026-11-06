//! `core.project_workspace`: binds a workflow to a registered project.
//!
//! The node outputs an opaque handle, never an absolute path. The host resolves
//! the handle when an Agent starts; a workflow JSON copied to another machine
//! therefore cannot smuggle a filesystem path into an Agent.

use async_trait::async_trait;
use lingxi_spec::{DataType, NodeSpec, ParamSpec, PortSpec};
use serde_json::{json, Value};

use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::registry::{NodeExecutor, NodeOutput, NodeRegistry};

pub const PROJECT_KIND: &str = "core.project_workspace";

pub fn register(registry: &mut NodeRegistry) {
    registry
        .register(spec(), Arc::new(ProjectWorkspace))
        .expect("project workspace kind is unique");
}

use std::sync::Arc;

pub fn spec() -> NodeSpec {
    NodeSpec::new(PROJECT_KIND, "Project Workspace", "Workspace")
        .description(
            "Binds the workflow to an opened project folder. Outputs an opaque workspace handle.",
        )
        .input(PortSpec::new("projectId", "Project", DataType::Text))
        .input(PortSpec::new("cwd", "Working directory", DataType::Text))
        .input(PortSpec::new("policy", "Access policy", DataType::Json))
        .output(PortSpec::new("workspace", "Workspace", DataType::Text))
        .output(PortSpec::new("project", "Project", DataType::Json))
        .output(PortSpec::new("metadata", "Metadata", DataType::Json))
        .output(PortSpec::new("ready", "Ready", DataType::Any).control())
        .param(
            ParamSpec::text("projectId", "Project id", "")
                .help("Stable id of a project registered by the desktop shell."),
        )
        .param(ParamSpec::text("cwd", "Working directory", ""))
        .param(ParamSpec::boolean(
            "showIgnored",
            "Show ignored files",
            false,
        ))
}

struct ProjectWorkspace;

#[async_trait]
impl NodeExecutor for ProjectWorkspace {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let project_id = ctx
            .input("projectId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
            .or_else(|| {
                ctx.param("projectId")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    .map(str::to_string)
            })
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::WORKSPACE_NOT_FOUND,
                    "project workspace has no project selected",
                )
            })?;
        let cwd = ctx
            .input("cwd")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| ctx.param("cwd").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        let catalog = ctx.services.workspace_catalog().ok_or_else(|| {
            NodeError::new(
                error_codes::WORKSPACE_NOT_FOUND,
                "no project catalog is attached to this run",
            )
        })?;
        let workspace = catalog.workspace_for_project(&project_id).ok_or_else(|| {
            NodeError::new(
                error_codes::WORKSPACE_NOT_FOUND,
                format!("project {project_id:?} is not open; select the folder again"),
            )
        })?;
        let handle = catalog
            .handles()
            .into_iter()
            .find(|handle| handle.project.project_id == project_id)
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::WORKSPACE_NOT_FOUND,
                    format!("project {project_id:?} has no workspace handle"),
                )
            })?;
        let entries = workspace.list(&cwd).unwrap_or_default();
        let metadata = json!({
            "projectId": handle.project.project_id,
            "name": handle.project.name,
            "cwd": handle.relative_cwd,
            "topLevelEntries": entries.len(),
            "git": workspace.is_git_repository(),
            "showIgnored": ctx.bool_param("showIgnored").unwrap_or(false),
        });
        ctx.log(
            crate::event::LogLevel::Info,
            format!("workspace bound to project {}", handle.project.name),
        );
        Ok(NodeOutput::new()
            .with("workspace", Value::String(handle.handle_id))
            .with(
                "project",
                serde_json::to_value(&handle.project).unwrap_or(Value::Null),
            )
            .with("metadata", metadata)
            .with("ready", Value::Bool(true)))
    }
}
