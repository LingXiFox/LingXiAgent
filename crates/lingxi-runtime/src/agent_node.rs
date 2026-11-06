//! First-class Agent node.
//!
//! The node only assembles inputs, registers the AgentInstance and delegates
//! the loop to `agent_runner`. It never implements model or tool logic itself,
//! and it never bypasses the TaskSession bus for agent-to-agent messages.

use std::sync::Arc;

use async_trait::async_trait;
use lingxi_spec::{DataType, NodeSpec, ParamOption, ParamSpec, PortSpec};
use serde_json::{json, Value};

use crate::agent_bus::AgentBus;
use crate::agent_protocol::{
    agent_instance_id, message_kinds, states, AgentConfigSnapshot, AgentInstance,
    AgentMessageEnvelope, AgentUsage, ArtifactRef, TaskSession,
};
use crate::agent_runner::{emit_agent_event, run_agent, AgentInput};
use crate::content::ContentPart;
use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::event::AgentEvent;
use crate::permissions::PermissionMode;
use crate::provider::{ProviderConfig, ProviderProtocol};
use crate::registry::{NodeExecutor, NodeOutput};
use crate::workspace::Workspace;

pub const AGENT_KIND: &str = "core.agent";

const CAPABILITIES: &str = "Capabilities";
const INSTRUCTIONS: &str = "Instructions";
const COLLABORATION: &str = "Collaboration";
const CONTROL: &str = "Control";

fn port(name: &str, label: &str, data_type: DataType, group: &str) -> PortSpec {
    PortSpec::new(name, label, data_type).group(group)
}

fn agent_spec() -> NodeSpec {
    NodeSpec::new(AGENT_KIND, "Agent", "Agent")
        .description(
            "A complete autonomous agent: multi-turn model calls, tools, budget, structured handoff and user-facing result.",
        )
        .input(port("provider", "Provider", DataType::Text, CAPABILITIES))
        .input(port("model", "Model", DataType::Text, CAPABILITIES))
        .input(port("reasoning", "Reasoning", DataType::Json, CAPABILITIES))
        .input(port("toolset", "Tool Set", DataType::Text, CAPABILITIES))
        .input(port("mcp", "MCP Set", DataType::Text, CAPABILITIES))
        .input(port("skills", "Skills Set", DataType::Text, CAPABILITIES))
        .input(port("lsp", "LSP Set", DataType::Text, CAPABILITIES))
        .input(port("systemPrompt", "System Prompt", DataType::Text, INSTRUCTIONS))
        .input(port("rolePrompt", "Role Prompt", DataType::Text, INSTRUCTIONS))
        .input(port("agentsMd", "AGENTS.md", DataType::Text, INSTRUCTIONS))
        .input(port("userPrompt", "User Prompt", DataType::Text, INSTRUCTIONS))
        .input(port("task", "Task Envelope", DataType::Json, COLLABORATION))
        .input(port("messages", "Agent Messages", DataType::Json, COLLABORATION))
        .input(port("artifacts", "Artifacts", DataType::Json, COLLABORATION))
        .input(port("media", "Media", DataType::Json, COLLABORATION))
        .input(port("workspace", "Project Workspace", DataType::Text, CONTROL))
        .input(PortSpec::new("start", "Start", DataType::Any).control().group(CONTROL))
        .input(port("budget", "Budget", DataType::Json, CONTROL))
        .input(port("policy", "Execution Policy", DataType::Json, CONTROL))
        .input(PortSpec::new("cancel", "Cancel / Intervene", DataType::Any).control().group(CONTROL))
        .output(port("agentMessage", "Agent Message", DataType::Json, "Result"))
        .output(port("userResponse", "User Response", DataType::Text, "Result"))
        .output(port("artifacts", "Artifacts", DataType::Json, "Result"))
        .output(port("executionState", "Execution State", DataType::Json, "Result"))
        .output(PortSpec::new("completed", "Completed", DataType::Any).control().group("Control"))
        .output(PortSpec::new("blocked", "Blocked", DataType::Any).control().group("Control"))
        .output(PortSpec::new("failed", "Failed", DataType::Any).control().group("Control"))
        .param(ParamSpec::text("providerId", "Provider ID", "openai"))
        .param(ParamSpec::text("baseUrl", "Base URL", "http://127.0.0.1:11434/v1"))
        .param(ParamSpec::text("credentialRef", "Credential", "env:OPENAI_API_KEY"))
        .param(ParamSpec::select(
            "protocol",
            "Protocol",
            "openai_chat",
            vec![
                ParamOption::new("openai_chat", "OpenAI Chat Completions"),
                ParamOption::new("openai_responses", "OpenAI Responses"),
                ParamOption::new("anthropic_messages", "Anthropic Messages"),
            ],
        ))
        .param(ParamSpec::text("model", "Model", "gpt-4o-mini"))
        .param(ParamSpec::number("temperature", "Temperature", 0.2))
        .param(ParamSpec::select(
            "reasoning",
            "Reasoning",
            "auto",
            vec![
                ParamOption::new("off", "Off"),
                ParamOption::new("auto", "Auto"),
                ParamOption::new("low", "Low"),
                ParamOption::new("medium", "Medium"),
                ParamOption::new("high", "High"),
                ParamOption::new("xhigh", "Extra high"),
            ],
        ))
        .param(ParamSpec::text_area(
            "rolePrompt",
            "Role Prompt",
            "You are a capable autonomous agent.",
        ))
        .param(ParamSpec::text_area("systemPrompt", "System Prompt", ""))
        .param(ParamSpec::text_area(
            "agentsMd",
            "AGENTS.md",
            "",
        ).help("Workspace instructions. Lower priority than system and role prompts."))
        .param(ParamSpec::text_area("instruction", "Default User Prompt", ""))
        .param(ParamSpec::text("recipient", "Result Recipient", "broadcast"))
        .param(ParamSpec::select(
            "permissionMode",
            "Permission Mode",
            "ask",
            vec![
                ParamOption::new("ask", "Ask every sensitive action"),
                ParamOption::new("workspace", "Workspace: trust project files and builds"),
                ParamOption::new("yolo", "YOLO: auto-approve routine project work"),
            ],
        )
        .help("An Agent may tighten the run policy but never widen it."))
        .param(ParamSpec::number("maxIterations", "Max Iterations", 12.0))
        .param(ParamSpec::number("maxToolCalls", "Max Tool Calls", 48.0))
        .param(ParamSpec::number("maxTotalTokens", "Max Total Tokens", 0.0))
        .param(ParamSpec::number("timeoutMs", "Timeout (ms)", 300000.0))
        .param(ParamSpec::text("toolset", "Tools (comma separated)", "calculator"))
        .param(ParamSpec::text("skills", "Skills (comma separated)", ""))
        .param(ParamSpec::text("lsp", "LSP Set (comma separated)", ""))
        .param(ParamSpec::number("maxTokens", "Max Output Tokens", 1024.0))
        .capability(lingxi_spec::node::capabilities::NETWORK)
        .capability(lingxi_spec::node::capabilities::FILESYSTEM)
        .capability(lingxi_spec::node::capabilities::PROCESS)
        .capability(lingxi_spec::node::capabilities::INTERACTION)
        .capability("credential")
}

pub fn register(registry: &mut crate::registry::NodeRegistry) {
    registry
        .register(agent_spec(), Arc::new(AgentNode))
        .expect("agent node registers");
}

struct AgentNode;

#[async_trait]
impl NodeExecutor for AgentNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let bus = ensure_bus(ctx, ctx.node.label.as_deref().unwrap_or("Agent"));
        let scope = ctx.emitter.scope().to_vec();
        let instance_id = agent_instance_id(ctx.run_id, &scope, &ctx.node.id);
        let label = ctx
            .node
            .label
            .clone()
            .unwrap_or_else(|| "Agent".to_string());
        let workspace = resolve_workspace(ctx)?;
        let mode =
            PermissionMode::parse(&text_param(ctx, "permissionMode", "ask")).unwrap_or_default();
        ctx.services
            .permissions
            .set_agent_mode(ctx.run_id, &ctx.node.id, mode);
        let config = build_config(ctx, workspace.as_ref())?;
        let first_registration = !bus.session().agents.contains_key(&instance_id);
        if first_registration {
            let instance = AgentInstance::new(
                instance_id.clone(),
                ctx.node.id.clone(),
                label.clone(),
                scope.clone(),
                config.clone(),
            );
            bus.register_instance(instance);
            emit_agent_event(
                ctx,
                AgentEvent::Registered {
                    agent_instance_id: instance_id.clone(),
                    node_id: ctx.node.id.clone(),
                    label: label.clone(),
                    scope,
                    state: states::PENDING.to_string(),
                    config: Box::new(config.clone()),
                },
            );
        }
        let activation = bus.start_activation(&instance_id, &config)?;
        emit_agent_event(
            ctx,
            AgentEvent::ActivationStarted {
                agent_instance_id: instance_id.clone(),
                activation_id: activation.clone(),
                index: bus
                    .session()
                    .agents
                    .get(&instance_id)
                    .and_then(|instance| {
                        instance
                            .activations
                            .iter()
                            .find(|record| record.activation_id == activation)
                            .map(|record| record.index)
                    })
                    .unwrap_or(1),
                config_revision: config.revision,
            },
        );
        let input = build_input(ctx, &bus, &instance_id, &config, workspace)?;
        let task_id = input.task_id.clone();
        let recipient = input
            .recipient
            .clone()
            .unwrap_or_else(|| "broadcast".to_string());
        let correlation = input.correlation_id.clone();
        let outcome = run_agent(ctx, &bus, &instance_id, &activation, config.clone(), input).await;
        match outcome {
            Ok(outcome) => {
                let message = publish_result(
                    ctx,
                    &bus,
                    &instance_id,
                    &task_id,
                    &recipient,
                    correlation.as_deref(),
                    &outcome.result,
                );
                bus.finish_activation(
                    &instance_id,
                    &activation,
                    states::COMPLETED,
                    &outcome.usage,
                    Some(&outcome.result.user_response),
                    message.as_ref().map(|message| message.message_id.as_str()),
                    None,
                )?;
                emit_agent_event(
                    ctx,
                    AgentEvent::ActivationFinished {
                        agent_instance_id: instance_id.clone(),
                        activation_id: activation.clone(),
                        state: states::COMPLETED.to_string(),
                        usage: outcome.usage.clone(),
                        user_response: Some(outcome.result.user_response.clone()),
                        message_id: message.as_ref().map(|message| message.message_id.clone()),
                        error: None,
                    },
                );
                let result_status = outcome.result.status.clone();
                let published = message
                    .as_ref()
                    .and_then(|message| serde_json::to_value(message).ok())
                    .unwrap_or_else(|| outcome.result.agent_message.clone());
                let control_port = match result_status.as_str() {
                    crate::agent_protocol::result_status::BLOCKED => "blocked",
                    crate::agent_protocol::result_status::FAILED => "failed",
                    _ => "completed",
                };
                // Only the selected terminal control port is emitted. Sending
                // the other ports as false would still create active control
                // tokens and let a loop gate observe a stale stop signal.
                Ok(NodeOutput::new()
                    .with("agentMessage", published)
                    .with("userResponse", Value::String(outcome.result.user_response))
                    .with(
                        "artifacts",
                        serde_json::to_value(&outcome.result.artifacts).unwrap_or(Value::Null),
                    )
                    .with(
                        "executionState",
                        json!({
                            "instanceId": instance_id,
                            "activationId": activation,
                            "state": result_status,
                            "configRevision": outcome.config.revision,
                            "usage": outcome.usage,
                        }),
                    )
                    .with(control_port, Value::Bool(true)))
            }
            Err(error) => {
                let state = if error.code == error_codes::CANCELLED {
                    states::CANCELLED
                } else {
                    states::FAILED
                };
                let usage = AgentUsage::default();
                let _ = bus.finish_activation(
                    &instance_id,
                    &activation,
                    state,
                    &usage,
                    None,
                    None,
                    Some(&error.message),
                );
                emit_agent_event(
                    ctx,
                    AgentEvent::ActivationFinished {
                        agent_instance_id: instance_id,
                        activation_id: activation,
                        state: state.to_string(),
                        usage,
                        user_response: None,
                        message_id: None,
                        error: Some(error.message.clone()),
                    },
                );
                Err(error)
            }
        }
    }
}

fn ensure_bus(ctx: &NodeContext<'_>, label: &str) -> Arc<AgentBus> {
    if let Some(bus) = ctx.control.agents() {
        return bus;
    }
    ctx.control
        .attach_agents(AgentBus::new(TaskSession::new(ctx.run_id, "", label)))
}

/// The controlled workspace an Agent is bound to for this activation. The
/// handle is opaque; only the host catalog can turn it into a real directory.
struct WorkspaceBinding {
    workspace: Arc<Workspace>,
    relative_cwd: String,
}

fn resolve_workspace(ctx: &NodeContext<'_>) -> Result<Option<WorkspaceBinding>, NodeError> {
    let handle = input_text(ctx, "workspace").or_else(|| {
        let value = text_param(ctx, "workspace", "");
        (!value.trim().is_empty()).then_some(value)
    });
    match handle {
        Some(handle) => {
            let workspace = ctx.services.workspace_for_handle(&handle)?;
            let relative_cwd = ctx
                .services
                .workspace_handle(&handle)
                .map(|handle| handle.relative_cwd)
                .unwrap_or_default();
            Ok(Some(WorkspaceBinding {
                workspace,
                relative_cwd,
            }))
        }
        None => Ok(ctx
            .services
            .workspace()
            .cloned()
            .map(|workspace| WorkspaceBinding {
                workspace,
                relative_cwd: String::new(),
            })),
    }
}

fn build_config(
    ctx: &NodeContext<'_>,
    workspace: Option<&WorkspaceBinding>,
) -> Result<AgentConfigSnapshot, NodeError> {
    let mut system =
        input_text(ctx, "systemPrompt").unwrap_or_else(|| text_param(ctx, "systemPrompt", ""));
    if let Some(agents) = input_text(ctx, "agentsMd").or_else(|| {
        let value = text_param(ctx, "agentsMd", "");
        (!value.trim().is_empty()).then_some(value)
    }) {
        system.push_str("\n\nWorkspace instructions (AGENTS.md):\n");
        system.push_str(&agents);
    }
    // Project rules are scoped to the operation directory: root AGENTS.md plus
    // each parent up to the Agent's cwd, not every AGENTS.md in the repository.
    if let Some(binding) = workspace {
        for document in binding.workspace.agents_md(&binding.relative_cwd) {
            system.push_str(&format!(
                "\n\nProject instructions ({}):\n{}",
                document.path, document.content
            ));
        }
    }
    let mut config = AgentConfigSnapshot {
        model: input_text(ctx, "model").unwrap_or_else(|| text_param(ctx, "model", "gpt-4o-mini")),
        temperature: number_param(ctx, "temperature", 0.2),
        reasoning: reasoning_value(ctx).unwrap_or_else(|| text_param(ctx, "reasoning", "auto")),
        role_prompt: input_text(ctx, "rolePrompt")
            .unwrap_or_else(|| text_param(ctx, "rolePrompt", "")),
        system_prompt: system,
        max_iterations: number_param(ctx, "maxIterations", 12.0).max(1.0) as u32,
        max_tool_calls: number_param(ctx, "maxToolCalls", 48.0).max(0.0) as u32,
        max_total_tokens: number_param(ctx, "maxTotalTokens", 0.0).max(0.0) as u64,
        timeout_ms: number_param(ctx, "timeoutMs", 300_000.0).max(1.0) as u64,
        toolset: csv_input(ctx, "toolset")
            .unwrap_or_else(|| split_csv(&text_param(ctx, "toolset", ""))),
        skills: csv_input(ctx, "skills")
            .unwrap_or_else(|| split_csv(&text_param(ctx, "skills", ""))),
        lsp: csv_input(ctx, "lsp").unwrap_or_else(|| split_csv(&text_param(ctx, "lsp", ""))),
        ..AgentConfigSnapshot::default()
    };
    if let Some(budget) = ctx.input("budget").and_then(Value::as_object) {
        if let Some(value) = budget.get("maxIterations").and_then(Value::as_u64) {
            config.max_iterations = value as u32;
        }
        if let Some(value) = budget.get("maxToolCalls").and_then(Value::as_u64) {
            config.max_tool_calls = value as u32;
        }
        if let Some(value) = budget.get("maxTotalTokens").and_then(Value::as_u64) {
            config.max_total_tokens = value;
        }
        if let Some(value) = budget.get("timeoutMs").and_then(Value::as_u64) {
            config.timeout_ms = value;
        }
    }
    config.validate()?;
    Ok(config)
}

fn related_messages(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    primary: Option<&AgentMessageEnvelope>,
) -> Result<Vec<AgentMessageEnvelope>, NodeError> {
    let Some(value) = ctx.input("messages") else {
        return Ok(Vec::new());
    };
    let items = match value {
        Value::Array(items) => items.clone(),
        Value::Object(_) if value.get("messageId").is_some() => vec![value.clone()],
        Value::Null => return Ok(Vec::new()),
        _ => {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                "messages input must be an AgentMessageEnvelope or an array of them",
            ))
        }
    };
    let session = bus.session();
    let mut messages: Vec<AgentMessageEnvelope> = Vec::new();
    for item in items {
        let message: AgentMessageEnvelope = serde_json::from_value(item).map_err(|error| {
            NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!("collaborator message is invalid: {error}"),
            )
        })?;
        message.validate()?;
        if primary.is_some_and(|primary| primary.message_id == message.message_id) {
            continue;
        }
        if messages
            .iter()
            .any(|known| known.message_id == message.message_id)
        {
            continue;
        }
        if !session
            .messages
            .iter()
            .any(|known| known.message_id == message.message_id)
        {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!(
                    "collaborator message {:?} was not delivered through the task bus",
                    message.message_id
                ),
            ));
        }
        if message.recipient != "broadcast"
            && message.recipient != instance_id
            && message.recipient != ctx.node.id
        {
            return Err(NodeError::new(
                error_codes::BUS_FORBIDDEN,
                format!(
                    "collaborator message {:?} is addressed to {:?}, not {instance_id:?}",
                    message.message_id, message.recipient
                ),
            ));
        }
        messages.push(message);
    }
    Ok(messages)
}

fn build_input(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    config: &AgentConfigSnapshot,
    workspace: Option<WorkspaceBinding>,
) -> Result<AgentInput, NodeError> {
    let task = ctx.input("task").cloned().unwrap_or(Value::Null);
    // A downstream Agent may receive an AgentMessageEnvelope over a data edge.
    // Accepting only messages that exist in the bus session prevents a workflow
    // from forging a handoff that bypassed schema validation, permission checks
    // or the persisted message log.
    let envelope = if task.get("messageId").and_then(Value::as_str).is_some() {
        let message: AgentMessageEnvelope =
            serde_json::from_value(task.clone()).map_err(|error| {
                NodeError::new(
                    error_codes::AGENT_INVALID_MESSAGE,
                    format!("agent message is invalid: {error}"),
                )
            })?;
        message.validate()?;
        let session = bus.session();
        let known = session
            .messages
            .iter()
            .any(|known| known.message_id == message.message_id);
        if !known {
            return Err(NodeError::new(
                error_codes::AGENT_INVALID_MESSAGE,
                format!(
                    "handoff message {:?} was not delivered through the task bus",
                    message.message_id
                ),
            ));
        }
        if message.recipient != "broadcast"
            && message.recipient != instance_id
            && message.recipient != ctx.node.id
        {
            return Err(NodeError::new(
                error_codes::BUS_FORBIDDEN,
                format!(
                    "agent message {:?} is addressed to {:?}, not {instance_id:?}",
                    message.message_id, message.recipient
                ),
            ));
        }
        Some(message)
    } else {
        None
    };

    let related = related_messages(ctx, bus, instance_id, envelope.as_ref())?;

    let task_id = envelope
        .as_ref()
        .map(|message| message.task_id.clone())
        .or_else(|| {
            task.get("taskId")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| format!("task-{}-{}", ctx.run_id, ctx.node.id));
    let correlation_id = envelope
        .as_ref()
        .and_then(|message| message.correlation_id.clone())
        .or_else(|| {
            task.get("correlationId")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
    let recipient = input_text(ctx, "recipient")
        .or_else(|| {
            let value = text_param(ctx, "recipient", "");
            (value != "broadcast" && !value.trim().is_empty()).then_some(value)
        })
        .or_else(|| {
            task.get("recipient")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| Some("broadcast".to_string()));
    let instruction = input_text(ctx, "userPrompt")
        .or_else(|| {
            envelope
                .as_ref()
                .and_then(|message| message.payload_text("instruction").map(str::to_string))
        })
        .or_else(|| {
            envelope
                .as_ref()
                .and_then(|message| message.payload_text("feedback").map(str::to_string))
        })
        .or_else(|| {
            related.iter().rev().find_map(|message| {
                message
                    .payload_text("feedback")
                    .or_else(|| message.payload_text("instruction"))
                    .map(str::to_string)
            })
        })
        .or_else(|| {
            task.get("instruction")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| {
            let value = text_param(ctx, "instruction", "");
            (!value.trim().is_empty()).then_some(value)
        })
        .ok_or_else(|| {
            NodeError::new(
                error_codes::AGENT_INVALID_CONFIG,
                "agent requires a user prompt or a task envelope instruction",
            )
        })?;

    let mut context = task
        .get("metadata")
        .and_then(|metadata| metadata.get("context"))
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(message) = &envelope {
        let deliverable = serde_json::to_string_pretty(&message.payload)
            .unwrap_or_else(|_| message.payload.to_string());
        context = Some(format!(
            "{}\nHandoff from {} ({}) status {}:\n{}",
            context.unwrap_or_default(),
            message.sender,
            message.message_type,
            message.status,
            deliverable
        ));
    }
    if !related.is_empty() {
        let messages = related
            .iter()
            .map(|message| {
                let payload = serde_json::to_string_pretty(&message.payload)
                    .unwrap_or_else(|_| message.payload.to_string());
                format!(
                    "- from {} ({}) status {} message {}:\n{}",
                    message.sender,
                    message.message_type,
                    message.status,
                    message.message_id,
                    payload
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        context = Some(format!(
            "{}\nMessages from collaborators:\n{}",
            context.unwrap_or_default(),
            messages
        ));
    }
    let artifacts = envelope
        .as_ref()
        .map(|message| message.artifact_refs.clone())
        .or_else(|| {
            ctx.input("artifacts")
                .and_then(|value| serde_json::from_value::<Vec<ArtifactRef>>(value.clone()).ok())
        })
        .unwrap_or_default();
    if let Some(binding) = &workspace {
        let cwd = if binding.relative_cwd.is_empty() {
            ".".to_string()
        } else {
            binding.relative_cwd.clone()
        };
        context = Some(format!(
            "{}\nProject workspace: {} (relative cwd {cwd}). All file tool paths are relative to this directory.",
            context.unwrap_or_default(),
            binding.workspace.root().display()
        ));
    }
    if !artifacts.is_empty() {
        let listing = artifacts
            .iter()
            .map(|artifact| format!("- {} ({})", artifact.name, artifact.id))
            .collect::<Vec<_>>()
            .join("\n");
        context = Some(format!(
            "{}\nArtifacts:\n{listing}",
            context.unwrap_or_default()
        ));
    }
    let tools = if let Some(handle) = input_text(ctx, "toolset") {
        if handle.starts_with("toolset-") {
            ctx.services.toolset(&handle)?
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };
    let media = ctx
        .input("media")
        .and_then(|value| serde_json::from_value::<Vec<ContentPart>>(value.clone()).ok())
        .unwrap_or_default();
    let provider_handle = provider_handle(ctx)?;
    let lsp = config
        .lsp
        .iter()
        .filter(|handle| !handle.trim().is_empty())
        .map(|handle| ctx.services.lsp_config(handle))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(AgentInput {
        provider_handle,
        instruction,
        task_context: context,
        max_tokens: number_param(ctx, "maxTokens", 1024.0).max(1.0) as u32,
        tools,
        task_id,
        correlation_id,
        recipient,
        media,
        lsp,
        workspace: workspace
            .as_ref()
            .map(|binding| Arc::clone(&binding.workspace)),
        relative_cwd: workspace
            .as_ref()
            .map(|binding| binding.relative_cwd.clone())
            .unwrap_or_default(),
        history: ctx.services.history(&ctx.node.id),
    })
}
fn provider_handle(ctx: &NodeContext<'_>) -> Result<String, NodeError> {
    if let Some(handle) = input_text(ctx, "provider") {
        return Ok(handle);
    }
    let protocol = match text_param(ctx, "protocol", "openai_chat").as_str() {
        "openai_responses" => ProviderProtocol::OpenAiResponses,
        "anthropic_messages" => ProviderProtocol::AnthropicMessages,
        _ => ProviderProtocol::OpenAiChat,
    };
    let config = ProviderConfig {
        provider_id: text_param(ctx, "providerId", "openai"),
        base_url: text_param(ctx, "baseUrl", "http://127.0.0.1:11434/v1"),
        credential_ref: text_param(ctx, "credentialRef", "env:OPENAI_API_KEY"),
        organization: String::new(),
        supports_reasoning: true,
        protocol,
        capabilities: Value::Null,
    };
    config.validate()?;
    Ok(ctx.services.register_provider(config))
}

fn publish_result(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    task_id: &str,
    recipient: &str,
    correlation: Option<&str>,
    result: &crate::agent_protocol::AgentResult,
) -> Option<AgentMessageEnvelope> {
    let kind = if result.status == "blocked" {
        message_kinds::BLOCKED
    } else {
        message_kinds::RESULT
    };
    let payload = json!({
        "summary": result.user_response,
        "status": result.status,
        "data": result.agent_message,
    });
    let mut message = AgentMessageEnvelope::new(task_id, instance_id, recipient, kind, payload);
    message.correlation_id = correlation.map(str::to_string);
    message.artifact_refs = result.artifacts.clone();
    match bus.send(message.clone()) {
        Ok(delivery) => {
            if !delivery.duplicate {
                emit_agent_event(
                    ctx,
                    AgentEvent::Message {
                        agent_instance_id: Some(instance_id.to_string()),
                        message: delivery.message.clone(),
                    },
                );
            }
            Some(delivery.message)
        }
        Err(error) => {
            ctx.log(
                crate::event::LogLevel::Warn,
                format!("agent result could not be delivered: {}", error.message),
            );
            None
        }
    }
}

fn input_text(ctx: &NodeContext<'_>, name: &str) -> Option<String> {
    ctx.input(name).and_then(|value| match value {
        Value::String(text) if !text.trim().is_empty() => Some(text.clone()),
        Value::Object(object) => object
            .get("text")
            .and_then(Value::as_str)
            .map(str::to_string),
        _ => None,
    })
}

fn csv_input(ctx: &NodeContext<'_>, name: &str) -> Option<Vec<String>> {
    ctx.input(name).map(|value| match value {
        Value::String(text) => split_csv(text),
        Value::Array(items) => items
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect(),
        _ => Vec::new(),
    })
}

fn split_csv(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

fn reasoning_value(ctx: &NodeContext<'_>) -> Option<String> {
    ctx.input("reasoning").and_then(|value| match value {
        Value::String(text) if !text.trim().is_empty() => Some(text.clone()),
        Value::Object(object) => object
            .get("level")
            .and_then(Value::as_str)
            .map(str::to_string),
        _ => None,
    })
}

fn text_param(ctx: &NodeContext<'_>, name: &str, fallback: &str) -> String {
    ctx.string_param(name)
        .map(str::to_string)
        .unwrap_or_else(|_| fallback.to_string())
}

fn number_param(ctx: &NodeContext<'_>, name: &str, fallback: f64) -> f64 {
    ctx.number_param(name).unwrap_or(fallback)
}
