use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use lingxi_runtime::{EventSink, InteractionDecision, RunControl, RunEvent};
use lingxi_spec::{NodeSpec, ValidationReport, Workflow};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::redact::redact_event;
use crate::runs::{now_ms, RunDatabase, RunDetail, RunRecord};
use crate::store::WorkflowSummary;
use crate::templates::{TemplateBundle, TemplateSummary};
use crate::AppState;

pub const RUN_EVENT: &str = "lingxi:run-event";
pub const PERSISTENCE_ERROR: &str = "lingxi:persistence-error";

struct TauriSink {
    app: AppHandle,
    db: Arc<RunDatabase>,
    control: Arc<RunControl>,
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
    workflow: Workflow,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<RunStartResponse, String> {
    let report = state.engine.validate(&workflow);
    if !report.ok {
        return Ok(RunStartResponse {
            started: false,
            run_id: None,
            report,
        });
    }

    let run_id = uuid::Uuid::new_v4().to_string();
    let control = RunControl::new();
    state
        .db
        .create_run(&run_id, &workflow, now_ms())
        .map_err(|error| format!("cannot persist run start: {error}"))?;

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

    let engine = state.engine.clone();
    let runs = state.runs.clone();
    let db = state.db.clone();
    let sink = TauriSink {
        app,
        db: db.clone(),
        control: control.clone(),
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

/// Lists models from an OpenAI-compatible provider. The credential is resolved
/// by reference in the host, so it never travels through the webview.
#[tauri::command]
pub async fn provider_models(
    base_url: String,
    credential_ref: String,
    state: State<'_, AppState>,
) -> Result<Vec<String>, String> {
    let config = lingxi_runtime::ProviderConfig {
        provider_id: "openai".to_string(),
        base_url,
        credential_ref: credential_ref.clone(),
        organization: String::new(),
        supports_reasoning: true,
    };
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
        .create(&config, secret)
        .await
        .map_err(node_error)?;
    provider.list_models().await.map_err(node_error)
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
    }
}
