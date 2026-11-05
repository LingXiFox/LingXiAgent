//! Company-style PM -> Coder -> Tester workflow with real rework.

mod common;

use std::sync::Arc;

use common::{engine_with_workspace, start_mock_provider, test_assets, ApproveAll, Recorder};
use lingxi_runtime::workspace::{Workspace, ABSENT_VERSION};
use lingxi_runtime::{RunControl, RunStatus};
use lingxi_spec::{Edge, Position, Workflow, WorkflowNode};
use serde_json::{json, Value};

fn agent(
    id: &str,
    label: &str,
    model: &str,
    base_url: &str,
    toolset: &str,
    instruction: &str,
) -> WorkflowNode {
    let mut node = WorkflowNode::new(id, "core.agent", Position::default());
    node.label = Some(label.to_string());
    node.params.insert("baseUrl".into(), Value::from(base_url));
    node.params
        .insert("credentialRef".into(), Value::from("test-key"));
    node.params.insert("model".into(), Value::from(model));
    node.params.insert("toolset".into(), Value::from(toolset));
    node.params
        .insert("instruction".into(), Value::from(instruction));
    node.params.insert("maxIterations".into(), json!(8));
    node
}

fn company_workflow(base_url: &str) -> Workflow {
    let mut workflow = Workflow::new("company demo");
    workflow.nodes = vec![
        agent(
            "pm",
            "Product Manager",
            "mock-pm",
            base_url,
            "",
            "Write a concise PRD and hand it to engineering.",
        ),
        agent(
            "coder",
            "Coder",
            "mock-coder",
            base_url,
            "read_file,write_file",
            "Implement the PRD, then hand the implementation to QA.",
        ),
        agent(
            "tester",
            "Tester",
            "mock-tester",
            base_url,
            "read_file",
            "Verify the implementation and report a pass or fail verdict.",
        ),
        {
            let mut gate = WorkflowNode::new("gate", "core.loop_gate", Position::default());
            gate.label = Some("Rework Loop".into());
            gate.params.insert("maxIterations".into(), json!(4));
            gate.params.insert("timeoutMs".into(), json!(120_000));
            gate
        },
        {
            let mut log = WorkflowNode::new("log", "core.log", Position::default());
            log.label = Some("Delivery".into());
            log.params
                .insert("prefix".into(), Value::from("delivery: "));
            log
        },
    ];
    workflow.edges = vec![
        Edge::control("pm", "completed", "gate", "start"),
        Edge::control("gate", "continue", "coder", "start"),
        Edge::control("coder", "completed", "tester", "start"),
        Edge::control("tester", "failed", "gate", "next"),
        Edge::control("tester", "completed", "gate", "stop"),
        Edge::control("gate", "exit", "log", "run"),
        Edge::new("pm", "agentMessage", "coder", "task"),
        Edge::new("coder", "agentMessage", "tester", "task"),
        Edge::new("tester", "agentMessage", "coder", "messages"),
        Edge::new("tester", "userResponse", "log", "value"),
    ];
    workflow
}

#[tokio::test]
async fn company_agents_handoff_and_rework_through_the_bus() {
    let provider = start_mock_provider();
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lingxi-company-{}-{unique}", std::process::id()));
    let workspace = Workspace::open(&root).expect("workspace");
    workspace
        .write("README.md", "company demo\n", ABSENT_VERSION)
        .expect("seed");
    let engine = engine_with_workspace(
        None,
        Arc::new(ApproveAll),
        test_assets(),
        Some(Arc::new(workspace.clone())),
    );
    let workflow = company_workflow(&provider.base_url);
    let report = engine.validate(&workflow);
    assert!(
        report.ok,
        "company workflow must validate: {:#?}",
        report.issues
    );

    let recorder = Recorder::default();
    let control = RunControl::new();
    let summary = engine
        .execute(&workflow, "run-company", control.clone(), &recorder)
        .await;
    assert_eq!(
        summary.status,
        RunStatus::Completed,
        "events: {:#?}",
        recorder.events()
    );

    let product_starts = recorder.node_starts("pm");
    let coder_starts = recorder.node_starts("coder");
    let tester_starts = recorder.node_starts("tester");
    assert_eq!(product_starts.len(), 1, "PM runs once");
    assert_eq!(
        coder_starts.len(),
        2,
        "coder is re-activated after failed QA"
    );
    assert_eq!(tester_starts.len(), 2, "QA runs before and after rework");

    let final_log = recorder.finished("log").expect("delivery log");
    assert!(
        final_log["text"]
            .as_str()
            .unwrap_or_default()
            .contains("Tests passed"),
        "final delivery must be the passing QA report: {final_log:#?}"
    );

    let bus = control.agents().expect("agent bus");
    let session = bus.session();
    assert_eq!(session.agents.len(), 3, "three first-class agent instances");
    let coder = session
        .agents
        .values()
        .find(|agent| agent.node_id == "coder")
        .expect("coder instance");
    assert_eq!(coder.activations.len(), 2);
    assert!(session.messages.len() >= 5);
    assert!(session.messages.iter().any(|message| {
        message.payload.get("status").and_then(Value::as_str) == Some("failed")
    }));

    let delivered = workspace
        .read("company-demo/feature.txt")
        .expect("coder wrote the workspace file");
    assert_eq!(delivered.content.trim(), "v2");
    let _ = std::fs::remove_dir_all(&root);
}
