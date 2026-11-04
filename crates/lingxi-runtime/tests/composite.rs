use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use lingxi_runtime::{
    error_codes, AllowAllPolicy, CapabilityPolicy, CapabilityRequest, Engine, EventSink,
    NodeContext, NodeError, NodeExecutor, NodeOutput, NodeRegistry, PendingInteractions, RunCause,
    RunControl, RunEvent, RunStatus,
};
use lingxi_spec::{
    DataType, Edge, NodeSpec, PortBinding, PortSpec, Position, Subgraph, SubgraphInput,
    SubgraphOutput, Workflow, WorkflowNode, COMPOSITE_NODE_KIND,
};
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

    fn finished(&self, node_id: &str) -> Option<serde_json::Map<String, Value>> {
        self.events().into_iter().find_map(|event| match event {
            RunEvent::NodeFinished {
                node_id: id,
                outputs,
                ..
            } if id == node_id => Some(outputs.into_iter().collect::<serde_json::Map<_, _>>()),
            _ => None,
        })
    }

    fn failed_codes(&self) -> Vec<(String, String)> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::NodeFailed { node_id, code, .. } => Some((node_id, code)),
                _ => None,
            })
            .collect()
    }

    fn started_iterations(&self, node_id: &str) -> Vec<Option<u32>> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::NodeStarted {
                    node_id: id,
                    iteration,
                    ..
                } if id == node_id => Some(iteration),
                _ => None,
            })
            .collect()
    }
}

fn engine() -> Engine {
    Engine::new(
        Arc::new(NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
        Arc::new(PendingInteractions::new()),
    )
}

fn engine_with(registry: NodeRegistry, policy: Arc<dyn CapabilityPolicy>) -> Engine {
    Engine::new(
        Arc::new(registry),
        policy,
        Arc::new(PendingInteractions::new()),
    )
}

fn node(id: &str, kind: &str) -> WorkflowNode {
    WorkflowNode::new(id, kind, Position::default())
}

fn number_input(id: &str, value: f64) -> WorkflowNode {
    let mut node = node(id, "core.number_input");
    node.params.insert("value".to_string(), Value::from(value));
    node
}

fn composite(id: &str, subgraph_id: &str) -> WorkflowNode {
    let mut node = node(id, COMPOSITE_NODE_KIND);
    node.subgraph_id = Some(subgraph_id.to_string());
    node
}

fn log_node(id: &str, prefix: &str) -> WorkflowNode {
    let mut node = node(id, "core.log");
    node.params
        .insert("prefix".to_string(), Value::from(prefix));
    node
}

fn subgraph(
    id: &str,
    workflow: Workflow,
    inputs: Vec<SubgraphInput>,
    outputs: Vec<SubgraphOutput>,
) -> Subgraph {
    Subgraph {
        id: id.to_string(),
        version: 1,
        name: id.to_string(),
        description: None,
        workflow,
        inputs,
        outputs,
    }
}

fn counter_subgraph() -> Subgraph {
    let mut inner = Workflow::new("counter inner");
    inner.nodes.push(node("counter", "core.counter"));
    subgraph(
        "sg-counter",
        inner,
        vec![SubgraphInput {
            port: PortSpec::new("value", "Value", DataType::Number).required(),
            targets: vec![PortBinding::new("counter", "value")],
        }],
        vec![SubgraphOutput {
            port: PortSpec::new("number", "Number", DataType::Number),
            source: PortBinding::new("counter", "number"),
        }],
    )
}

fn add_subgraph() -> Subgraph {
    let mut inner = Workflow::new("add inner");
    inner.nodes.push(node("add", "core.number_add"));
    subgraph(
        "sg-add",
        inner,
        vec![
            SubgraphInput {
                port: PortSpec::new("a", "A", DataType::Number).required(),
                targets: vec![PortBinding::new("add", "a")],
            },
            SubgraphInput {
                port: PortSpec::new("b", "B", DataType::Number).required(),
                targets: vec![PortBinding::new("add", "b")],
            },
        ],
        vec![SubgraphOutput {
            port: PortSpec::new("sum", "Sum", DataType::Number),
            source: PortBinding::new("add", "number"),
        }],
    )
}

fn loop_subgraph() -> Subgraph {
    let mut inner = Workflow::new("loop inner");
    let mut gate = node("gate", "core.loop_gate");
    gate.params.insert("maxIterations".into(), Value::from(5.0));
    gate.params
        .insert("timeoutMs".into(), Value::from(60_000.0));
    let mut counter = node("counter", "core.counter");
    counter
        .params
        .insert("threshold".to_string(), Value::from(3.0));
    inner.nodes.push(number_input("seed", 0.0));
    inner.nodes.push(gate);
    inner.nodes.push(counter);
    inner.nodes.push(node("condition", "core.condition"));
    inner.nodes.push(log_node("log", "count: "));
    inner
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    inner
        .edges
        .push(Edge::control("gate", "continue", "counter", "value"));
    inner
        .edges
        .push(Edge::new("counter", "number", "condition", "payload"));
    inner
        .edges
        .push(Edge::new("counter", "done", "condition", "condition"));
    inner
        .edges
        .push(Edge::control("condition", "false", "gate", "next"));
    inner
        .edges
        .push(Edge::control("condition", "true", "gate", "stop"));
    inner
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));
    subgraph("sg-loop", inner, Vec::new(), Vec::new())
}

/// The shape the UI creates when a loop is grouped: the gate is triggered by
/// a composite input binding instead of an internal seed edge.
fn externally_triggered_loop_subgraph() -> Subgraph {
    let mut subgraph = loop_subgraph();
    subgraph.workflow.nodes.retain(|node| node.id != "seed");
    subgraph
        .workflow
        .edges
        .retain(|edge| !(edge.target == "gate" && edge.target_port == "start"));
    subgraph.inputs.push(SubgraphInput {
        port: PortSpec::new("start", "Start", DataType::Any).control(),
        targets: vec![PortBinding::new("gate", "start")],
    });
    subgraph
}

async fn run(
    workflow: &Workflow,
    control: Arc<RunControl>,
) -> (Recorder, lingxi_runtime::RunSummary) {
    let recorder = Recorder::default();
    let summary = engine()
        .execute(workflow, "run-composite", control, &recorder)
        .await;
    (recorder, summary)
}

#[tokio::test]
async fn a_wrapped_dag_produces_the_same_outputs() {
    let mut direct = Workflow::new("direct");
    direct.nodes.push(number_input("a", 2.0));
    direct.nodes.push(number_input("b", 40.0));
    direct.nodes.push(node("add", "core.number_add"));
    direct.edges.push(Edge::new("a", "number", "add", "a"));
    direct.edges.push(Edge::new("b", "number", "add", "b"));
    let (direct_recorder, direct_summary) = run(&direct, RunControl::new()).await;
    assert_eq!(direct_summary.status, RunStatus::Completed);

    let mut wrapped = Workflow::new("wrapped");
    wrapped.nodes.push(number_input("a", 2.0));
    wrapped.nodes.push(number_input("b", 40.0));
    wrapped.nodes.push(composite("comp", "sg-add"));
    wrapped.edges.push(Edge::new("a", "number", "comp", "a"));
    wrapped.edges.push(Edge::new("b", "number", "comp", "b"));
    wrapped.subgraphs.insert("sg-add".into(), add_subgraph());
    let (wrapped_recorder, wrapped_summary) = run(&wrapped, RunControl::new()).await;
    assert_eq!(wrapped_summary.status, RunStatus::Completed);
    assert_eq!(
        wrapped_recorder.finished("comp").unwrap().get("sum"),
        Some(&Value::from(42.0))
    );
    assert_eq!(
        wrapped_recorder.finished("comp").unwrap().get("sum"),
        direct_recorder.finished("add").unwrap().get("number")
    );
}

#[tokio::test]
async fn multiple_ports_map_in_and_out() {
    let mut workflow = Workflow::new("ports");
    workflow.nodes.push(number_input("a", 7.0));
    workflow.nodes.push(number_input("b", 8.0));
    workflow.nodes.push(composite("comp", "sg-add"));
    workflow.nodes.push(log_node("out", "sum: "));
    workflow.edges.push(Edge::new("a", "number", "comp", "a"));
    workflow.edges.push(Edge::new("b", "number", "comp", "b"));
    workflow
        .edges
        .push(Edge::new("comp", "sum", "out", "value"));
    workflow.subgraphs.insert("sg-add".into(), add_subgraph());

    let (recorder, summary) = run(&workflow, RunControl::new()).await;
    assert_eq!(summary.status, RunStatus::Completed);
    let outputs = recorder.finished("comp").expect("composite finished");
    assert_eq!(outputs.get("sum"), Some(&Value::from(15.0)));
    let log = recorder
        .events()
        .into_iter()
        .find_map(|event| match event {
            RunEvent::Log {
                node_id: Some(node_id),
                message,
                ..
            } if node_id == "out" => Some(message),
            _ => None,
        })
        .expect("log event");
    assert_eq!(log, "sum: 15.0");
}

#[tokio::test]
async fn an_inner_failure_propagates_to_the_composite() {
    struct Fails;
    #[async_trait]
    impl NodeExecutor for Fails {
        async fn execute(&self, _ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
            Err(NodeError::new("test.boom", "inner node exploded"))
        }
    }

    let mut registry = NodeRegistry::builtin();
    registry
        .register(NodeSpec::new("test.fail", "Fail", "Test"), Arc::new(Fails))
        .unwrap();
    let mut inner = Workflow::new("inner fail");
    inner.nodes.push(node("inner", "test.fail"));
    let mut workflow = Workflow::new("outer fail");
    workflow.nodes.push(composite("comp", "sg-fail"));
    workflow.subgraphs.insert(
        "sg-fail".into(),
        subgraph("sg-fail", inner, Vec::new(), Vec::new()),
    );

    let recorder = Recorder::default();
    let summary = engine_with(registry, Arc::new(AllowAllPolicy))
        .execute(&workflow, "run-fail", RunControl::new(), &recorder)
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    assert!(summary.failed_nodes.contains(&"comp".to_string()));
    let codes = recorder.failed_codes();
    assert!(
        codes.contains(&("inner".to_string(), "test.boom".to_string())),
        "{codes:?}"
    );
    assert!(
        codes.contains(&("comp".to_string(), "test.boom".to_string())),
        "{codes:?}"
    );
}

#[tokio::test]
async fn cancellation_interrupts_an_inner_node() {
    struct Slow;
    #[async_trait]
    impl NodeExecutor for Slow {
        async fn execute(&self, _ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
            tokio::time::sleep(Duration::from_secs(30)).await;
            Ok(NodeOutput::new())
        }
    }

    let mut registry = NodeRegistry::builtin();
    registry
        .register(NodeSpec::new("test.slow", "Slow", "Test"), Arc::new(Slow))
        .unwrap();
    let mut inner = Workflow::new("inner slow");
    inner.nodes.push(node("slow", "test.slow"));
    let mut workflow = Workflow::new("outer cancel");
    workflow.nodes.push(composite("comp", "sg-slow"));
    workflow.subgraphs.insert(
        "sg-slow".into(),
        subgraph("sg-slow", inner, Vec::new(), Vec::new()),
    );

    let control = RunControl::new();
    let cancel = Arc::clone(&control);
    let recorder = Recorder::default();
    let task = tokio::spawn(async move {
        engine_with(registry, Arc::new(AllowAllPolicy))
            .execute(&workflow, "run-cancel", control, &recorder)
            .await
    });
    tokio::time::sleep(Duration::from_millis(80)).await;
    cancel.cancel();
    let summary = task.await.expect("run task");
    assert_eq!(summary.status, RunStatus::Cancelled);
}

#[tokio::test]
async fn multiple_instances_keep_independent_state() {
    let mut workflow = Workflow::new("two instances");
    workflow.nodes.push(number_input("a", 0.0));
    workflow.nodes.push(number_input("b", 10.0));
    workflow.nodes.push(composite("left", "sg-counter"));
    workflow.nodes.push(composite("right", "sg-counter"));
    workflow.nodes.push(log_node("left-log", ""));
    workflow.nodes.push(log_node("right-log", ""));
    workflow
        .edges
        .push(Edge::new("a", "number", "left", "value"));
    workflow
        .edges
        .push(Edge::new("b", "number", "right", "value"));
    workflow
        .edges
        .push(Edge::new("left", "number", "left-log", "value"));
    workflow
        .edges
        .push(Edge::new("right", "number", "right-log", "value"));
    workflow
        .subgraphs
        .insert("sg-counter".into(), counter_subgraph());

    let (recorder, summary) = run(&workflow, RunControl::new()).await;
    assert_eq!(summary.status, RunStatus::Completed);
    assert_eq!(
        recorder.finished("left").unwrap().get("number"),
        Some(&Value::from(1.0))
    );
    assert_eq!(
        recorder.finished("right").unwrap().get("number"),
        Some(&Value::from(11.0))
    );
}

#[tokio::test]
async fn a_saved_and_reloaded_composite_executes() {
    let mut workflow = Workflow::new("reload");
    workflow.nodes.push(number_input("seed", 4.0));
    workflow.nodes.push(composite("comp", "sg-counter"));
    workflow
        .subgraphs
        .insert("sg-counter".into(), counter_subgraph());
    workflow
        .edges
        .push(Edge::new("seed", "number", "comp", "value"));

    let json = serde_json::to_string(&workflow).expect("serialize");
    let restored: Workflow = serde_json::from_str(&json).expect("deserialize");
    let (recorder, summary) = run(&restored, RunControl::new()).await;
    assert_eq!(summary.status, RunStatus::Completed);
    assert_eq!(
        recorder.finished("comp").unwrap().get("number"),
        Some(&Value::from(5.0))
    );
}

#[tokio::test]
async fn a_loop_inside_a_composite_emits_scoped_events_with_one_sequence() {
    let mut workflow = Workflow::new("wrapped loop");
    workflow.nodes.push(composite("comp", "sg-loop"));
    workflow.subgraphs.insert("sg-loop".into(), loop_subgraph());

    let (recorder, summary) = run(&workflow, RunControl::new()).await;
    assert_eq!(summary.status, RunStatus::Completed);
    let events = recorder.events();
    for (index, event) in events.iter().enumerate() {
        assert_eq!(event.seq(), index as u64, "seq gap at {index}");
    }
    let log = events
        .iter()
        .find_map(|event| match event {
            RunEvent::Log {
                node_id: Some(node_id),
                message,
                ..
            } if node_id == "log" => Some(message.clone()),
            _ => None,
        })
        .expect("inner log");
    assert_eq!(log, "count: 3.0");
    let inner_events = events
        .iter()
        .filter(
            |event| matches!(event, RunEvent::NodeStarted { node_id, .. } if node_id == "counter"),
        )
        .count();
    assert_eq!(inner_events, 3);
    for event in &events {
        match event {
            RunEvent::RunStarted { .. } | RunEvent::RunFinished { .. } => {
                assert!(event.scope().is_empty());
            }
            RunEvent::NodeStarted { node_id, .. } | RunEvent::NodeFinished { node_id, .. }
                if node_id == "comp" =>
            {
                assert!(event.scope().is_empty());
            }
            RunEvent::Log { node_id: None, .. } => {
                assert!(event.scope().is_empty());
            }
            _ => {
                assert_eq!(event.scope().len(), 1, "missing scope on {event:?}");
                assert_eq!(event.scope()[0].instance_id, "comp");
                assert_eq!(event.scope()[0].subgraph_id, "sg-loop");
            }
        }
    }
    assert_eq!(
        recorder.started_iterations("counter"),
        vec![Some(1), Some(2), Some(3)]
    );
}

#[tokio::test]
async fn a_loop_triggered_through_a_composite_input_executes() {
    let mut workflow = Workflow::new("externally triggered loop");
    workflow.nodes.push(number_input("trigger", 0.0));
    workflow.nodes.push(composite("comp", "sg-loop"));
    workflow
        .edges
        .push(Edge::control("trigger", "number", "comp", "start"));
    workflow
        .subgraphs
        .insert("sg-loop".into(), externally_triggered_loop_subgraph());

    let (recorder, summary) = run(&workflow, RunControl::new()).await;
    assert_eq!(
        summary.status,
        RunStatus::Completed,
        "{:?}",
        summary.failed_nodes
    );
    let log = recorder
        .events()
        .into_iter()
        .find_map(|event| match event {
            RunEvent::Log {
                node_id: Some(node_id),
                message,
                ..
            } if node_id == "log" => Some(message),
            _ => None,
        })
        .expect("inner log");
    assert_eq!(log, "count: 3.0");
    assert_eq!(recorder.started_iterations("counter").len(), 3);
}

#[tokio::test]
async fn a_capability_denial_inside_a_composite_fails_the_run() {
    struct DenyAll;
    impl CapabilityPolicy for DenyAll {
        fn authorize(&self, _request: &CapabilityRequest<'_>) -> Result<(), NodeError> {
            Err(NodeError::new(error_codes::CAPABILITY_DENIED, "denied"))
        }
    }

    let mut inner = Workflow::new("inner approval");
    inner.nodes.push(node("approval", "core.approval"));
    let mut workflow = Workflow::new("outer approval");
    workflow.nodes.push(composite("comp", "sg-approval"));
    workflow.subgraphs.insert(
        "sg-approval".into(),
        subgraph("sg-approval", inner, Vec::new(), Vec::new()),
    );

    let recorder = Recorder::default();
    let summary = engine_with(NodeRegistry::builtin(), Arc::new(DenyAll))
        .execute(&workflow, "run-policy", RunControl::new(), &recorder)
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder.failed_codes().contains(&(
        "approval".to_string(),
        error_codes::CAPABILITY_DENIED.to_string()
    )));
}

#[tokio::test]
async fn a_recursive_definition_is_rejected_before_any_node_runs() {
    let mut inner = Workflow::new("inner recursive");
    inner.nodes.push(composite("self", "sg-recursive"));
    let mut workflow = Workflow::new("outer recursive");
    workflow.nodes.push(composite("comp", "sg-recursive"));
    workflow.subgraphs.insert(
        "sg-recursive".into(),
        subgraph("sg-recursive", inner, Vec::new(), Vec::new()),
    );

    let recorder = Recorder::default();
    let summary = engine()
        .execute(&workflow, "run-recursive", RunControl::new(), &recorder)
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        RunEvent::RunFinished {
            cause: Some(RunCause::ValidationFailed),
            ..
        }
    )));
    assert!(!recorder
        .events()
        .iter()
        .any(|event| matches!(event, RunEvent::NodeStarted { .. })));
}
