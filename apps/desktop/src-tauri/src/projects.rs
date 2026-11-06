//! Project registry, workspace browsing and conversation persistence commands.
//!
//! These are host-side commands for the desktop UI. Agents reach the same
//! project only through an opaque workspace handle; the frontend never passes
//! an absolute path into a workflow.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use lingxi_runtime::workspace::{FileEntry, FileMatch, FileSnapshot, InstructionDocument};
use lingxi_runtime::{ProjectRef, Workspace};
use lingxi_spec::{Edge, Position, Workflow, WorkflowNode};
use serde::Serialize;
use serde_json::{json, Value};
use tauri::State;

use crate::runs::{ConversationMessage, ConversationRecord, PermissionAuditRecord, ProjectRecord};
use crate::AppState;

const DEFAULT_TOOLSET: &str =
    "read_file,write_file,list_files,delete_file,search_files,run_command,git_status,git_diff,git_log";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectOpenResponse {
    pub project: ProjectRecord,
    pub workspace_handle: String,
    pub tree: Vec<FileEntry>,
    pub git: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRules {
    pub documents: Vec<InstructionDocument>,
}

fn project_id_for(root: &Path) -> String {
    // FNV-1a keeps the id stable across launches and machines without a new
    // dependency. It is an identifier, not a security primitive: the catalog
    // still canonicalizes and authorizes the directory.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in root.to_string_lossy().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("proj-{hash:016x}")
}

fn display_name(root: &Path) -> String {
    root.file_name()
        .map(|name| name.to_string_lossy().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| root.to_string_lossy().to_string())
}

fn workspace_for(state: &AppState, project_id: &str) -> Result<Arc<Workspace>, String> {
    let handle = state.ensure_project_workspace(project_id)?;
    state
        .workspaces
        .workspace(&handle.handle_id)
        .ok_or_else(|| format!("project {project_id} has no live workspace"))
}

fn node_error(error: lingxi_runtime::NodeError) -> String {
    format!("{}: {}", error.code, error.message)
}

#[tauri::command]
pub fn project_open(
    root: String,
    state: State<'_, AppState>,
) -> Result<ProjectOpenResponse, String> {
    let candidate = PathBuf::from(root.trim());
    if !candidate.is_dir() {
        return Err(format!(
            "project directory does not exist: {}",
            candidate.display()
        ));
    }
    let workspace = Workspace::open_existing(&candidate).map_err(node_error)?;
    let canonical = workspace.root().to_path_buf();
    let project_id = project_id_for(&canonical);
    let name = display_name(&canonical);
    let project = state
        .db
        .upsert_project(&project_id, &name, &canonical.to_string_lossy())
        .map_err(|error| format!("cannot register project: {error}"))?;
    let handle = state
        .workspaces
        .register_workspace(
            ProjectRef::new(project.project_id.clone(), project.name.clone()),
            Arc::new(workspace),
            "",
        )
        .map_err(node_error)?;
    let live = state
        .workspaces
        .workspace(&handle.handle_id)
        .ok_or_else(|| "project workspace disappeared after registration".to_string())?;
    let tree = live.list("").map_err(node_error)?;
    let git = live.is_git_repository();
    Ok(ProjectOpenResponse {
        project,
        workspace_handle: handle.handle_id,
        tree,
        git,
    })
}

#[tauri::command]
pub fn project_list(state: State<'_, AppState>) -> Result<Vec<ProjectRecord>, String> {
    state.db.list_projects()
}

#[tauri::command]
pub fn project_remove(project_id: String, state: State<'_, AppState>) -> Result<bool, String> {
    state.db.remove_project(&project_id)?;
    let handles = state.workspaces.handles();
    for handle in handles {
        if handle.project.project_id == project_id {
            state.workspaces.remove(&handle.handle_id);
        }
    }
    Ok(true)
}

#[tauri::command]
pub fn project_tree(
    project_id: String,
    path: Option<String>,
    show_ignored: Option<bool>,
    state: State<'_, AppState>,
) -> Result<Vec<FileEntry>, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace
        .list_filtered(path.as_deref().unwrap_or(""), show_ignored.unwrap_or(false))
        .map_err(node_error)
}

#[tauri::command]
pub fn project_read(
    project_id: String,
    path: String,
    state: State<'_, AppState>,
) -> Result<FileSnapshot, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace.read(&path).map_err(node_error)
}

#[tauri::command]
pub fn project_write(
    project_id: String,
    path: String,
    content: String,
    expected_version: Option<String>,
    state: State<'_, AppState>,
) -> Result<FileSnapshot, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace
        .write(
            &path,
            &content,
            expected_version
                .as_deref()
                .unwrap_or(lingxi_runtime::ABSENT_VERSION),
        )
        .map_err(node_error)
}

#[tauri::command]
pub fn project_delete(
    project_id: String,
    path: String,
    expected_version: Option<String>,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace
        .delete(&path, expected_version.as_deref())
        .map_err(node_error)?;
    Ok(true)
}

#[tauri::command]
pub fn project_search(
    project_id: String,
    query: String,
    path: Option<String>,
    limit: Option<u32>,
    state: State<'_, AppState>,
) -> Result<Vec<FileMatch>, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace
        .search(
            path.as_deref().unwrap_or(""),
            &query,
            limit.unwrap_or(50) as usize,
        )
        .map_err(node_error)
}

#[tauri::command]
pub fn project_git_status(
    project_id: String,
    state: State<'_, AppState>,
) -> Result<Vec<lingxi_runtime::workspace::GitEntry>, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace.git_status().map_err(node_error)
}

#[tauri::command]
pub fn project_git_diff(
    project_id: String,
    path: Option<String>,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace.git_diff(path.as_deref()).map_err(node_error)
}

#[tauri::command]
pub fn project_git_log(
    project_id: String,
    limit: Option<u32>,
    state: State<'_, AppState>,
) -> Result<Vec<lingxi_runtime::workspace::GitCommit>, String> {
    let workspace = workspace_for(&state, &project_id)?;
    workspace
        .git_log(limit.unwrap_or(20) as usize)
        .map_err(node_error)
}

#[tauri::command]
pub fn project_rules(
    project_id: String,
    path: Option<String>,
    state: State<'_, AppState>,
) -> Result<ProjectRules, String> {
    let workspace = workspace_for(&state, &project_id)?;
    Ok(ProjectRules {
        documents: workspace.agents_md(path.as_deref().unwrap_or("")),
    })
}

#[tauri::command]
pub fn project_reveal(
    project_id: String,
    path: Option<String>,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    let workspace = workspace_for(&state, &project_id)?;
    let target = workspace
        .resolve(path.as_deref().unwrap_or(""))
        .map_err(node_error)?;
    reveal(&target)?;
    Ok(true)
}

fn reveal(target: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = std::process::Command::new("open");
        command.arg("-R").arg(target);
        command
    };
    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = std::process::Command::new("explorer");
        command.arg(format!("/select,{}", target.display()));
        command
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut command = {
        let mut command = std::process::Command::new("xdg-open");
        command.arg(target.parent().unwrap_or(target));
        command
    };
    let status = command
        .status()
        .map_err(|error| format!("cannot open file manager: {error}"))?;
    if !status.success() {
        return Err(format!("file manager exited with {status}"));
    }
    Ok(())
}

#[tauri::command]
pub fn conversation_list(
    project_id: Option<String>,
    limit: Option<u32>,
    state: State<'_, AppState>,
) -> Result<Vec<ConversationRecord>, String> {
    state
        .db
        .list_conversations(project_id.as_deref(), limit.unwrap_or(100))
}

#[tauri::command]
pub fn conversation_create(
    project_id: String,
    title: Option<String>,
    workflow: Option<Workflow>,
    state: State<'_, AppState>,
) -> Result<ConversationRecord, String> {
    let handle = state.ensure_project_workspace(&project_id)?;
    let conversation_id = uuid::Uuid::new_v4().to_string();
    let title = title
        .filter(|title| !title.trim().is_empty())
        .unwrap_or_else(|| "新会话".to_string());
    let workflow =
        workflow.unwrap_or_else(|| default_workflow(&project_id, &handle.handle_id, "ask"));
    let report = state.engine.validate(&workflow);
    if !report.ok {
        return Err(format!(
            "default workflow failed validation: {}",
            report
                .issues
                .iter()
                .map(|issue| issue.message.as_str())
                .collect::<Vec<_>>()
                .join("; ")
        ));
    }
    state
        .db
        .create_conversation(&conversation_id, &project_id, &title, &workflow)
}

#[tauri::command]
pub fn conversation_get(
    conversation_id: String,
    state: State<'_, AppState>,
) -> Result<Option<ConversationRecord>, String> {
    state.db.conversation(&conversation_id)
}

#[tauri::command]
pub fn conversation_save_workflow(
    conversation_id: String,
    workflow: Workflow,
    title: Option<String>,
    state: State<'_, AppState>,
) -> Result<ConversationRecord, String> {
    state
        .db
        .save_conversation_workflow(&conversation_id, &workflow, title.as_deref())
}

#[tauri::command]
pub fn conversation_messages(
    conversation_id: String,
    state: State<'_, AppState>,
) -> Result<Vec<ConversationMessage>, String> {
    state.db.conversation_messages(&conversation_id)
}

/// Persists a user turn that is injected into an already-running Agent. The
/// AgentBus directive and this row are written together by the UI caller.
#[tauri::command]
pub fn conversation_append_user_message(
    conversation_id: String,
    run_id: Option<String>,
    agent_node_id: Option<String>,
    content: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    if content.trim().is_empty() {
        return Ok(false);
    }
    state.db.add_conversation_message(
        &conversation_id,
        &format!("user-{}", uuid::Uuid::new_v4()),
        run_id.as_deref(),
        agent_node_id.as_deref(),
        None,
        "user",
        &content,
    )?;
    Ok(true)
}

#[tauri::command]
pub fn permission_audit(
    run_id: Option<String>,
    limit: Option<u32>,
    state: State<'_, AppState>,
) -> Result<Vec<PermissionAuditRecord>, String> {
    state
        .db
        .permission_audit(run_id.as_deref(), limit.unwrap_or(200))
}

/// Tightening or relaxing the mode changes live authorization immediately.
/// It does not rewrite the workflow draft; the node param is updated by the
/// caller so the next run and the canvas agree.
#[tauri::command]
pub fn set_permission_mode(
    run_id: String,
    mode: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    let parsed = lingxi_runtime::PermissionMode::parse(&mode)
        .ok_or_else(|| format!("unknown permission mode: {mode}"))?;
    state.permissions.set_mode(&run_id, parsed);
    Ok(true)
}

/// Builds the default single-Agent workflow behind a normal-user session.
/// The node editor shows exactly this document; there is no shadow workflow.
pub fn default_workflow(project_id: &str, workspace_handle: &str, mode: &str) -> Workflow {
    let mut workflow = Workflow::new("新建 Agent 会话");
    let mut workspace_node = WorkflowNode::new(
        "project",
        lingxi_runtime::project_node::PROJECT_KIND,
        Position { x: 40.0, y: 180.0 },
    );
    workspace_node.label = Some("项目工作区".to_string());
    workspace_node.params.insert(
        "projectId".to_string(),
        Value::String(project_id.to_string()),
    );
    workspace_node
        .params
        .insert("cwd".to_string(), Value::String(String::new()));

    let mut agent = WorkflowNode::new(
        "agent",
        lingxi_runtime::agent_node::AGENT_KIND,
        Position { x: 420.0, y: 120.0 },
    );
    agent.label = Some("Agent".to_string());
    for (key, value) in [
        ("permissionMode", Value::String(mode.to_string())),
        ("toolset", Value::String(DEFAULT_TOOLSET.to_string())),
        ("instruction", Value::String(String::new())),
        ("recipient", Value::String("user".to_string())),
    ] {
        agent.params.insert(key.to_string(), value);
    }

    let mut output = WorkflowNode::new("log", "core.log", Position { x: 820.0, y: 180.0 });
    output.label = Some("输出".to_string());

    workflow.nodes = vec![workspace_node, agent, output];
    workflow.edges = vec![
        Edge::new("project", "workspace", "agent", "workspace"),
        Edge::control("project", "ready", "agent", "start"),
        Edge::new("agent", "userResponse", "log", "value"),
        Edge::control("agent", "completed", "log", "run"),
    ];
    workflow.metadata.insert(
        "workspaceHandle".to_string(),
        Value::String(workspace_handle.to_string()),
    );
    workflow
}

/// Default team workflow: project workspace feeding a PM -> Coder -> Tester
/// pipeline. Messages and artifacts travel over the AgentBus.
pub fn team_workflow(project_id: &str, workspace_handle: &str, mode: &str) -> Workflow {
    let mut workflow = Workflow::new("公司团队");
    let mut workspace_node = WorkflowNode::new(
        "project",
        lingxi_runtime::project_node::PROJECT_KIND,
        Position { x: 40.0, y: 280.0 },
    );
    workspace_node.label = Some("项目工作区".to_string());
    workspace_node.params.insert(
        "projectId".to_string(),
        Value::String(project_id.to_string()),
    );
    let mut agents = Vec::new();
    for (index, (id, label, role)) in [
        (
            "pm",
            "产品经理",
            "You are a product manager. Turn the user requirement into a structured PRD with scope, acceptance criteria and task breakdown. Hand it to the coder through the message bus.",
        ),
        (
            "coder",
            "程序员",
            "You are a senior engineer. Read the PM handoff, inspect the project with real workspace tools, implement the change with versioned writes and report the result.",
        ),
        (
            "tester",
            "测试",
            "You are a tester. Verify the coder's implementation with real commands and file reads, report defects, and publish a pass or fail verdict.",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let mut node = WorkflowNode::new(
            id,
            lingxi_runtime::agent_node::AGENT_KIND,
            Position {
                x: 360.0 + index as f64 * 360.0,
                y: 120.0,
            },
        );
        node.label = Some(label.to_string());
        for (key, value) in [
            ("permissionMode", Value::String(mode.to_string())),
            ("toolset", Value::String(DEFAULT_TOOLSET.to_string())),
            ("rolePrompt", Value::String(role.to_string())),
            ("recipient", Value::String("broadcast".to_string())),
        ] {
            node.params.insert(key.to_string(), value);
        }
        agents.push(node);
    }
    let mut gate = WorkflowNode::new(
        "rework",
        "core.loop_gate",
        Position {
            x: 1560.0,
            y: 120.0,
        },
    );
    gate.label = Some("返工循环".to_string());
    gate.params.insert("maxIterations".to_string(), json!(4));
    gate.params.insert("timeoutMs".to_string(), json!(120_000));
    let mut log = WorkflowNode::new(
        "log",
        "core.log",
        Position {
            x: 1900.0,
            y: 180.0,
        },
    );
    log.label = Some("交付".to_string());
    workflow.nodes.push(workspace_node);
    workflow.nodes.extend(agents);
    workflow.nodes.push(gate);
    workflow.nodes.push(log);
    workflow.edges = vec![
        Edge::new("project", "workspace", "pm", "workspace"),
        Edge::new("project", "workspace", "coder", "workspace"),
        Edge::new("project", "workspace", "tester", "workspace"),
        Edge::control("project", "ready", "pm", "start"),
        Edge::control("pm", "completed", "rework", "start"),
        Edge::control("rework", "continue", "coder", "start"),
        Edge::control("coder", "completed", "tester", "start"),
        Edge::control("tester", "failed", "rework", "next"),
        Edge::control("tester", "completed", "rework", "stop"),
        Edge::control("rework", "exit", "log", "run"),
        Edge::new("pm", "agentMessage", "coder", "task"),
        Edge::new("coder", "agentMessage", "tester", "task"),
        Edge::new("tester", "agentMessage", "coder", "messages"),
        Edge::new("tester", "userResponse", "log", "value"),
    ];
    workflow.metadata.insert(
        "workspaceHandle".to_string(),
        Value::String(workspace_handle.to_string()),
    );
    workflow.metadata.insert("team".to_string(), json!(true));
    workflow
}

#[tauri::command]
pub fn conversation_create_team(
    project_id: String,
    title: Option<String>,
    state: State<'_, AppState>,
) -> Result<ConversationRecord, String> {
    let handle = state.ensure_project_workspace(&project_id)?;
    let conversation_id = uuid::Uuid::new_v4().to_string();
    let title = title
        .filter(|title| !title.trim().is_empty())
        .unwrap_or_else(|| "公司团队".to_string());
    let workflow = team_workflow(&project_id, &handle.handle_id, "ask");
    state
        .db
        .create_conversation(&conversation_id, &project_id, &title, &workflow)
}
