//! Versioned protocol shared by every Agent instance and by the Message Bus.
//!
//! The protocol deliberately stays independent from the execution engine: a
//! workflow can be serialized, persisted and inspected without a running
//! scheduler. Validation covers both this crate's typed fields and a small,
//! documented JSON Schema subset used for message payloads and tool results.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::error::{error_codes, NodeError};
use crate::event::ScopeFrame;

pub const AGENT_NODE_KIND: &str = "core.agent";
pub const AGENT_PROTOCOL_VERSION: &str = "1.0";
pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] = &["1.0"];
pub const MAX_ARTIFACT_REFS: usize = 64;
pub const MAX_MESSAGE_BYTES: usize = 512 * 1024;

pub mod states {
    pub const PENDING: &str = "pending";
    pub const RUNNING: &str = "running";
    pub const PAUSING: &str = "pausing";
    pub const PAUSED: &str = "paused";
    pub const WAITING_APPROVAL: &str = "waiting_approval";
    pub const BLOCKED: &str = "blocked";
    pub const COMPLETED: &str = "completed";
    pub const FAILED: &str = "failed";
    pub const CANCELLED: &str = "cancelled";
    pub const INTERRUPTED: &str = "interrupted";
}

pub mod message_kinds {
    pub const REQUEST: &str = "task.request";
    pub const HANDOFF: &str = "task.handoff";
    pub const RESULT: &str = "task.result";
    pub const FEEDBACK: &str = "task.feedback";
    pub const QUESTION: &str = "task.question";
    pub const BLOCKED: &str = "task.blocked";
    pub const PROGRESS: &str = "task.progress";
    pub const ALL: &[&str] = &[
        REQUEST, HANDOFF, RESULT, FEEDBACK, QUESTION, BLOCKED, PROGRESS,
    ];
}

pub mod message_status {
    pub const QUEUED: &str = "queued";
    pub const DELIVERED: &str = "delivered";
    pub const ACKNOWLEDGED: &str = "acknowledged";
    pub const COMPLETED: &str = "completed";
    pub const FAILED: &str = "failed";
    pub const REJECTED: &str = "rejected";
}

pub mod result_status {
    pub const COMPLETED: &str = "completed";
    pub const BLOCKED: &str = "blocked";
    pub const FAILED: &str = "failed";
}

pub mod config_status {
    pub const DRAFT: &str = "draft";
    pub const PENDING: &str = "pending";
    pub const APPLIED: &str = "applied";
    pub const REJECTED: &str = "rejected";
    pub const SUPERSEDED: &str = "superseded";
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

/// A stable instance id. The composite instance path is part of the id, so two
/// Agent nodes with the same display label never collapse into one instance.
pub fn agent_instance_id(run_id: &str, scope: &[ScopeFrame], node_id: &str) -> String {
    let mut path = String::new();
    for frame in scope {
        path.push_str(&frame.instance_id);
        path.push('/');
    }
    format!("agent:{run_id}:{path}{node_id}")
}

pub fn activation_id(instance_id: &str, index: u64) -> String {
    format!("{instance_id}#activation-{index}")
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentBudget {
    #[serde(default = "default_iterations")]
    pub max_iterations: u32,
    #[serde(default = "default_tool_calls")]
    pub max_tool_calls: u32,
    #[serde(default)]
    pub max_total_tokens: u64,
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
}

fn default_iterations() -> u32 {
    12
}
fn default_tool_calls() -> u32 {
    48
}
fn default_timeout() -> u64 {
    300_000
}

impl Default for AgentBudget {
    fn default() -> Self {
        Self {
            max_iterations: default_iterations(),
            max_tool_calls: default_tool_calls(),
            max_total_tokens: 0,
            timeout_ms: default_timeout(),
        }
    }
}

impl AgentBudget {
    /// Rejects configurations that would otherwise spin forever. A zero token
    /// cap means "unbounded by tokens", never "no execution".
    pub fn validate(&self) -> Result<(), NodeError> {
        if self.max_iterations == 0 {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_BUDGET,
                "maxIterations must be at least 1",
            ));
        }
        if self.max_tool_calls == 0 {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_BUDGET,
                "maxToolCalls must be at least 1",
            ));
        }
        if self.timeout_ms == 0 {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_BUDGET,
                "timeoutMs must be at least 1",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsage {
    pub iterations: u32,
    pub model_calls: u32,
    pub tool_calls: u32,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub elapsed_ms: u64,
}

impl AgentUsage {
    pub fn total_tokens(&self) -> u64 {
        self.prompt_tokens.saturating_add(self.completion_tokens)
    }
}

/// The immutable part of a configuration revision. Credentials and provider
/// handles never appear here; only stable handles and user-facing settings do.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentConfigSnapshot {
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub temperature: f64,
    #[serde(default)]
    pub reasoning: String,
    #[serde(default)]
    pub role_prompt: String,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default)]
    pub max_iterations: u32,
    #[serde(default)]
    pub max_tool_calls: u32,
    #[serde(default)]
    pub max_total_tokens: u64,
    #[serde(default)]
    pub timeout_ms: u64,
    #[serde(default)]
    pub toolset: Vec<String>,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default)]
    pub lsp: Vec<String>,
}

impl Default for AgentConfigSnapshot {
    fn default() -> Self {
        Self {
            revision: 0,
            model: "gpt-4o-mini".to_string(),
            temperature: 0.2,
            reasoning: "auto".to_string(),
            role_prompt: "You are a capable autonomous agent.".to_string(),
            system_prompt: String::new(),
            max_iterations: 12,
            max_tool_calls: 48,
            max_total_tokens: 0,
            timeout_ms: 300_000,
            toolset: Vec::new(),
            skills: Vec::new(),
            lsp: Vec::new(),
        }
    }
}

impl AgentConfigSnapshot {
    pub fn budget(&self) -> AgentBudget {
        AgentBudget {
            max_iterations: self.max_iterations,
            max_tool_calls: self.max_tool_calls,
            max_total_tokens: self.max_total_tokens,
            timeout_ms: self.timeout_ms,
        }
    }

    pub fn validate(&self) -> Result<(), NodeError> {
        self.budget().validate()?;
        if self.model.trim().is_empty() {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_CONFIG,
                "agent model must not be empty",
            ));
        }
        Ok(())
    }

    /// Returns the user-visible fields that differ, used by the apply preview
    /// and by the event log. Prompt bodies are summarised, never duplicated.
    pub fn diff(&self, next: &Self) -> Vec<ConfigChange> {
        let mut changes = Vec::new();
        macro_rules! scalar {
            ($field:ident, $label:literal) => {
                if self.$field != next.$field {
                    changes.push(ConfigChange {
                        field: $label.to_string(),
                        before: Value::String(self.$field.to_string()),
                        after: Value::String(next.$field.to_string()),
                    });
                }
            };
        }
        scalar!(model, "model");
        scalar!(reasoning, "reasoning");
        scalar!(temperature, "temperature");
        scalar!(max_iterations, "maxIterations");
        scalar!(max_tool_calls, "maxToolCalls");
        scalar!(max_total_tokens, "maxTotalTokens");
        scalar!(timeout_ms, "timeoutMs");
        for (field, before, after) in [
            ("rolePrompt", &self.role_prompt, &next.role_prompt),
            ("systemPrompt", &self.system_prompt, &next.system_prompt),
        ] {
            if before != after {
                changes.push(ConfigChange {
                    field: field.to_string(),
                    before: Value::String(summarize_prompt(before)),
                    after: Value::String(summarize_prompt(after)),
                });
            }
        }
        if self.toolset != next.toolset {
            changes.push(ConfigChange {
                field: "toolset".to_string(),
                before: json!(self.toolset),
                after: json!(next.toolset),
            });
        }
        if self.skills != next.skills {
            changes.push(ConfigChange {
                field: "skills".to_string(),
                before: json!(self.skills),
                after: json!(next.skills),
            });
        }
        if self.lsp != next.lsp {
            changes.push(ConfigChange {
                field: "lsp".to_string(),
                before: json!(self.lsp),
                after: json!(next.lsp),
            });
        }
        changes
    }
}

fn summarize_prompt(prompt: &str) -> String {
    let compact = prompt.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= 80 {
        compact
    } else {
        format!("{}…", compact.chars().take(79).collect::<String>())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigChange {
    pub field: String,
    pub before: Value,
    pub after: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentConfigRevision {
    pub revision: u64,
    pub status: String,
    pub applied_at_ms: Option<u64>,
    pub before: AgentConfigSnapshot,
    pub after: AgentConfigSnapshot,
    pub changes: Vec<ConfigChange>,
    #[serde(default)]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactRef {
    pub id: String,
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub mime: String,
    #[serde(default)]
    pub size: u64,
    #[serde(default)]
    pub digest: String,
    #[serde(default)]
    pub uri: Option<String>,
}

impl ArtifactRef {
    pub fn validate(&self) -> Result<(), NodeError> {
        if self.id.trim().is_empty() || self.name.trim().is_empty() {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_ARTIFACT,
                "artifact id and name must not be empty",
            ));
        }
        if !self.digest.is_empty()
            && (self.digest.len() != 64 || !self.digest.chars().all(|c| c.is_ascii_hexdigit()))
        {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_ARTIFACT,
                format!("artifact {:?} has an invalid sha256 digest", self.id),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskEnvelope {
    pub schema_version: String,
    pub task_id: String,
    pub session_id: String,
    #[serde(default)]
    pub parent_task_id: Option<String>,
    pub sender: String,
    pub recipient: String,
    pub instruction: String,
    #[serde(default)]
    pub artifacts: Vec<ArtifactRef>,
    #[serde(default)]
    pub budget: Option<AgentBudget>,
    #[serde(default)]
    pub correlation_id: Option<String>,
    pub idempotency_key: String,
    pub created_at_ms: u64,
    #[serde(default)]
    pub metadata: Value,
}

impl TaskEnvelope {
    pub fn validate(&self) -> Result<(), NodeError> {
        validate_version(&self.schema_version)?;
        require_text("taskId", &self.task_id)?;
        require_text("sessionId", &self.session_id)?;
        require_text("sender", &self.sender)?;
        require_text("recipient", &self.recipient)?;
        require_text("instruction", &self.instruction)?;
        require_text("idempotencyKey", &self.idempotency_key)?;
        validate_artifacts(&self.artifacts)?;
        if let Some(budget) = &self.budget {
            budget.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentMessageEnvelope {
    pub schema_version: String,
    pub message_id: String,
    pub task_id: String,
    pub sender: String,
    pub recipient: String,
    #[serde(rename = "type")]
    pub message_type: String,
    pub status: String,
    pub payload: Value,
    #[serde(default)]
    pub artifact_refs: Vec<ArtifactRef>,
    #[serde(default)]
    pub correlation_id: Option<String>,
    pub idempotency_key: String,
    pub created_at_ms: u64,
}

impl AgentMessageEnvelope {
    pub fn new(
        task_id: impl Into<String>,
        sender: impl Into<String>,
        recipient: impl Into<String>,
        message_type: impl Into<String>,
        payload: Value,
    ) -> Self {
        let message_id = format!("msg-{}", uuid::Uuid::new_v4());
        Self {
            schema_version: AGENT_PROTOCOL_VERSION.to_string(),
            message_id: message_id.clone(),
            task_id: task_id.into(),
            sender: sender.into(),
            recipient: recipient.into(),
            message_type: message_type.into(),
            status: message_status::QUEUED.to_string(),
            payload,
            artifact_refs: Vec::new(),
            correlation_id: None,
            idempotency_key: message_id,
            created_at_ms: now_ms(),
        }
    }

    pub fn validate(&self) -> Result<(), NodeError> {
        validate_version(&self.schema_version)?;
        for (name, value) in [
            ("messageId", &self.message_id),
            ("taskId", &self.task_id),
            ("sender", &self.sender),
            ("recipient", &self.recipient),
            ("idempotencyKey", &self.idempotency_key),
        ] {
            require_text(name, value)?;
        }
        if !message_kinds::ALL.contains(&self.message_type.as_str()) {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!("unsupported agent message type {:?}", self.message_type),
            ));
        }
        if ![
            message_status::QUEUED,
            message_status::DELIVERED,
            message_status::ACKNOWLEDGED,
            message_status::COMPLETED,
            message_status::FAILED,
            message_status::REJECTED,
        ]
        .contains(&self.status.as_str())
        {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!("unsupported agent message status {:?}", self.status),
            ));
        }
        validate_artifacts(&self.artifact_refs)?;
        let size = serde_json::to_vec(self)
            .map(|bytes| bytes.len())
            .unwrap_or(0);
        if size > MAX_MESSAGE_BYTES {
            return Err(NodeError::new(
                error_codes::AGENT_MESSAGE_TOO_LARGE,
                format!("agent message is {size} bytes; limit is {MAX_MESSAGE_BYTES}"),
            ));
        }
        let schema = message_payload_schema(&self.message_type).ok_or_else(|| {
            NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!("no payload schema for {:?}", self.message_type),
            )
        })?;
        let mut violations = Vec::new();
        validate_json_schema(&schema, &self.payload, "payload", &mut violations);
        if !violations.is_empty() {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!(
                    "agent message payload failed validation: {}",
                    violations.join("; ")
                ),
            ));
        }
        Ok(())
    }

    pub fn payload_text(&self, field: &str) -> Option<&str> {
        self.payload.get(field).and_then(Value::as_str)
    }
}

fn validate_version(version: &str) -> Result<(), NodeError> {
    if SUPPORTED_PROTOCOL_VERSIONS.contains(&version) {
        Ok(())
    } else {
        Err(NodeError::new(
            error_codes::AGENT_UNSUPPORTED_PROTOCOL,
            format!("unsupported agent protocol version {version:?}"),
        ))
    }
}

fn require_text(name: &str, value: &str) -> Result<(), NodeError> {
    if value.trim().is_empty() {
        Err(NodeError::new(
            error_codes::AGENT_INVALID_MESSAGE,
            format!("{name} must not be empty"),
        ))
    } else {
        Ok(())
    }
}

fn validate_artifacts(artifacts: &[ArtifactRef]) -> Result<(), NodeError> {
    if artifacts.len() > MAX_ARTIFACT_REFS {
        return Err(NodeError::new(
            error_codes::AGENT_INVALID_ARTIFACT,
            format!("at most {MAX_ARTIFACT_REFS} artifact references are allowed"),
        ));
    }
    for artifact in artifacts {
        artifact.validate()?;
    }
    Ok(())
}

/// The JSON Schema subset used by the protocol. It is intentionally small and
/// documented instead of silently accepting unknown keywords: type,
/// properties, required, additionalProperties, items, enum, minLength,
/// maxLength, minimum and maximum.
pub fn message_payload_schema(message_type: &str) -> Option<Value> {
    let schema = match message_type {
        message_kinds::REQUEST | message_kinds::HANDOFF => json!({
            "type": "object",
            "properties": {
                "instruction": {"type": "string", "minLength": 1},
                "context": {"type": ["object", "string", "null"]}
            },
            "required": ["instruction"],
            "additionalProperties": true
        }),
        message_kinds::RESULT => json!({
            "type": "object",
            "properties": {
                "summary": {"type": "string", "minLength": 1},
                "status": {"type": "string", "enum": ["completed", "blocked", "failed"]},
                "data": {"type": ["object", "array", "string", "null"]}
            },
            "required": ["summary", "status"],
            "additionalProperties": true
        }),
        message_kinds::FEEDBACK => json!({
            "type": "object",
            "properties": {
                "feedback": {"type": "string", "minLength": 1},
                "verdict": {"type": "string", "enum": ["pass", "fail", "revise"]}
            },
            "required": ["feedback"],
            "additionalProperties": true
        }),
        message_kinds::QUESTION => json!({
            "type": "object",
            "properties": {"question": {"type": "string", "minLength": 1}},
            "required": ["question"],
            "additionalProperties": true
        }),
        message_kinds::BLOCKED => json!({
            "type": "object",
            "properties": {"reason": {"type": "string", "minLength": 1}},
            "required": ["reason"],
            "additionalProperties": true
        }),
        message_kinds::PROGRESS => json!({
            "type": "object",
            "properties": {
                "step": {"type": "string", "minLength": 1},
                "percent": {"type": "number", "minimum": 0, "maximum": 100}
            },
            "required": ["step"],
            "additionalProperties": true
        }),
        _ => return None,
    };
    Some(schema)
}

pub fn validate_json_schema(
    schema: &Value,
    value: &Value,
    path: &str,
    violations: &mut Vec<String>,
) {
    let Some(object) = schema.as_object() else {
        violations.push(format!("{path}: schema is not an object"));
        return;
    };
    if let Some(expected) = object.get("type") {
        let allowed: Vec<&str> = match expected {
            Value::String(name) => vec![name.as_str()],
            Value::Array(names) => names.iter().filter_map(Value::as_str).collect(),
            _ => Vec::new(),
        };
        if !allowed.is_empty() && !allowed.iter().any(|name| type_matches(name, value)) {
            violations.push(format!(
                "{path}: expected {}, got {}",
                allowed.join("|"),
                json_type(value)
            ));
            return;
        }
    }
    if let Some(options) = object.get("enum").and_then(Value::as_array) {
        if !options.iter().any(|option| option == value) {
            violations.push(format!("{path}: value is not one of the allowed options"));
        }
    }
    if let Some(text) = value.as_str() {
        if let Some(min) = object.get("minLength").and_then(Value::as_u64) {
            if (text.chars().count() as u64) < min {
                violations.push(format!("{path}: shorter than minLength {min}"));
            }
        }
        if let Some(max) = object.get("maxLength").and_then(Value::as_u64) {
            if (text.chars().count() as u64) > max {
                violations.push(format!("{path}: longer than maxLength {max}"));
            }
        }
    }
    if let Some(number) = value.as_f64() {
        if let Some(min) = object.get("minimum").and_then(Value::as_f64) {
            if number < min {
                violations.push(format!("{path}: below minimum {min}"));
            }
        }
        if let Some(max) = object.get("maximum").and_then(Value::as_f64) {
            if number > max {
                violations.push(format!("{path}: above maximum {max}"));
            }
        }
    }
    if let Some(object_value) = value.as_object() {
        if let Some(required) = object.get("required").and_then(Value::as_array) {
            for key in required.iter().filter_map(Value::as_str) {
                if !object_value.contains_key(key) {
                    violations.push(format!("{path}: missing required property {key:?}"));
                }
            }
        }
        if let Some(properties) = object.get("properties").and_then(Value::as_object) {
            for (key, child_schema) in properties {
                if let Some(child) = object_value.get(key) {
                    validate_json_schema(child_schema, child, &format!("{path}.{key}"), violations);
                }
            }
        }
        if object.get("additionalProperties") == Some(&Value::Bool(false)) {
            let known: BTreeSet<&str> = object
                .get("properties")
                .and_then(Value::as_object)
                .map(|properties| properties.keys().map(String::as_str).collect())
                .unwrap_or_default();
            for key in object_value.keys() {
                if !known.contains(key.as_str()) {
                    violations.push(format!("{path}: unexpected property {key:?}"));
                }
            }
        }
    }
    if let (Some(items), Some(array)) = (object.get("items"), value.as_array()) {
        for (index, child) in array.iter().enumerate() {
            validate_json_schema(items, child, &format!("{path}[{index}]"), violations);
        }
    }
}

fn type_matches(name: &str, value: &Value) -> bool {
    match name {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "number" => value.is_number(),
        "integer" => value.as_i64().is_some() || value.as_u64().is_some(),
        "boolean" => value.is_boolean(),
        "null" => value.is_null(),
        _ => true,
    }
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// Final structured answer produced by the submit_result tool. The same
/// payload carries the machine-readable message and the human-readable report,
/// so a normal run never needs a second model call.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentResult {
    pub status: String,
    pub agent_message: Value,
    pub user_response: String,
    #[serde(default)]
    pub artifacts: Vec<ArtifactRef>,
    #[serde(default)]
    pub correlation_id: Option<String>,
}

impl AgentResult {
    pub fn schema() -> Value {
        json!({
            "type": "object",
            "properties": {
                "status": {"type": "string", "enum": ["completed", "blocked", "failed"]},
                "agentMessage": {"type": "object"},
                "userResponse": {"type": "string", "minLength": 1},
                "artifacts": {"type": "array", "items": {"type": "object"}},
                "correlationId": {"type": ["string", "null"]}
            },
            "required": ["status", "agentMessage", "userResponse"],
            "additionalProperties": false
        })
    }

    pub fn validate(&self) -> Result<(), NodeError> {
        let mut violations = Vec::new();
        validate_json_schema(
            &Self::schema(),
            &serde_json::to_value(self).unwrap_or(Value::Null),
            "$",
            &mut violations,
        );
        if !violations.is_empty() {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_RESULT,
                format!("agent result failed validation: {}", violations.join("; ")),
            ));
        }
        validate_artifacts(&self.artifacts)?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivationRecord {
    pub activation_id: String,
    pub index: u64,
    pub state: String,
    pub started_at_ms: u64,
    pub finished_at_ms: Option<u64>,
    pub config_revision: u64,
    #[serde(default)]
    pub iterations: u32,
    #[serde(default)]
    pub user_response: Option<String>,
    #[serde(default)]
    pub agent_message_id: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentInstance {
    pub instance_id: String,
    pub node_id: String,
    pub label: String,
    #[serde(default)]
    pub scope: Vec<ScopeFrame>,
    pub state: String,
    #[serde(default)]
    pub current_activation: Option<String>,
    #[serde(default)]
    pub activations: Vec<ActivationRecord>,
    pub config: AgentConfigSnapshot,
    #[serde(default)]
    pub config_revisions: Vec<AgentConfigRevision>,
    #[serde(default)]
    pub usage: AgentUsage,
    #[serde(default)]
    pub pending_directives: Vec<String>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
}

impl AgentInstance {
    pub fn new(
        instance_id: String,
        node_id: String,
        label: String,
        scope: Vec<ScopeFrame>,
        config: AgentConfigSnapshot,
    ) -> Self {
        let now = now_ms();
        Self {
            instance_id,
            node_id,
            label,
            scope,
            state: states::PENDING.to_string(),
            current_activation: None,
            activations: Vec::new(),
            config,
            config_revisions: Vec::new(),
            usage: AgentUsage::default(),
            pending_directives: Vec::new(),
            created_at_ms: now,
            updated_at_ms: now,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingReview {
    pub review_id: String,
    pub agent_instance_id: String,
    pub activation_id: String,
    pub tool_name: String,
    pub tool_call_id: String,
    pub reason: String,
    pub arguments: Value,
    pub created_at_ms: u64,
    pub resolved: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskSession {
    pub session_id: String,
    pub run_id: String,
    pub workflow_id: String,
    pub workflow_name: String,
    pub workflow_revision: u64,
    pub state: String,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    #[serde(default)]
    pub agents: BTreeMap<String, AgentInstance>,
    #[serde(default)]
    pub messages: Vec<AgentMessageEnvelope>,
    #[serde(default)]
    pub pending_reviews: Vec<PendingReview>,
    #[serde(default)]
    pub artifacts: Vec<ArtifactRef>,
}

impl TaskSession {
    pub fn new(run_id: &str, workflow_id: &str, workflow_name: &str) -> Self {
        let now = now_ms();
        Self {
            session_id: format!("session-{run_id}"),
            run_id: run_id.to_string(),
            workflow_id: workflow_id.to_string(),
            workflow_name: workflow_name.to_string(),
            workflow_revision: 1,
            state: states::PENDING.to_string(),
            created_at_ms: now,
            updated_at_ms: now,
            agents: BTreeMap::new(),
            messages: Vec::new(),
            pending_reviews: Vec::new(),
            artifacts: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> AgentMessageEnvelope {
        AgentMessageEnvelope::new(
            "task-1",
            "pm",
            "coder",
            message_kinds::REQUEST,
            json!({"instruction": "implement the parser"}),
        )
    }

    #[test]
    fn a_valid_message_round_trips_with_its_schema_version() {
        let message = request();
        message.validate().expect("valid");
        let encoded = serde_json::to_value(&message).expect("serialize");
        assert_eq!(encoded["schemaVersion"], AGENT_PROTOCOL_VERSION);
        assert_eq!(encoded["type"], "task.request");
        let decoded: AgentMessageEnvelope = serde_json::from_value(encoded).expect("decode");
        assert_eq!(decoded, message);
    }

    #[test]
    fn a_message_without_a_required_payload_is_rejected() {
        let mut message = request();
        message.payload = json!({"context": "missing instruction"});
        let error = message.validate().expect_err("must reject");
        assert_eq!(error.code, error_codes::AGENT_INVALID_MESSAGE);
        assert!(error.message.contains("instruction"));
    }

    #[test]
    fn unknown_protocol_versions_are_rejected() {
        let mut message = request();
        message.schema_version = "9.9".to_string();
        let error = message.validate().expect_err("must reject");
        assert_eq!(error.code, error_codes::AGENT_UNSUPPORTED_PROTOCOL);
    }

    #[test]
    fn an_agent_result_requires_both_outputs() {
        let result = AgentResult {
            status: "completed".to_string(),
            agent_message: json!({"summary": "done"}),
            user_response: "Finished the parser.".to_string(),
            artifacts: Vec::new(),
            correlation_id: None,
        };
        result.validate().expect("valid");
        let mut missing = result.clone();
        missing.user_response.clear();
        assert_eq!(
            missing.validate().expect_err("must reject").code,
            error_codes::AGENT_INVALID_RESULT
        );
    }

    #[test]
    fn config_diff_summarises_prompt_changes_instead_of_copying_them() {
        let before = AgentConfigSnapshot::default();
        let mut after = before.clone();
        after.model = "other".to_string();
        after.role_prompt = "A".repeat(200);
        let diff = before.diff(&after);
        assert_eq!(diff.len(), 2);
        let prompt = diff
            .iter()
            .find(|change| change.field == "rolePrompt")
            .unwrap();
        assert!(prompt.after.as_str().unwrap().ends_with('…'));
        assert!(prompt.after.as_str().unwrap().chars().count() <= 80);
    }

    #[test]
    fn instance_ids_include_every_composite_scope() {
        let scope = vec![ScopeFrame {
            instance_id: "comp-1".to_string(),
            subgraph_id: "sg-1".to_string(),
            label: "team".to_string(),
        }];
        let id = agent_instance_id("run-1", &scope, "agent-coder");
        assert!(id.contains("comp-1"));
        assert!(id.ends_with("agent-coder"));
        assert_ne!(id, agent_instance_id("run-1", &[], "agent-coder"));
    }
}
