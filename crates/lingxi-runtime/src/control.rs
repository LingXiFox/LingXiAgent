use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Notify;

/// Cancellation intent for one run. Cancellation is an intent, not a failure:
/// the engine reports it as a cancelled run and never fabricates a failure.
#[derive(Debug, Default)]
pub struct RunControl {
    cancelled: AtomicBool,
    notify: Notify,
}

impl RunControl {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::SeqCst) {
            self.notify.notify_waiters();
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
        let notified = self.notify.notified();
        if self.is_cancelled() {
            return;
        }
        notified.await;
    }
}
