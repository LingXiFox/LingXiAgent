use std::sync::Arc;

use lingxi_runtime::{EventSink, InteractionDecision, RunControl, RunEvent};
use lingxi_spec::{NodeSpec, ValidationReport, Workflow};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::store::WorkflowSummary;
use crate::AppState;

pub const RUN_EVENT: &str = "lingxi:run-event";

struct TauriSink {
    app: AppHandle,
}

impl EventSink for TauriSink {
    fn emit(&self, event: RunEvent) {
        let _ = self.app.emit(RUN_EVENT, &event);
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
        .runs
        .lock()
        .map_err(|_| "run registry is poisoned".to_string())?
        .insert(run_id.clone(), control.clone());

    let engine = state.engine.clone();
    let runs = state.runs.clone();
    let sink = TauriSink { app };
    let run_for_task = run_id.clone();
    let control_for_task = control.clone();
    let workflow_for_task = workflow.clone();

    tauri::async_runtime::spawn(async move {
        engine
            .execute(&workflow_for_task, &run_for_task, control_for_task, &sink)
            .await;
        if let Ok(mut runs) = runs.lock() {
            runs.remove(&run_for_task);
        }
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

#[allow(dead_code)]
fn _assert_send_sync(_: Arc<RunControl>) {}
