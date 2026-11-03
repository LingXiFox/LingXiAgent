use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};
use tokio::sync::oneshot;

use crate::error::NodeError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InteractionDecision {
    Approved,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InteractionOption {
    pub value: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InteractionRequest {
    pub request_id: String,
    pub run_id: String,
    pub node_id: String,
    pub prompt: String,
    pub options: Vec<InteractionOption>,
}

/// The interaction bus. The runtime never talks to a window directly; the
/// desktop shell installs a broker that forwards requests to the UI.
#[async_trait]
pub trait InteractionBroker: Send + Sync {
    async fn request(&self, request: InteractionRequest) -> Result<InteractionDecision, NodeError>;

    /// Delivers a decision for a pending request. Returns false when the
    /// request is unknown, already resolved or already abandoned.
    fn resolve(&self, request_id: &str, decision: InteractionDecision) -> bool;
}

/// Default bus: requests wait in a map until the host calls resolve.
#[derive(Debug, Default)]
pub struct PendingInteractions {
    pending: Mutex<HashMap<String, oneshot::Sender<InteractionDecision>>>,
}

impl PendingInteractions {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<String, oneshot::Sender<InteractionDecision>>> {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn pending_count(&self) -> usize {
        self.lock().len()
    }

    pub fn resolve_pending(&self, request_id: &str, decision: InteractionDecision) -> bool {
        let sender = self.lock().remove(request_id);
        match sender {
            Some(sender) => sender.send(decision).is_ok(),
            None => false,
        }
    }
}

/// Removes an abandoned request when the waiting future is dropped, for
/// example because the run was cancelled.
struct RequestGuard<'a> {
    broker: &'a PendingInteractions,
    request_id: String,
}

impl Drop for RequestGuard<'_> {
    fn drop(&mut self) {
        self.broker.lock().remove(&self.request_id);
    }
}

#[async_trait]
impl InteractionBroker for PendingInteractions {
    async fn request(&self, request: InteractionRequest) -> Result<InteractionDecision, NodeError> {
        let (sender, receiver) = oneshot::channel();
        self.lock().insert(request.request_id.clone(), sender);
        let _guard = RequestGuard {
            broker: self,
            request_id: request.request_id.clone(),
        };
        receiver.await.map_err(|_| {
            NodeError::new(
                crate::error::error_codes::CANCELLED,
                "interaction request was abandoned before a decision arrived",
            )
        })
    }

    fn resolve(&self, request_id: &str, decision: InteractionDecision) -> bool {
        self.resolve_pending(request_id, decision)
    }
}
