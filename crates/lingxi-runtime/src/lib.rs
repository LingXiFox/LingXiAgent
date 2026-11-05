//! Workflow execution engine. The runtime owns topology resolution, capability
//! gating, cancellation, interactions and event emission. Node logic is
//! supplied through the registry, so plugins and built-ins share one path.

pub mod agent;
pub mod agent_bus;
pub mod agent_node;
pub mod agent_protocol;
pub mod agent_runner;
pub mod agent_template;
pub mod anthropic;
pub mod assets;
pub mod builtin;
pub mod capabilities;
pub mod content;
pub mod context;
pub mod control;
mod control_flow;
pub mod conversation;
pub mod credentials;
pub mod engine;
pub mod error;
pub mod event;
pub mod interaction;
pub mod lsp;
pub mod lsp_node;
pub mod mcp;
pub mod media;
pub mod permissions;
pub mod provider;
pub mod registry;
pub mod responses;
pub mod services;
pub mod skills;
pub mod tools;
pub mod workspace;
pub mod workspace_tools;

pub use assets::AssetStore;
pub use capabilities::{ModelCapabilities, ReasoningLevel, Support};
pub use content::{ContentPart, MessageContent};
pub use context::NodeContext;
pub use control::RunControl;
pub use conversation::{ContextSnapshot, ContextStore, OverflowPolicy};
pub use credentials::{CredentialResolver, EnvCredentials, Secret};
pub use engine::{AllowAllPolicy, CapabilityPolicy, CapabilityRequest, Engine, RunSummary};
pub use error::{error_codes, NodeError, RegistryError};
pub use event::{EventEmitter, EventSink, LogLevel, RunCause, RunEvent, RunStatus};
pub use interaction::{
    InteractionBroker, InteractionDecision, InteractionOption, InteractionRequest,
    PendingInteractions,
};
pub use mcp::{McpHttpConfig, McpManager, McpStdioConfig, McpTool};
pub use permissions::{PermissionClass, PermissionManager};
pub use provider::{
    ChatMessage, ChatProvider, ChatRequest, ChatResponse, MessageRole, OpenAiFactory,
    ProviderConfig, ProviderFactory, ProviderProtocol, TokenUsage, ToolCall,
};
pub use registry::{NodeExecutor, NodeOutput, NodeRegistry};
pub use services::{RunServices, ServiceConfig, UsageRecord};
pub use skills::{SkillDocument, SkillLibrary, SkillSummary};
pub use tools::{BuiltinTools, ToolDefinition, ToolExecutor, ToolResult};
pub use workspace::{FileEntry, FileSnapshot, Workspace, ABSENT_VERSION};
