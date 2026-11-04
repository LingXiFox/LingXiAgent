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

use crate::context::NodeContext;
use crate::conversation::{messages_from_json, ContextSnapshot, OverflowPolicy, ToolResultRecord};
use crate::error::{error_codes, NodeError};
use crate::event::RunEvent;
use crate::mcp::{McpHttpConfig, McpStdioConfig};
use crate::permissions::PermissionClass;
use crate::provider::{
    ChatMessage, ChatRequest, OpenAiFactory, ProviderConfig, ProviderFactory, ToolCall,
};
use crate::registry::{NodeExecutor, NodeOutput};
use crate::skills::SkillLibrary;
use crate::tools::{
    parse_tool_definitions, tool_definitions_json, validate_arguments, ToolDefinition,
};

pub const PROVIDER_KIND: &str = "core.provider";
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

fn provider_spec() -> NodeSpec {
    NodeSpec::new(PROVIDER_KIND, "Provider", "Agent")
        .description("Declares an OpenAI-compatible model service. Secrets are referenced, never stored here.")
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
        .param(ParamSpec::boolean("supportsReasoning", "Reasoning support", true))
}

fn model_spec() -> NodeSpec {
    NodeSpec::new(MODEL_KIND, "Model", "Agent")
        .description("Calls one chat completion. Emits text, tool calls and a done control signal.")
        .input(control_port("run", "Run"))
        .input(text_port("provider", "Provider").required())
        .input(json_port("context", "Context"))
        .input(json_port("messages", "Messages"))
        .input(text_port("toolset", "Tool Set"))
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
        .param(ParamSpec::number("timeoutMs", "Timeout (ms)", 60000.0))
        .param(
            ParamSpec::number("maxCalls", "Max Calls", 8.0)
                .help("Budget for this model node in one run. Exhaustion fails the run."),
        )
        .param(ParamSpec::number("maxTotalTokens", "Max Total Tokens", 0.0))
        .capability(lingxi_spec::node::capabilities::NETWORK)
        .capability("credential")
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
        .output(json_port("context", "Context"))
        .output(text_port("handle", "Handle"))
        .output(json_port("messages", "Messages"))
        .output(PortSpec::new("trimmed", "Trimmed", DataType::Number))
        .output(control_port("done", "Done"))
        .param(ParamSpec::number("maxMessages", "Max Messages", 40.0))
        .param(ParamSpec::number("maxTokens", "Max Estimated Tokens", 12000.0))
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
    registry
        .register(provider_spec(), Arc::new(ProviderNode))
        .expect("provider node registers");
    registry
        .register(model_spec(), Arc::new(ModelNode))
        .expect("model node registers");
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

fn assistant_message_json(text: &str, calls: &[ToolCall]) -> Value {
    let message = ChatMessage {
        role: crate::provider::MessageRole::Assistant,
        content: text.to_string(),
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

        let model = ctx.string_param("model")?.trim().to_string();
        if model.is_empty() {
            return Err(NodeError::new(
                error_codes::PROVIDER_CONFIG,
                "model id must not be empty",
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
                &config.host(),
                &format!("provider {} at {}", config.provider_id, config.base_url),
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
        let provider = OpenAiFactory::default().create(&config, secret).await?;

        let temperature = ctx.number_param("temperature")?;
        let max_tokens = ctx.number_param("maxTokens")?;
        let reasoning = ctx.string_param("reasoningEffort")?.to_string();
        let stream = ctx.bool_param("stream")?;
        let timeout_ms = ctx.number_param("timeoutMs")?.max(1.0) as u64;
        let request = ChatRequest {
            model,
            messages,
            temperature: Some(temperature),
            max_tokens: if max_tokens > 0.0 {
                Some(max_tokens as u32)
            } else {
                None
            },
            reasoning_effort: Some(reasoning),
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
            .with("done", Value::Bool(true)))
    }
}

fn request_model_label(ctx: &NodeContext<'_>) -> String {
    ctx.string_param("model")
        .map(str::to_string)
        .unwrap_or_else(|_| "unknown".to_string())
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
        Ok(NodeOutput::new()
            .with("context", snapshot_json(&snapshot))
            .with("handle", Value::String(snapshot.handle.clone()))
            .with(
                "messages",
                serde_json::to_value(&snapshot.messages).unwrap_or(Value::Null),
            )
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
            ctx.services
                .permissions
                .authorize(
                    ctx,
                    PermissionClass::Process,
                    &command,
                    &format!("spawn MCP server {command} as namespace {namespace}"),
                    true,
                )
                .await?;
            let args: Vec<String> = ctx
                .string_param("args")?
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_string)
                .collect();
            ctx.services
                .mcp
                .connect_stdio(
                    &handle,
                    &namespace,
                    &McpStdioConfig {
                        command,
                        args,
                        env: std::collections::HashMap::new(),
                        cwd: None,
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
