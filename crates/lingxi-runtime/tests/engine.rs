use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use lingxi_runtime::{
    error_codes, AllowAllPolicy, CapabilityPolicy, CapabilityRequest, Engine, EventSink,
    InteractionDecision, NodeContext, NodeError, NodeExecutor, NodeOutput, NodeRegistry,
    PendingInteractions, RunCause, RunControl, RunEvent, RunStatus,
};
use lingxi_spec::{DataType, Edge, NodeSpec, PortSpec, Position, Workflow, WorkflowNode};
use serde_json::Value;

#[derive(Clone, Default)]
struct Recorder {
    events: Arc<Mutex<Vec<RunEvent>>>,
}

impl EventSink for Recorder {
    fn emit(&self, event: RunEvent) {
        self.events.lock().expect("recorder poisoned").push(event);
    }
}

impl Recorder {
    fn events(&self) -> Vec<RunEvent> {
        self.events.lock().expect("recorder poisoned").clone()
    }

    fn started_nodes(&self) -> Vec<String> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::NodeStarted { node_id, .. } => Some(node_id),
                _ => None,
            })
            .collect()
    }

    fn finished_output(&self, node_id: &str, port: &str) -> Option<Value> {
        self.events().into_iter().find_map(|event| match event {
            RunEvent::NodeFinished {
                node_id: id,
                outputs,
                ..
            } if id == node_id => outputs.get(port).cloned(),
            _ => None,
        })
    }
}

fn engine_with(
    policy: Arc<dyn CapabilityPolicy>,
    interactions: Arc<PendingInteractions>,
) -> Engine {
    Engine::new(Arc::new(NodeRegistry::builtin()), policy, interactions)
}

fn text_input(id: &str, text: &str) -> WorkflowNode {
    let mut node = WorkflowNode::new(id, "core.text_input", Position::default());
    node.params.insert("text".to_string(), Value::from(text));
    node
}

fn chain() -> Workflow {
    let mut workflow = Workflow::new("chain");
    workflow.nodes.push(text_input("t1", "hello"));
    workflow.nodes.push(WorkflowNode::new(
        "up",
        "core.text_uppercase",
        Position::default(),
    ));
    workflow.edges.push(Edge::new("t1", "text", "up", "text"));
    workflow
}

#[tokio::test]
async fn runs_dependencies_in_order_and_publishes_outputs() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = engine_with(Arc::new(AllowAllPolicy), interactions);

    let summary = engine
        .execute(&chain(), "run-1", RunControl::new(), &recorder)
        .await;

    assert_eq!(summary.status, RunStatus::Completed);
    assert!(summary.failed_nodes.is_empty());
    assert_eq!(recorder.started_nodes(), vec!["t1", "up"]);
    assert_eq!(
        recorder.finished_output("up", "text"),
        Some(Value::from("HELLO"))
    );

    let events = recorder.events();
    assert!(matches!(events.first(), Some(RunEvent::RunStarted { .. })));
    assert!(matches!(
        events.last(),
        Some(RunEvent::RunFinished {
            status: RunStatus::Completed,
            ..
        })
    ));
}

#[tokio::test]
async fn invalid_workflows_never_reach_a_node() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = engine_with(Arc::new(AllowAllPolicy), interactions);

    let mut workflow = Workflow::new("broken");
    workflow.nodes.push(WorkflowNode::new(
        "ghost",
        "core.missing",
        Position::default(),
    ));

    let summary = engine
        .execute(&workflow, "run-2", RunControl::new(), &recorder)
        .await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder.started_nodes().is_empty());
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        RunEvent::RunFinished {
            cause: Some(RunCause::ValidationFailed),
            ..
        }
    )));
}

#[derive(Debug)]
struct DenyAll;

impl CapabilityPolicy for DenyAll {
    fn authorize(&self, request: &CapabilityRequest<'_>) -> Result<(), NodeError> {
        Err(NodeError::new(
            error_codes::CAPABILITY_DENIED,
            format!(
                "{} is not allowed to use {}",
                request.kind, request.capability
            ),
        ))
    }
}

#[tokio::test]
async fn capability_denial_blocks_the_executor() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = engine_with(Arc::new(DenyAll), interactions.clone());

    let mut workflow = Workflow::new("gate");
    let mut gate = WorkflowNode::new("gate", "core.approval", Position::default());
    gate.params
        .insert("prompt".to_string(), Value::from("continue?"));
    workflow.nodes.push(gate);

    let summary = engine
        .execute(&workflow, "run-3", RunControl::new(), &recorder)
        .await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert_eq!(summary.failed_nodes, vec!["gate"]);
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        RunEvent::NodeFailed { code, .. } if code == error_codes::CAPABILITY_DENIED
    )));
    assert_eq!(interactions.pending_count(), 0, "executor must not run");
}

#[tokio::test]
async fn disabled_nodes_skip_their_dependents() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = engine_with(Arc::new(AllowAllPolicy), interactions);

    let mut workflow = chain();
    workflow.nodes[0].enabled = false;

    let summary = engine
        .execute(&workflow, "run-4", RunControl::new(), &recorder)
        .await;

    assert_eq!(summary.status, RunStatus::Completed);
    assert_eq!(summary.skipped_nodes, vec!["t1", "up"]);
    assert!(recorder.started_nodes().is_empty());
}

struct Slow;

#[async_trait]
impl NodeExecutor for Slow {
    async fn execute(&self, _ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        tokio::time::sleep(Duration::from_secs(30)).await;
        Ok(NodeOutput::new().with("done", Value::from("late")))
    }
}

fn registry_with_slow_node() -> NodeRegistry {
    let mut registry = NodeRegistry::builtin();
    registry
        .register(
            NodeSpec::new("test.slow", "Slow", "Test").output(PortSpec::new(
                "done",
                "Done",
                DataType::Text,
            )),
            Arc::new(Slow),
        )
        .expect("register slow node");
    registry
}

#[tokio::test]
async fn cancellation_interrupts_a_running_node() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = Arc::new(Engine::new(
        Arc::new(registry_with_slow_node()),
        Arc::new(AllowAllPolicy),
        interactions,
    ));

    let mut workflow = Workflow::new("slow");
    workflow
        .nodes
        .push(WorkflowNode::new("slow", "test.slow", Position::default()));

    let control = RunControl::new();
    let sink = recorder.clone();
    let control_for_task = control.clone();
    let handle = tokio::spawn(async move {
        engine
            .execute(&workflow, "run-5", control_for_task, &sink)
            .await
    });

    tokio::time::sleep(Duration::from_millis(150)).await;
    control.cancel();

    let summary = tokio::time::timeout(Duration::from_secs(5), handle)
        .await
        .expect("run did not stop after cancel")
        .expect("run task panicked");

    assert_eq!(summary.status, RunStatus::Cancelled);
    assert!(recorder
        .events()
        .iter()
        .any(|event| matches!(event, RunEvent::NodeCancelled { .. })));
}

#[tokio::test]
async fn interaction_requests_wait_for_a_decision() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = Arc::new(Engine::new(
        Arc::new(NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
        interactions.clone(),
    ));

    let mut workflow = Workflow::new("approval");
    let mut gate = WorkflowNode::new("gate", "core.approval", Position::default());
    gate.params
        .insert("prompt".to_string(), Value::from("ship it?"));
    workflow.nodes.push(gate);

    let sink = recorder.clone();
    let handle = tokio::spawn(async move {
        engine
            .execute(&workflow, "run-6", RunControl::new(), &sink)
            .await
    });

    let mut request_id = None;
    for _ in 0..200 {
        if let Some(id) = recorder.events().into_iter().find_map(|event| match event {
            RunEvent::InteractionRequested { request_id, .. } => Some(request_id),
            _ => None,
        }) {
            request_id = Some(id);
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let request_id = request_id.expect("interaction.requested was never emitted");
    assert_eq!(interactions.pending_count(), 1);
    assert!(interactions.resolve_pending(&request_id, InteractionDecision::Approved));

    let summary = tokio::time::timeout(Duration::from_secs(5), handle)
        .await
        .expect("approval did not resume the run")
        .expect("run task panicked");

    assert_eq!(summary.status, RunStatus::Completed);
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        RunEvent::InteractionResolved {
            decision: InteractionDecision::Approved,
            ..
        }
    )));
}

#[tokio::test]
async fn rejected_interactions_fail_the_node() {
    let recorder = Recorder::default();
    let interactions = Arc::new(PendingInteractions::new());
    let engine = Arc::new(Engine::new(
        Arc::new(NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
        interactions.clone(),
    ));

    let mut workflow = Workflow::new("reject");
    workflow.nodes.push(WorkflowNode::new(
        "gate",
        "core.approval",
        Position::default(),
    ));

    let sink = recorder.clone();
    let handle = tokio::spawn(async move {
        engine
            .execute(&workflow, "run-7", RunControl::new(), &sink)
            .await
    });

    let mut request_id = None;
    for _ in 0..200 {
        if let Some(id) = recorder.events().into_iter().find_map(|event| match event {
            RunEvent::InteractionRequested { request_id, .. } => Some(request_id),
            _ => None,
        }) {
            request_id = Some(id);
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let request_id = request_id.expect("interaction.requested was never emitted");
    assert!(interactions.resolve_pending(&request_id, InteractionDecision::Rejected));

    let summary = tokio::time::timeout(Duration::from_secs(5), handle)
        .await
        .expect("rejection did not resume the run")
        .expect("run task panicked");

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        RunEvent::NodeFailed { code, .. } if code == error_codes::INTERACTION_DENIED
    )));
}
