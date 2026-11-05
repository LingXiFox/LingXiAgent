use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

use crate::agent_bus::AgentBus;

/// Cancellation and pause intent for one run. Cancellation is an intent, not a
/// failure: the engine reports it as a cancelled run and never fabricates a
/// failure. Pausing never discards completed work; executors observe it at
/// safe points.
#[derive(Debug, Default)]
pub struct RunControl {
    cancelled: AtomicBool,
    paused: AtomicBool,
    cancel_notify: Notify,
    pause_notify: Notify,
    agents: Mutex<Option<Arc<AgentBus>>>,
}

impl RunControl {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::SeqCst) {
            self.cancel_notify.notify_waiters();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Resolves once cancellation has been requested; returns immediately when
    /// it already happened.
    pub async fn cancelled(&self) {
        if self.is_cancelled() {
            return;
        }
        let notified = self.cancel_notify.notified();
        if self.is_cancelled() {
            return;
        }
        notified.await;
    }

    pub fn pause(&self) {
        if !self.paused.swap(true, Ordering::SeqCst) {
            self.pause_notify.notify_waiters();
        }
    }

    pub fn resume(&self) {
        if self.paused.swap(false, Ordering::SeqCst) {
            self.pause_notify.notify_waiters();
        }
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    /// Blocks while the run is paused. Returns false when the run was cancelled
    /// while waiting, true when execution may continue.
    pub async fn wait_if_paused(&self) -> bool {
        loop {
            if self.is_cancelled() {
                return false;
            }
            if !self.is_paused() {
                return true;
            }
            let notified = self.pause_notify.notified();
            if !self.is_paused() || self.is_cancelled() {
                continue;
            }
            tokio::select! {
                _ = notified => {}
                _ = self.cancelled() => return false,
            }
        }
    }

    /// Attaches the run-scoped agent session and message bus. The engine calls
    /// this before dispatching any node; attach is idempotent so a nested
    /// composite keeps one session for the whole run.
    pub fn attach_agents(&self, bus: Arc<AgentBus>) -> Arc<AgentBus> {
        let mut slot = self
            .agents
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(existing) = slot.as_ref() {
            return existing.clone();
        }
        *slot = Some(bus.clone());
        bus
    }

    pub fn agents(&self) -> Option<Arc<AgentBus>> {
        self.agents
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone()
    }
}
