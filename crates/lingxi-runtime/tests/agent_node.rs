//! End-to-end tests for the first-class Agent node and AgentRunner.

mod common;

use std::sync::Arc;

use common::{
    engine, engine_with_workspace, python_bin, start_mock_provider, test_assets, ApproveAll,
    Recorder,
};
use lingxi_runtime::agent_protocol::{message_kinds, states};
use lingxi_runtime::workspace::{Workspace, ABSENT_VERSION};
use lingxi_runtime::{RunControl, RunStatus};
use lingxi_spec::{Edge, Position, Workflow, WorkflowNode};
use serde_json::{json, Value};

fn agent_node(model: &str, base_url: &str, params: &[(&str, Value)]) -> WorkflowNode {
    let mut node = WorkflowNode::new("agent", "core.agent", Position::default());
    node.label = Some("Coder".into());
    node.params.insert("baseUrl".into(), Value::from(base_url));
    node.params
        .insert("credentialRef".into(), Value::from("test-key"));
    node.params.insert("model".into(), Value::from(model));
    node.params.insert(
        "instruction".into(),
        Value::from("Finish the task and submit a structured result."),
    );
    for (key, value) in params {
        node.params.insert((*key).into(), value.clone());
    }
    node
}

fn workflow(model: &str, base_url: &str, params: &[(&str, Value)]) -> Workflow {
    let mut workflow = Workflow::new("agent node");
    workflow.nodes = vec![agent_node(model, base_url, params)];
    workflow
}

fn event_count(recorder: &Recorder) -> usize {
    recorder.events().len()
}

async fn execute_spawned(
    workflow: Workflow,
    run_id: &str,
) -> (Recorder, Arc<RunControl>, lingxi_runtime::RunSummary) {
    let engine = engine(None);
    let recorder = Recorder::default();
    let control = RunControl::new();
    let summary = engine
        .execute(&workflow, run_id, control.clone(), &recorder)
        .await;
    (recorder, control, summary)
}

#[tokio::test]
async fn agent_node_completes_through_the_runner_and_publishes_a_result() {
    let provider = start_mock_provider();
    let (recorder, control, summary) = execute_spawned(
        workflow("mock-agent", &provider.base_url, &[]),
        "run-agent-complete",
    )
    .await;

    assert_eq!(
        summary.status,
        RunStatus::Completed,
        "events: {}",
        event_count(&recorder)
    );
    let outputs = recorder.finished("agent").expect("agent output");
    assert_eq!(
        outputs.get("userResponse").and_then(Value::as_str),
        Some("Agent completed the task.")
    );
    assert_eq!(
        outputs
            .get("executionState")
            .and_then(|state| state.get("state"))
            .and_then(Value::as_str),
        Some(states::COMPLETED)
    );

    let bus = control.agents().expect("agent bus attached");
    let session = bus.session();
    let instance = session
        .agents
        .get("agent:run-agent-complete:agent")
        .expect("instance");
    assert_eq!(instance.state, states::COMPLETED);
    assert_eq!(instance.activations.len(), 1);
    assert!(session.messages.iter().any(|message| {
        message.sender == instance.instance_id
            && message.message_type == message_kinds::RESULT
            && message.status == "queued"
    }));
}

#[tokio::test]
async fn agent_node_runs_a_real_tool_before_submitting() {
    let provider = start_mock_provider();
    let (recorder, control, summary) = execute_spawned(
        workflow("mock-agent-tool", &provider.base_url, &[]),
        "run-agent-tool",
    )
    .await;

    assert_eq!(summary.status, RunStatus::Completed);
    let outputs = recorder.finished("agent").expect("agent output");
    let message = outputs.get("agentMessage").expect("agent message");
    assert_eq!(
        message.get("type").and_then(Value::as_str),
        Some("task.result")
    );
    assert_eq!(
        message
            .pointer("/payload/data/value")
            .and_then(Value::as_str),
        Some("32768.0")
    );

    let bus = control.agents().expect("agent bus");
    let session = bus.session();
    let instance = &session.agents["agent:run-agent-tool:agent"];
    assert_eq!(instance.usage.tool_calls, 1);
    assert_eq!(instance.usage.model_calls, 2);
}

#[tokio::test]
async fn agent_budget_exhaustion_fails_with_a_stable_code() {
    let provider = start_mock_provider();
    let mut workflow = workflow("mock-always-tool", &provider.base_url, &[]);
    workflow.nodes[0]
        .params
        .insert("maxToolCalls".into(), json!(1));
    let (recorder, _, summary) = execute_spawned(workflow, "run-agent-budget").await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        lingxi_runtime::RunEvent::NodeFailed { node_id, code, .. }
            if node_id == "agent" && code == "agent.tool_budget"
    )));
}

#[tokio::test]
async fn invalid_agent_result_is_repaired_only_once() {
    let provider = start_mock_provider();
    let (recorder, _, summary) = execute_spawned(
        workflow("mock-agent-invalid", &provider.base_url, &[]),
        "run-agent-invalid",
    )
    .await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        lingxi_runtime::RunEvent::NodeFailed { node_id, code, .. }
            if node_id == "agent" && code == "agent.invalid_result"
    )));
}

async fn wait_until(mut check: impl FnMut() -> bool, label: &str) {
    for _ in 0..500 {
        if check() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for {label}");
}

#[tokio::test]
async fn pause_applies_a_config_revision_and_directive_before_resuming() {
    let provider = start_mock_provider();
    let workflow = workflow("mock-agent-slow-tool", &provider.base_url, &[]);
    let engine = Arc::new(engine(None));
    let recorder = Recorder::default();
    let control = RunControl::new();
    let handle = tokio::spawn({
        let engine = engine.clone();
        let recorder = recorder.clone();
        let control = control.clone();
        async move {
            engine
                .execute(&workflow, "run-agent-pause", control, &recorder)
                .await
        }
    });

    wait_until(|| control.agents().is_some(), "agent bus").await;
    let bus = control.agents().expect("bus");
    let instance_id = "agent:run-agent-pause:agent";
    wait_until(|| bus.runtime(instance_id).is_some(), "agent runtime").await;
    bus.pause_agent(instance_id).expect("pause requested");
    wait_until(
        || {
            bus.session()
                .agents
                .get(instance_id)
                .map(|agent| agent.state == states::PAUSED)
                .unwrap_or(false)
        },
        "safe pause point",
    )
    .await;

    let mut next = bus.session().agents[instance_id].config.clone();
    assert_eq!(next.revision, 0);
    next.model = "mock-agent".into();
    let revision = bus
        .apply_config(instance_id, next, 0)
        .expect("config accepted");
    assert_eq!(revision.status, "pending");
    bus.intervention(instance_id, "Use the fast path and submit the result.")
        .expect("directive accepted");
    bus.resume_agent(instance_id).expect("resume requested");

    let summary = handle.await.expect("engine task");
    assert_eq!(summary.status, RunStatus::Completed);
    assert_eq!(
        recorder.finished("agent").expect("output")["userResponse"],
        Value::from("Agent completed the task.")
    );

    let session = bus.session();
    let instance = &session.agents[instance_id];
    assert_eq!(instance.state, states::COMPLETED);
    assert_eq!(instance.config.revision, 1);
    assert_eq!(instance.config.model, "mock-agent");
    let applied = instance
        .config_revisions
        .iter()
        .find(|change| change.revision == 1)
        .expect("revision record");
    assert_eq!(applied.status, "applied");
    assert!(applied.applied_at_ms.is_some());

    let events = recorder.events();
    assert!(events.iter().any(|event| matches!(
        event,
        lingxi_runtime::RunEvent::Agent { event, .. }
            if matches!(&**event, lingxi_runtime::event::AgentEvent::Directive { .. })
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        lingxi_runtime::RunEvent::Agent { event, .. }
            if matches!(&**event, lingxi_runtime::event::AgentEvent::ConfigChanged { .. })
    )));
}

#[tokio::test]
async fn agent_exposes_real_lsp_diagnostics_as_tools() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("lingxi-agent-lsp-{}-{unique}", std::process::id()));
    let workspace = Workspace::open(&root).expect("workspace");
    workspace
        .write(
            "src/demo.py",
            "# TODO: fix this\ndef mock_fn():\n    return 1\n",
            ABSENT_VERSION,
        )
        .expect("seed file");
    let engine = engine_with_workspace(
        None,
        Arc::new(ApproveAll),
        test_assets(),
        Some(Arc::new(workspace)),
    );
    let provider = start_mock_provider();
    let mut workflow = workflow("mock-agent-lsp", &provider.base_url, &[]);
    let mut lsp = WorkflowNode::new("lsp", "core.lsp_server", Position::default());
    lsp.label = Some("Python LSP".into());
    lsp.params
        .insert("command".into(), Value::from(python_bin()));
    lsp.params.insert(
        "args".into(),
        Value::from(
            serde_json::to_string(&[format!(
                "{}/../../fixtures/mock-lsp/server.py",
                env!("CARGO_MANIFEST_DIR")
            )])
            .unwrap(),
        ),
    );
    workflow.nodes.insert(0, lsp);
    workflow
        .edges
        .push(Edge::new("lsp", "handle", "agent", "lsp"));
    let recorder = Recorder::default();
    let control = RunControl::new();
    let summary = engine
        .execute(&workflow, "run-agent-lsp", control, &recorder)
        .await;
    assert_eq!(
        summary.status,
        RunStatus::Completed,
        "events: {:#?}",
        recorder.events()
    );
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        lingxi_runtime::RunEvent::Agent { event, .. }
            if matches!(
                &**event,
                lingxi_runtime::event::AgentEvent::ToolFinished {
                    tool_name,
                    ok: true,
                    ..
                } if tool_name == "lsp_diagnostics"
            )
    )));
    let outputs = recorder.finished("agent").expect("agent output");
    assert_eq!(
        outputs.get("userResponse").and_then(Value::as_str),
        Some("Language-server checks completed.")
    );
    let _ = std::fs::remove_dir_all(&root);
}
