//! Node that registers a language-server definition for Agent capability sets.
//! It does not start a process; the AgentRunner starts and authorises the server
//! only when an Agent actually consumes the handle in an activation.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::lsp::LspConfig;
use crate::registry::{NodeExecutor, NodeOutput, NodeRegistry};
use lingxi_spec::{DataType, NodeSpec, ParamSpec, PortSpec};

pub const LSP_SERVER_KIND: &str = "core.lsp_server";

pub fn register(registry: &mut NodeRegistry) {
    registry
        .register(
            NodeSpec::new(LSP_SERVER_KIND, "LSP Server", "Capabilities")
                .description("Registers a language server for Agent diagnostics and symbols")
                .output(PortSpec::new("handle", "Handle", DataType::Text).required())
                .param(ParamSpec::text("command", "Command", "rust-analyzer"))
                .param(ParamSpec::text("args", "Arguments (JSON array)", "[]"))
                .param(ParamSpec::text("root", "Root (workspace-relative)", "")),
            Arc::new(LspServerNode),
        )
        .expect("LSP server node registers");
}

struct LspServerNode;

#[async_trait]
impl NodeExecutor for LspServerNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let command = ctx
            .string_param("command")
            .unwrap_or("rust-analyzer")
            .trim()
            .to_string();
        let raw_args = ctx.string_param("args").unwrap_or("[]").trim().to_string();
        let args: Vec<String> = if raw_args.is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(&raw_args).map_err(|error| {
                NodeError::new(
                    error_codes::LSP_PROTOCOL,
                    format!("LSP args must be a JSON string array: {error}"),
                )
            })?
        };
        let root = match ctx.string_param("root").unwrap_or("").trim() {
            "" => ctx
                .services
                .workspace()
                .map(|workspace| workspace.root().to_path_buf())
                .ok_or_else(|| {
                    NodeError::new(
                        error_codes::LSP_NOT_FOUND,
                        "LSP root is required when the run has no workspace",
                    )
                })?,
            relative => ctx
                .services
                .workspace()
                .ok_or_else(|| {
                    NodeError::new(
                        error_codes::LSP_NOT_FOUND,
                        "LSP root is relative but the run has no workspace",
                    )
                })?
                .resolve(relative)?,
        };
        let config = LspConfig::new(command, args, root);
        config.validate()?;
        let handle = ctx.services.register_lsp(config);
        ctx.log(
            crate::event::LogLevel::Info,
            format!("registered LSP server {handle}"),
        );
        Ok(NodeOutput::new().with("handle", Value::String(handle)))
    }
}
