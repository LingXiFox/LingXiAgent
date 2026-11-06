//! Run-scoped Agent Message Bus and TaskSession registry.
//!
//! Every inter-Agent message passes through this type. The bus validates the
//! versioned envelope, checks sender/recipient membership, deduplicates,
//! persists messages in the session snapshot and enforces per-recipient queue
//! limits. The external user endpoint may receive results but has no inbox:
//! those messages are persisted and emitted for the UI, not queued.
//! Agents never receive direct access to another agent's context.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::agent_protocol::{
    activation_id, config_status, message_kinds, message_status, now_ms, states,
    AgentConfigRevision, AgentConfigSnapshot, AgentInstance, AgentMessageEnvelope, AgentUsage,
    ArtifactRef, PendingReview, TaskSession,
};
use crate::error::{error_codes, NodeError};

pub const DEFAULT_QUEUE_LIMIT: usize = 128;
pub const DEFAULT_MESSAGE_LIMIT: usize = 4_096;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Delivery {
    pub message: AgentMessageEnvelope,
    /// True when the idempotency key was already present. The existing message
    /// is returned and no second copy is queued.
    pub duplicate: bool,
}

#[derive(Debug, Default)]
pub struct AgentRuntime {
    paused: AtomicBool,
    cancelled: AtomicBool,
    notify: tokio::sync::Notify,
    pending_config: Mutex<Option<AgentConfigSnapshot>>,
    directives: Mutex<VecDeque<String>>,
}

impl AgentRuntime {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn pause(&self) {
        if !self.paused.swap(true, Ordering::SeqCst) {
            self.notify.notify_waiters();
        }
    }

    pub fn resume(&self) {
        if self.paused.swap(false, Ordering::SeqCst) {
            self.notify.notify_waiters();
        }
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    pub fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::SeqCst) {
            self.notify.notify_waiters();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    pub async fn wait_until_resumed(&self, run: &crate::control::RunControl) {
        while self.is_paused() && !self.is_cancelled() && !run.is_cancelled() {
            let notified = self.notify.notified();
            if !self.is_paused() || self.is_cancelled() || run.is_cancelled() {
                break;
            }
            tokio::select! {
                _ = notified => {}
                _ = run.cancelled() => break,
            }
        }
    }

    pub fn queue_directive(&self, text: impl Into<String>) {
        let text = text.into();
        if text.trim().is_empty() {
            return;
        }
        self.directives
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .push_back(text);
        self.notify.notify_waiters();
    }

    pub fn take_directives(&self) -> Vec<String> {
        let mut queue = self
            .directives
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        queue.drain(..).collect()
    }

    pub fn pending_config(&self) -> Option<AgentConfigSnapshot> {
        self.pending_config
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone()
    }

    pub fn take_pending_config(&self) -> Option<AgentConfigSnapshot> {
        self.pending_config
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .take()
    }

    pub fn set_pending_config(&self, config: AgentConfigSnapshot) {
        *self
            .pending_config
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = Some(config);
        self.notify.notify_waiters();
    }
}

#[derive(Debug, Default)]
struct BusState {
    session: Option<TaskSession>,
    messages: BTreeMap<String, AgentMessageEnvelope>,
    idempotency: HashMap<String, String>,
    inbox: BTreeMap<String, VecDeque<String>>,
    delivered: HashSet<String>,
}

#[derive(Debug)]
pub struct AgentBus {
    state: Mutex<BusState>,
    controls: Mutex<HashMap<String, Arc<AgentRuntime>>>,
    queue_limit: usize,
    message_limit: usize,
}

impl AgentBus {
    pub fn new(session: TaskSession) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(BusState {
                session: Some(session),
                ..BusState::default()
            }),
            controls: Mutex::new(HashMap::new()),
            queue_limit: DEFAULT_QUEUE_LIMIT,
            message_limit: DEFAULT_MESSAGE_LIMIT,
        })
    }

    #[cfg(test)]
    pub fn with_limits(
        session: TaskSession,
        queue_limit: usize,
        message_limit: usize,
    ) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(BusState {
                session: Some(session),
                ..BusState::default()
            }),
            controls: Mutex::new(HashMap::new()),
            queue_limit,
            message_limit,
        })
    }

    fn lock(mutex: &Mutex<BusState>) -> MutexGuard<'_, BusState> {
        mutex.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    pub fn session(&self) -> TaskSession {
        Self::lock(&self.state)
            .session
            .clone()
            .unwrap_or_else(|| TaskSession::new("unknown", "unknown", "unknown"))
    }

    pub fn session_id(&self) -> String {
        self.session().session_id
    }

    /// Registers an instance once. A repeated registration for the same id
    /// keeps the existing activation history and only refreshes display data.
    pub fn register_instance(&self, instance: AgentInstance) -> bool {
        let mut state = Self::lock(&self.state);
        let Some(session) = state.session.as_mut() else {
            return false;
        };
        if let Some(existing) = session.agents.get_mut(&instance.instance_id) {
            existing.label = instance.label;
            existing.node_id = instance.node_id;
            existing.scope = instance.scope;
            existing.updated_at_ms = now_ms();
            return false;
        }
        let instance_id = instance.instance_id.clone();
        session.agents.insert(instance_id.clone(), instance);
        session.updated_at_ms = now_ms();
        self.controls().entry(instance_id).or_default();
        true
    }

    fn controls(&self) -> MutexGuard<'_, HashMap<String, Arc<AgentRuntime>>> {
        self.controls
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    pub fn runtime(&self, instance_id: &str) -> Option<Arc<AgentRuntime>> {
        self.controls().get(instance_id).cloned()
    }

    pub fn ensure_runtime(&self, instance_id: &str) -> Arc<AgentRuntime> {
        let mut controls = self.controls();
        controls.entry(instance_id.to_string()).or_default().clone()
    }

    pub fn pause_agent(&self, instance_id: &str) -> Result<(), NodeError> {
        let runtime = self.ensure_runtime(instance_id);
        runtime.pause();
        // The pause is only a request until the runner reaches a safe point.
        self.set_instance_state(instance_id, states::PAUSING)?;
        Ok(())
    }

    pub fn resume_agent(&self, instance_id: &str) -> Result<(), NodeError> {
        let runtime = self.ensure_runtime(instance_id);
        runtime.resume();
        let state = {
            let state = Self::lock(&self.state);
            state
                .session
                .as_ref()
                .and_then(|session| session.agents.get(instance_id))
                .map(|instance| instance.state.clone())
        };
        if matches!(
            state.as_deref(),
            Some(states::PAUSED) | Some(states::PAUSING)
        ) {
            self.set_instance_state(instance_id, states::RUNNING)?;
        }
        Ok(())
    }

    pub fn cancel_agent(&self, instance_id: &str) -> Result<(), NodeError> {
        self.ensure_runtime(instance_id).cancel();
        Ok(())
    }

    pub fn set_instance_state(&self, instance_id: &str, value: &str) -> Result<(), NodeError> {
        let mut state = Self::lock(&self.state);
        let Some(session) = state.session.as_mut() else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                "no task session",
            ));
        };
        let Some(instance) = session.agents.get_mut(instance_id) else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                format!("agent instance {instance_id:?} is not registered"),
            ));
        };
        instance.state = value.to_string();
        instance.updated_at_ms = now_ms();
        if let Some(activation) = instance.current_activation.clone() {
            if let Some(record) = instance
                .activations
                .iter_mut()
                .find(|record| record.activation_id == activation)
            {
                record.state = value.to_string();
            }
        }
        update_session_state(session);
        Ok(())
    }

    pub fn start_activation(
        &self,
        instance_id: &str,
        config: &AgentConfigSnapshot,
    ) -> Result<String, NodeError> {
        let mut state = Self::lock(&self.state);
        let Some(session) = state.session.as_mut() else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                "no task session",
            ));
        };
        let Some(instance) = session.agents.get_mut(instance_id) else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                format!("agent instance {instance_id:?} is not registered"),
            ));
        };
        let index = instance.activations.len() as u64 + 1;
        let id = activation_id(instance_id, index);
        instance.current_activation = Some(id.clone());
        instance.state = states::RUNNING.to_string();
        instance.usage = AgentUsage::default();
        instance
            .activations
            .push(crate::agent_protocol::ActivationRecord {
                activation_id: id.clone(),
                index,
                state: states::RUNNING.to_string(),
                started_at_ms: now_ms(),
                finished_at_ms: None,
                config_revision: config.revision,
                iterations: 0,
                user_response: None,
                agent_message_id: None,
                error: None,
            });
        instance.updated_at_ms = now_ms();
        update_session_state(session);
        Ok(id)
    }

    // Kept as explicit fields so one call records the activation, its usage
    // and its terminal message atomically.
    #[allow(clippy::too_many_arguments)]
    pub fn finish_activation(
        &self,
        instance_id: &str,
        activation: &str,
        state_value: &str,
        usage: &AgentUsage,
        user_response: Option<&str>,
        agent_message_id: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), NodeError> {
        let mut state = Self::lock(&self.state);
        {
            let Some(session) = state.session.as_mut() else {
                return Ok(());
            };
            let Some(instance) = session.agents.get_mut(instance_id) else {
                return Ok(());
            };
            if let Some(record) = instance
                .activations
                .iter_mut()
                .find(|record| record.activation_id == activation)
            {
                record.state = state_value.to_string();
                record.finished_at_ms = Some(now_ms());
                record.iterations = usage.iterations;
                record.user_response = user_response.map(str::to_string);
                record.agent_message_id = agent_message_id.map(str::to_string);
                record.error = error.map(str::to_string);
            }
            instance.state = state_value.to_string();
            instance.usage = usage.clone();
            instance.updated_at_ms = now_ms();
            update_session_state(session);
        }
        if let Some(message_id) = agent_message_id {
            if let Some(message) = state.messages.get_mut(message_id) {
                message.status = message_status::COMPLETED.to_string();
            }
        }
        Ok(())
    }

    pub fn record_usage(
        &self,
        instance_id: &str,
        activation: &str,
        usage: &AgentUsage,
    ) -> Result<(), NodeError> {
        let mut state = Self::lock(&self.state);
        let Some(session) = state.session.as_mut() else {
            return Ok(());
        };
        let Some(instance) = session.agents.get_mut(instance_id) else {
            return Ok(());
        };
        instance.usage = usage.clone();
        instance.updated_at_ms = now_ms();
        if let Some(record) = instance
            .activations
            .iter_mut()
            .find(|record| record.activation_id == activation)
        {
            record.iterations = usage.iterations;
        }
        Ok(())
    }

    pub fn send(&self, message: AgentMessageEnvelope) -> Result<Delivery, NodeError> {
        message.validate()?;
        let mut state = Self::lock(&self.state);
        if state.session.is_none() {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                "no task session",
            ));
        }
        if let Some(existing) = state.idempotency.get(&message.idempotency_key).cloned() {
            let message =
                state.messages.get(&existing).cloned().ok_or_else(|| {
                    NodeError::new(error_codes::BUS_DUPLICATE, "duplicate message")
                })?;
            return Ok(Delivery {
                message,
                duplicate: true,
            });
        }
        if state.messages.contains_key(&message.message_id) {
            return Err(NodeError::new(
                error_codes::BUS_DUPLICATE,
                format!("message id {:?} already exists", message.message_id),
            ));
        }
        let recipients: Vec<String> = {
            let session = state.session.as_ref().expect("checked above");
            let known_sender = message.sender == "user"
                || message.sender == "workflow"
                || session.agents.contains_key(&message.sender);
            if !known_sender {
                return Err(NodeError::new(
                    error_codes::BUS_FORBIDDEN,
                    format!(
                        "sender {:?} is not a member of this task session",
                        message.sender
                    ),
                ));
            }
            if !session.agents.contains_key(&message.recipient)
                && message.recipient != "broadcast"
                && message.recipient != "user"
            {
                return Err(NodeError::new(
                    error_codes::BUS_UNKNOWN_RECIPIENT,
                    format!(
                        "recipient {:?} is not a member of this task session",
                        message.recipient
                    ),
                ));
            }
            if message.recipient == "broadcast" {
                session
                    .agents
                    .keys()
                    .filter(|id| id.as_str() != message.sender)
                    .cloned()
                    .collect()
            } else if message.recipient == "user" {
                // The user is an external observer. The message is persisted in
                // the session and emitted as an event, but there is no agent
                // runtime to drain an inbox for it.
                Vec::new()
            } else {
                vec![message.recipient.clone()]
            }
        };
        for id in &recipients {
            self.enqueue(&mut state, id, &message)?;
        }
        state
            .idempotency
            .insert(message.idempotency_key.clone(), message.message_id.clone());
        state
            .messages
            .insert(message.message_id.clone(), message.clone());
        let removed: Vec<String> = {
            let session = state.session.as_mut().expect("checked above");
            session.messages.push(message.clone());
            session.updated_at_ms = now_ms();
            if session.messages.len() > self.message_limit {
                let excess = session.messages.len() - self.message_limit;
                session
                    .messages
                    .drain(..excess)
                    .map(|message| message.message_id)
                    .collect()
            } else {
                Vec::new()
            }
        };
        for id in removed {
            state.messages.remove(&id);
        }
        Ok(Delivery {
            message,
            duplicate: false,
        })
    }

    fn enqueue(
        &self,
        state: &mut BusState,
        recipient: &str,
        message: &AgentMessageEnvelope,
    ) -> Result<(), NodeError> {
        let queue = state.inbox.entry(recipient.to_string()).or_default();
        if queue.len() >= self.queue_limit {
            return Err(NodeError::new(
                error_codes::BUS_QUEUE_FULL,
                format!(
                    "inbox for {recipient:?} is full ({} messages); retry after acknowledgement",
                    queue.len()
                ),
            ));
        }
        queue.push_back(message.message_id.clone());
        Ok(())
    }

    /// Returns queued messages and marks them delivered. A message is never
    /// returned twice unless the caller explicitly asks for re-delivery.
    pub fn receive(&self, recipient: &str, limit: usize) -> Vec<AgentMessageEnvelope> {
        let mut state = Self::lock(&self.state);
        let ids: Vec<String> = {
            let Some(queue) = state.inbox.get_mut(recipient) else {
                return Vec::new();
            };
            (0..limit.min(queue.len()))
                .filter_map(|_| queue.pop_front())
                .collect()
        };
        let mut output = Vec::new();
        for id in ids {
            let message = {
                let Some(message) = state.messages.get_mut(&id) else {
                    continue;
                };
                if message.status == message_status::QUEUED {
                    message.status = message_status::DELIVERED.to_string();
                }
                message.clone()
            };
            state.delivered.insert(id.clone());
            output.push(message);
        }
        if let Some(session) = state.session.as_mut() {
            for message in &output {
                if let Some(stored) = session
                    .messages
                    .iter_mut()
                    .find(|stored| stored.message_id == message.message_id)
                {
                    stored.status = message.status.clone();
                }
            }
        }
        output
    }

    pub fn acknowledge(&self, message_id: &str, status: &str) -> Result<(), NodeError> {
        if ![
            message_status::ACKNOWLEDGED,
            message_status::COMPLETED,
            message_status::FAILED,
            message_status::REJECTED,
        ]
        .contains(&status)
        {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!("invalid acknowledgement status {status:?}"),
            ));
        }
        let mut state = Self::lock(&self.state);
        let Some(message) = state.messages.get_mut(message_id) else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                format!("message {message_id:?} does not exist"),
            ));
        };
        message.status = status.to_string();
        if let Some(session) = state.session.as_mut() {
            if let Some(stored) = session
                .messages
                .iter_mut()
                .find(|stored| stored.message_id == message_id)
            {
                stored.status = status.to_string();
            }
        }
        Ok(())
    }

    pub fn messages_for(&self, instance_id: &str) -> Vec<AgentMessageEnvelope> {
        self.session()
            .messages
            .into_iter()
            .filter(|message| message.sender == instance_id || message.recipient == instance_id)
            .collect()
    }

    pub fn intervention(
        &self,
        instance_id: &str,
        text: &str,
    ) -> Result<AgentMessageEnvelope, NodeError> {
        if text.trim().is_empty() {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                "intervention text must not be empty",
            ));
        }
        let mut message = AgentMessageEnvelope::new(
            format!("task-{instance_id}"),
            "user",
            instance_id,
            message_kinds::FEEDBACK,
            json!({"feedback": text, "verdict": "revise"}),
        );
        message.correlation_id = Some(instance_id.to_string());
        let delivery = self.send(message)?;
        self.ensure_runtime(instance_id).queue_directive(text);
        Ok(delivery.message)
    }

    pub fn apply_config(
        &self,
        instance_id: &str,
        next: AgentConfigSnapshot,
        expected_revision: u64,
    ) -> Result<AgentConfigRevision, NodeError> {
        next.validate()?;
        let mut state = Self::lock(&self.state);
        let Some(session) = state.session.as_mut() else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                "no task session",
            ));
        };
        let Some(instance) = session.agents.get_mut(instance_id) else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                format!("agent instance {instance_id:?} is not registered"),
            ));
        };
        if instance.config.revision != expected_revision {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_CONFIG,
                format!(
                    "config revision is {}, expected {expected_revision}; reload before applying",
                    instance.config.revision
                ),
            ));
        }
        let before = instance.config.clone();
        let mut after = next;
        after.revision = before.revision + 1;
        let changes = before.diff(&after);
        if changes.is_empty() {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_CONFIG,
                "no effective configuration change",
            ));
        }
        let revision = AgentConfigRevision {
            revision: after.revision,
            status: config_status::PENDING.to_string(),
            applied_at_ms: None,
            before,
            after: after.clone(),
            changes,
            detail: None,
        };
        for existing in &mut instance.config_revisions {
            if existing.status == config_status::PENDING {
                existing.status = config_status::SUPERSEDED.to_string();
            }
        }
        instance.config_revisions.push(revision.clone());
        instance.updated_at_ms = now_ms();
        drop(state);
        self.ensure_runtime(instance_id).set_pending_config(after);
        Ok(revision)
    }

    pub fn mark_config_applied(
        &self,
        instance_id: &str,
        revision: u64,
    ) -> Result<AgentConfigSnapshot, NodeError> {
        let mut state = Self::lock(&self.state);
        let Some(session) = state.session.as_mut() else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                "no task session",
            ));
        };
        let Some(instance) = session.agents.get_mut(instance_id) else {
            return Err(NodeError::new(
                error_codes::BUS_UNKNOWN_RECIPIENT,
                format!("agent instance {instance_id:?} is not registered"),
            ));
        };
        let Some(change) = instance
            .config_revisions
            .iter_mut()
            .find(|change| change.revision == revision)
        else {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_CONFIG,
                format!("unknown config revision {revision}"),
            ));
        };
        let config = change.after.clone();
        change.status = config_status::APPLIED.to_string();
        change.applied_at_ms = Some(now_ms());
        instance.config = config.clone();
        instance.updated_at_ms = now_ms();
        Ok(config)
    }

    pub fn reject_config(&self, instance_id: &str, revision: u64, detail: &str) {
        if let Some(session) = Self::lock(&self.state).session.as_mut() {
            if let Some(instance) = session.agents.get_mut(instance_id) {
                if let Some(change) = instance
                    .config_revisions
                    .iter_mut()
                    .find(|change| change.revision == revision)
                {
                    change.status = config_status::REJECTED.to_string();
                    change.detail = Some(detail.to_string());
                }
            }
        }
    }

    pub fn add_review(
        &self,
        instance_id: &str,
        activation: &str,
        tool_name: &str,
        tool_call_id: &str,
        reason: &str,
        arguments: Value,
    ) -> PendingReview {
        let review = PendingReview {
            review_id: format!("review-{}", uuid::Uuid::new_v4()),
            agent_instance_id: instance_id.to_string(),
            activation_id: activation.to_string(),
            tool_name: tool_name.to_string(),
            tool_call_id: tool_call_id.to_string(),
            reason: reason.to_string(),
            arguments,
            created_at_ms: now_ms(),
            resolved: false,
        };
        if let Some(session) = Self::lock(&self.state).session.as_mut() {
            session.pending_reviews.push(review.clone());
            session.updated_at_ms = now_ms();
        }
        review
    }

    pub fn add_artifacts(&self, artifacts: &[ArtifactRef]) {
        if let Some(session) = Self::lock(&self.state).session.as_mut() {
            for artifact in artifacts {
                if !session
                    .artifacts
                    .iter()
                    .any(|existing| existing.id == artifact.id)
                {
                    session.artifacts.push(artifact.clone());
                }
            }
        }
    }

    pub fn complete_session(&self, state_value: &str) {
        if let Some(session) = Self::lock(&self.state).session.as_mut() {
            session.state = state_value.to_string();
            session.updated_at_ms = now_ms();
        }
    }
}

fn update_session_state(session: &mut TaskSession) {
    let states: Vec<&str> = session
        .agents
        .values()
        .map(|instance| instance.state.as_str())
        .collect();
    // The most actionable state wins when agents disagree, so the session never
    // looks completed while one member is still running or blocked.
    const PRIORITY: [&str; 8] = [
        states::RUNNING,
        states::WAITING_APPROVAL,
        states::PAUSED,
        states::PENDING,
        states::BLOCKED,
        states::FAILED,
        states::CANCELLED,
        states::INTERRUPTED,
    ];
    session.state = PRIORITY
        .iter()
        .find(|candidate| states.contains(candidate))
        .map(|state| (*state).to_string())
        .unwrap_or_else(|| states::COMPLETED.to_string());
    session.updated_at_ms = now_ms();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bus() -> Arc<AgentBus> {
        let bus = AgentBus::with_limits(TaskSession::new("run-1", "wf-1", "demo"), 2, 10);
        for name in ["pm", "coder", "tester"] {
            let id = format!("agent-{name}");
            bus.register_instance(AgentInstance::new(
                id.clone(),
                id.clone(),
                name.to_string(),
                Vec::new(),
                AgentConfigSnapshot::default(),
            ));
        }
        bus
    }

    fn request(from: &str, to: &str, key: &str) -> AgentMessageEnvelope {
        let mut message = AgentMessageEnvelope::new(
            "task-1",
            from,
            to,
            message_kinds::REQUEST,
            json!({"instruction": "do the work"}),
        );
        message.idempotency_key = key.to_string();
        message
    }

    #[test]
    fn an_idempotency_key_delivers_exactly_once() {
        let bus = bus();
        let first = bus
            .send(request("agent-pm", "agent-coder", "key-1"))
            .expect("first");
        assert!(!first.duplicate);
        let second = bus
            .send(request("agent-pm", "agent-coder", "key-1"))
            .expect("second");
        assert!(second.duplicate);
        assert_eq!(bus.receive("agent-coder", 10).len(), 1);
        assert!(bus.receive("agent-coder", 10).is_empty());
    }

    #[test]
    fn an_agent_cannot_send_to_a_non_member() {
        let bus = bus();
        let error = bus
            .send(request("agent-pm", "intruder", "key-1"))
            .expect_err("must reject");
        assert_eq!(error.code, error_codes::BUS_UNKNOWN_RECIPIENT);
    }

    #[test]
    fn results_can_be_addressed_to_the_external_user_without_an_inbox() {
        let bus = bus();
        for index in 0..3 {
            let mut message = AgentMessageEnvelope::new(
                "task-1",
                "agent-pm",
                "user",
                message_kinds::RESULT,
                json!({"summary": "done", "status": "completed"}),
            );
            message.idempotency_key = format!("result-{index}");
            bus.send(message).expect("user can receive results");
        }
        assert!(bus.receive("user", 10).is_empty());
        assert_eq!(
            bus.session().messages.len(),
            3,
            "user-addressed messages stay in the session transcript"
        );
    }

    #[test]
    fn an_agent_cannot_send_as_an_unregistered_sender() {
        let bus = bus();
        let error = bus
            .send(request("intruder", "agent-coder", "key-1"))
            .expect_err("must reject");
        assert_eq!(error.code, error_codes::BUS_FORBIDDEN);
    }

    #[test]
    fn a_full_inbox_applies_backpressure() {
        let bus = bus();
        bus.send(request("agent-pm", "agent-coder", "key-1"))
            .expect("one");
        bus.send(request("agent-pm", "agent-coder", "key-2"))
            .expect("two");
        let error = bus
            .send(request("agent-pm", "agent-coder", "key-3"))
            .expect_err("must reject");
        assert_eq!(error.code, error_codes::BUS_QUEUE_FULL);
    }

    #[test]
    fn a_config_revision_is_pending_until_the_runner_applies_it() {
        let bus = bus();
        let next = AgentConfigSnapshot {
            model: "other".to_string(),
            ..AgentConfigSnapshot::default()
        };
        let revision = bus
            .apply_config("agent-coder", next, 0)
            .expect("apply pending");
        assert_eq!(revision.status, config_status::PENDING);
        assert_eq!(
            bus.session().agents["agent-coder"].config.model,
            AgentConfigSnapshot::default().model
        );
        let applied = bus
            .mark_config_applied("agent-coder", revision.revision)
            .expect("apply");
        assert_eq!(applied.model, "other");
        assert_eq!(applied.revision, 1);
    }

    #[test]
    fn a_stale_config_revision_is_rejected() {
        let bus = bus();
        let next = AgentConfigSnapshot {
            model: "other".to_string(),
            ..AgentConfigSnapshot::default()
        };
        let error = bus
            .apply_config("agent-coder", next, 7)
            .expect_err("must reject");
        assert_eq!(error.code, error_codes::AGENT_INVALID_CONFIG);
    }
}
