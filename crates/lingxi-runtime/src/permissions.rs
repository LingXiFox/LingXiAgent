//! Per-action authorization on top of the engine's declared capabilities.
//!
//! Declaring a capability never grants it. A run must additionally authorize
//! each concrete target (a provider host, an MCP command, a skill directory,
//! a tool that is not inherently safe). The first approval for a target is
//! remembered for the lifetime of the run, so a loop does not prompt again.

use std::collections::HashSet;
use std::sync::{Mutex, MutexGuard};

use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::interaction::{InteractionDecision, InteractionOption};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionClass {
    Network,
    Process,
    Filesystem,
    Tool,
}

impl PermissionClass {
    fn key(self) -> &'static str {
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
    approved: Mutex<HashSet<String>>,
}

impl PermissionManager {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, HashSet<String>> {
        self.approved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn is_approved(&self, run_id: &str, class: PermissionClass, target: &str) -> bool {
        self.lock().contains(&approval_key(run_id, class, target))
    }

    /// Grants a target without a prompt. Only used by tests and by the host
    /// when the owner explicitly pre-authorized a target.
    pub fn pre_approve(&self, run_id: &str, class: PermissionClass, target: &str) {
        self.lock().insert(approval_key(run_id, class, target));
    }

    pub fn revoke_run(&self, run_id: &str) {
        let prefix = format!("{run_id}\u{1f}");
        self.lock().retain(|key| !key.starts_with(&prefix));
    }

    /// Requests authorization for one concrete target.
    ///
    /// `require_prompt == false` only skips the prompt for inherently safe
    /// local computation; callers must pass true for network, process,
    /// filesystem and any tool whose capability is not `compute`.
    pub async fn authorize(
        &self,
        ctx: &NodeContext<'_>,
        class: PermissionClass,
        target: &str,
        detail: &str,
        require_prompt: bool,
    ) -> Result<(), NodeError> {
        if !require_prompt {
            return Ok(());
        }
        if self.is_approved(ctx.run_id, class, target) {
            return Ok(());
        }

        let prompt = format!("Allow {} access to {target}?\n{detail}", class.key());
        let decision = ctx
            .request_interaction(
                prompt,
                vec![
                    InteractionOption {
                        value: "approve".to_string(),
                        label: "Allow for this run".to_string(),
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
                self.lock().insert(approval_key(ctx.run_id, class, target));
                ctx.log(
                    crate::event::LogLevel::Info,
                    format!("authorized {} target {target}", class.key()),
                );
                Ok(())
            }
            InteractionDecision::Rejected => Err(NodeError::new(
                error_codes::CAPABILITY_DENIED,
                format!(
                    "{} access to {target} was rejected by the user",
                    class.key()
                ),
            )),
        }
    }
}

fn approval_key(run_id: &str, class: PermissionClass, target: &str) -> String {
    format!("{run_id}\u{1f}{}\u{1f}{target}", class.key())
}
