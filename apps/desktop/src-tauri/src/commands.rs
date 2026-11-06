use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use lingxi_runtime::event::AgentEvent;
use lingxi_runtime::{
    ChatMessage, EventSink, InteractionDecision, PermissionMode, PermissionPolicy, RunControl,
    RunEvent,
};
use lingxi_spec::{NodeSpec, ValidationReport, Workflow};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, State};

use crate::redact::{redact_event, redact_task_session};
use crate::runs::{now_ms, RunDatabase, RunDetail, RunRecord};
use crate::store::WorkflowSummary;
use crate::templates::{TemplateBundle, TemplateSummary};
use crate::AppState;

pub const RUN_EVENT: &str = "lingxi:run-event";
pub const PERSISTENCE_ERROR: &str = "lingxi:persistence-error";
pub const HOST_INTERACTION: &str = "lingxi:host-interaction";
pub const HOST_INTERACTION_RESOLVED: &str = "lingxi:host-interaction-resolved";

struct TauriSink {
    app: AppHandle,
    db: Arc<RunDatabase>,
    control: Arc<RunControl>,
    permissions: Arc<lingxi_runtime::PermissionManager>,
    conversation_id: Option<String>,
    failed: AtomicBool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistenceError {
    run_id: String,
    message: String,
}

impl EventSink for TauriSink {
    fn emit(&self, event: RunEvent) {
        let event = redact_event(&event);
        if let Err(error) = self.db.append_event(&event) {
            if !self.failed.swap(true, Ordering::SeqCst) {
                eprintln!(
                    "run event persistence failed for {}: {error}",
                    event.run_id()
                );
                let _ = self.app.emit(
                    PERSISTENCE_ERROR,
                    PersistenceError {
                        run_id: event.run_id().to_string(),
                        message: error,
                    },
                );
            }
            // Stop producing new work instead of pretending durable state.
            self.control.cancel();
        }
        // Agent state is checkpointed separately from the event log. Doing it
        // after the event append keeps the last_seq and session snapshot in the
        // same causal order; a failed checkpoint stops the run rather than
        // silently losing recoverable agent state. run.finished is included so
        // messages published after the last agent event (for example the final
        // task.result of the last agent) reach the durable session snapshot.
        if matches!(
            &event,
            RunEvent::Agent { .. } | RunEvent::RunFinished { .. }
        ) {
            if let Some(bus) = self.control.agents() {
                let mut session = bus.session();
                redact_task_session(&mut session);
                if let Err(error) = self.db.save_task_session(&session) {
                    if !self.failed.swap(true, Ordering::SeqCst) {
                        eprintln!(
                            "task session persistence failed for {}: {error}",
                            event.run_id()
                        );
                        let _ = self.app.emit(
                            PERSISTENCE_ERROR,
                            PersistenceError {
                                run_id: event.run_id().to_string(),
                                message: error,
                            },
                        );
                    }
                    self.control.cancel();
                }
            }
        }
        if let RunEvent::Agent {
            event: agent_event, ..
        } = &event
        {
            if let AgentEvent::ActivationFinished {
                agent_instance_id,
                activation_id,
                user_response: Some(response),
                ..
            } = agent_event.as_ref()
            {
                if let Some(conversation_id) = &self.conversation_id {
                    let node_id = self.control.agents().and_then(|bus| {
                        bus.session()
                            .agents
                            .get(agent_instance_id)
                            .map(|agent| agent.node_id.clone())
                    });
                    let message_id = format!("{}:{activation_id}", event.run_id());
                    if let Err(error) = self.db.add_conversation_message(
                        conversation_id,
                        &message_id,
                        Some(event.run_id()),
                        node_id.as_deref(),
                        Some(agent_instance_id),
                        "assistant",
                        response,
                    ) {
                        eprintln!("conversation message persistence failed: {error}");
                    }
                }
            }
        }
        // Persist the authorization trail with the run. The audit table is
        // unique per decision, so replaying the in-memory log is idempotent.
        if matches!(
            &event,
            RunEvent::Agent { .. } | RunEvent::RunFinished { .. }
        ) {
            for entry in self.permissions.audit_for(event.run_id()) {
                if let Err(error) = self.db.record_permission_audit(
                    &entry.run_id,
                    &entry.node_id,
                    entry.mode.as_str(),
                    &entry.class,
                    &entry.target,
                    &entry.decision,
                    &entry.detail,
                ) {
                    eprintln!("permission audit persistence failed: {error}");
                }
            }
        }
        let _ = self.app.emit(RUN_EVENT, &event);
    }
}

/// Removes the control handle and, if the engine ended without a terminal
/// event (including a panic), marks the stored run interrupted.
struct RunTaskGuard {
    db: Arc<RunDatabase>,
    runs: Arc<Mutex<HashMap<String, Arc<RunControl>>>>,
    run_id: String,
}

impl Drop for RunTaskGuard {
    fn drop(&mut self) {
        if let Ok(mut runs) = self.runs.lock() {
            runs.remove(&self.run_id);
        }
        if let Err(error) = self
            .db
            .mark_interrupted(&self.run_id, "run task ended without a terminal event")
        {
            eprintln!("cannot mark run {} interrupted: {error}", self.run_id);
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunStartResponse {
    pub started: bool,
    pub run_id: Option<String>,
    pub report: ValidationReport,
}

#[tauri::command]
pub fn list_node_specs(state: State<'_, AppState>) -> Vec<NodeSpec> {
    state.registry.specs().into_iter().cloned().collect()
}

#[tauri::command]
pub fn validate_workflow(workflow: Workflow, state: State<'_, AppState>) -> ValidationReport {
    state.engine.validate(&workflow)
}

#[tauri::command]
pub async fn run_workflow(
    mut workflow: Workflow,
    conversation_id: Option<String>,
    user_message: Option<String>,
    permission_mode: Option<String>,
    agent_node_id: Option<String>,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<RunStartResponse, String> {
    // The composer message belongs to this run snapshot only. It is injected
    // into the chosen Agent node's instruction without rewriting the saved
    // conversation draft, and prior turns arrive through per-agent history.
    let addressed_agent = match user_message.as_deref() {
        Some(message) if !message.trim().is_empty() => {
            inject_user_message(&mut workflow, agent_node_id.as_deref(), message)
        }
        _ => agent_node_id.or_else(|| first_agent_node_id(&workflow)),
    };
    let report = state.engine.validate(&workflow);
    if !report.ok {
        return Ok(RunStartResponse {
            started: false,
            run_id: None,
            report,
        });
    }

    let conversation = match &conversation_id {
        Some(id) => Some(
            state
                .db
                .conversation(id)?
                .ok_or_else(|| format!("conversation {id} does not exist"))?,
        ),
        None => None,
    };
    let project_id = conversation
        .as_ref()
        .map(|record| record.project_id.clone());
    let mode = match permission_mode.as_deref() {
        Some(value) => PermissionMode::parse(value)
            .ok_or_else(|| format!("unknown permission mode {value:?}"))?,
        None => workflow_permission_mode(&workflow),
    };
    let engine = match &conversation {
        Some(record) => {
            let handle = state.ensure_project_workspace(&record.project_id)?;
            let workspace = state
                .workspaces
                .workspace(&handle.handle_id)
                .ok_or_else(|| "project workspace disappeared".to_string())?;
            let project = state
                .db
                .project(&record.project_id)?
                .ok_or_else(|| format!("project {} does not exist", record.project_id))?;
            let project_ref = lingxi_runtime::ProjectRef {
                project_id: project.project_id,
                name: project.name,
            };
            let histories = conversation_history(&state.db, &record.conversation_id, &workflow)?;
            state.engine_for(Some(workspace), Some(project_ref), histories)?
        }
        // A workflow without a conversation is the standalone editor path. It
        // keeps the app's default agent workspace; only project-bound runs need
        // a run-scoped catalog with exactly one project.
        None => state.engine.clone(),
    };

    let run_id = uuid::Uuid::new_v4().to_string();
    let control = RunControl::new();
    state
        .db
        .create_run(&run_id, &workflow, now_ms())
        .map_err(|error| format!("cannot persist run start: {error}"))?;
    if let Some(record) = &conversation {
        state
            .db
            .link_conversation_run(&record.conversation_id, &run_id)?;
    }
    let mut policy = PermissionPolicy::new(&run_id, mode);
    policy.project_id = project_id.clone();
    policy.session_id = conversation_id.clone();
    policy.revision = 1;
    state.permissions.set_policy(policy);
    if let (Some(record), Some(message)) = (&conversation, user_message.as_deref()) {
        if !message.trim().is_empty() {
            state.db.add_conversation_message(
                &record.conversation_id,
                &format!("user-{}", uuid::Uuid::new_v4()),
                Some(&run_id),
                addressed_agent.as_deref(),
                None,
                "user",
                message,
            )?;
        }
    }

    if let Err(error) = state
        .runs
        .lock()
        .map_err(|_| "run registry is poisoned".to_string())
        .map(|mut runs| {
            runs.insert(run_id.clone(), control.clone());
        })
    {
        let _ = state.db.mark_interrupted(&run_id, &error);
        return Err(error);
    }

    let runs = state.runs.clone();
    let db = state.db.clone();
    let sink = TauriSink {
        app,
        db: db.clone(),
        control: control.clone(),
        permissions: state.permissions.clone(),
        conversation_id: conversation_id.clone(),
        failed: AtomicBool::new(false),
    };
    let run_for_task = run_id.clone();
    let workflow_for_task = workflow.clone();

    tauri::async_runtime::spawn(async move {
        let _guard = RunTaskGuard {
            db,
            runs,
            run_id: run_for_task.clone(),
        };
        engine
            .execute(&workflow_for_task, &run_for_task, control, &sink)
            .await;
    });

    Ok(RunStartResponse {
        started: true,
        run_id: Some(run_id),
        report,
    })
}

fn find_node_mut<'a>(
    workflow: &'a mut Workflow,
    node_id: &str,
) -> Option<&'a mut lingxi_spec::WorkflowNode> {
    if let Some(index) = workflow.nodes.iter().position(|node| node.id == node_id) {
        return workflow.nodes.get_mut(index);
    }
    for definition in workflow.subgraphs.values_mut() {
        if let Some(node) = find_node_mut(&mut definition.workflow, node_id) {
            return Some(node);
        }
    }
    None
}

fn first_agent_mut(workflow: &mut Workflow) -> Option<&mut lingxi_spec::WorkflowNode> {
    if let Some(index) = workflow
        .nodes
        .iter()
        .position(|node| node.kind == lingxi_runtime::agent_node::AGENT_KIND)
    {
        return workflow.nodes.get_mut(index);
    }
    for definition in workflow.subgraphs.values_mut() {
        if let Some(node) = first_agent_mut(&mut definition.workflow) {
            return Some(node);
        }
    }
    None
}

fn first_agent_node_id(workflow: &Workflow) -> Option<String> {
    if let Some(node) = workflow
        .nodes
        .iter()
        .find(|node| node.kind == lingxi_runtime::agent_node::AGENT_KIND)
    {
        return Some(node.id.clone());
    }
    workflow
        .subgraphs
        .values()
        .find_map(|definition| first_agent_node_id(&definition.workflow))
}

/// Returns the addressed Agent node id after updating the run snapshot.
fn inject_user_message(
    workflow: &mut Workflow,
    agent_node_id: Option<&str>,
    message: &str,
) -> Option<String> {
    let requested = match agent_node_id {
        Some(id) => find_node_mut(workflow, id),
        None => None,
    };
    let target = match requested {
        Some(node) => node,
        None => first_agent_mut(workflow)?,
    };
    let existing = target
        .params
        .get("instruction")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let instruction = if existing.is_empty() {
        message.trim().to_string()
    } else {
        format!("{existing}\n\n{}", message.trim())
    };
    target
        .params
        .insert("instruction".to_string(), Value::String(instruction));
    Some(target.id.clone())
}

fn workflow_permission_mode(workflow: &Workflow) -> PermissionMode {
    workflow
        .nodes
        .iter()
        .find(|node| node.kind == lingxi_runtime::agent_node::AGENT_KIND)
        .and_then(|node| node.params.get("permissionMode"))
        .and_then(|value| value.as_str())
        .and_then(PermissionMode::parse)
        .unwrap_or_default()
}

/// Builds per-agent conversation history from durable messages. User turns are
/// shared; assistant turns belong to the agent that produced them. Agent-to-
/// agent handoffs never come from this table; they travel over the AgentBus.
fn conversation_history(
    db: &RunDatabase,
    conversation_id: &str,
    workflow: &Workflow,
) -> Result<std::collections::BTreeMap<String, Vec<ChatMessage>>, String> {
    let messages = db.conversation_messages(conversation_id)?;
    let mut histories = std::collections::BTreeMap::new();
    for node in workflow
        .nodes
        .iter()
        .filter(|node| node.kind == lingxi_runtime::agent_node::AGENT_KIND)
    {
        let mut history = Vec::new();
        for message in &messages {
            match message.role.as_str() {
                "user" => history.push(ChatMessage::user(message.content.clone())),
                "assistant" if message.agent_node_id.as_deref() == Some(node.id.as_str()) => {
                    history.push(ChatMessage::assistant(message.content.clone()));
                }
                _ => {}
            }
        }
        if !history.is_empty() {
            histories.insert(node.id.clone(), history);
        }
    }
    Ok(histories)
}

#[tauri::command]
pub fn stop_workflow(run_id: String, state: State<'_, AppState>) -> bool {
    match state.runs.lock() {
        Ok(runs) => match runs.get(&run_id) {
            Some(control) => {
                control.cancel();
                true
            }
            None => false,
        },
        Err(_) => false,
    }
}

fn run_control(state: &AppState, run_id: &str) -> Result<Arc<RunControl>, String> {
    state
        .runs
        .lock()
        .map_err(|_| "run registry is poisoned".to_string())?
        .get(run_id)
        .cloned()
        .ok_or_else(|| format!("run {run_id} is not active"))
}

fn run_bus(
    state: &AppState,
    run_id: &str,
) -> Result<Arc<lingxi_runtime::agent_bus::AgentBus>, String> {
    run_control(state, run_id)?
        .agents()
        .ok_or_else(|| format!("run {run_id} has no agent task session"))
}

fn checkpoint_session(
    state: &AppState,
    bus: &lingxi_runtime::agent_bus::AgentBus,
) -> Result<(), String> {
    let mut session = bus.session();
    redact_task_session(&mut session);
    state.db.save_task_session(&session)
}

#[tauri::command]
pub fn pause_workflow(run_id: String, state: State<'_, AppState>) -> Result<bool, String> {
    let control = run_control(&state, &run_id)?;
    control.pause();
    Ok(true)
}

#[tauri::command]
pub fn resume_workflow(run_id: String, state: State<'_, AppState>) -> Result<bool, String> {
    let control = run_control(&state, &run_id)?;
    control.resume();
    Ok(true)
}

#[tauri::command]
pub fn pause_agent(
    run_id: String,
    agent_instance_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let bus = run_bus(&state, &run_id)?;
    bus.pause_agent(&agent_instance_id).map_err(node_error)?;
    checkpoint_session(&state, &bus)
}

#[tauri::command]
pub fn resume_agent(
    run_id: String,
    agent_instance_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let bus = run_bus(&state, &run_id)?;
    bus.resume_agent(&agent_instance_id).map_err(node_error)?;
    checkpoint_session(&state, &bus)
}

#[tauri::command]
pub fn cancel_agent(
    run_id: String,
    agent_instance_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let bus = run_bus(&state, &run_id)?;
    bus.cancel_agent(&agent_instance_id).map_err(node_error)?;
    checkpoint_session(&state, &bus)
}

#[tauri::command]
pub fn send_agent_directive(
    run_id: String,
    agent_instance_id: String,
    text: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let bus = run_bus(&state, &run_id)?;
    bus.intervention(&agent_instance_id, &text)
        .map_err(node_error)?;
    checkpoint_session(&state, &bus)
}

#[tauri::command]
pub fn preview_agent_config(
    run_id: String,
    agent_instance_id: String,
    config: lingxi_runtime::agent_protocol::AgentConfigSnapshot,
    state: State<'_, AppState>,
) -> Result<Vec<lingxi_runtime::agent_protocol::ConfigChange>, String> {
    config.validate().map_err(node_error)?;
    let bus = run_bus(&state, &run_id)?;
    let session = bus.session();
    let agent = session
        .agents
        .get(&agent_instance_id)
        .ok_or_else(|| format!("agent {agent_instance_id} is not registered"))?;
    Ok(agent.config.diff(&config))
}

#[tauri::command]
pub fn apply_agent_config(
    run_id: String,
    agent_instance_id: String,
    config: lingxi_runtime::agent_protocol::AgentConfigSnapshot,
    expected_revision: u64,
    state: State<'_, AppState>,
) -> Result<lingxi_runtime::agent_protocol::AgentConfigRevision, String> {
    let bus = run_bus(&state, &run_id)?;
    let revision = bus
        .apply_config(&agent_instance_id, config, expected_revision)
        .map_err(node_error)?;
    checkpoint_session(&state, &bus)?;
    Ok(revision)
}

#[tauri::command]
pub fn reject_agent_config(
    run_id: String,
    agent_instance_id: String,
    revision: u64,
    detail: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let bus = run_bus(&state, &run_id)?;
    bus.reject_config(&agent_instance_id, revision, &detail);
    checkpoint_session(&state, &bus)
}

#[tauri::command]
pub fn task_session(
    run_id: String,
    state: State<'_, AppState>,
) -> Result<Option<lingxi_runtime::agent_protocol::TaskSession>, String> {
    state.db.task_session(&run_id)
}

#[tauri::command]
pub fn respond_interaction(request_id: String, approved: bool, state: State<'_, AppState>) -> bool {
    let decision = if approved {
        InteractionDecision::Approved
    } else {
        InteractionDecision::Rejected
    };
    state.interactions.resolve_pending(&request_id, decision)
}

#[tauri::command]
pub fn workflow_list(state: State<'_, AppState>) -> Result<Vec<WorkflowSummary>, String> {
    state.store.list()
}

#[tauri::command]
pub fn save_workflow(
    name: String,
    workflow: Workflow,
    state: State<'_, AppState>,
) -> Result<WorkflowSummary, String> {
    state.store.save(&name, &workflow)
}

#[tauri::command]
pub fn load_workflow(name: String, state: State<'_, AppState>) -> Result<Workflow, String> {
    state.store.load(&name)
}

#[tauri::command]
pub fn delete_workflow(name: String, state: State<'_, AppState>) -> Result<bool, String> {
    state.store.delete(&name)
}

#[tauri::command]
pub fn template_list(state: State<'_, AppState>) -> Result<Vec<TemplateSummary>, String> {
    state.templates.list()
}

#[tauri::command]
pub fn template_load(id: String, state: State<'_, AppState>) -> Result<TemplateBundle, String> {
    state.templates.load(&id)
}

#[tauri::command]
pub fn template_save(
    name: String,
    bundle: TemplateBundle,
    state: State<'_, AppState>,
) -> Result<TemplateSummary, String> {
    state.templates.save(&name, &bundle)
}

#[tauri::command]
pub fn template_delete(id: String, state: State<'_, AppState>) -> Result<bool, String> {
    state.templates.delete(&id)
}

#[tauri::command]
pub fn run_list(limit: Option<u32>, state: State<'_, AppState>) -> Result<Vec<RunRecord>, String> {
    state.db.list_runs(limit.unwrap_or(50).min(200))
}

#[tauri::command]
pub fn run_detail(run_id: String, state: State<'_, AppState>) -> Result<Option<RunDetail>, String> {
    state.db.run_detail(&run_id)
}

#[tauri::command]
pub fn run_events(
    run_id: String,
    after_seq: Option<u64>,
    state: State<'_, AppState>,
) -> Result<Vec<RunEvent>, String> {
    state.db.run_events(&run_id, after_seq)
}

#[tauri::command]
pub fn active_run(state: State<'_, AppState>) -> Result<Option<RunDetail>, String> {
    state.db.active_run()
}

#[allow(dead_code)]
fn _assert_send_sync(_: Arc<RunControl>) {}
fn node_error(error: lingxi_runtime::NodeError) -> String {
    format!("{}: {}", error.code, error.message)
}

fn keyring_name(reference: &str) -> Result<String, String> {
    let name = reference
        .strip_prefix("keyring:")
        .unwrap_or(reference)
        .trim();
    if name.is_empty() {
        return Err("credential name must not be empty".to_string());
    }
    if name.starts_with("env:") {
        return Err("environment references cannot be stored in the OS keychain".to_string());
    }
    Ok(name.to_string())
}

/// Whether a credential reference can be resolved without exposing the value.
#[tauri::command]
pub async fn credential_status(
    reference: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    state
        .credentials
        .status(&reference)
        .await
        .map_err(node_error)
}

/// Stores a secret in the operating system keychain and returns its reference.
/// The secret is never written to SQLite, workflow JSON or logs.
#[tauri::command]
pub async fn credential_set(
    name: String,
    secret: String,
    _state: State<'_, AppState>,
) -> Result<String, String> {
    let name = keyring_name(&name)?;
    lingxi_runtime::credentials::set_keyring_secret(&name, &secret)
        .await
        .map_err(node_error)?;
    Ok(format!("keyring:{name}"))
}

#[tauri::command]
pub async fn credential_delete(name: String, _state: State<'_, AppState>) -> Result<bool, String> {
    let name = keyring_name(&name)?;
    lingxi_runtime::credentials::delete_keyring_secret(&name)
        .await
        .map_err(node_error)?;
    Ok(true)
}

/// Lists models from a configured provider. The credential is resolved by
/// reference in the host, so it never travels through the webview. Discovery
/// uses the same protocol+host+port authorization rule as inference.
#[tauri::command]
pub async fn provider_models(
    base_url: String,
    credential_ref: String,
    protocol: Option<String>,
    capabilities: Option<serde_json::Value>,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Vec<String>, String> {
    let config = lingxi_runtime::ProviderConfig {
        provider_id: "openai".to_string(),
        base_url,
        credential_ref: credential_ref.clone(),
        organization: String::new(),
        supports_reasoning: true,
        protocol: lingxi_runtime::ProviderProtocol::parse(
            protocol.as_deref().unwrap_or("openai_chat"),
        )
        .map_err(node_error)?,
        capabilities: capabilities.unwrap_or(serde_json::Value::Null),
    };
    config.validate().map_err(node_error)?;
    let target = config.target();
    let run_id = "host-provider-models";
    let class = lingxi_runtime::permissions::PermissionClass::Network;
    if !state.permissions.is_approved(run_id, class, &target) {
        let request = lingxi_runtime::interaction::InteractionRequest {
            request_id: format!("host-{}", uuid::Uuid::new_v4()),
            run_id: run_id.to_string(),
            node_id: "provider-discovery".to_string(),
            prompt: format!(
                "Allow network access to {target}?\nDiscover models for {}.",
                config.protocol.label()
            ),
            options: vec![
                lingxi_runtime::interaction::InteractionOption {
                    value: "approve".to_string(),
                    label: "Allow for this session".to_string(),
                },
                lingxi_runtime::interaction::InteractionOption {
                    value: "reject".to_string(),
                    label: "Reject".to_string(),
                },
            ],
        };
        let request_id = request.request_id.clone();
        app.emit(HOST_INTERACTION, &request)
            .map_err(|error| format!("cannot show authorization prompt: {error}"))?;
        use lingxi_runtime::interaction::InteractionBroker;
        let decision = tokio::time::timeout(
            std::time::Duration::from_secs(300),
            state.interactions.request(request),
        )
        .await
        .map_err(|_| format!("authorization for {target} timed out"))?
        .map_err(node_error)?;
        app.emit(
            HOST_INTERACTION_RESOLVED,
            serde_json::json!({ "requestId": request_id }),
        )
        .ok();
        if decision != InteractionDecision::Approved {
            return Err(format!("network access to {target} was rejected"));
        }
        state.permissions.pre_approve(run_id, class, &target);
    }
    let secret = if credential_ref.trim().is_empty() {
        None
    } else {
        Some(
            state
                .credentials
                .resolve(&credential_ref)
                .await
                .map_err(node_error)?,
        )
    };
    use lingxi_runtime::{OpenAiFactory, ProviderFactory};
    let provider = OpenAiFactory::default()
        .create(&config, secret, state.assets.clone())
        .await
        .map_err(node_error)?;
    provider.list_models().await.map_err(node_error)
}

/// Resolves the effective capability profile for a model without contacting
/// the provider. The Model node uses it to explain which media and reasoning
/// options are actually available before a run starts.
#[tauri::command]
pub fn model_capabilities(
    protocol: String,
    model: String,
    capabilities: Option<serde_json::Value>,
) -> Result<lingxi_runtime::ModelCapabilities, String> {
    lingxi_runtime::ProviderProtocol::parse(&protocol).map_err(node_error)?;
    let profile = lingxi_runtime::ModelCapabilities::infer(&protocol, &model);
    match capabilities {
        Some(overrides) => profile.with_overrides(&overrides).map_err(node_error),
        None => Ok(profile),
    }
}

/// Resolves a host-level authorization prompt raised outside a workflow run,
/// for example provider model discovery.
#[tauri::command]
pub fn respond_host_interaction(
    request_id: String,
    approved: bool,
    state: State<'_, AppState>,
) -> bool {
    use lingxi_runtime::interaction::InteractionBroker;
    let decision = if approved {
        InteractionDecision::Approved
    } else {
        InteractionDecision::Rejected
    };
    state.interactions.resolve(&request_id, decision)
}

#[tauri::command]
pub async fn asset_import(
    path: String,
    kind: String,
    state: State<'_, AppState>,
) -> Result<lingxi_spec::AssetRef, String> {
    let kind = match kind.as_str() {
        "image" => lingxi_spec::AssetKind::Image,
        "audio" => lingxi_spec::AssetKind::Audio,
        "video" => lingxi_spec::AssetKind::Video,
        "document" => lingxi_spec::AssetKind::Document,
        other => return Err(format!("unknown asset kind {other:?}")),
    };
    state
        .assets
        .import_path(std::path::Path::new(&path), kind, "user-picker")
        .map_err(node_error)
}

/// Returns a data URL for a small local preview. The frontend never receives
/// arbitrary filesystem access: only blobs already in the content-addressed
/// store can be read, and oversized media is refused rather than buffered.
#[tauri::command]
pub fn asset_preview(
    id: String,
    mime: Option<String>,
    state: State<'_, AppState>,
) -> Result<String, String> {
    const MAX_PREVIEW: usize = 24 * 1024 * 1024;
    let bytes = state.assets.read_by_id(&id).map_err(node_error)?;
    if bytes.len() > MAX_PREVIEW {
        return Err(format!(
            "asset preview is limited to {MAX_PREVIEW} bytes; use the metadata panel instead"
        ));
    }
    use base64::Engine;
    let mime = mime
        .filter(|value| !value.trim().is_empty())
        .or_else(|| infer::get(&bytes).map(|kind| kind.mime_type().to_string()))
        .unwrap_or_else(|| "application/octet-stream".to_string());
    let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
    Ok(format!("data:{mime};base64,{encoded}"))
}

#[tauri::command]
pub fn skill_list(state: State<'_, AppState>) -> Result<Vec<lingxi_runtime::SkillSummary>, String> {
    let Some(root) = &state.skills_root else {
        return Ok(Vec::new());
    };
    lingxi_runtime::SkillLibrary::new(root)
        .discover()
        .map_err(node_error)
}

/// The built-in ReAct agent is sourced from the Rust runtime, not duplicated in
/// the frontend. Users can insert it and expand every node for editing.
#[tauri::command]
pub fn agent_template() -> TemplateBundle {
    let mut subgraphs = std::collections::BTreeMap::new();
    subgraphs.insert(
        lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID.to_string(),
        lingxi_runtime::agent_template::standard_agent(),
    );
    TemplateBundle {
        root_id: lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID.to_string(),
        subgraphs,
        assets: std::collections::BTreeMap::new(),
    }
}
