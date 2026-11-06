//! Per-action authorization on top of declared capabilities.
//!
//! Declaring a capability never grants it. Every concrete target is checked
//! against the active `PermissionMode` and the run's policy scope. `ask` is
//! the default and only auto-allows safe read-only project reads. `workspace`
//! additionally auto-allows writes inside the selected project and allowlisted
//! build commands. `yolo` is an explicit opt-in that auto-approves routine
//! project actions but still stops high-risk or out-of-scope operations.
//!
//! None of these modes sandbox arbitrary child processes. `workspace` means
//! "file tools stay in the project"; a spawned process can still touch anything
//! the user account can. The UI must say so.

use std::collections::HashMap;
use std::path::{Component, Path};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::interaction::{InteractionDecision, InteractionOption};

pub const WORKSPACE_COMMANDS: &[&str] = &[
    "cargo", "npm", "pnpm", "node", "python", "python3", "pytest", "npx", "go", "rustc", "dotnet",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum PermissionMode {
    #[default]
    Ask,
    Workspace,
    Yolo,
}

impl PermissionMode {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_lowercase().as_str() {
            "ask" => Some(Self::Ask),
            "workspace" => Some(Self::Workspace),
            "yolo" => Some(Self::Yolo),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Workspace => "workspace",
            Self::Yolo => "yolo",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionPolicy {
    pub run_id: String,
    pub project_id: Option<String>,
    pub session_id: Option<String>,
    pub mode: PermissionMode,
    /// Empty means every capability class is in scope.
    pub allowed_capabilities: Vec<String>,
    /// Empty means every target of an allowed class is in scope.
    pub allowed_targets: Vec<String>,
    pub expires_at_ms: Option<u64>,
    pub revision: u32,
}

impl PermissionPolicy {
    pub fn new(run_id: impl Into<String>, mode: PermissionMode) -> Self {
        Self {
            run_id: run_id.into(),
            project_id: None,
            session_id: None,
            mode,
            allowed_capabilities: Vec::new(),
            allowed_targets: Vec::new(),
            expires_at_ms: None,
            revision: 1,
        }
    }

    pub fn expired(&self, now_ms: u64) -> bool {
        self.expires_at_ms.is_some_and(|expiry| now_ms >= expiry)
    }

    fn allows_class(&self, class: PermissionClass) -> bool {
        self.allowed_capabilities.is_empty()
            || self
                .allowed_capabilities
                .iter()
                .any(|item| item == class.key())
    }

    fn allows_target(&self, target: &str) -> bool {
        self.allowed_targets.is_empty()
            || self
                .allowed_targets
                .iter()
                .any(|prefix| target == prefix || target.starts_with(&format!("{prefix}/")))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionAuditEntry {
    pub at_ms: u64,
    pub run_id: String,
    pub node_id: String,
    pub mode: PermissionMode,
    pub class: String,
    pub target: String,
    pub decision: String,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionClass {
    Network,
    Process,
    Filesystem,
    Tool,
}

impl PermissionClass {
    pub fn key(self) -> &'static str {
        match self {
            Self::Network => "network",
            Self::Process => "process",
            Self::Filesystem => "filesystem",
            Self::Tool => "tool",
        }
    }
}

#[derive(Debug, Default)]
pub struct PermissionManager {
    approved: Mutex<HashMap<String, u64>>,
    policies: Mutex<HashMap<String, PermissionPolicy>>,
    agent_modes: Mutex<HashMap<String, PermissionMode>>,
    audit: Mutex<Vec<PermissionAuditEntry>>,
}

impl PermissionManager {
    pub fn new() -> Self {
        Self::default()
    }

    fn approved_lock(&self) -> MutexGuard<'_, HashMap<String, u64>> {
        self.approved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn policy_lock(&self) -> MutexGuard<'_, HashMap<String, PermissionPolicy>> {
        self.policies
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn modes_lock(&self) -> MutexGuard<'_, HashMap<String, PermissionMode>> {
        self.agent_modes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn audit_lock(&self) -> MutexGuard<'_, Vec<PermissionAuditEntry>> {
        self.audit
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn set_policy(&self, policy: PermissionPolicy) {
        let previous = self
            .policy_lock()
            .insert(policy.run_id.clone(), policy.clone());
        self.record(
            &policy.run_id,
            "*",
            policy.mode,
            "policy",
            &policy.run_id,
            "policy.updated",
            &format!(
                "mode {} revision {} (previous revision {})",
                policy.mode.as_str(),
                policy.revision,
                previous.map(|item| item.revision).unwrap_or(0)
            ),
        );
    }

    pub fn set_mode(&self, run_id: &str, mode: PermissionMode) {
        let previous = self.policy_for(run_id).mode;
        let mut policies = self.policy_lock();
        match policies.get_mut(run_id) {
            Some(policy) => {
                policy.mode = mode;
                policy.revision = policy.revision.saturating_add(1);
            }
            None => {
                policies.insert(run_id.to_string(), PermissionPolicy::new(run_id, mode));
            }
        }
        drop(policies);
        // Cached approvals belong to the old mode. A live switch must make the
        // next operation follow the new policy instead of a stale grant.
        if previous != mode {
            self.clear_run_approvals(run_id);
        }
        self.record(
            run_id,
            "*",
            mode,
            "policy",
            run_id,
            "policy.mode",
            "permission mode changed live",
        );
    }

    /// An Agent node may tighten the run policy but cannot silently widen it.
    pub fn set_agent_mode(&self, run_id: &str, node_id: &str, mode: PermissionMode) {
        let current = self.mode_for(run_id, node_id);
        let effective = if mode as u8 > current as u8 {
            current
        } else {
            mode
        };
        self.modes_lock()
            .insert(format!("{run_id}\u{1f}{node_id}"), effective);
        if effective != current {
            self.clear_node_approvals(run_id, node_id);
            self.record(
                run_id,
                node_id,
                effective,
                "policy",
                node_id,
                "policy.agent",
                "agent node tightened its permission mode",
            );
        }
    }

    pub fn mode_for(&self, run_id: &str, node_id: &str) -> PermissionMode {
        if let Some(mode) = self
            .modes_lock()
            .get(&format!("{run_id}\u{1f}{node_id}"))
            .copied()
        {
            return mode;
        }
        self.policy_for(run_id).mode
    }

    pub fn policy_for(&self, run_id: &str) -> PermissionPolicy {
        let policy = self
            .policy_lock()
            .get(run_id)
            .cloned()
            .unwrap_or_else(|| PermissionPolicy::new(run_id, PermissionMode::Ask));
        if policy.expired(now_ms()) {
            let mut fallback = policy;
            fallback.mode = PermissionMode::Ask;
            return fallback;
        }
        policy
    }

    pub fn is_approved(&self, run_id: &str, class: PermissionClass, target: &str) -> bool {
        let now = now_ms();
        let key = format!("{run_id}\u{1f}*\u{1f}{}\u{1f}{target}", class.key());
        self.approved_lock()
            .get(&key)
            .is_some_and(|expiry| *expiry > now)
    }

    pub fn is_approved_for(
        &self,
        run_id: &str,
        node_id: &str,
        class: PermissionClass,
        target: &str,
    ) -> bool {
        let now = now_ms();
        let key = approval_key(run_id, node_id, class, target);
        let wildcard = format!("{run_id}\u{1f}*\u{1f}{}\u{1f}{target}", class.key());
        let approved = self.approved_lock();
        approved.get(&key).is_some_and(|expiry| *expiry > now)
            || approved.get(&wildcard).is_some_and(|expiry| *expiry > now)
    }

    /// Grants a target without a prompt. Used by tests and host-level
    /// pre-authorization.
    pub fn pre_approve(&self, run_id: &str, class: PermissionClass, target: &str) {
        self.pre_approve_until(run_id, class, target, u64::MAX);
    }

    pub fn pre_approve_until(
        &self,
        run_id: &str,
        class: PermissionClass,
        target: &str,
        expires_at_ms: u64,
    ) {
        let key = format!("{run_id}\u{1f}*\u{1f}{}\u{1f}{target}", class.key());
        self.approved_lock().insert(key, expires_at_ms);
    }

    fn clear_run_approvals(&self, run_id: &str) {
        let prefix = format!("{run_id}\u{1f}");
        self.approved_lock()
            .retain(|key, _| !key.starts_with(&prefix));
    }

    fn clear_node_approvals(&self, run_id: &str, node_id: &str) {
        let prefix = format!("{run_id}\u{1f}{node_id}\u{1f}");
        self.approved_lock()
            .retain(|key, _| !key.starts_with(&prefix));
    }

    pub fn revoke_run(&self, run_id: &str) {
        self.clear_run_approvals(run_id);
        self.policies
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(run_id);
        let prefix = format!("{run_id}\u{1f}");
        self.agent_modes
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .retain(|key, _| !key.starts_with(&prefix));
    }

    pub fn audit_for(&self, run_id: &str) -> Vec<PermissionAuditEntry> {
        self.audit_lock()
            .iter()
            .filter(|entry| entry.run_id == run_id)
            .cloned()
            .collect()
    }

    pub fn clear_audit(&self, run_id: &str) {
        self.audit_lock().retain(|entry| entry.run_id != run_id);
    }

    /// Requests authorization for one concrete target.
    ///
    /// `read_only == true` only affects the `ask` mode's safe project reads;
    /// callers must still pass true for every target that mutates state.
    pub async fn authorize(
        &self,
        ctx: &NodeContext<'_>,
        class: PermissionClass,
        target: &str,
        detail: &str,
        require_prompt: bool,
    ) -> Result<(), NodeError> {
        self.authorize_with(ctx, class, target, detail, require_prompt, false)
            .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn authorize_with(
        &self,
        ctx: &NodeContext<'_>,
        class: PermissionClass,
        target: &str,
        detail: &str,
        require_prompt: bool,
        read_only: bool,
    ) -> Result<(), NodeError> {
        if !require_prompt {
            return Ok(());
        }
        let policy = self.policy_for(ctx.run_id);
        let mode = self.mode_for(ctx.run_id, &ctx.node.id);
        if !policy.allows_class(class) || !policy.allows_target(target) {
            self.record(
                ctx.run_id,
                &ctx.node.id,
                mode,
                class.key(),
                target,
                "denied",
                "target is outside the run policy scope",
            );
            return Err(NodeError::new(
                error_codes::CAPABILITY_DENIED,
                format!(
                    "{} access to {target} is outside the permission policy",
                    class.key()
                ),
            ));
        }
        if self.is_approved_for(ctx.run_id, &ctx.node.id, class, target) {
            return Ok(());
        }
        if self.auto_allowed(mode, class, target, read_only) {
            self.record(
                ctx.run_id,
                &ctx.node.id,
                mode,
                class.key(),
                target,
                "auto",
                detail,
            );
            return Ok(());
        }

        let prompt = format!(
            "Allow {} access to {target}?\n{detail}\nMode: {}",
            class.key(),
            mode.as_str()
        );
        let decision = ctx
            .request_interaction(
                prompt,
                vec![
                    InteractionOption {
                        value: "approve_once".to_string(),
                        label: "Allow once".to_string(),
                    },
                    InteractionOption {
                        value: "approve".to_string(),
                        label: "Allow for this session".to_string(),
                    },
                    InteractionOption {
                        value: "reject".to_string(),
                        label: "Reject".to_string(),
                    },
                ],
            )
            .await?;

        match decision {
            InteractionDecision::Approved => {
                let expiry = policy.expires_at_ms.unwrap_or(u64::MAX);
                self.approved_lock().insert(
                    approval_key(ctx.run_id, &ctx.node.id, class, target),
                    expiry,
                );
                self.record(
                    ctx.run_id,
                    &ctx.node.id,
                    mode,
                    class.key(),
                    target,
                    "approved",
                    detail,
                );
                ctx.log(
                    crate::event::LogLevel::Info,
                    format!("authorized {} target {target}", class.key()),
                );
                Ok(())
            }
            InteractionDecision::ApprovedOnce => {
                self.record(
                    ctx.run_id,
                    &ctx.node.id,
                    mode,
                    class.key(),
                    target,
                    "approved_once",
                    detail,
                );
                Ok(())
            }
            InteractionDecision::Rejected => {
                self.record(
                    ctx.run_id,
                    &ctx.node.id,
                    mode,
                    class.key(),
                    target,
                    "rejected",
                    detail,
                );
                Err(NodeError::new(
                    error_codes::CAPABILITY_DENIED,
                    format!(
                        "{} access to {target} was rejected by the user",
                        class.key()
                    ),
                ))
            }
        }
    }

    fn auto_allowed(
        &self,
        mode: PermissionMode,
        class: PermissionClass,
        target: &str,
        read_only: bool,
    ) -> bool {
        if sensitive_target(target) {
            return false;
        }
        match mode {
            PermissionMode::Ask => {
                class == PermissionClass::Filesystem && read_only && safe_relative(target)
            }
            PermissionMode::Workspace => {
                if class == PermissionClass::Filesystem {
                    return safe_relative(target);
                }
                if class == PermissionClass::Process {
                    return workspace_process_allowed(target);
                }
                false
            }
            PermissionMode::Yolo => {
                if high_risk_target(target) {
                    return false;
                }
                match class {
                    PermissionClass::Filesystem => safe_relative(target),
                    PermissionClass::Process => safe_process(target),
                    PermissionClass::Network => true,
                    PermissionClass::Tool => true,
                }
            }
        }
    }

    // Mirrors the persisted audit fields one-to-one; wrapping them in a
    // transient struct would only move the same arguments around.
    #[allow(clippy::too_many_arguments)]
    fn record(
        &self,
        run_id: &str,
        node_id: &str,
        mode: PermissionMode,
        class: &str,
        target: &str,
        decision: &str,
        detail: &str,
    ) {
        let mut audit = self.audit_lock();
        audit.push(PermissionAuditEntry {
            at_ms: now_ms(),
            run_id: run_id.to_string(),
            node_id: node_id.to_string(),
            mode,
            class: class.to_string(),
            target: target.to_string(),
            decision: decision.to_string(),
            detail: detail.to_string(),
        });
        if audit.len() > 2000 {
            let drain = audit.len() - 2000;
            audit.drain(0..drain);
        }
    }
}

fn approval_key(run_id: &str, node_id: &str, class: PermissionClass, target: &str) -> String {
    format!("{run_id}\u{1f}{node_id}\u{1f}{}\u{1f}{target}", class.key())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn safe_relative(target: &str) -> bool {
    let path = Path::new(target);
    !target.trim().is_empty()
        && !path.is_absolute()
        && !target.contains('\0')
        && path.components().all(|component| {
            !matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
}

fn safe_process(target: &str) -> bool {
    let command = target.split_whitespace().next().unwrap_or("");
    let name = Path::new(command)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    WORKSPACE_COMMANDS.contains(&name) && !high_risk_target(target)
}

/// Workspace mode is limited to project checks and builds. It does not turn
/// arbitrary interpreters or package installation into implicit code execution;
/// those still require an explicit prompt (or a separate YOLO opt-in).
fn workspace_process_allowed(target: &str) -> bool {
    if !safe_process(target) {
        return false;
    }
    let tokens: Vec<&str> = target.split_whitespace().collect();
    let command = Path::new(tokens.first().copied().unwrap_or(""))
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    let sub = tokens.get(1).copied().unwrap_or("");
    match command {
        "cargo" => matches!(
            sub,
            "test" | "check" | "build" | "clippy" | "fmt" | "metadata" | "tree" | "bench"
        ),
        "npm" | "pnpm" => {
            matches!(
                sub,
                "test" | "run" | "build" | "lint" | "check" | "typecheck"
            ) && !tokens
                .iter()
                .any(|token| matches!(*token, "install" | "add" | "publish" | "exec"))
        }
        "go" => matches!(sub, "test" | "build" | "vet"),
        "dotnet" => matches!(sub, "build" | "test"),
        "pytest" => true,
        "node" => sub == "--test",
        "python" | "python3" => sub == "-m" && tokens.get(2).copied() == Some("pytest"),
        _ => false,
    }
}

fn high_risk_target(target: &str) -> bool {
    let lower = target.to_lowercase();
    [
        "rm -rf",
        "rm -fr",
        "sudo ",
        "git push",
        "cargo publish",
        "cargo clean",
        "npm publish",
        "pnpm publish",
        "git reset --hard",
        "git clean -",
        "chmod 777",
        "mkfs",
        "shutdown",
        "reboot",
        "> /dev/",
        "curl | sh",
        "wget | sh",
        "del /f",
        "format ",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

fn sensitive_target(target: &str) -> bool {
    let lower = target.replace('\\', "/").to_lowercase();
    [
        ".env",
        ".ssh/",
        "id_rsa",
        "id_ed25519",
        ".aws/credentials",
        ".npmrc",
        ".pypirc",
        "secrets.",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_parse_and_tighten_monotonically() {
        assert_eq!(PermissionMode::parse("ASK"), Some(PermissionMode::Ask));
        assert_eq!(PermissionMode::parse("yolo"), Some(PermissionMode::Yolo));
        assert_eq!(PermissionMode::parse("sandbox"), None);
        let manager = PermissionManager::new();
        manager.set_policy(PermissionPolicy::new("run", PermissionMode::Yolo));
        manager.set_agent_mode("run", "agent", PermissionMode::Ask);
        assert_eq!(manager.mode_for("run", "agent"), PermissionMode::Ask);
        manager.set_agent_mode("run", "agent", PermissionMode::Yolo);
        assert_eq!(manager.mode_for("run", "agent"), PermissionMode::Ask);
    }

    #[test]
    fn changing_mode_drops_stale_approvals() {
        let manager = PermissionManager::new();
        manager.set_policy(PermissionPolicy::new("run", PermissionMode::Yolo));
        manager.pre_approve("run", PermissionClass::Filesystem, "src/lib.rs");
        assert!(manager.is_approved("run", PermissionClass::Filesystem, "src/lib.rs"));
        manager.set_mode("run", PermissionMode::Ask);
        assert!(
            !manager.is_approved("run", PermissionClass::Filesystem, "src/lib.rs"),
            "a grant made under yolo must not survive a live switch back to ask"
        );
        assert_eq!(manager.policy_for("run").mode, PermissionMode::Ask);
        assert!(manager
            .audit_for("run")
            .iter()
            .any(|entry| entry.decision == "policy.mode"));
    }

    #[test]
    fn approval_cache_expires() {
        let manager = PermissionManager::new();
        manager.pre_approve_until("run", PermissionClass::Process, "cargo test", now_ms() - 1);
        assert!(!manager.is_approved("run", PermissionClass::Process, "cargo test"));
    }

    #[test]
    fn unsafe_and_sensitive_targets_are_never_auto_allowed() {
        let manager = PermissionManager::new();
        assert!(!manager.auto_allowed(
            PermissionMode::Yolo,
            PermissionClass::Process,
            "git push origin main",
            false
        ));
        assert!(!manager.auto_allowed(
            PermissionMode::Workspace,
            PermissionClass::Filesystem,
            "../outside",
            false
        ));
        assert!(!manager.auto_allowed(
            PermissionMode::Yolo,
            PermissionClass::Filesystem,
            "src/.env",
            false
        ));
        assert!(manager.auto_allowed(
            PermissionMode::Workspace,
            PermissionClass::Filesystem,
            "src/lib.rs",
            false
        ));
        assert!(!manager.auto_allowed(
            PermissionMode::Workspace,
            PermissionClass::Network,
            "api.example.com",
            false
        ));
        assert!(manager.auto_allowed(
            PermissionMode::Workspace,
            PermissionClass::Process,
            "cargo test --workspace",
            false
        ));
        assert!(!manager.auto_allowed(
            PermissionMode::Workspace,
            PermissionClass::Process,
            "python3 -c 'print(1)'",
            false
        ));
        assert!(!manager.auto_allowed(
            PermissionMode::Workspace,
            PermissionClass::Process,
            "npm install",
            false
        ));
        assert!(!manager.auto_allowed(
            PermissionMode::Yolo,
            PermissionClass::Process,
            "cargo publish",
            false
        ));
    }
}
