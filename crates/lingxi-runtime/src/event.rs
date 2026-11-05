use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

/// One level of composite nesting on an event. The stack is ordered outermost
/// first; inner node ids stay local to their definition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScopeFrame {
    pub instance_id: String,
    pub subgraph_id: String,
    pub label: String,
}

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

/// Events scoped to one AgentInstance/Activation. They carry the same run-wide
/// sequence as every other event so the workbench can merge them without a
/// second clock.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all_fields = "camelCase")]
pub enum AgentEvent {
    #[serde(rename = "agent.registered")]
    Registered {
        agent_instance_id: String,
        node_id: String,
        label: String,
        scope: Vec<ScopeFrame>,
        state: String,
        config: Box<crate::agent_protocol::AgentConfigSnapshot>,
    },
    #[serde(rename = "agent.state")]
    StateChanged {
        agent_instance_id: String,
        activation_id: Option<String>,
        state: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "agent.activation.started")]
    ActivationStarted {
        agent_instance_id: String,
        activation_id: String,
        index: u64,
        config_revision: u64,
    },
    #[serde(rename = "agent.activation.finished")]
    ActivationFinished {
        agent_instance_id: String,
        activation_id: String,
        state: String,
        usage: crate::agent_protocol::AgentUsage,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        user_response: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    #[serde(rename = "agent.message")]
    Message {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agent_instance_id: Option<String>,
        message: crate::agent_protocol::AgentMessageEnvelope,
    },
    #[serde(rename = "agent.delta")]
    Delta {
        agent_instance_id: String,
        activation_id: String,
        delta: String,
    },
    #[serde(rename = "agent.tool.started")]
    ToolStarted {
        agent_instance_id: String,
        activation_id: String,
        tool_call_id: String,
        tool_name: String,
        arguments: String,
    },
    #[serde(rename = "agent.tool.finished")]
    ToolFinished {
        agent_instance_id: String,
        activation_id: String,
        tool_call_id: String,
        tool_name: String,
        ok: bool,
        duration_ms: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        result: String,
    },
    #[serde(rename = "agent.config")]
    ConfigChanged {
        agent_instance_id: String,
        revision: Box<crate::agent_protocol::AgentConfigRevision>,
    },
    #[serde(rename = "agent.directive")]
    Directive {
        agent_instance_id: String,
        activation_id: String,
        text: String,
    },
    #[serde(rename = "agent.review")]
    Review {
        agent_instance_id: String,
        review: crate::agent_protocol::PendingReview,
    },
    #[serde(rename = "agent.usage")]
    Usage {
        agent_instance_id: String,
        usage: crate::agent_protocol::AgentUsage,
    },
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        at_ms: u64,
        level: LogLevel,
        node_id: Option<String>,
        message: String,
    },
    #[serde(rename = "model.delta")]
    ModelDelta {
        run_id: String,
        seq: u64,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        node_id: String,
        label: String,
        delta: String,
    },
    #[serde(rename = "tool.started")]
    ToolStarted {
        run_id: String,
        seq: u64,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        node_id: String,
        label: String,
        tool_call_id: String,
        tool_name: String,
        arguments: String,
    },
    #[serde(rename = "tool.finished")]
    ToolFinished {
        run_id: String,
        seq: u64,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        node_id: String,
        label: String,
        tool_call_id: String,
        tool_name: String,
        ok: bool,
        duration_ms: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        result: String,
    },
    #[serde(rename = "interaction.requested")]
    InteractionRequested {
        run_id: String,
        seq: u64,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        request_id: String,
        node_id: String,
        prompt: String,
        options: Vec<InteractionOption>,
    },
    #[serde(rename = "interaction.resolved")]
    InteractionResolved {
        run_id: String,
        seq: u64,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        request_id: String,
        node_id: String,
        decision: InteractionDecision,
    },
    #[serde(rename = "agent.event")]
    Agent {
        run_id: String,
        seq: u64,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        scope: Vec<ScopeFrame>,
        event: Box<AgentEvent>,
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
            | RunEvent::ModelDelta { run_id, .. }
            | RunEvent::ToolStarted { run_id, .. }
            | RunEvent::ToolFinished { run_id, .. }
            | RunEvent::InteractionRequested { run_id, .. }
            | RunEvent::InteractionResolved { run_id, .. }
            | RunEvent::Agent { run_id, .. }
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
            | RunEvent::ModelDelta { seq, .. }
            | RunEvent::ToolStarted { seq, .. }
            | RunEvent::ToolFinished { seq, .. }
            | RunEvent::InteractionRequested { seq, .. }
            | RunEvent::InteractionResolved { seq, .. }
            | RunEvent::Agent { seq, .. }
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
            | RunEvent::ModelDelta { seq, .. }
            | RunEvent::ToolStarted { seq, .. }
            | RunEvent::ToolFinished { seq, .. }
            | RunEvent::InteractionRequested { seq, .. }
            | RunEvent::InteractionResolved { seq, .. }
            | RunEvent::Agent { seq, .. }
            | RunEvent::RunFinished { seq, .. } => *seq = value,
        }
    }

    /// The scope stack for correlation. Top-level events return an empty slice.
    pub fn scope(&self) -> &[ScopeFrame] {
        match self {
            RunEvent::RunStarted { .. } | RunEvent::RunFinished { .. } => &[],
            RunEvent::NodeStarted { scope, .. }
            | RunEvent::NodeFinished { scope, .. }
            | RunEvent::NodeFailed { scope, .. }
            | RunEvent::NodeSkipped { scope, .. }
            | RunEvent::NodeCancelled { scope, .. }
            | RunEvent::Log { scope, .. }
            | RunEvent::ModelDelta { scope, .. }
            | RunEvent::ToolStarted { scope, .. }
            | RunEvent::ToolFinished { scope, .. }
            | RunEvent::InteractionRequested { scope, .. }
            | RunEvent::InteractionResolved { scope, .. }
            | RunEvent::Agent { scope, .. } => scope,
        }
    }

    pub fn scope_mut(&mut self) -> Option<&mut Vec<ScopeFrame>> {
        match self {
            RunEvent::RunStarted { .. } | RunEvent::RunFinished { .. } => None,
            RunEvent::NodeStarted { scope, .. }
            | RunEvent::NodeFinished { scope, .. }
            | RunEvent::NodeFailed { scope, .. }
            | RunEvent::NodeSkipped { scope, .. }
            | RunEvent::NodeCancelled { scope, .. }
            | RunEvent::Log { scope, .. }
            | RunEvent::ModelDelta { scope, .. }
            | RunEvent::ToolStarted { scope, .. }
            | RunEvent::ToolFinished { scope, .. }
            | RunEvent::InteractionRequested { scope, .. }
            | RunEvent::InteractionResolved { scope, .. }
            | RunEvent::Agent { scope, .. } => Some(scope),
        }
    }

    fn set_scope(&mut self, frames: Vec<ScopeFrame>) {
        match self {
            RunEvent::RunStarted { .. } | RunEvent::RunFinished { .. } => {}
            RunEvent::NodeStarted { scope, .. }
            | RunEvent::NodeFinished { scope, .. }
            | RunEvent::NodeFailed { scope, .. }
            | RunEvent::NodeSkipped { scope, .. }
            | RunEvent::NodeCancelled { scope, .. }
            | RunEvent::Log { scope, .. }
            | RunEvent::ModelDelta { scope, .. }
            | RunEvent::ToolStarted { scope, .. }
            | RunEvent::ToolFinished { scope, .. }
            | RunEvent::InteractionRequested { scope, .. }
            | RunEvent::InteractionResolved { scope, .. }
            | RunEvent::Agent { scope, .. } => *scope = frames,
        }
    }
}

/// Assigns the per-run sequence number exactly once, immediately before the
/// sink sees the event. Every event emitted by the runtime goes through this
/// type; sinks therefore never need to invent sequence numbers.
///
/// A scoped emitter shares the parent's sequence counter, so events from inside
/// a composite stay on the single run stream and keep exact ordering.
pub struct EventEmitter<'a> {
    sink: &'a dyn EventSink,
    next_seq: Arc<AtomicU64>,
    scope: Vec<ScopeFrame>,
}

impl<'a> EventEmitter<'a> {
    pub fn new(sink: &'a dyn EventSink) -> Self {
        Self {
            sink,
            next_seq: Arc::new(AtomicU64::new(0)),
            scope: Vec::new(),
        }
    }

    /// Creates an emitter for one composite activation. The returned emitter
    /// shares the run's sequence counter and appends one scope frame.
    pub fn fork(&self) -> Self {
        Self {
            sink: self.sink,
            next_seq: Arc::clone(&self.next_seq),
            scope: self.scope.clone(),
        }
    }

    pub fn scoped(&self, frame: ScopeFrame) -> Self {
        let mut scope = self.scope.clone();
        scope.push(frame);
        Self {
            sink: self.sink,
            next_seq: Arc::clone(&self.next_seq),
            scope,
        }
    }

    pub fn scope(&self) -> &[ScopeFrame] {
        &self.scope
    }

    pub fn allocate_seq(&self) -> u64 {
        self.next_seq.fetch_add(1, Ordering::SeqCst)
    }

    pub fn emit(&self, mut event: RunEvent) -> u64 {
        let seq = self.allocate_seq();
        event.set_seq(seq);
        event.set_scope(self.scope.clone());
        self.sink.emit(event);
        seq
    }

    /// Emits an event whose sequence number was allocated in advance (needed
    /// when the event payload, such as an interaction request id, embeds seq).
    pub fn emit_with_seq(&self, mut event: RunEvent, seq: u64) {
        event.set_seq(seq);
        event.set_scope(self.scope.clone());
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
            scope: Vec::new(),
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
