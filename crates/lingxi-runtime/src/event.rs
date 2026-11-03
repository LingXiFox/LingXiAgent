use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

use crate::interaction::{InteractionDecision, InteractionOption};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunCause {
    ValidationFailed,
    NodeFailed,
    Cancelled,
    EngineError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

/// Everything the UI needs to render a run. Events are emitted in order from a
/// single task, so consumers may rely on run.started arriving first and
/// run.finished arriving last.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all_fields = "camelCase")]
pub enum RunEvent {
    #[serde(rename = "run.started")]
    RunStarted {
        run_id: String,
        workflow_id: String,
        workflow_name: String,
        node_count: usize,
    },
    #[serde(rename = "node.started")]
    NodeStarted {
        run_id: String,
        node_id: String,
        kind: String,
        label: String,
        #[serde(default)]
        activation: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        iteration: Option<u32>,
    },
    #[serde(rename = "node.finished")]
    NodeFinished {
        run_id: String,
        node_id: String,
        kind: String,
        label: String,
        outputs: BTreeMap<String, Value>,
        duration_ms: u64,
        #[serde(default)]
        activation: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        iteration: Option<u32>,
    },
    #[serde(rename = "node.failed")]
    NodeFailed {
        run_id: String,
        node_id: String,
        kind: String,
        label: String,
        code: String,
        message: String,
        duration_ms: u64,
        #[serde(default)]
        activation: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        iteration: Option<u32>,
    },
    #[serde(rename = "node.skipped")]
    NodeSkipped {
        run_id: String,
        node_id: String,
        kind: String,
        label: String,
        reason: String,
        #[serde(default)]
        activation: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        iteration: Option<u32>,
    },
    #[serde(rename = "node.cancelled")]
    NodeCancelled {
        run_id: String,
        node_id: String,
        kind: String,
        label: String,
        #[serde(default)]
        activation: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        iteration: Option<u32>,
    },
    #[serde(rename = "log")]
    Log {
        run_id: String,
        seq: u64,
        at_ms: u64,
        level: LogLevel,
        node_id: Option<String>,
        message: String,
    },
    #[serde(rename = "interaction.requested")]
    InteractionRequested {
        run_id: String,
        request_id: String,
        node_id: String,
        prompt: String,
        options: Vec<InteractionOption>,
    },
    #[serde(rename = "interaction.resolved")]
    InteractionResolved {
        run_id: String,
        request_id: String,
        node_id: String,
        decision: InteractionDecision,
    },
    #[serde(rename = "run.finished")]
    RunFinished {
        run_id: String,
        status: RunStatus,
        cause: Option<RunCause>,
        detail: Option<String>,
        duration_ms: u64,
    },
}

impl RunEvent {
    pub fn run_id(&self) -> &str {
        match self {
            RunEvent::RunStarted { run_id, .. }
            | RunEvent::NodeStarted { run_id, .. }
            | RunEvent::NodeFinished { run_id, .. }
            | RunEvent::NodeFailed { run_id, .. }
            | RunEvent::NodeSkipped { run_id, .. }
            | RunEvent::NodeCancelled { run_id, .. }
            | RunEvent::Log { run_id, .. }
            | RunEvent::InteractionRequested { run_id, .. }
            | RunEvent::InteractionResolved { run_id, .. }
            | RunEvent::RunFinished { run_id, .. } => run_id,
        }
    }
}

/// Milliseconds since the Unix epoch, used on every log record.
pub fn unix_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

/// Synchronous sink. Implementations must not block; the desktop shell forwards
/// to the Tauri event system from here.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: RunEvent);
}

impl EventSink for tokio::sync::mpsc::UnboundedSender<RunEvent> {
    fn emit(&self, event: RunEvent) {
        let _ = self.send(event);
    }
}
