use std::fmt;

/// Namespaced error codes shared by the runtime, the desktop shell and the UI.
pub mod error_codes {
    pub const CAPABILITY_DENIED: &str = "capability.denied";
    pub const INVALID_PARAM: &str = "node.invalid_param";
    pub const INVALID_INPUT: &str = "node.invalid_input";
    pub const MISSING_INPUT: &str = "node.missing_input";
    pub const INTERACTION_DENIED: &str = "node.interaction_denied";
    pub const INTERACTION_TIMEOUT: &str = "node.interaction_timeout";
    pub const CANCELLED: &str = "node.cancelled";
    pub const EXECUTOR_FAILED: &str = "node.executor_failed";
    pub const LOOP_BUDGET_EXHAUSTED: &str = "loop.budget_exhausted";
    pub const LOOP_TIMEOUT: &str = "loop.timeout";
    pub const LOOP_INVALID_BUDGET: &str = "loop.invalid_budget";
    pub const LOOP_MISSING_TRIGGER: &str = "loop.missing_trigger";
    pub const LOOP_INVALID_STATE: &str = "loop.invalid_state";
    pub const SUBGRAPH_UNKNOWN_REFERENCE: &str = "subgraph.unknown_reference";
    pub const CAPABILITY_UNSUPPORTED: &str = "capability.unsupported";
    pub const CAPABILITY_UNAVAILABLE: &str = "capability.unavailable";
    pub const PROVIDER_AUTH: &str = "provider.auth";
    pub const PROVIDER_RATE_LIMITED: &str = "provider.rate_limited";
    pub const PROVIDER_HTTP: &str = "provider.http";
    pub const PROVIDER_TIMEOUT: &str = "provider.timeout";
    pub const PROVIDER_NETWORK: &str = "provider.network";
    pub const PROVIDER_INVALID_RESPONSE: &str = "provider.invalid_response";
    pub const PROVIDER_CONFIG: &str = "provider.invalid_config";
    pub const PROVIDER_MISSING_CREDENTIAL: &str = "provider.missing_credential";
    pub const MODEL_EMPTY_RESPONSE: &str = "model.empty_response";
    pub const CONTEXT_UNKNOWN_HANDLE: &str = "context.unknown_handle";
    pub const CONTEXT_INVALID_MESSAGES: &str = "context.invalid_messages";
    pub const CONTEXT_OVERFLOW: &str = "context.overflow";
    pub const TOOL_INVALID_ARGUMENTS: &str = "tool.invalid_arguments";
    pub const TOOL_UNKNOWN: &str = "tool.unknown";
    pub const TOOL_FAILED: &str = "tool.failed";
    pub const TOOL_TIMEOUT: &str = "tool.timeout";
    pub const TOOLSET_UNKNOWN_HANDLE: &str = "toolset.unknown_handle";
    pub const TOOLSET_NAMESPACE_CONFLICT: &str = "toolset.namespace_conflict";
    pub const MCP_CONNECT: &str = "mcp.connect";
    pub const MCP_PROTOCOL: &str = "mcp.protocol";
    pub const MCP_TIMEOUT: &str = "mcp.timeout";
    pub const MCP_CRASHED: &str = "mcp.crashed";
    pub const MCP_UNSUPPORTED: &str = "mcp.unsupported";
    pub const SKILL_NOT_FOUND: &str = "skill.not_found";
    pub const SKILL_INVALID: &str = "skill.invalid";
    pub const BUDGET_CALLS_EXHAUSTED: &str = "budget.calls_exhausted";
    pub const BUDGET_TOKENS_EXHAUSTED: &str = "budget.tokens_exhausted";
    pub const CREDENTIALS_UNAVAILABLE: &str = "credentials.unavailable";
    pub const CREDENTIALS_INVALID_REFERENCE: &str = "credentials.invalid_reference";
    pub const ASSET_READ: &str = "asset.read_failed";
    pub const ASSET_WRITE: &str = "asset.write_failed";
    pub const ASSET_IO: &str = "asset.io_failed";
    pub const ASSET_EMPTY: &str = "asset.empty";
    pub const ASSET_TOO_LARGE: &str = "asset.too_large";
    pub const ASSET_INVALID: &str = "asset.invalid";
    pub const ASSET_MISSING: &str = "asset.missing";
    pub const ASSET_UNSUPPORTED: &str = "asset.unsupported";
    pub const MODEL_UNSUPPORTED_MODALITY: &str = "model.unsupported_modality";
    pub const MODEL_UNSUPPORTED_REASONING: &str = "model.unsupported_reasoning";
    pub const MODEL_UNKNOWN_CAPABILITY: &str = "model.unknown_capability";
    pub const MEDIA_PROCESSING: &str = "media.processing_failed";
    pub const MEDIA_TOOL_MISSING: &str = "media.tool_missing";
    pub const PROVIDER_PERMISSION_REQUIRED: &str = "provider.permission_required";
    pub const AGENT_INVALID_CONFIG: &str = "agent.invalid_config";
    pub const AGENT_INVALID_BUDGET: &str = "agent.invalid_budget";
    pub const AGENT_INVALID_MESSAGE: &str = "agent.invalid_message";
    pub const AGENT_UNSUPPORTED_PROTOCOL: &str = "agent.unsupported_protocol";
    pub const AGENT_INVALID_ARTIFACT: &str = "agent.invalid_artifact";
    pub const AGENT_INVALID_RESULT: &str = "agent.invalid_result";
    pub const AGENT_MESSAGE_TOO_LARGE: &str = "agent.message_too_large";
    pub const AGENT_ITERATION_BUDGET: &str = "agent.iteration_budget";
    pub const AGENT_TOOL_BUDGET: &str = "agent.tool_budget";
    pub const AGENT_TOKEN_BUDGET: &str = "agent.token_budget";
    pub const AGENT_TIMEOUT: &str = "agent.timeout";
    pub const AGENT_PAUSED: &str = "agent.paused";
    pub const BUS_DUPLICATE: &str = "bus.duplicate";
    pub const BUS_UNKNOWN_RECIPIENT: &str = "bus.unknown_recipient";
    pub const BUS_QUEUE_FULL: &str = "bus.queue_full";
    pub const BUS_FORBIDDEN: &str = "bus.forbidden";
    pub const WORKSPACE_PATH_ESCAPE: &str = "workspace.path_escape";
    pub const WORKSPACE_NOT_FOUND: &str = "workspace.not_found";
    pub const WORKSPACE_VERSION_CONFLICT: &str = "workspace.version_conflict";
    pub const WORKSPACE_IO: &str = "workspace.io";
    pub const LSP_NOT_FOUND: &str = "lsp.not_found";
    pub const LSP_PROTOCOL: &str = "lsp.protocol";
    pub const LSP_TIMEOUT: &str = "lsp.timeout";
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeError {
    pub code: String,
    pub message: String,
}

impl NodeError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn cancelled(message: impl Into<String>) -> Self {
        Self::new(error_codes::CANCELLED, message)
    }
}

pub(crate) fn json_type_name(value: &serde_json::Value) -> &'static str {
    match value {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "boolean",
        serde_json::Value::Number(_) => "number",
        serde_json::Value::String(_) => "text",
        serde_json::Value::Array(_) => "array",
        serde_json::Value::Object(_) => "object",
    }
}

impl fmt::Display for NodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for NodeError {}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RegistryError {
    #[error("node kind {kind:?} is already registered")]
    DuplicateKind { kind: String },
    #[error("node kind must not be empty")]
    EmptyKind,
}
