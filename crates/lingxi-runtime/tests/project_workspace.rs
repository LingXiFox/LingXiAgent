//! Project workspace binding through the opaque catalog handle.

mod common;

use std::collections::BTreeMap;
use std::sync::Arc;

use common::{start_mock_provider, test_assets, ApproveAll, Recorder, RejectAll};
use lingxi_runtime::permissions::{PermissionManager, PermissionMode, PermissionPolicy};
use lingxi_runtime::project::{ProjectRef, WorkspaceCatalog};
use lingxi_runtime::workspace::{Workspace, ABSENT_VERSION};
use lingxi_runtime::{AllowAllPolicy, Engine, NodeRegistry, RunControl, RunStatus, ServiceConfig};
use lingxi_spec::{Edge, Position, Workflow, WorkflowNode};
use serde_json::Value;

fn temp_root(label: &str) -> std::path::PathBuf {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("lingxi-{label}-{}-{unique}", std::process::id()))
}

fn project_engine(
    root: &std::path::Path,
    project: ProjectRef,
    permissions: Arc<PermissionManager>,
    interactions: Arc<dyn lingxi_runtime::InteractionBroker>,
) -> Engine {
    std::fs::create_dir_all(root).expect("project root");
    let workspace = Arc::new(Workspace::open_existing(root).expect("existing workspace"));
    let catalog = WorkspaceCatalog::new();
    catalog
        .register_workspace(project, workspace.clone(), "")
        .expect("register project");
    Engine::with_services(
        Arc::new(NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
        interactions,
        ServiceConfig {
            permissions,
            credentials: lingxi_runtime::credentials::MemoryCredentials::arc(vec![(
                "test-key".to_string(),
                "test-key".to_string(),
            )]),
            skills_root: None,
            assets: test_assets(),
            workspace: Some(workspace),
            workspaces: Some(Arc::new(catalog)),
            histories: Arc::new(BTreeMap::new()),
        },
    )
}

fn project_node(project_id: &str) -> WorkflowNode {
    let mut node = WorkflowNode::new("project", "core.project_workspace", Position::default());
    node.label = Some("Project".into());
    node.params
        .insert("projectId".into(), Value::from(project_id));
    node
}

fn agent_node(base_url: &str, toolset: &str, mode: &str) -> WorkflowNode {
    let mut node = WorkflowNode::new("coder", "core.agent", Position::default());
    node.label = Some("Coder".into());
    node.params.insert("baseUrl".into(), Value::from(base_url));
    node.params
        .insert("credentialRef".into(), Value::from("test-key"));
    node.params
        .insert("model".into(), Value::from("mock-coder"));
    node.params.insert("toolset".into(), Value::from(toolset));
    node.params
        .insert("permissionMode".into(), Value::from(mode));
    node.params
        .insert("instruction".into(), Value::from("Implement the feature."));
    node
}

fn write_workflow(project_id: &str, base_url: &str, mode: &str) -> Workflow {
    let mut workflow = Workflow::new("project agent");
    workflow.nodes = vec![
        project_node(project_id),
        agent_node(base_url, "write_file", mode),
    ];
    workflow.edges = vec![
        Edge::new("project", "workspace", "coder", "workspace"),
        Edge::control("project", "ready", "coder", "start"),
    ];
    workflow
}

#[tokio::test]
async fn project_node_outputs_an_opaque_handle_not_the_root_path() {
    let root = temp_root("project-node");
    let project = ProjectRef {
        project_id: "proj-demo".into(),
        name: "Demo".into(),
    };
    let permissions = Arc::new(PermissionManager::new());
    let engine = project_engine(&root, project, permissions, Arc::new(ApproveAll));

    let mut workflow = Workflow::new("project handle");
    workflow.nodes = vec![project_node("proj-demo"), {
        let mut log = WorkflowNode::new("out", "core.log", Position::default());
        log.params.insert("prefix".into(), Value::from("handle: "));
        log
    }];
    workflow.edges = vec![
        Edge::control("project", "ready", "out", "run"),
        Edge::new("project", "workspace", "out", "value"),
    ];

    let recorder = Recorder::default();
    let summary = engine
        .execute(
            &workflow,
            "run-project-handle",
            RunControl::new(),
            &recorder,
        )
        .await;
    assert_eq!(summary.status, RunStatus::Completed);
    let handle_line = recorder
        .logs()
        .into_iter()
        .find_map(|(_, message)| message.strip_prefix("handle: ").map(str::to_string))
        .expect("project handle log");
    assert!(
        handle_line.starts_with("ws-"),
        "unexpected handle: {handle_line}"
    );
    assert!(
        !handle_line.contains(&root.display().to_string()),
        "the workflow must never receive the absolute project path"
    );
}

#[tokio::test]
async fn an_agent_writes_to_the_project_bound_by_the_workspace_node() {
    let provider = start_mock_provider();
    let root = temp_root("project-agent");
    let project = ProjectRef {
        project_id: "proj-demo".into(),
        name: "Demo".into(),
    };
    let permissions = Arc::new(PermissionManager::new());
    permissions.set_policy(PermissionPolicy::new(
        "run-project-write",
        PermissionMode::Workspace,
    ));
    let engine = project_engine(&root, project, permissions, Arc::new(ApproveAll));
    let workflow = write_workflow("proj-demo", &provider.base_url, "workspace");

    let report = engine.validate(&workflow);
    assert!(report.ok, "workflow must validate: {:#?}", report.issues);
    let recorder = Recorder::default();
    let summary = engine
        .execute(&workflow, "run-project-write", RunControl::new(), &recorder)
        .await;
    assert_eq!(
        summary.status,
        RunStatus::Completed,
        "events: {:#?}",
        recorder.events()
    );
    let workspace = Workspace::open_existing(&root).expect("workspace");
    assert_eq!(
        workspace
            .read("company-demo/feature.txt")
            .expect("agent file")
            .content,
        "v1"
    );
    assert!(
        !root.join("agent-workspace").exists(),
        "the agent must not fall back to the app data workspace"
    );
}

#[tokio::test]
async fn a_project_outside_the_run_catalog_is_rejected() {
    let provider = start_mock_provider();
    let root = temp_root("project-isolation");
    let project = ProjectRef {
        project_id: "proj-a".into(),
        name: "A".into(),
    };
    let permissions = Arc::new(PermissionManager::new());
    let engine = project_engine(&root, project, permissions, Arc::new(ApproveAll));
    let workflow = write_workflow("proj-b", &provider.base_url, "ask");

    let recorder = Recorder::default();
    let summary = engine
        .execute(
            &workflow,
            "run-project-isolation",
            RunControl::new(),
            &recorder,
        )
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    let failed = recorder.events().into_iter().any(|event| {
        matches!(
            event,
            lingxi_runtime::RunEvent::NodeFailed { ref node_id, ref code, .. }
                if node_id == "project" && code == "workspace.not_found"
        )
    });
    assert!(failed, "project node must fail with workspace.not_found");
}

#[tokio::test]
async fn ask_mode_rejection_stops_the_agent_before_it_writes() {
    let provider = start_mock_provider();
    let root = temp_root("project-ask");
    let project = ProjectRef {
        project_id: "proj-demo".into(),
        name: "Demo".into(),
    };
    let permissions = Arc::new(PermissionManager::new());
    let engine = project_engine(&root, project, permissions, Arc::new(RejectAll));
    let workflow = write_workflow("proj-demo", &provider.base_url, "ask");

    let recorder = Recorder::default();
    let summary = engine
        .execute(&workflow, "run-project-ask", RunControl::new(), &recorder)
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    let workspace = Workspace::open_existing(&root).expect("workspace");
    assert!(workspace.read("company-demo/feature.txt").is_err());
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        lingxi_runtime::RunEvent::NodeFailed { ref code, .. } if code == "capability.denied"
    )));
}

#[test]
fn agents_md_rules_follow_the_operation_directory() {
    let root = temp_root("project-rules");
    std::fs::create_dir_all(root.join("src/deep")).unwrap();
    let workspace = Workspace::open_existing(&root).unwrap();
    workspace
        .write("AGENTS.md", "root rule\n", ABSENT_VERSION)
        .unwrap();
    workspace
        .write("src/AGENTS.md", "src rule\n", ABSENT_VERSION)
        .unwrap();

    let docs = workspace.agents_md("src/deep");
    assert_eq!(docs.len(), 2);
    assert_eq!(docs[0].path, "AGENTS.md");
    assert_eq!(docs[1].path, "src/AGENTS.md");
    assert!(workspace
        .agents_md("")
        .iter()
        .all(|doc| doc.path == "AGENTS.md"));
}
