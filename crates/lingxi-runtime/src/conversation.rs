//! Per-run conversation state. Handles are opaque strings; the actual message
//! arrays never enter workflow JSON. Contexts are keyed by a fresh id and each
//! RunServices instance owns its own store, so two agent instances cannot see
//! each other's history.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{error_codes, NodeError};
use crate::provider::{ChatMessage, MessageRole};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolResultRecord {
    pub tool_call_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub error: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextSnapshot {
    pub handle: String,
    pub messages: Vec<ChatMessage>,
    pub count: usize,
    pub estimated_tokens: u64,
    pub trimmed: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverflowPolicy {
    TrimOldest,
    Error,
}

impl OverflowPolicy {
    pub fn parse(value: &str) -> Self {
        match value {
            "error" => Self::Error,
            _ => Self::TrimOldest,
        }
    }
}

#[derive(Debug, Clone)]
struct ContextEntry {
    messages: Vec<ChatMessage>,
}

#[derive(Debug, Default)]
pub struct ContextStore {
    entries: BTreeMap<String, ContextEntry>,
}

impl ContextStore {
    pub fn init(
        &mut self,
        messages: Vec<ChatMessage>,
        max_messages: usize,
        max_tokens: u64,
        policy: OverflowPolicy,
    ) -> Result<ContextSnapshot, NodeError> {
        if messages.is_empty() {
            return Err(NodeError::new(
                error_codes::CONTEXT_INVALID_MESSAGES,
                "initial context has no messages",
            ));
        }
        let handle = format!("ctx-{}", uuid::Uuid::new_v4());
        let mut entry = ContextEntry {
            messages: Vec::new(),
        };
        let mut trimmed = 0;
        for message in messages {
            trimmed += push_message(&mut entry, message, max_messages, max_tokens, policy)?;
        }
        let snapshot = snapshot_of(&handle, &entry, trimmed);
        self.entries.insert(handle, entry);
        Ok(snapshot)
    }

    pub fn update(
        &mut self,
        handle: &str,
        messages: Vec<ChatMessage>,
        tool_results: Vec<ToolResultRecord>,
        max_messages: usize,
        max_tokens: u64,
        policy: OverflowPolicy,
    ) -> Result<ContextSnapshot, NodeError> {
        let mut entry = self.entries.remove(handle).ok_or_else(|| {
            NodeError::new(
                error_codes::CONTEXT_UNKNOWN_HANDLE,
                format!("context handle {handle:?} is not known in this run"),
            )
        })?;
        let mut trimmed = 0;
        for message in messages {
            trimmed += push_message(&mut entry, message, max_messages, max_tokens, policy)?;
        }
        for result in tool_results {
            let content = if result.error {
                format!("ERROR: {}", result.content)
            } else {
                result.content
            };
            let mut message = ChatMessage::tool(result.tool_call_id, content);
            if !result.name.is_empty() {
                message.name = Some(result.name);
            }
            trimmed += push_message(&mut entry, message, max_messages, max_tokens, policy)?;
        }
        let snapshot = snapshot_of(handle, &entry, trimmed);
        self.entries.insert(handle.to_string(), entry);
        Ok(snapshot)
    }

    pub fn snapshot(&self, handle: &str) -> Result<ContextSnapshot, NodeError> {
        let entry = self.entries.get(handle).ok_or_else(|| {
            NodeError::new(
                error_codes::CONTEXT_UNKNOWN_HANDLE,
                format!("context handle {handle:?} is not known in this run"),
            )
        })?;
        Ok(snapshot_of(handle, entry, 0))
    }

    pub fn messages(&self, handle: &str) -> Result<Vec<ChatMessage>, NodeError> {
        Ok(self.snapshot(handle)?.messages)
    }
}

fn push_message(
    entry: &mut ContextEntry,
    message: ChatMessage,
    max_messages: usize,
    max_tokens: u64,
    policy: OverflowPolicy,
) -> Result<usize, NodeError> {
    entry.messages.push(message);
    enforce_limits(entry, max_messages, max_tokens, policy)
}

fn enforce_limits(
    entry: &mut ContextEntry,
    max_messages: usize,
    max_tokens: u64,
    policy: OverflowPolicy,
) -> Result<usize, NodeError> {
    let max_messages = max_messages.max(1);
    let max_tokens = max_tokens.max(1);
    let mut removed = 0;
    while entry.messages.len() > max_messages || estimate_tokens(&entry.messages) > max_tokens {
        if policy == OverflowPolicy::Error {
            return Err(NodeError::new(
                error_codes::CONTEXT_OVERFLOW,
                format!(
                    "context exceeds the configured limit ({} messages, {} estimated tokens)",
                    max_messages, max_tokens
                ),
            ));
        }
        let removable = entry
            .messages
            .iter()
            .position(|message| message.role != MessageRole::System);
        let Some(index) = removable else {
            return Err(NodeError::new(
                error_codes::CONTEXT_OVERFLOW,
                "context consists only of system messages and cannot be trimmed",
            ));
        };
        entry.messages.remove(index);
        removed += 1;
    }
    Ok(removed)
}

fn snapshot_of(handle: &str, entry: &ContextEntry, trimmed: usize) -> ContextSnapshot {
    ContextSnapshot {
        handle: handle.to_string(),
        messages: entry.messages.clone(),
        count: entry.messages.len(),
        estimated_tokens: estimate_tokens(&entry.messages),
        trimmed,
    }
}

pub fn estimate_tokens(messages: &[ChatMessage]) -> u64 {
    messages
        .iter()
        .map(|message| {
            4 + (message.content.char_count() as u64 / 4)
                + message
                    .tool_calls
                    .iter()
                    .map(|call| 8 + call.arguments.to_string().chars().count() as u64 / 4)
                    .sum::<u64>()
        })
        .sum()
}

pub fn messages_from_json(value: &Value) -> Result<Vec<ChatMessage>, NodeError> {
    serde_json::from_value(value.clone()).map_err(|error| {
        NodeError::new(
            error_codes::CONTEXT_INVALID_MESSAGES,
            format!("messages are not valid conversation messages: {error}"),
        )
    })
}

pub fn tool_results_from_json(value: &Value) -> Result<Vec<ToolResultRecord>, NodeError> {
    serde_json::from_value(value.clone()).map_err(|error| {
        NodeError::new(
            error_codes::TOOL_INVALID_ARGUMENTS,
            format!("tool results are not valid: {error}"),
        )
    })
}
