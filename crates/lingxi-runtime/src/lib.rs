//! Workflow execution engine. The runtime owns topology resolution, capability
//! gating, cancellation, interactions and event emission. Node logic is
//! supplied through the registry, so plugins and built-ins share one path.

pub mod builtin;
pub mod context;
pub mod control;
mod control_flow;
pub mod engine;
pub mod error;
pub mod event;
pub mod interaction;
pub mod registry;

pub use context::NodeContext;
pub use control::RunControl;
pub use engine::{AllowAllPolicy, CapabilityPolicy, CapabilityRequest, Engine, RunSummary};
pub use error::{error_codes, NodeError, RegistryError};
pub use event::{EventSink, LogLevel, RunCause, RunEvent, RunStatus};
pub use interaction::{
    InteractionBroker, InteractionDecision, InteractionOption, InteractionRequest,
    PendingInteractions,
};
pub use registry::{NodeExecutor, NodeOutput, NodeRegistry};
