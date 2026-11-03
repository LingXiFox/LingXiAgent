use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::interaction::{InteractionDecision, InteractionOption};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunCause {
    ValidationFailed,
    NodeFailed,
    Cancelled,
    EngineError,
    Interrupted,
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
        seq: u64,
        workflow_id: String,
        workflow_name: String,
        node_count: usize,
    },
    #[serde(rename = "node.started")]
    NodeStarted {
        run_id: String,
        seq: u64,
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
        seq: u64,
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
        seq: u64,
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
        seq: u64,
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
        seq: u64,
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
        seq: u64,
        request_id: String,
        node_id: String,
        prompt: String,
        options: Vec<InteractionOption>,
    },
    #[serde(rename = "interaction.resolved")]
    InteractionResolved {
        run_id: String,
        seq: u64,
        request_id: String,
        node_id: String,
        decision: InteractionDecision,
    },
    #[serde(rename = "run.finished")]
    RunFinished {
        run_id: String,
        seq: u64,
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

    /// Per-run monotonic sequence number. Consumers use it to deduplicate
    /// replay/live overlap and to detect gaps.
    pub fn seq(&self) -> u64 {
        match self {
            RunEvent::RunStarted { seq, .. }
            | RunEvent::NodeStarted { seq, .. }
            | RunEvent::NodeFinished { seq, .. }
            | RunEvent::NodeFailed { seq, .. }
            | RunEvent::NodeSkipped { seq, .. }
            | RunEvent::NodeCancelled { seq, .. }
            | RunEvent::Log { seq, .. }
            | RunEvent::InteractionRequested { seq, .. }
            | RunEvent::InteractionResolved { seq, .. }
            | RunEvent::RunFinished { seq, .. } => *seq,
        }
    }

    fn set_seq(&mut self, value: u64) {
        match self {
            RunEvent::RunStarted { seq, .. }
            | RunEvent::NodeStarted { seq, .. }
            | RunEvent::NodeFinished { seq, .. }
            | RunEvent::NodeFailed { seq, .. }
            | RunEvent::NodeSkipped { seq, .. }
            | RunEvent::NodeCancelled { seq, .. }
            | RunEvent::Log { seq, .. }
            | RunEvent::InteractionRequested { seq, .. }
            | RunEvent::InteractionResolved { seq, .. }
            | RunEvent::RunFinished { seq, .. } => *seq = value,
        }
    }
}

/// Assigns the per-run sequence number exactly once, immediately before the
/// sink sees the event. Every event emitted by the runtime goes through this
/// type; sinks therefore never need to invent sequence numbers.
pub struct EventEmitter<'a> {
    sink: &'a dyn EventSink,
    next_seq: AtomicU64,
}

impl<'a> EventEmitter<'a> {
    pub fn new(sink: &'a dyn EventSink) -> Self {
        Self {
            sink,
            next_seq: AtomicU64::new(0),
        }
    }

    pub fn allocate_seq(&self) -> u64 {
        self.next_seq.fetch_add(1, Ordering::SeqCst)
    }

    pub fn emit(&self, mut event: RunEvent) -> u64 {
        let seq = self.allocate_seq();
        event.set_seq(seq);
        self.sink.emit(event);
        seq
    }

    /// Emits an event whose sequence number was allocated in advance (needed
    /// when the event payload, such as an interaction request id, embeds seq).
    pub fn emit_with_seq(&self, mut event: RunEvent, seq: u64) {
        event.set_seq(seq);
        self.sink.emit(event);
    }

    pub fn log(
        &self,
        run_id: &str,
        level: LogLevel,
        node_id: Option<String>,
        message: impl Into<String>,
    ) {
        self.emit(RunEvent::Log {
            run_id: run_id.to_string(),
            seq: 0,
            at_ms: unix_millis(),
            level,
            node_id,
            message: message.into(),
        });
    }
}

/// Milliseconds since the Unix epoch, used on every log record.
pub fn unix_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

/// Synchronous sink. Implementations must be fast and non-blocking; the
/// desktop shell commits durable state before forwarding to the Tauri event
/// system. A sink never invents sequence numbers: `EventEmitter` assigns them.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: RunEvent);
}

impl EventSink for tokio::sync::mpsc::UnboundedSender<RunEvent> {
    fn emit(&self, event: RunEvent) {
        let _ = self.send(event);
    }
}
