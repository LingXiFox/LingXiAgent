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
