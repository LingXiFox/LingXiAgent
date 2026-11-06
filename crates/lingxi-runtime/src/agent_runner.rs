//! Independent AgentRunner.
//!
//! The runner owns a multi-turn model/tool loop for one Agent activation. It
//! reuses the same provider, permission, context and workspace-tool modules as
//! the ordinary Model/Tool Dispatch nodes; the workflow engine never looks
//! inside the loop. Pause, intervention and config revision checks happen at
//! explicit safe points between model requests and tool calls.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::agent_bus::{AgentBus, AgentRuntime};
use crate::agent_protocol::{states, AgentConfigSnapshot, AgentResult, AgentUsage};
use crate::capabilities::{ModelCapabilities, ReasoningLevel};
use crate::content::{ContentPart, MessageContent};
use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::event::{AgentEvent, RunEvent};
use crate::lsp::LspClient;
use crate::permissions::PermissionClass;
use crate::provider::{
    ChatMessage, ChatRequest, MessageRole, OpenAiFactory, ProviderFactory, ToolCall,
};
use crate::tools::{validate_arguments, ToolDefinition};

pub const SUBMIT_RESULT_TOOL: &str = "submit_result";

/// One activation immutable inputs. Configuration that may change while the
/// task is running lives in `AgentConfigSnapshot` instead.
#[derive(Debug, Clone)]
pub struct AgentInput {
    pub provider_handle: String,
    pub instruction: String,
    pub task_context: Option<String>,
    pub max_tokens: u32,
    pub tools: Vec<ToolDefinition>,
    pub task_id: String,
    pub correlation_id: Option<String>,
    pub recipient: Option<String>,
    pub media: Vec<ContentPart>,
    pub lsp: Vec<crate::lsp::LspConfig>,
    /// Project workspace bound to this Agent. File, process and LSP tools all
    /// use this same root; a missing workspace disables those tools.
    pub workspace: Option<Arc<crate::workspace::Workspace>>,
    pub relative_cwd: String,
    /// Prior conversation turns for this Agent node in the current task session.
    pub history: Vec<ChatMessage>,
}

#[derive(Debug, Clone)]
pub struct AgentOutcome {
    pub result: AgentResult,
    pub usage: AgentUsage,
    pub config: AgentConfigSnapshot,
    pub messages: Vec<ChatMessage>,
}

pub fn submit_result_definition() -> ToolDefinition {
    ToolDefinition {
        name: SUBMIT_RESULT_TOOL.to_string(),
        description: "Submit the final structured result. agentMessage is for other agents; userResponse is the human-readable report. Call this exactly once when the task is finished or blocked.".to_string(),
        parameters: AgentResult::schema(),
        capability: "compute".to_string(),
        source: "agent".to_string(),
        timeout_ms: 1_000,
    }
}

pub async fn run_agent(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    activation_id: &str,
    mut config: AgentConfigSnapshot,
    input: AgentInput,
) -> Result<AgentOutcome, NodeError> {
    config.validate()?;
    let runtime = bus
        .runtime(instance_id)
        .unwrap_or_else(|| bus.ensure_runtime(instance_id));
    let provider_config = ctx.services.provider(&input.provider_handle)?;
    let capabilities = ModelCapabilities::infer(provider_config.protocol.as_str(), &config.model);
    capabilities.check_parts(&input.media)?;
    let mut reasoning = ReasoningLevel::parse(&config.reasoning).ok_or_else(|| {
        NodeError::new(
            error_codes::AGENT_INVALID_CONFIG,
            format!("unknown reasoning level {:?}", config.reasoning),
        )
    })?;
    // `auto` means choose from the model's declared capabilities. Models without
    // native reasoning simply run without a reasoning level instead of failing.
    if reasoning == ReasoningLevel::Auto
        && capabilities.features.reasoning != crate::capabilities::Support::Native
    {
        reasoning = ReasoningLevel::Off;
    }
    capabilities.check_reasoning(reasoning)?;
    ctx.services
        .permissions
        .authorize(
            ctx,
            PermissionClass::Network,
            &provider_config.target(),
            &format!(
                "agent {} uses provider {} at {}",
                instance_id, provider_config.provider_id, provider_config.base_url
            ),
            true,
        )
        .await?;
    let secret = if provider_config.credential_ref.trim().is_empty() {
        None
    } else {
        Some(
            ctx.services
                .credentials
                .resolve(&provider_config.credential_ref)
                .await?,
        )
    };
    let provider = OpenAiFactory::default()
        .create(&provider_config, secret, Arc::clone(&ctx.services.assets))
        .await?;
    if input.lsp.len() > 1 {
        return Err(NodeError::new(
            error_codes::AGENT_INVALID_CONFIG,
            "only one LSP server can be attached to an activation",
        ));
    }
    let mut lsp_client = if let Some(lsp) = input.lsp.first() {
        ctx.services
            .permissions
            .authorize(
                ctx,
                PermissionClass::Process,
                &lsp.command,
                &format!("agent {instance_id} starts language server {}", lsp.command),
                true,
            )
            .await?;
        let mut client = LspClient::spawn(lsp).await?;
        client.initialize().await?;
        Some(client)
    } else {
        None
    };
    let budget = config.budget();
    let deadline = Instant::now() + Duration::from_millis(budget.timeout_ms);
    let state_key = ctx.state_key();
    let mut usage = AgentUsage::default();
    let started = Instant::now();
    let mut messages = initial_messages(&input);
    let mut repair_attempts = 0u32;
    let mut invalid_submissions = 0u32;
    let mut tool_calls_total = 0u32;

    loop {
        ensure_active(ctx, &runtime)?;
        wait_for_safe_point(ctx, bus, instance_id, activation_id, &runtime).await?;
        apply_pending_config(ctx, bus, instance_id, activation_id, &mut config)?;
        drain_directives(ctx, &runtime, instance_id, activation_id, &mut messages);
        if Instant::now() >= deadline {
            return Err(NodeError::new(
                error_codes::AGENT_TIMEOUT,
                format!("agent exceeded its {}ms budget", budget.timeout_ms),
            ));
        }
        if usage.iterations >= config.max_iterations {
            return Err(NodeError::new(
                error_codes::AGENT_ITERATION_BUDGET,
                format!(
                    "agent used all {} iterations without a final result",
                    config.max_iterations
                ),
            ));
        }
        usage.iterations += 1;
        usage.model_calls += 1;
        let tools = current_tools(ctx, &config, &input);
        let mut request_messages = messages.clone();
        if !input.media.is_empty() {
            merge_media(&mut request_messages, input.media.clone());
        }
        if let Some(system) = system_message(ctx, &config)? {
            request_messages.insert(0, ChatMessage::system(system));
        }
        let reasoning_effort = if reasoning.enabled() {
            Some(reasoning.as_str().to_string())
        } else {
            None
        };
        let timeout_ms = deadline
            .saturating_duration_since(Instant::now())
            .as_millis()
            .max(1) as u64;
        let request = ChatRequest {
            model: config.model.clone(),
            messages: request_messages,
            temperature: Some(config.temperature),
            max_tokens: if input.max_tokens > 0 {
                Some(input.max_tokens)
            } else {
                None
            },
            reasoning_effort,
            previous_response_id: None,
            stream: true,
            tools: provider_tool_schema(&tools),
            timeout_ms,
        };
        let emitter = ctx.emitter.fork();
        let run_id = ctx.run_id.to_string();
        let agent_instance = instance_id.to_string();
        let activation = activation_id.to_string();
        let mut delta = move |chunk: String| {
            if chunk.is_empty() {
                return;
            }
            emitter.emit(RunEvent::Agent {
                run_id: run_id.clone(),
                seq: 0,
                scope: Vec::new(),
                event: Box::new(AgentEvent::Delta {
                    agent_instance_id: agent_instance.clone(),
                    activation_id: activation.clone(),
                    delta: chunk,
                }),
            });
        };
        let response = provider.complete(request, ctx.control, &mut delta).await?;
        usage.prompt_tokens = usage
            .prompt_tokens
            .saturating_add(response.usage.prompt_tokens);
        usage.completion_tokens = usage
            .completion_tokens
            .saturating_add(response.usage.completion_tokens);
        usage.elapsed_ms = started.elapsed().as_millis() as u64;
        if config.max_total_tokens > 0 && usage.total_tokens() > config.max_total_tokens {
            return Err(NodeError::new(
                error_codes::AGENT_TOKEN_BUDGET,
                format!(
                    "agent used {} tokens; budget is {}",
                    usage.total_tokens(),
                    config.max_total_tokens
                ),
            ));
        }
        let _ = ctx.services.record_tokens(
            &state_key,
            response.usage.prompt_tokens,
            response.usage.completion_tokens,
            0,
        );
        bus.record_usage(instance_id, activation_id, &usage)?;
        emit_usage(ctx, instance_id, &usage);
        // A pause requested while the model request was in flight must take effect
        // before any tool call or structured result is acted on.
        wait_for_safe_point(ctx, bus, instance_id, activation_id, &runtime).await?;

        if response.tool_calls.is_empty() {
            if response.text.trim().is_empty() {
                return Err(NodeError::new(
                    error_codes::AGENT_INVALID_RESULT,
                    "model returned neither text nor tool calls",
                ));
            }
            if repair_attempts >= 1 {
                return Err(NodeError::new(
                    error_codes::AGENT_INVALID_RESULT,
                    "model did not submit a structured result after one repair request",
                ));
            }
            repair_attempts += 1;
            messages.push(ChatMessage::assistant(response.text.clone()));
            messages.push(ChatMessage::user(
                "Your previous answer was prose only. Call the submit_result tool with status, agentMessage (object), userResponse (string) and artifacts. Do not answer with prose.",
            ));
            continue;
        }

        messages.push(ChatMessage {
            role: MessageRole::Assistant,
            content: MessageContent::text(response.text.clone()),
            tool_calls: response.tool_calls.clone(),
            tool_call_id: None,
            name: None,
        });
        for call in &response.tool_calls {
            if call.name == SUBMIT_RESULT_TOOL {
                match parse_result(call, &input) {
                    Ok(result) => {
                        usage.elapsed_ms = started.elapsed().as_millis() as u64;
                        bus.record_usage(instance_id, activation_id, &usage)?;
                        emit_usage(ctx, instance_id, &usage);
                        if let Some(client) = lsp_client.take() {
                            client.shutdown().await;
                        }
                        return Ok(AgentOutcome {
                            result,
                            usage,
                            config,
                            messages,
                        });
                    }
                    Err(error) => {
                        invalid_submissions += 1;
                        if invalid_submissions > 1 {
                            return Err(error);
                        }
                        messages.push(ChatMessage::tool(
                            call.id.clone(),
                            json!({"ok": false, "error": error.message}).to_string(),
                        ));
                        messages.push(ChatMessage::user(
                            "The submit_result payload was rejected. Fix it and call submit_result again. agentMessage must be an object and userResponse must be non-empty.",
                        ));
                        continue;
                    }
                }
            }
            if tool_calls_total >= config.max_tool_calls {
                return Err(NodeError::new(
                    error_codes::AGENT_TOOL_BUDGET,
                    format!(
                        "agent used all {} tool calls without a final result",
                        config.max_tool_calls
                    ),
                ));
            }
            ensure_active(ctx, &runtime)?;
            wait_for_safe_point(ctx, bus, instance_id, activation_id, &runtime).await?;
            tool_calls_total += 1;
            usage.tool_calls += 1;
            let definition = tools.iter().find(|definition| definition.name == call.name);
            let Some(definition) = definition else {
                return Err(NodeError::new(
                    error_codes::TOOL_UNKNOWN,
                    format!("tool {:?} is not in this agent tool set", call.name),
                ));
            };
            validate_arguments(&definition.parameters, &call.arguments)?;
            authorize_tool(ctx, bus, instance_id, activation_id, call, definition).await?;
            emit_agent_event(
                ctx,
                AgentEvent::ToolStarted {
                    agent_instance_id: instance_id.to_string(),
                    activation_id: activation_id.to_string(),
                    tool_call_id: call.id.clone(),
                    tool_name: call.name.clone(),
                    arguments: call.arguments.to_string(),
                },
            );
            let tool_started = Instant::now();
            let result = if matches!(call.name.as_str(), "lsp_diagnostics" | "lsp_symbols") {
                match (lsp_client.as_mut(), input.workspace.as_ref()) {
                    (Some(client), Some(workspace)) => {
                        tokio::select! {
                            result = execute_lsp(client, workspace, &call.name, &call.arguments) => result,
                            _ = ctx.control.cancelled() => Err(NodeError::cancelled("agent execution cancelled")),
                        }
                    }
                    (None, _) => Err(NodeError::new(
                        error_codes::LSP_NOT_FOUND,
                        "LSP tool was called without an attached language server",
                    )),
                    (_, None) => Err(NodeError::new(
                        error_codes::WORKSPACE_NOT_FOUND,
                        "LSP tool requires a workspace",
                    )),
                }
            } else {
                ctx.services
                    .builtin_tools()
                    .execute_with_workspace(
                        &call.name,
                        call.arguments.clone(),
                        ctx.control,
                        input.workspace.clone(),
                    )
                    .await
            };
            let duration_ms = tool_started.elapsed().as_millis() as u64;
            if let Err(error) = &result {
                if error.code == error_codes::CANCELLED {
                    return Err(error.clone());
                }
            }
            let record = match &result {
                Ok(value) => crate::tools::ToolResult {
                    tool_call_id: call.id.clone(),
                    name: call.name.clone(),
                    ok: true,
                    result: value.clone(),
                    error: None,
                    duration_ms,
                },
                Err(error) => crate::tools::ToolResult {
                    tool_call_id: call.id.clone(),
                    name: call.name.clone(),
                    ok: false,
                    result: Value::Null,
                    error: Some(error.message.clone()),
                    duration_ms,
                },
            };
            emit_agent_event(
                ctx,
                AgentEvent::ToolFinished {
                    agent_instance_id: instance_id.to_string(),
                    activation_id: activation_id.to_string(),
                    tool_call_id: call.id.clone(),
                    tool_name: call.name.clone(),
                    ok: record.ok,
                    duration_ms,
                    error: record.error.clone(),
                    result: serde_json::to_string(&record.result).unwrap_or_default(),
                },
            );
            let content = serde_json::to_string(&record).unwrap_or_else(|_| "{}".to_string());
            messages.push(ChatMessage::tool(call.id.clone(), content));
            usage.elapsed_ms = started.elapsed().as_millis() as u64;
            bus.record_usage(instance_id, activation_id, &usage)?;
        }
        usage.elapsed_ms = started.elapsed().as_millis() as u64;
        bus.record_usage(instance_id, activation_id, &usage)?;
        emit_usage(ctx, instance_id, &usage);
    }
}

fn initial_messages(input: &AgentInput) -> Vec<ChatMessage> {
    let mut user = String::new();
    if let Some(context) = &input.task_context {
        user.push_str("Task context:\n");
        user.push_str(context);
        user.push_str("\n\n");
    }
    user.push_str(&input.instruction);
    // The task session owns history; the frontend never replays it. Prior turns
    // are ordinary chat messages so the model sees the same conversation.
    let mut messages = input.history.clone();
    messages.push(ChatMessage::user(user));
    messages
}

fn system_message(
    ctx: &NodeContext<'_>,
    config: &AgentConfigSnapshot,
) -> Result<Option<String>, NodeError> {
    let mut sections = Vec::new();
    if !config.role_prompt.trim().is_empty() {
        sections.push(config.role_prompt.trim().to_string());
    }
    if !config.system_prompt.trim().is_empty() {
        sections.push(config.system_prompt.trim().to_string());
    }
    for skill in &config.skills {
        if let Some(library) = ctx.services.skills() {
            let document = library.load(skill)?;
            sections.push(format!(
                "Skill {}:\n{}\n\n{}",
                document.name, document.description, document.instructions
            ));
        }
    }
    sections.push(
        "You are an autonomous agent inside a workflow. Use the available tools when needed. When the task is complete, call submit_result with a structured agentMessage for downstream agents and a separate userResponse for the human. Never put secrets or huge file contents in messages; use artifact references.".to_string(),
    );
    Ok(Some(sections.join("\n\n")))
}

fn current_tools(
    ctx: &NodeContext<'_>,
    config: &AgentConfigSnapshot,
    input: &AgentInput,
) -> Vec<ToolDefinition> {
    let mut tools = if input.tools.is_empty() {
        ctx.services.builtin_tools().definitions(&config.toolset)
    } else {
        input.tools.clone()
    };
    if !tools.iter().any(|tool| tool.name == SUBMIT_RESULT_TOOL) {
        tools.push(submit_result_definition());
    }
    if !input.lsp.is_empty() {
        tools.push(lsp_tool(
            "lsp_diagnostics",
            "Return language-server diagnostics for a workspace file",
        ));
        tools.push(lsp_tool(
            "lsp_symbols",
            "Return document symbols for a workspace file",
        ));
    }
    tools
}

fn lsp_tool(name: &str, description: &str) -> ToolDefinition {
    ToolDefinition {
        name: name.to_string(),
        description: description.to_string(),
        parameters: json!({
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
            "additionalProperties": false
        }),
        capability: "tool".to_string(),
        source: "lsp".to_string(),
        timeout_ms: 10_000,
    }
}

async fn execute_lsp(
    client: &mut LspClient,
    workspace: &crate::workspace::Workspace,
    name: &str,
    arguments: &Value,
) -> Result<Value, NodeError> {
    let path = arguments
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| NodeError::new(error_codes::LSP_PROTOCOL, "LSP tool requires path"))?;
    let operation =
        async {
            match name {
                "lsp_diagnostics" => Ok(serde_json::to_value(
                    client.diagnostics(workspace, path).await?,
                )
                .unwrap_or(Value::Null)),
                "lsp_symbols" => Ok(serde_json::to_value(client.symbols(workspace, path).await?)
                    .unwrap_or(Value::Null)),
                other => Err(NodeError::new(
                    error_codes::TOOL_UNKNOWN,
                    format!("unknown LSP tool {other:?}"),
                )),
            }
        };
    match tokio::time::timeout(Duration::from_secs(10), operation).await {
        Ok(result) => result,
        Err(_) => Err(NodeError::new(
            error_codes::LSP_TIMEOUT,
            format!("language server did not answer {name} within 10s"),
        )),
    }
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

fn parse_result(call: &ToolCall, input: &AgentInput) -> Result<AgentResult, NodeError> {
    let mut result: AgentResult =
        serde_json::from_value(call.arguments.clone()).map_err(|error| {
            NodeError::new(
                error_codes::AGENT_INVALID_RESULT,
                format!("submit_result payload is invalid: {error}"),
            )
        })?;
    if result.correlation_id.is_none() {
        result.correlation_id = input.correlation_id.clone();
    }
    result.validate()?;
    for artifact in &result.artifacts {
        artifact.validate()?;
    }
    Ok(result)
}

async fn authorize_tool(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    activation_id: &str,
    call: &ToolCall,
    definition: &ToolDefinition,
) -> Result<(), NodeError> {
    let class = match definition.capability.as_str() {
        "filesystem" => PermissionClass::Filesystem,
        "process" => PermissionClass::Process,
        "network" => PermissionClass::Network,
        _ => PermissionClass::Tool,
    };
    let target = match call.name.as_str() {
        "read_file" | "write_file" | "list_files" | "delete_file" | "search_files" => call
            .arguments
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or(".")
            .to_string(),
        "run_command" => call
            .arguments
            .get("command")
            .and_then(Value::as_str)
            .unwrap_or("command")
            .to_string(),
        other => other.to_string(),
    };
    let read_only = matches!(
        call.name.as_str(),
        "read_file"
            | "list_files"
            | "search_files"
            | "git_status"
            | "git_diff"
            | "git_log"
            | "lsp_diagnostics"
            | "lsp_symbols"
    );
    let already_approved = ctx
        .services
        .permissions
        .is_approved(ctx.run_id, class, &target);
    if !already_approved {
        let _ = bus.set_instance_state(instance_id, states::WAITING_APPROVAL);
        emit_agent_event(
            ctx,
            AgentEvent::StateChanged {
                agent_instance_id: instance_id.to_string(),
                activation_id: Some(activation_id.to_string()),
                state: states::WAITING_APPROVAL.to_string(),
                reason: Some(format!("waiting for approval to use {}", call.name)),
            },
        );
    }
    let result = ctx
        .services
        .permissions
        .authorize_with(
            ctx,
            class,
            &target,
            &format!("agent tool {:?}", call.name),
            true,
            read_only,
        )
        .await;
    if !already_approved && !ctx.control.is_cancelled() {
        let _ = bus.set_instance_state(instance_id, states::RUNNING);
        emit_agent_event(
            ctx,
            AgentEvent::StateChanged {
                agent_instance_id: instance_id.to_string(),
                activation_id: Some(activation_id.to_string()),
                state: states::RUNNING.to_string(),
                reason: Some("approval resolved".to_string()),
            },
        );
    }
    result?;
    Ok(())
}

fn ensure_active(ctx: &NodeContext<'_>, runtime: &AgentRuntime) -> Result<(), NodeError> {
    if ctx.control.is_cancelled() || runtime.is_cancelled() {
        return Err(NodeError::cancelled("agent execution cancelled"));
    }
    Ok(())
}

async fn wait_for_safe_point(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    activation_id: &str,
    runtime: &Arc<AgentRuntime>,
) -> Result<(), NodeError> {
    if !runtime.is_paused() {
        return Ok(());
    }
    let _ = bus.set_instance_state(instance_id, states::PAUSED);
    emit_agent_event(
        ctx,
        AgentEvent::StateChanged {
            agent_instance_id: instance_id.to_string(),
            activation_id: Some(activation_id.to_string()),
            state: states::PAUSED.to_string(),
            reason: Some("safe pause point reached".to_string()),
        },
    );
    runtime.wait_until_resumed(ctx.control).await;
    ensure_active(ctx, runtime)?;
    let _ = bus.set_instance_state(instance_id, states::RUNNING);
    emit_agent_event(
        ctx,
        AgentEvent::StateChanged {
            agent_instance_id: instance_id.to_string(),
            activation_id: Some(activation_id.to_string()),
            state: states::RUNNING.to_string(),
            reason: Some("resumed".to_string()),
        },
    );
    Ok(())
}

fn apply_pending_config(
    ctx: &NodeContext<'_>,
    bus: &Arc<AgentBus>,
    instance_id: &str,
    activation_id: &str,
    config: &mut AgentConfigSnapshot,
) -> Result<(), NodeError> {
    let Some(pending) = bus
        .runtime(instance_id)
        .and_then(|runtime| runtime.take_pending_config())
    else {
        return Ok(());
    };
    let applied = bus.mark_config_applied(instance_id, pending.revision)?;
    *config = applied.clone();
    if let Some(revision) = bus.session().agents.get(instance_id).and_then(|instance| {
        instance
            .config_revisions
            .iter()
            .find(|revision| revision.revision == applied.revision)
            .cloned()
    }) {
        emit_agent_event(
            ctx,
            AgentEvent::ConfigChanged {
                agent_instance_id: instance_id.to_string(),
                revision: Box::new(revision),
            },
        );
    }
    emit_agent_event(
        ctx,
        AgentEvent::StateChanged {
            agent_instance_id: instance_id.to_string(),
            activation_id: Some(activation_id.to_string()),
            state: states::RUNNING.to_string(),
            reason: Some(format!(
                "config revision {} applied at the next iteration",
                applied.revision
            )),
        },
    );
    Ok(())
}

fn drain_directives(
    ctx: &NodeContext<'_>,
    runtime: &Arc<AgentRuntime>,
    instance_id: &str,
    activation_id: &str,
    messages: &mut Vec<ChatMessage>,
) {
    for text in runtime.take_directives() {
        messages.push(ChatMessage::user(format!(
            "User intervention for the current task (follow it; do not restart completed work):\n{text}"
        )));
        emit_agent_event(
            ctx,
            AgentEvent::Directive {
                agent_instance_id: instance_id.to_string(),
                activation_id: activation_id.to_string(),
                text,
            },
        );
    }
}

fn merge_media(messages: &mut [ChatMessage], media: Vec<ContentPart>) {
    if let Some(last_user) = messages
        .iter_mut()
        .rev()
        .find(|message| message.role == MessageRole::User)
    {
        let text = last_user.content.plain_text();
        let mut parts = vec![ContentPart::text(text)];
        parts.extend(media);
        last_user.content = MessageContent::Parts(parts);
    }
}

pub fn emit_agent_event(ctx: &NodeContext<'_>, event: AgentEvent) {
    ctx.emitter.emit(RunEvent::Agent {
        run_id: ctx.run_id.to_string(),
        seq: 0,
        scope: Vec::new(),
        event: Box::new(event),
    });
}

fn emit_usage(ctx: &NodeContext<'_>, instance_id: &str, usage: &AgentUsage) {
    emit_agent_event(
        ctx,
        AgentEvent::Usage {
            agent_instance_id: instance_id.to_string(),
            usage: usage.clone(),
        },
    );
}
