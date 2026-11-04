//! Per-run state shared by agent node executors. A fresh `RunServices` is
//! created for every engine execution, so two agents never share contexts,
//! provider handles, tool sets, budgets or MCP connections.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::Value;

use crate::conversation::{
    messages_from_json, tool_results_from_json, ContextSnapshot, ContextStore, OverflowPolicy,
    ToolResultRecord,
};
use crate::credentials::CredentialResolver;
use crate::error::{error_codes, NodeError};
use crate::mcp::McpManager;
use crate::permissions::PermissionManager;
use crate::provider::{ChatMessage, ProviderConfig};
use crate::skills::SkillLibrary;
use crate::tools::{BuiltinTools, ToolDefinition};

#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRecord {
    pub calls: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

impl UsageRecord {
    pub fn total_tokens(&self) -> u64 {
        self.prompt_tokens.saturating_add(self.completion_tokens)
    }
}

/// Host-level dependencies that survive between runs. Everything mutable is
/// created fresh for each run by `RunServices::new`.
#[derive(Clone)]
pub struct ServiceConfig {
    pub credentials: Arc<dyn CredentialResolver>,
    pub skills_root: Option<PathBuf>,
}

impl std::fmt::Debug for ServiceConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ServiceConfig")
            .field("skills_root", &self.skills_root)
            .finish_non_exhaustive()
    }
}

pub struct RunServices {
    pub credentials: Arc<dyn CredentialResolver>,
    pub permissions: PermissionManager,
    pub mcp: McpManager,
    skills: Option<SkillLibrary>,
    builtins: BuiltinTools,
    contexts: Mutex<ContextStore>,
    context_handles: Mutex<BTreeMap<String, String>>,
    providers: Mutex<BTreeMap<String, ProviderConfig>>,
    toolsets: Mutex<BTreeMap<String, Vec<ToolDefinition>>>,
    usage: Mutex<HashMap<String, UsageRecord>>,
}

impl RunServices {
    pub fn new(config: &ServiceConfig) -> Self {
        Self {
            credentials: Arc::clone(&config.credentials),
            permissions: PermissionManager::new(),
            mcp: McpManager::new(),
            skills: config
                .skills_root
                .clone()
                .map(SkillLibrary::new)
                .or_else(SkillLibrary::from_environment),
            builtins: BuiltinTools::new(),
            contexts: Mutex::new(ContextStore::default()),
            context_handles: Mutex::new(BTreeMap::new()),
            providers: Mutex::new(BTreeMap::new()),
            toolsets: Mutex::new(BTreeMap::new()),
            usage: Mutex::new(HashMap::new()),
        }
    }

    fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
        mutex
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn builtin_tools(&self) -> &BuiltinTools {
        &self.builtins
    }

    pub fn skills(&self) -> Option<&SkillLibrary> {
        self.skills.as_ref()
    }

    pub fn register_provider(&self, config: ProviderConfig) -> String {
        let handle = format!("prov-{}", uuid::Uuid::new_v4());
        Self::lock(&self.providers).insert(handle.clone(), config);
        handle
    }

    pub fn provider(&self, handle: &str) -> Result<ProviderConfig, NodeError> {
        Self::lock(&self.providers)
            .get(handle)
            .cloned()
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::PROVIDER_CONFIG,
                    format!("provider handle {handle:?} is not known in this run"),
                )
            })
    }

    pub fn register_toolset(&self, definitions: Vec<ToolDefinition>) -> Result<String, NodeError> {
        let mut names = HashSet::new();
        for definition in &definitions {
            if !names.insert(definition.name.clone()) {
                return Err(NodeError::new(
                    error_codes::TOOLSET_NAMESPACE_CONFLICT,
                    format!("duplicate tool name {:?}", definition.name),
                ));
            }
        }
        let handle = format!("toolset-{}", uuid::Uuid::new_v4());
        Self::lock(&self.toolsets).insert(handle.clone(), definitions);
        Ok(handle)
    }

    pub fn toolset(&self, handle: &str) -> Result<Vec<ToolDefinition>, NodeError> {
        Self::lock(&self.toolsets)
            .get(handle)
            .cloned()
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::TOOLSET_UNKNOWN_HANDLE,
                    format!("tool set handle {handle:?} is not known in this run"),
                )
            })
    }

    /// Applies the first activation as init and every later activation as an
    /// append/update to the same per-node context.
    // The arguments mirror the Context node's ports and budget params; grouping
    // only the budget half into a struct would obscure that mapping.
    #[allow(clippy::too_many_arguments)]
    pub fn update_context(
        &self,
        node_id: &str,
        initial: Option<&Value>,
        assistant: Option<&Value>,
        tool_results: Option<&Value>,
        max_messages: usize,
        max_tokens: u64,
        policy: OverflowPolicy,
    ) -> Result<ContextSnapshot, NodeError> {
        let mut handles = Self::lock(&self.context_handles);
        let mut contexts = Self::lock(&self.contexts);
        let existing = handles.get(node_id).cloned();
        let mut appended = Vec::new();
        if let Some(value) = assistant {
            if !value.is_null() {
                appended.extend(messages_from_json(value)?);
            }
        }
        let mut results: Vec<ToolResultRecord> = Vec::new();
        if let Some(value) = tool_results {
            if !value.is_null() {
                results = tool_results_from_json(value)?;
            }
        }
        match existing {
            Some(handle) => {
                let snapshot = contexts.update(
                    &handle,
                    appended,
                    results,
                    max_messages,
                    max_tokens,
                    policy,
                )?;
                Ok(snapshot)
            }
            None => {
                let messages = match initial {
                    Some(value) if !value.is_null() => messages_from_json(value)?,
                    _ => {
                        return Err(NodeError::new(
                            error_codes::CONTEXT_INVALID_MESSAGES,
                            "the first context activation needs initial messages",
                        ))
                    }
                };
                let initial_snapshot = contexts.init(messages, max_messages, max_tokens, policy)?;
                // The first activation may already carry an assistant turn and
                // its tool results; store them together with the prompt.
                let snapshot = if appended.is_empty() && results.is_empty() {
                    initial_snapshot
                } else {
                    contexts.update(
                        &initial_snapshot.handle,
                        appended,
                        results,
                        max_messages,
                        max_tokens,
                        policy,
                    )?
                };
                handles.insert(node_id.to_string(), snapshot.handle.clone());
                Ok(snapshot)
            }
        }
    }

    pub fn context_snapshot(&self, handle: &str) -> Result<ContextSnapshot, NodeError> {
        Self::lock(&self.contexts).snapshot(handle)
    }

    pub fn context_handle_for(&self, node_id: &str) -> Result<String, NodeError> {
        Self::lock(&self.context_handles)
            .get(node_id)
            .cloned()
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::CONTEXT_UNKNOWN_HANDLE,
                    format!("context for node {node_id:?} has not been initialized"),
                )
            })
    }

    pub fn usage(&self, node_id: &str) -> UsageRecord {
        Self::lock(&self.usage)
            .get(node_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Reserves one model call and fails before hitting the network when the
    /// call budget is exhausted.
    pub fn reserve_model_call(
        &self,
        node_id: &str,
        max_calls: u64,
    ) -> Result<UsageRecord, NodeError> {
        let mut usage = Self::lock(&self.usage);
        let record = usage.entry(node_id.to_string()).or_default();
        if record.calls >= max_calls {
            return Err(NodeError::new(
                error_codes::BUDGET_CALLS_EXHAUSTED,
                format!(
                    "model call budget exhausted after {} call(s) (maxCalls={max_calls})",
                    record.calls
                ),
            ));
        }
        record.calls += 1;
        Ok(record.clone())
    }

    pub fn record_tokens(
        &self,
        node_id: &str,
        prompt_tokens: u64,
        completion_tokens: u64,
        max_total: u64,
    ) -> Result<UsageRecord, NodeError> {
        let mut usage = Self::lock(&self.usage);
        let record = usage.entry(node_id.to_string()).or_default();
        record.prompt_tokens = record.prompt_tokens.saturating_add(prompt_tokens);
        record.completion_tokens = record.completion_tokens.saturating_add(completion_tokens);
        let total = record.total_tokens();
        if max_total > 0 && total > max_total {
            return Err(NodeError::new(
                error_codes::BUDGET_TOKENS_EXHAUSTED,
                format!("token budget exhausted: {total} tokens used, maxTotalTokens={max_total}"),
            ));
        }
        Ok(record.clone())
    }

    pub fn reset_usage(&self, node_id: &str) {
        Self::lock(&self.usage).remove(node_id);
    }

    pub fn cleanup(&self) {
        self.mcp.disconnect_all();
    }
}

/// Convenience used by the engine when the host did not configure services.
pub fn assistant_messages(system: Option<&str>, user: &str) -> Vec<ChatMessage> {
    let mut messages = Vec::new();
    if let Some(system) = system {
        if !system.trim().is_empty() {
            messages.push(ChatMessage::system(system));
        }
    }
    if !user.trim().is_empty() {
        messages.push(ChatMessage::user(user));
    }
    messages
}
