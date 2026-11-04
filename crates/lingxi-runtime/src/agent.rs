//! Agent nodes: provider/model selection, prompts, conversation context,
//! tool sets, tool dispatch, MCP servers and local skills.
//!
//! None of these nodes hard-code an agent loop. They are ordinary building
//! blocks that a workflow (or a composite template) wires together.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use lingxi_spec::{DataType, NodeSpec, ParamOption, ParamSpec, PortSpec};
use serde_json::{json, Value};

use crate::capabilities::{ModelCapabilities, ReasoningLevel, Support};
use crate::content::{ContentPart, MessageContent};
use crate::context::NodeContext;
use crate::conversation::{messages_from_json, ContextSnapshot, OverflowPolicy, ToolResultRecord};
use crate::error::{error_codes, NodeError};
use crate::event::RunEvent;
use crate::mcp::{McpHttpConfig, McpStdioConfig};
use crate::permissions::PermissionClass;
use crate::provider::{
    ChatMessage, ChatRequest, OpenAiFactory, ProviderConfig, ProviderFactory, ProviderProtocol,
    ToolCall,
};
use crate::registry::{NodeExecutor, NodeOutput};
use crate::skills::SkillLibrary;
use crate::tools::{
    parse_tool_definitions, tool_definitions_json, validate_arguments, ToolDefinition,
};

pub const PROVIDER_KIND: &str = "core.provider";
pub const PROVIDER_OPENAI_CHAT_KIND: &str = "core.provider.openai_chat";
pub const PROVIDER_OPENAI_RESPONSES_KIND: &str = "core.provider.openai_responses";
pub const PROVIDER_ANTHROPIC_KIND: &str = "core.provider.anthropic_messages";
pub const REASONING_KIND: &str = "core.reasoning";
pub const MODEL_KIND: &str = "core.model";
pub const PROMPT_KIND: &str = "core.prompt";
pub const CONTEXT_KIND: &str = "core.context";
pub const TOOL_SET_KIND: &str = "core.tool_set";
pub const TOOL_DISPATCH_KIND: &str = "core.tool_dispatch";
pub const MCP_SERVER_KIND: &str = "core.mcp_server";
pub const SKILL_KIND: &str = "core.skill";

fn control_port(name: &str, label: &str) -> PortSpec {
    PortSpec::new(name, label, DataType::Any).control()
}

fn text_port(name: &str, label: &str) -> PortSpec {
    PortSpec::new(name, label, DataType::Text)
}

fn json_port(name: &str, label: &str) -> PortSpec {
    PortSpec::new(name, label, DataType::Json)
}

fn provider_spec(kind: &str, title: &str, protocol: &str, description: &str) -> NodeSpec {
    NodeSpec::new(kind, title, "Agent")
        .description(description)
        .output(text_port("provider", "Provider"))
        .output(json_port("config", "Config"))
        .param(ParamSpec::text("providerId", "Provider ID", "openai"))
        .param(
            ParamSpec::text("baseUrl", "Base URL", "http://127.0.0.1:11434/v1")
                .help("OpenAI-compatible endpoint, including the /v1 prefix when required."),
        )
        .param(
            ParamSpec::text("credentialRef", "Credential", "env:OPENAI_API_KEY")
                .help("env:NAME reads an environment variable. key:NAME reads the OS keyring."),
        )
        .param(ParamSpec::text("organization", "Organization", ""))
        .param(ParamSpec::boolean(
            "supportsReasoning",
            "Reasoning support",
            true,
        ))
        .param(ParamSpec::select(
            "protocol",
            "Protocol",
            protocol,
            vec![
                ParamOption::new("openai_chat", "OpenAI Chat Completions"),
                ParamOption::new("openai_responses", "OpenAI Responses"),
                ParamOption::new("anthropic_messages", "Anthropic Messages"),
            ],
        ))
        .param(
            ParamSpec::text_area("capabilities", "Capability overrides (JSON)", "{}").help(
                "Merged over the conservative built-in profile and marked as manually configured.",
            ),
        )
}

fn model_spec() -> NodeSpec {
    NodeSpec::new(MODEL_KIND, "Model", "Agent")
        .description("Calls one chat completion. Emits text, tool calls and a done control signal.")
        .input(control_port("run", "Run"))
        .input(text_port("provider", "Provider").required())
        .input(json_port("context", "Context"))
        .input(json_port("messages", "Messages"))
        .input(text_port("toolset", "Tool Set"))
        .input(json_port("reasoning", "Reasoning"))
        .output(text_port("text", "Text"))
        .output(json_port("toolCalls", "Tool Calls"))
        .output(PortSpec::new(
            "hasToolCalls",
            "Has Tool Calls",
            DataType::Boolean,
        ))
        .output(json_port("assistant", "Assistant Message"))
        .output(json_port("usage", "Usage"))
        .output(control_port("done", "Done"))
        .output(json_port("capabilities", "Capabilities"))
        .output(text_port("reasoningSummary", "Reasoning Summary"))
        .param(ParamSpec::text("model", "Model", "llama3.2"))
        .param(ParamSpec::number("temperature", "Temperature", 0.7))
        .param(ParamSpec::number("maxTokens", "Max Output Tokens", 1024.0))
        .param(ParamSpec::select(
            "reasoningEffort",
            "Reasoning Effort",
            "none",
            vec![
                ParamOption::new("none", "None"),
                ParamOption::new("low", "Low"),
                ParamOption::new("medium", "Medium"),
                ParamOption::new("high", "High"),
            ],
        ))
        .param(ParamSpec::boolean("stream", "Streaming", true))
        .param(
            ParamSpec::text_area("capabilities", "Capability overrides (JSON)", "{}")
                .help("Optional manual evidence for local or self-hosted models."),
        )
        .param(ParamSpec::number("timeoutMs", "Timeout (ms)", 60000.0))
        .param(
            ParamSpec::number("maxCalls", "Max Calls", 8.0)
                .help("Budget for this model node in one run. Exhaustion fails the run."),
        )
        .param(ParamSpec::number("maxTotalTokens", "Max Total Tokens", 0.0))
        .capability(lingxi_spec::node::capabilities::NETWORK)
        .capability("credential")
}

fn reasoning_spec() -> NodeSpec {
    NodeSpec::new(REASONING_KIND, "Reasoning", "Agent")
        .description("Selects a reasoning effort independently of the model and validates it against capabilities.")
        .input(control_port("run", "Run"))
        .input(json_port("capabilities", "Model Capabilities"))
        .input(json_port("override", "Upstream Override"))
        .output(json_port("config", "Reasoning Config"))
        .output(text_port("level", "Level"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::select(
            "level",
            "Reasoning Effort",
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
}

fn prompt_spec() -> NodeSpec {
    NodeSpec::new(PROMPT_KIND, "Prompt", "Agent")
        .description("Builds system/user messages from templates and upstream inputs.")
        .input(control_port("run", "Run"))
        .input(PortSpec::new("input", "Input", DataType::Any))
        .input(text_port("skill", "Skill"))
        .output(text_port("system", "System"))
        .output(text_port("user", "User"))
        .output(json_port("messages", "Messages"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::text_area(
            "system",
            "System Prompt",
            "You are a concise, helpful assistant. Use tools when they are needed.",
        ))
        .param(ParamSpec::text_area("user", "User Prompt", "{{input}}"))
        .param(ParamSpec::text("variables", "Variables (JSON)", "{}"))
}

fn context_spec() -> NodeSpec {
    NodeSpec::new(CONTEXT_KIND, "Context", "Agent")
        .description("Owns the per-run message history. Each activation appends assistant/tool messages or initializes it.")
        .input(control_port("run", "Run"))
        .input(json_port("messages", "Initial Messages"))
        .input(json_port("assistant", "Assistant Message"))
        .input(json_port("toolResults", "Tool Results"))
        .input(PortSpec::new("assets", "Media Parts", DataType::Any))
        .input(text_port("text", "Text"))
        .input(json_port("image", "Image Parts"))
        .input(json_port("audio", "Audio Parts"))
        .input(json_port("video", "Video Parts"))
        .input(json_port("document", "Document Parts"))
        .output(json_port("context", "Context"))
        .output(text_port("handle", "Handle"))
        .output(json_port("messages", "Messages"))
        .output(PortSpec::new("assets", "Media Parts", DataType::Any))
        .output(json_port("parts", "Ordered Parts"))
        .output(PortSpec::new("trimmed", "Trimmed", DataType::Number))
        .output(control_port("done", "Done"))
        .param(ParamSpec::number("maxMessages", "Max Messages", 40.0))
        .param(ParamSpec::number("maxTokens", "Max Estimated Tokens", 12000.0))
        .param(ParamSpec::text(
            "partOrder",
            "Media Part Order",
            "text,image,audio,video,document",
        ))
        .param(ParamSpec::select(
            "overflow",
            "Overflow Policy",
            "trim_oldest",
            vec![
                ParamOption::new("trim_oldest", "Trim oldest"),
                ParamOption::new("error", "Fail the run"),
            ],
        ))
}

fn tool_set_spec() -> NodeSpec {
    NodeSpec::new(TOOL_SET_KIND, "Tool Set", "Tools")
        .description("Publishes a named tool set for a model and the dispatcher.")
        .input(json_port("mcp", "MCP Tools"))
        .output(text_port("toolset", "Tool Set"))
        .output(json_port("tools", "Tools"))
        .output(json_port("names", "Names"))
        .param(ParamSpec::text(
            "builtins",
            "Builtin tools",
            "calculator,text_transform,json_query",
        ))
}

fn tool_dispatch_spec() -> NodeSpec {
    NodeSpec::new(TOOL_DISPATCH_KIND, "Tool Dispatcher", "Tools")
        .description("Validates and executes model tool calls, one result per call id.")
        .input(control_port("run", "Run"))
        .input(text_port("toolset", "Tool Set").required())
        .input(json_port("calls", "Tool Calls").required())
        .output(json_port("results", "Results"))
        .output(text_port("summary", "Summary"))
        .output(PortSpec::new("failed", "Any Failed", DataType::Boolean))
        .output(control_port("done", "Done"))
        .capability(lingxi_spec::node::capabilities::INTERACTION)
}

fn mcp_spec() -> NodeSpec {
    NodeSpec::new(MCP_SERVER_KIND, "MCP Server", "Tools")
        .description(
            "Connects to a local stdio or Streamable HTTP MCP server and discovers its tools.",
        )
        .input(control_port("run", "Run"))
        .output(json_port("mcp", "MCP"))
        .output(json_port("tools", "Tools"))
        .output(text_port("handle", "Handle"))
        .output(PortSpec::new("toolCount", "Tool Count", DataType::Number))
        .output(control_port("done", "Done"))
        .param(ParamSpec::select(
            "transport",
            "Transport",
            "stdio",
            vec![
                ParamOption::new("stdio", "stdio"),
                ParamOption::new("http", "Streamable HTTP"),
            ],
        ))
        .param(ParamSpec::text("namespace", "Namespace", "local"))
        .param(ParamSpec::text("command", "Command", "python3"))
        .param(ParamSpec::text_area(
            "args",
            "Arguments",
            "test-mcp-server.py",
        ))
        .param(ParamSpec::text(
            "url",
            "HTTP URL",
            "http://127.0.0.1:8765/mcp",
        ))
        .param(ParamSpec::text("credentialRef", "Credential", ""))
        .param(ParamSpec::text("cwd", "Working Directory", ""))
        .param(ParamSpec::text_area("env", "Environment (KEY=VALUE)", ""))
        .capability(lingxi_spec::node::capabilities::PROCESS)
        .capability(lingxi_spec::node::capabilities::NETWORK)
        .capability(lingxi_spec::node::capabilities::INTERACTION)
}

fn skill_spec() -> NodeSpec {
    NodeSpec::new(SKILL_KIND, "Skill", "Agent")
        .description("Loads a local SKILL.md and exposes its instructions as a system message.")
        .input(control_port("run", "Run"))
        .input(PortSpec::new("input", "Input", DataType::Any))
        .output(text_port("skill", "Skill"))
        .output(json_port("messages", "Messages"))
        .output(json_port("resources", "Resources"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::text("skillId", "Skill ID", "text-stats"))
        .capability(lingxi_spec::node::capabilities::FILESYSTEM)
        .capability(lingxi_spec::node::capabilities::INTERACTION)
}

pub fn register(registry: &mut crate::registry::NodeRegistry) {
    for (kind, title, protocol, description) in [
        (
            PROVIDER_OPENAI_CHAT_KIND,
            "OpenAI Chat Provider",
            "openai_chat",
            "Declares an OpenAI Chat Completions endpoint. Secrets are referenced, never stored here.",
        ),
        (
            PROVIDER_OPENAI_RESPONSES_KIND,
            "OpenAI Responses Provider",
            "openai_responses",
            "Declares an OpenAI Responses endpoint with server-side conversation state.",
        ),
        (
            PROVIDER_ANTHROPIC_KIND,
            "Anthropic Provider",
            "anthropic_messages",
            "Declares an Anthropic Messages endpoint with native documents and thinking.",
        ),
        (
            PROVIDER_KIND,
            "Provider (legacy)",
            "openai_chat",
            "Legacy compatibility alias for an OpenAI Chat Completions endpoint.",
        ),
    ] {
        registry
            .register(provider_spec(kind, title, protocol, description), Arc::new(ProviderNode))
            .expect("provider node registers");
    }
    registry
        .register(model_spec(), Arc::new(ModelNode))
        .expect("model node registers");
    registry
        .register(reasoning_spec(), Arc::new(ReasoningNode))
        .expect("reasoning node registers");
    registry
        .register(prompt_spec(), Arc::new(PromptNode))
        .expect("prompt node registers");
    registry
        .register(context_spec(), Arc::new(ContextNode))
        .expect("context node registers");
    registry
        .register(tool_set_spec(), Arc::new(ToolSetNode))
        .expect("tool set node registers");
    registry
        .register(tool_dispatch_spec(), Arc::new(ToolDispatchNode))
        .expect("tool dispatch node registers");
    registry
        .register(mcp_spec(), Arc::new(McpServerNode))
        .expect("mcp server node registers");
    registry
        .register(skill_spec(), Arc::new(SkillNode))
        .expect("skill node registers");
}

struct ProviderNode;

#[async_trait]
impl NodeExecutor for ProviderNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let config = ProviderConfig {
            provider_id: ctx.string_param("providerId")?.to_string(),
            base_url: ctx.string_param("baseUrl")?.trim().to_string(),
            credential_ref: ctx.string_param("credentialRef")?.trim().to_string(),
            organization: ctx.string_param("organization")?.trim().to_string(),
            supports_reasoning: ctx.bool_param("supportsReasoning")?,
            protocol: ctx
                .string_param("protocol")
                .ok()
                .and_then(|value| match value.trim() {
                    "openai_responses" => Some(ProviderProtocol::OpenAiResponses),
                    "anthropic_messages" => Some(ProviderProtocol::AnthropicMessages),
                    "openai_chat" => Some(ProviderProtocol::OpenAiChat),
                    _ => None,
                })
                .unwrap_or(match ctx.node.kind.as_str() {
                    PROVIDER_OPENAI_RESPONSES_KIND => ProviderProtocol::OpenAiResponses,
                    PROVIDER_ANTHROPIC_KIND => ProviderProtocol::AnthropicMessages,
                    _ => ProviderProtocol::OpenAiChat,
                }),
            capabilities: ctx
                .param("capabilities")
                .and_then(|value| match value {
                    Value::String(raw) if !raw.trim().is_empty() => serde_json::from_str(raw).ok(),
                    Value::Object(_) => Some(value.clone()),
                    _ => None,
                })
                .unwrap_or(Value::Null),
        };
        config.validate()?;
        let handle = ctx.services.register_provider(config.clone());
        ctx.log(
            crate::event::LogLevel::Info,
            format!(
                "provider {} registered for {}",
                config.provider_id,
                config.host()
            ),
        );
        Ok(NodeOutput::new()
            .with("provider", Value::String(handle))
            .with(
                "config",
                serde_json::to_value(&config).unwrap_or(Value::Null),
            ))
    }
}

struct ModelNode;

fn parse_context_messages(value: &Value) -> Result<Vec<ChatMessage>, NodeError> {
    let messages = value
        .get("messages")
        .cloned()
        .unwrap_or_else(|| value.clone());
    messages_from_json(&messages)
}

fn tool_definitions_from_input(value: &Value) -> Result<Vec<ToolDefinition>, NodeError> {
    let tools = value.get("tools").cloned().unwrap_or_else(|| value.clone());
    parse_tool_definitions(&tools)
}

fn provider_tool_schema(definitions: &[ToolDefinition]) -> Vec<Value> {
    definitions
        .iter()
        .map(|definition| {
            json!({
                "type": "function",
                "function": {
                    "name": definition.name,
                    "description": definition.description,
                    "parameters": definition.parameters,
                }
            })
        })
        .collect()
}

fn message_fingerprint(message: &ChatMessage) -> String {
    format!("{:?}:{}", message.role, message.plain_text())
}

fn assistant_message_json(text: &str, calls: &[ToolCall]) -> Value {
    let message = ChatMessage {
        role: crate::provider::MessageRole::Assistant,
        content: MessageContent::text(text),
        tool_calls: calls.to_vec(),
        tool_call_id: None,
        name: None,
    };
    serde_json::to_value(&message).unwrap_or_else(|_| Value::Array(Vec::new()))
}

#[async_trait]
impl NodeExecutor for ModelNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let provider_handle = ctx.text_input("provider")?;
        let config = ctx.services.provider(&provider_handle)?;
        // The first activation uses the prompt messages directly; later
        // activations use the conversation snapshot maintained by Context.
        let messages = match ctx.input("context") {
            Some(value) if !value.is_null() => parse_context_messages(value)?,
            _ => match ctx.input("messages") {
                Some(value) if !value.is_null() => parse_context_messages(value)?,
                _ => {
                    return Err(NodeError::new(
                        error_codes::MISSING_INPUT,
                        "model needs either a context or messages input",
                    ))
                }
            },
        };
        let tools = match ctx.input("toolset") {
            Some(Value::String(handle)) if !handle.is_empty() => ctx.services.toolset(handle)?,
            Some(value) if !value.is_null() => tool_definitions_from_input(value)?,
            _ => Vec::new(),
        };
        let mut messages = messages;
        let requested_parts = match ctx.input("assets") {
            Some(Value::Array(items)) if !items.is_empty() => {
                serde_json::from_value::<Vec<ContentPart>>(Value::Array(items.clone())).map_err(
                    |error| {
                        NodeError::new(
                            error_codes::INVALID_INPUT,
                            format!("assets input is not a valid content part list: {error}"),
                        )
                    },
                )?
            }
            _ => Vec::new(),
        };

        let model = ctx.string_param("model")?.trim().to_string();
        if model.is_empty() {
            return Err(NodeError::new(
                error_codes::PROVIDER_CONFIG,
                "model id must not be empty",
            ));
        }
        let capabilities_override = match ctx.param("capabilities") {
            Some(Value::String(raw)) if !raw.trim().is_empty() => {
                serde_json::from_str::<Value>(raw).map_err(|error| {
                    NodeError::new(
                        error_codes::MODEL_UNKNOWN_CAPABILITY,
                        format!("capabilities override is not valid JSON: {error}"),
                    )
                })?
            }
            Some(Value::Object(_)) => ctx.param("capabilities").cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        };
        let capabilities = ModelCapabilities::infer(config.protocol.as_str(), &model)
            .with_overrides(&capabilities_override)?;
        let mut media_parts = Vec::new();
        for part in requested_parts {
            media_parts.extend(part.flatten());
        }
        let mut all_parts = Vec::new();
        for message in &messages {
            if let MessageContent::Parts(parts) = &message.content {
                all_parts.extend(parts.iter().cloned());
            }
        }
        all_parts.extend(media_parts.iter().cloned());
        capabilities.check_parts(&all_parts)?;
        if !media_parts.is_empty() {
            merge_media_into_last_user(&mut messages, media_parts);
        }
        let state_key = ctx.state_key();
        let mut request_messages = messages.clone();
        let mut previous_response_id = None;
        if config.protocol == ProviderProtocol::OpenAiResponses {
            if let Some(session) = ctx.services.response_session(&state_key) {
                let first = request_messages
                    .first()
                    .map(message_fingerprint)
                    .unwrap_or_default();
                if request_messages.len() >= session.message_count && first == session.first_message
                {
                    previous_response_id = Some(session.id);
                    request_messages = request_messages[session.message_count..].to_vec();
                } else {
                    // Local history was trimmed or replaced; server state no
                    // longer lines up, so send the complete local transcript.
                    ctx.services.clear_response_session(&state_key);
                }
            }
        }
        let sent_count = request_messages.len();
        let sent_first = request_messages
            .first()
            .map(message_fingerprint)
            .unwrap_or_default();
        let reasoning_input = ctx.input("reasoning").cloned();
        let reasoning_value = reasoning_input
            .as_ref()
            .and_then(|value| value.get("level").or_else(|| value.get("effort")))
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| {
                ctx.string_param("reasoningEffort")
                    .unwrap_or("none")
                    .to_string()
            });
        let reasoning_level = ReasoningLevel::parse(&reasoning_value).ok_or_else(|| {
            NodeError::new(
                error_codes::MODEL_UNSUPPORTED_REASONING,
                format!("unknown reasoning level {reasoning_value:?}"),
            )
        })?;
        capabilities.check_reasoning(reasoning_level)?;
        let reasoning_effort = if reasoning_level.enabled() {
            Some(reasoning_level.as_str().to_string())
        } else {
            None
        };
        if !tools.is_empty() && capabilities.features.tool_calling == Support::Unsupported {
            return Err(NodeError::new(
                error_codes::MODEL_UNSUPPORTED_MODALITY,
                "model does not declare tool calling support",
            ));
        }
        let max_calls = ctx.number_param("maxCalls")?.max(1.0) as u64;
        ctx.services
            .reserve_model_call(&ctx.state_key(), max_calls)?;
        ctx.services
            .permissions
            .authorize(
                ctx,
                PermissionClass::Network,
                &config.target(),
                &format!(
                    "provider {} ({}) at {}",
                    config.provider_id,
                    config.protocol.label(),
                    config.base_url
                ),
                true,
            )
            .await?;

        let secret = if config.credential_ref.trim().is_empty() {
            None
        } else {
            Some(
                ctx.services
                    .credentials
                    .resolve(&config.credential_ref)
                    .await?,
            )
        };
        let provider = OpenAiFactory::default()
            .create(&config, secret, Arc::clone(&ctx.services.assets))
            .await?;

        let temperature = ctx.number_param("temperature")?;
        let max_tokens = ctx.number_param("maxTokens")?;
        let stream = ctx.bool_param("stream")?;
        let timeout_ms = ctx.number_param("timeoutMs")?.max(1.0) as u64;
        let request = ChatRequest {
            model,
            messages: request_messages,
            temperature: Some(temperature),
            max_tokens: if max_tokens > 0.0 {
                Some(max_tokens as u32)
            } else {
                None
            },
            reasoning_effort,
            previous_response_id,
            stream,
            tools: provider_tool_schema(&tools),
            timeout_ms,
        };

        let node_id = ctx.node.id.clone();
        let label = ctx.node.display_name(Some(ctx.spec));
        let emitter = ctx.emitter.fork();
        let stream_state = Arc::new(Mutex::new((Instant::now(), String::new())));
        let shared = Arc::clone(&stream_state);
        let run_id = ctx.run_id.to_string();
        let mut delta = move |chunk: String| {
            if chunk.is_empty() {
                return;
            }
            let mut state = shared
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.1.push_str(&chunk);
            if state.0.elapsed() >= Duration::from_millis(200) {
                emitter.emit(RunEvent::ModelDelta {
                    run_id: run_id.clone(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node_id.clone(),
                    label: label.clone(),
                    delta: std::mem::take(&mut state.1),
                });
                state.0 = Instant::now();
            }
        };
        let response = provider.complete(request, ctx.control, &mut delta).await?;
        if let Some(response_id) = response.response_id.clone() {
            ctx.services.set_response_session(
                &state_key,
                crate::services::ResponseSession {
                    id: response_id,
                    message_count: sent_count,
                    first_message: sent_first,
                },
            );
        }
        {
            let mut state = stream_state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !state.1.is_empty() {
                ctx.model_delta(std::mem::take(&mut state.1));
            }
        }
        if response.text.trim().is_empty() && response.tool_calls.is_empty() {
            return Err(NodeError::new(
                error_codes::MODEL_EMPTY_RESPONSE,
                "model returned neither text nor tool calls",
            ));
        }
        let usage = ctx.services.record_tokens(
            &ctx.state_key(),
            response.usage.prompt_tokens,
            response.usage.completion_tokens,
            ctx.number_param("maxTotalTokens")?.max(0.0) as u64,
        )?;
        let has_calls = !response.tool_calls.is_empty();
        let calls = serde_json::to_value(&response.tool_calls).unwrap_or(Value::Array(Vec::new()));
        let assistant = assistant_message_json(&response.text, &response.tool_calls);
        if let Some(reasoning) = &response.reasoning {
            ctx.log(
                crate::event::LogLevel::Info,
                format!("model reasoning summary: {reasoning}"),
            );
        }
        ctx.log(
            crate::event::LogLevel::Info,
            format!(
                "model {} responded with {} chars, {} tool call(s), {} token(s)",
                request_model_label(ctx),
                response.text.chars().count(),
                response.tool_calls.len(),
                response.usage.total_tokens
            ),
        );
        Ok(NodeOutput::new()
            .with("text", Value::String(response.text))
            .with("toolCalls", calls)
            .with("hasToolCalls", Value::Bool(has_calls))
            .with("assistant", json!([assistant]))
            .with("usage", serde_json::to_value(&usage).unwrap_or(Value::Null))
            .with(
                "capabilities",
                serde_json::to_value(&capabilities).unwrap_or(Value::Null),
            )
            .with(
                "reasoningSummary",
                response
                    .reasoning
                    .clone()
                    .map(Value::String)
                    .unwrap_or(Value::Null),
            )
            .with(
                "responseId",
                response
                    .response_id
                    .clone()
                    .map(Value::String)
                    .unwrap_or(Value::Null),
            )
            .with("done", Value::Bool(true)))
    }
}

/// Media arrives separately from the conversation snapshot, but protocols
/// expect it in the same user turn as the text it belongs to. Merge instead of
/// appending a second user message, de-duplicating the exact text that already
/// came from the Prompt node.
fn merge_media_into_last_user(messages: &mut Vec<ChatMessage>, media_parts: Vec<ContentPart>) {
    let existing = messages
        .iter()
        .rev()
        .find(|message| matches!(message.role, crate::provider::MessageRole::User))
        .map(ChatMessage::plain_text)
        .unwrap_or_default();
    if existing.is_empty() && media_parts.is_empty() {
        return;
    }
    let mut parts = Vec::new();
    if !existing.is_empty() {
        parts.push(ContentPart::text(existing.clone()));
    }
    for part in media_parts {
        let duplicate = matches!(&part, ContentPart::Text { text, .. } if text == &existing);
        if !duplicate {
            parts.push(part);
        }
    }
    if let Some(last) = messages
        .iter_mut()
        .rev()
        .find(|message| matches!(message.role, crate::provider::MessageRole::User))
    {
        last.content = MessageContent::Parts(parts);
    } else {
        messages.push(ChatMessage::with_parts(
            crate::provider::MessageRole::User,
            parts,
        ));
    }
}

fn request_model_label(ctx: &NodeContext<'_>) -> String {
    ctx.string_param("model")
        .map(str::to_string)
        .unwrap_or_else(|_| "unknown".to_string())
}

struct ReasoningNode;

#[async_trait]
impl NodeExecutor for ReasoningNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let requested = match ctx.input("override") {
            Some(value) if !value.is_null() => value
                .get("level")
                .or_else(|| value.get("effort"))
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| ctx.string_param("level").unwrap_or("auto").to_string()),
            _ => ctx.string_param("level").unwrap_or("auto").to_string(),
        };
        let level = ReasoningLevel::parse(&requested).ok_or_else(|| {
            NodeError::new(
                error_codes::MODEL_UNSUPPORTED_REASONING,
                format!("unknown reasoning level {requested:?}"),
            )
        })?;
        if let Some(Value::Object(_)) = ctx.input("capabilities") {
            let capabilities: ModelCapabilities =
                serde_json::from_value(ctx.input("capabilities").cloned().unwrap_or(Value::Null))
                    .map_err(|error| {
                    NodeError::new(
                        error_codes::MODEL_UNKNOWN_CAPABILITY,
                        format!("capabilities input is not valid: {error}"),
                    )
                })?;
            capabilities.check_reasoning(level)?;
        }
        let config = json!({
            "level": level.as_str(),
            "enabled": level.enabled(),
            "source": "reasoning-node",
        });
        ctx.log(
            crate::event::LogLevel::Info,
            format!("reasoning level {}", level.as_str()),
        );
        Ok(NodeOutput::new()
            .with("config", config)
            .with("level", Value::String(level.as_str().to_string()))
            .with("done", Value::Bool(true)))
    }
}

struct PromptNode;

fn render_template(
    template: &str,
    variables: &BTreeMap<String, Value>,
    input: Option<&Value>,
) -> String {
    let mut rendered = template.to_string();
    if let Some(value) = input {
        let text = match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        };
        rendered = rendered.replace("{{input}}", &text);
        if let Value::Object(map) = value {
            for (key, value) in map {
                let text = match value {
                    Value::String(text) => text.clone(),
                    other => other.to_string(),
                };
                rendered = rendered.replace(&format!("{{{{{key}}}}}"), &text);
            }
        }
    }
    for (key, value) in variables {
        let text = match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        };
        rendered = rendered.replace(&format!("{{{{{key}}}}}"), &text);
    }
    rendered
}

#[async_trait]
impl NodeExecutor for PromptNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let input = ctx.input("input");
        let skill = ctx
            .input("skill")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let variables: BTreeMap<String, Value> = match ctx.param("variables") {
            Some(Value::String(text)) if !text.trim().is_empty() => serde_json::from_str(text)
                .map_err(|error| {
                    NodeError::new(
                        error_codes::INVALID_PARAM,
                        format!("prompt variables are not valid JSON: {error}"),
                    )
                })?,
            Some(Value::Object(map)) => map.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
            _ => BTreeMap::new(),
        };
        let mut system = render_template(ctx.string_param("system")?, &variables, input);
        if !skill.trim().is_empty() {
            system.push_str("\n\n");
            system.push_str(skill);
        }
        let user = render_template(ctx.string_param("user")?, &variables, input);
        let mut messages = Vec::new();
        if !system.trim().is_empty() {
            messages.push(ChatMessage::system(system.clone()));
        }
        if !user.trim().is_empty() {
            messages.push(ChatMessage::user(user.clone()));
        }
        let messages = serde_json::to_value(&messages).unwrap_or(Value::Array(Vec::new()));
        Ok(NodeOutput::new()
            .with("system", Value::String(system))
            .with("user", Value::String(user))
            .with("messages", messages)
            .with("done", Value::Bool(true)))
    }
}

struct ContextNode;

fn snapshot_json(snapshot: &ContextSnapshot) -> Value {
    json!({
        "handle": snapshot.handle,
        "messages": snapshot.messages,
        "count": snapshot.count,
        "estimatedTokens": snapshot.estimated_tokens,
        "trimmed": snapshot.trimmed,
    })
}

fn content_parts_from_input(value: Option<&Value>) -> Vec<ContentPart> {
    let Some(value) = value else {
        return Vec::new();
    };
    let list = match value {
        Value::Array(items) => items.clone(),
        Value::Object(map) => match map.get("parts") {
            Some(Value::Array(items)) => items.clone(),
            _ => vec![value.clone()],
        },
        _ => Vec::new(),
    };
    list.into_iter()
        .filter_map(|item| serde_json::from_value::<ContentPart>(item).ok())
        .collect()
}

/// Builds the ordered multimodal payload that travels Context -> Model.
/// Each input slot keeps the order of its own media list; the partOrder
/// parameter decides how the different modalities interleave.
fn ordered_context_parts(ctx: &NodeContext<'_>) -> Vec<ContentPart> {
    let order = ctx
        .string_param("partOrder")
        .unwrap_or("text,image,audio,video,document");
    let mut parts = Vec::new();
    for token in order.split(',') {
        let token = token.trim().to_ascii_lowercase();
        match token.as_str() {
            "text" => {
                if let Some(text) = ctx.input("text").and_then(Value::as_str) {
                    if !text.is_empty() {
                        parts.push(ContentPart::text(text.to_string()));
                    }
                }
            }
            "image" | "audio" | "video" | "document" => {
                parts.extend(content_parts_from_input(ctx.input(token.as_str())));
            }
            "assets" | "media" => {
                parts.extend(content_parts_from_input(ctx.input("assets")));
            }
            _ => {}
        }
    }
    // Unknown custom part arrays still reach the model instead of being dropped.
    parts.extend(content_parts_from_input(ctx.input("assets")));
    parts
}

#[async_trait]
impl NodeExecutor for ContextNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let max_messages = ctx.number_param("maxMessages")?.max(1.0) as usize;
        let max_tokens = ctx.number_param("maxTokens")?.max(1.0) as u64;
        let overflow = OverflowPolicy::parse(ctx.string_param("overflow")?);
        let initial = ctx.input("messages");
        let assistant = ctx.input("assistant");
        // The dispatcher emits its own result objects; normalize them into the
        // context record shape before storing the tool turn.
        let normalized_results;
        let tool_results = match ctx.input("toolResults") {
            Some(Value::Array(items)) if items.iter().any(|item| item.get("ok").is_some()) => {
                normalized_results = Value::Array(
                    items
                        .iter()
                        .map(record_from_result)
                        .filter_map(|record| serde_json::to_value(record).ok())
                        .collect(),
                );
                Some(&normalized_results)
            }
            other => other,
        };
        let snapshot = ctx.services.update_context(
            &ctx.state_key(),
            initial,
            assistant,
            tool_results,
            max_messages,
            max_tokens,
            overflow,
        )?;
        if snapshot.trimmed > 0 {
            ctx.log(
                crate::event::LogLevel::Warn,
                format!("context trimmed {} old message(s)", snapshot.trimmed),
            );
        }
        let parts = ordered_context_parts(ctx);
        let parts_json = serde_json::to_value(&parts).unwrap_or(Value::Null);
        Ok(NodeOutput::new()
            .with("context", snapshot_json(&snapshot))
            .with("handle", Value::String(snapshot.handle.clone()))
            .with(
                "messages",
                serde_json::to_value(&snapshot.messages).unwrap_or(Value::Null),
            )
            .with("assets", parts_json.clone())
            .with("parts", parts_json)
            .with("trimmed", Value::from(snapshot.trimmed))
            .with("done", Value::Bool(true)))
    }
}

struct ToolSetNode;

#[async_trait]
impl NodeExecutor for ToolSetNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let requested: Vec<String> = ctx
            .string_param("builtins")?
            .split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect();
        let available = ctx.services.builtin_tools().definitions(&requested);
        let found: Vec<&str> = available.iter().map(|tool| tool.name.as_str()).collect();
        for name in &requested {
            if !found.contains(&name.as_str()) {
                return Err(NodeError::new(
                    error_codes::TOOL_UNKNOWN,
                    format!("unknown builtin tool {name:?}"),
                ));
            }
        }
        let mut definitions = available;
        if let Some(mcp) = ctx.input("mcp") {
            if !mcp.is_null() {
                let mcp_tools = mcp.get("tools").cloned().unwrap_or_else(|| mcp.clone());
                definitions.extend(parse_tool_definitions(&mcp_tools)?);
            }
        }
        let handle = ctx.services.register_toolset(definitions.clone())?;
        let names: Vec<&str> = definitions.iter().map(|tool| tool.name.as_str()).collect();
        Ok(NodeOutput::new()
            .with("toolset", Value::String(handle))
            .with("tools", tool_definitions_json(&definitions))
            .with("names", json!(names)))
    }
}

struct ToolDispatchNode;

fn tool_result_json(call: &ToolCall, result: Result<Value, NodeError>, duration_ms: u64) -> Value {
    match result {
        Ok(value) => json!({
            "toolCallId": call.id,
            "name": call.name,
            "ok": true,
            "result": value,
            "error": Value::Null,
            "durationMs": duration_ms,
        }),
        Err(error) => json!({
            "toolCallId": call.id,
            "name": call.name,
            "ok": false,
            "result": Value::Null,
            "error": error.message,
            "errorCode": error.code,
            "durationMs": duration_ms,
        }),
    }
}

fn record_from_result(value: &Value) -> ToolResultRecord {
    let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let content = if ok {
        value
            .get("result")
            .map(|result| match result {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            })
            .unwrap_or_default()
    } else {
        value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("tool failed")
            .to_string()
    };
    ToolResultRecord {
        tool_call_id: value
            .get("toolCallId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        name: value
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        content,
        error: !ok,
    }
}

#[async_trait]
impl NodeExecutor for ToolDispatchNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let toolset = ctx.input("toolset").ok_or_else(|| {
            NodeError::new(error_codes::MISSING_INPUT, "toolset input is required")
        })?;
        let definitions = match toolset {
            Value::String(handle) if !handle.is_empty() => ctx.services.toolset(handle)?,
            value => tool_definitions_from_input(value)?,
        };
        let calls_value = ctx
            .input("calls")
            .ok_or_else(|| NodeError::new(error_codes::MISSING_INPUT, "calls input is required"))?;
        let calls: Vec<ToolCall> =
            serde_json::from_value(calls_value.clone()).map_err(|error| {
                NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("tool calls are not valid: {error}"),
                )
            })?;
        let mut results = Vec::with_capacity(calls.len());
        let mut failed = false;
        for call in &calls {
            let started = Instant::now();
            let Some(definition) = definitions.iter().find(|tool| tool.name == call.name) else {
                failed = true;
                let error = NodeError::new(
                    error_codes::TOOL_UNKNOWN,
                    format!("no tool named {:?} in this tool set", call.name),
                );
                ctx.tool_started(&call.id, &call.name, &call.arguments.to_string());
                let result = tool_result_json(call, Err(error), 0);
                ctx.tool_finished(
                    &call.id,
                    &call.name,
                    false,
                    0,
                    result
                        .get("error")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    "unknown tool".to_string(),
                );
                results.push(result);
                continue;
            };
            let arguments_text = call.arguments.to_string();
            ctx.tool_started(&call.id, &call.name, &arguments_text);
            let outcome = async {
                validate_arguments(&definition.parameters, &call.arguments)?;
                let permission_target = if definition.source.starts_with("mcp:") {
                    format!("{} via {}", call.name, definition.source)
                } else {
                    call.name.clone()
                };
                ctx.services
                    .permissions
                    .authorize(
                        ctx,
                        PermissionClass::Tool,
                        &permission_target,
                        &format!(
                            "{} (capability {}) with arguments {}",
                            definition.description, definition.capability, arguments_text
                        ),
                        definition.capability != "compute",
                    )
                    .await?;
                let timeout = Duration::from_millis(definition.timeout_ms.max(1));
                let execution = async {
                    if let Some(handle) = definition.source.strip_prefix("mcp:") {
                        ctx.services
                            .mcp
                            .call(
                                handle,
                                &definition.name,
                                call.arguments.clone(),
                                ctx.control,
                            )
                            .await
                    } else {
                        ctx.services
                            .builtin_tools()
                            .execute(&definition.name, call.arguments.clone(), ctx.control)
                            .await
                    }
                };
                match tokio::time::timeout(timeout, execution).await {
                    Ok(result) => result,
                    Err(_) => Err(NodeError::new(
                        error_codes::TOOL_TIMEOUT,
                        format!(
                            "tool {:?} timed out after {} ms",
                            call.name, definition.timeout_ms
                        ),
                    )),
                }
            }
            .await;
            let duration_ms = started.elapsed().as_millis() as u64;
            let ok = outcome.is_ok();
            failed |= !ok;
            let result = tool_result_json(call, outcome, duration_ms);
            let preview = if ok {
                result
                    .get("result")
                    .map(|value| match value {
                        Value::String(text) => text.clone(),
                        other => other.to_string(),
                    })
                    .unwrap_or_default()
            } else {
                result
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("tool failed")
                    .to_string()
            };
            ctx.tool_finished(
                &call.id,
                &call.name,
                ok,
                duration_ms,
                if ok { None } else { Some(preview.clone()) },
                preview.chars().take(500).collect(),
            );
            results.push(result);
        }
        let summary = results
            .iter()
            .map(|result| {
                format!(
                    "{}: {}",
                    result.get("name").and_then(Value::as_str).unwrap_or("tool"),
                    if result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                        "ok"
                    } else {
                        "failed"
                    }
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        Ok(NodeOutput::new()
            .with("results", json!(results.clone()))
            .with("summary", Value::String(summary))
            .with("failed", Value::Bool(failed))
            .with("done", Value::Bool(true)))
    }
}

struct McpServerNode;

#[async_trait]
impl NodeExecutor for McpServerNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let transport = ctx.string_param("transport")?.to_string();
        let namespace = ctx.string_param("namespace")?.trim().to_string();
        if namespace.is_empty() {
            return Err(NodeError::new(
                error_codes::INVALID_PARAM,
                "MCP namespace must not be empty",
            ));
        }
        let handle = format!("mcp-{}", uuid::Uuid::new_v4());
        let definitions = if transport == "http" {
            let url = ctx.string_param("url")?.trim().to_string();
            ctx.services
                .permissions
                .authorize(
                    ctx,
                    PermissionClass::Network,
                    &url,
                    "connect to a Streamable HTTP MCP server",
                    true,
                )
                .await?;
            let credential_ref = ctx.string_param("credentialRef")?.trim().to_string();
            let secret = if credential_ref.is_empty() {
                None
            } else {
                Some(ctx.services.credentials.resolve(&credential_ref).await?)
            };
            ctx.services
                .mcp
                .connect_http(
                    &handle,
                    &namespace,
                    &McpHttpConfig {
                        url,
                        credential_ref: if credential_ref.is_empty() {
                            None
                        } else {
                            Some(credential_ref)
                        },
                    },
                    secret,
                )
                .await?
        } else {
            let command = ctx.string_param("command")?.trim().to_string();
            if command.is_empty() {
                return Err(NodeError::new(
                    error_codes::INVALID_PARAM,
                    "MCP command must not be empty",
                ));
            }
            let args: Vec<String> = ctx
                .string_param("args")?
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_string)
                .collect();
            let cwd = {
                let value = ctx.string_param("cwd")?.trim();
                (!value.is_empty()).then(|| std::path::PathBuf::from(value))
            };
            let env: Vec<(String, String)> = ctx
                .string_param("env")?
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(|line| {
                    line.split_once('=')
                        .map(|(key, value)| (key.trim().to_string(), value.to_string()))
                        .ok_or_else(|| {
                            NodeError::new(
                                error_codes::INVALID_PARAM,
                                format!("MCP environment line {line:?} must be KEY=VALUE"),
                            )
                        })
                })
                .collect::<Result<_, _>>()?;
            let executable = resolve_executable(&command);
            let env_names: Vec<&str> = env.iter().map(|(key, _)| key.as_str()).collect();
            let detail = format!(
                "spawn MCP server as namespace {namespace}\nexecutable: {executable}\narguments: {args:?}\ncwd: {}\nenvironment keys: {}\nisolation: child process inherits this user's permissions; it is not sandboxed",
                cwd.as_ref().map(|path| path.display().to_string()).unwrap_or_else(|| "(inherited)".to_string()),
                if env_names.is_empty() { "(none)".to_string() } else { env_names.join(", ") }
            );
            ctx.services
                .permissions
                .authorize(ctx, PermissionClass::Process, &executable, &detail, true)
                .await?;
            ctx.services
                .mcp
                .connect_stdio(
                    &handle,
                    &namespace,
                    &McpStdioConfig {
                        command,
                        args,
                        env: env.into_iter().collect(),
                        cwd: cwd.as_ref().map(|path| path.display().to_string()),
                    },
                )
                .await?
        };
        let names: Vec<&str> = definitions.iter().map(|tool| tool.name.as_str()).collect();
        ctx.log(
            crate::event::LogLevel::Info,
            format!(
                "MCP namespace {namespace} discovered {} tool(s): {}",
                definitions.len(),
                names.join(", ")
            ),
        );
        let tools = tool_definitions_json(&definitions);
        Ok(NodeOutput::new()
            .with(
                "mcp",
                json!({"handle": handle, "namespace": namespace, "tools": tools.clone()}),
            )
            .with("tools", tools)
            .with("handle", Value::String(handle))
            .with("toolCount", Value::from(definitions.len()))
            .with("done", Value::Bool(true)))
    }
}

struct SkillNode;

fn resolve_executable(command: &str) -> String {
    let candidate = std::path::Path::new(command);
    if candidate.components().count() > 1 {
        return candidate
            .canonicalize()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| command.to_string());
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for directory in std::env::split_paths(&paths) {
            let path = directory.join(command);
            if path.is_file() {
                return path.display().to_string();
            }
        }
    }
    command.to_string()
}

fn skill_messages(skill: &crate::skills::SkillDocument, input: Option<&Value>) -> Vec<ChatMessage> {
    let mut messages = vec![ChatMessage::system(
        skill
            .system_message()
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )];
    if let Some(value) = input {
        let text = match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        };
        if !text.trim().is_empty() {
            messages.push(ChatMessage::user(text));
        }
    }
    messages
}

#[async_trait]
impl NodeExecutor for SkillNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let library: &SkillLibrary = ctx.services.skills().ok_or_else(|| {
            NodeError::new(
                error_codes::SKILL_NOT_FOUND,
                "no skills directory is configured (set LINGXI_SKILLS_DIR)",
            )
        })?;
        let id = ctx.string_param("skillId")?.trim().to_string();
        let root = library.root().display().to_string();
        ctx.services
            .permissions
            .authorize(
                ctx,
                PermissionClass::Filesystem,
                &root,
                &format!("read local skill {id:?}"),
                true,
            )
            .await?;
        let skill = library.load(&id)?;
        let input = ctx.input("input");
        let messages = skill_messages(&skill, input);
        let content = skill
            .system_message()
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        Ok(NodeOutput::new()
            .with("skill", Value::String(content))
            .with(
                "messages",
                serde_json::to_value(&messages).unwrap_or(Value::Array(Vec::new())),
            )
            .with("resources", json!(skill.resources))
            .with("done", Value::Bool(true)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image_part() -> ContentPart {
        let asset: lingxi_spec::AssetRef = serde_json::from_value(json!({
            "id": format!("asset-{}", "a".repeat(64)),
            "name": "pixel.png",
            "mime": "image/png",
            "size": 8,
            "sha256": "a".repeat(64),
            "kind": "image",
            "source": "test"
        }))
        .expect("asset fixture");
        ContentPart::image(asset)
    }

    #[test]
    fn media_parts_merge_into_the_last_user_turn() {
        let mut messages = vec![
            ChatMessage::system("system"),
            ChatMessage::user("describe the picture"),
        ];
        merge_media_into_last_user(
            &mut messages,
            vec![ContentPart::text("describe the picture"), image_part()],
        );
        assert_eq!(messages.len(), 2, "media must not add a second user turn");
        let parts = messages[1].content.as_parts();
        assert_eq!(parts.len(), 2, "duplicate text is not repeated: {parts:?}");
        assert!(
            matches!(&parts[0], ContentPart::Text { text, .. } if text == "describe the picture")
        );
        assert!(matches!(&parts[1], ContentPart::Image { .. }));
    }
}
