use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use lingxi_runtime::{
    error_codes, AllowAllPolicy, Engine, EventSink, NodeContext, NodeError, NodeExecutor,
    NodeOutput, PendingInteractions, RunControl, RunEvent, RunStatus,
};
use lingxi_spec::{DataType, Edge, PortSpec, Position, Workflow, WorkflowNode};
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

    fn started(&self) -> Vec<(String, Option<u32>)> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::NodeStarted {
                    node_id, iteration, ..
                } => Some((node_id, iteration)),
                _ => None,
            })
            .collect()
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

    fn counter_values(&self) -> Vec<f64> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::NodeFinished {
                    node_id, outputs, ..
                } if node_id == "counter" => outputs.get("number").and_then(Value::as_f64),
                _ => None,
            })
            .collect()
    }
}

fn engine() -> Engine {
    Engine::new(
        Arc::new(lingxi_runtime::NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
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

fn counter(id: &str, threshold: f64) -> WorkflowNode {
    let mut node = node(id, "core.counter");
    node.params
        .insert("threshold".to_string(), Value::from(threshold));
    node
}

fn gate(id: &str, max_iterations: f64, timeout_ms: f64) -> WorkflowNode {
    let mut node = node(id, "core.loop_gate");
    node.params
        .insert("maxIterations".to_string(), Value::from(max_iterations));
    node.params
        .insert("timeoutMs".to_string(), Value::from(timeout_ms));
    node
}

/// seed -> gate.start; gate.continue -> counter -> condition; false -> gate.next;
/// true -> gate.stop; gate.exit -> log.
fn counter_loop(threshold: f64, max_iterations: f64, timeout_ms: f64) -> Workflow {
    let mut workflow = Workflow::new("counter-loop");
    workflow.nodes.push(number_input("seed", 0.0));
    workflow
        .nodes
        .push(gate("gate", max_iterations, timeout_ms));
    workflow.nodes.push(counter("counter", threshold));
    workflow.nodes.push(node("condition", "core.condition"));
    workflow.nodes.push(node("log", "core.log"));

    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "counter", "value"));
    workflow
        .edges
        .push(Edge::new("counter", "number", "condition", "payload"));
    workflow
        .edges
        .push(Edge::new("counter", "done", "condition", "condition"));
    workflow
        .edges
        .push(Edge::control("condition", "false", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("condition", "true", "gate", "stop"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));
    workflow
}

fn branch_workflow(value: bool) -> Workflow {
    let mut input = node("seed", "core.boolean_input");
    input.params.insert("value".to_string(), Value::from(value));

    let mut workflow = Workflow::new("branch");
    workflow.nodes.push(input);
    workflow.nodes.push(node("condition", "core.condition"));
    workflow.nodes.push(node("yes", "core.log"));
    workflow.nodes.push(node("no", "core.log"));

    workflow
        .edges
        .push(Edge::new("seed", "boolean", "condition", "condition"));
    workflow
        .edges
        .push(Edge::control("condition", "true", "yes", "value"));
    workflow
        .edges
        .push(Edge::control("condition", "false", "no", "value"));
    workflow
}

async fn run(
    workflow: &Workflow,
    control: Arc<RunControl>,
) -> (Recorder, lingxi_runtime::RunSummary) {
    let recorder = Recorder::default();
    let summary = engine()
        .execute(workflow, "run-1", control, &recorder)
        .await;
    (recorder, summary)
}

#[tokio::test]
async fn condition_true_runs_only_the_true_branch() {
    let (recorder, summary) = run(&branch_workflow(true), RunControl::new()).await;
    assert_eq!(summary.status, RunStatus::Completed);
    let started = recorder.started();
    assert!(started.iter().any(|(id, _)| id == "yes"));
    assert!(!started.iter().any(|(id, _)| id == "no"));
    assert!(!recorder.failed_codes().iter().any(|(id, _)| id == "no"));
    assert!(summary.skipped_nodes.contains(&"no".to_string()));
}

#[tokio::test]
async fn condition_false_runs_only_the_false_branch() {
    let (recorder, summary) = run(&branch_workflow(false), RunControl::new()).await;
    assert_eq!(summary.status, RunStatus::Completed);
    let started = recorder.started();
    assert!(started.iter().any(|(id, _)| id == "no"));
    assert!(!started.iter().any(|(id, _)| id == "yes"));
    assert!(summary.skipped_nodes.contains(&"yes".to_string()));
}

#[tokio::test]
async fn counter_loop_runs_three_iterations_then_exits() {
    let workflow = counter_loop(3.0, 10.0, 60_000.0);
    let (recorder, summary) = run(&workflow, RunControl::new()).await;

    assert_eq!(summary.status, RunStatus::Completed);
    assert_eq!(recorder.counter_values(), vec![1.0, 2.0, 3.0]);
    let gate_starts: Vec<Option<u32>> = recorder
        .started()
        .into_iter()
        .filter(|(id, _)| id == "gate")
        .map(|(_, iteration)| iteration)
        .collect();
    assert_eq!(gate_starts, vec![Some(1), Some(2), Some(3), Some(3)]);
    assert!(recorder.started().iter().any(|(id, _)| id == "log"));
}

#[tokio::test]
async fn budget_exhaustion_fails_the_run() {
    let workflow = counter_loop(999.0, 2.0, 60_000.0);
    let (recorder, summary) = run(&workflow, RunControl::new()).await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(summary.failed_nodes.contains(&"gate".to_string()));
    assert!(recorder
        .failed_codes()
        .iter()
        .any(|(id, code)| id == "gate" && code == error_codes::LOOP_BUDGET_EXHAUSTED));
    assert_eq!(recorder.counter_values(), vec![1.0, 2.0]);
}

#[tokio::test]
async fn timeout_fails_the_run() {
    let mut registry = lingxi_runtime::NodeRegistry::builtin();
    registry
        .register(
            lingxi_spec::NodeSpec::new("test.slow_bool", "Slow Bool", "Test")
                .input(PortSpec::new("value", "Value", DataType::Any))
                .output(PortSpec::new("boolean", "Boolean", DataType::Boolean)),
            Arc::new(SlowBool),
        )
        .expect("test node registers");

    let mut workflow = Workflow::new("timeout-loop");
    workflow.nodes.push(number_input("seed", 0.0));
    workflow.nodes.push(gate("gate", 100.0, 50.0));
    workflow.nodes.push(node("slow", "test.slow_bool"));
    workflow.nodes.push(node("condition", "core.condition"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "slow", "value"));
    workflow
        .edges
        .push(Edge::new("slow", "boolean", "condition", "condition"));
    workflow
        .edges
        .push(Edge::control("condition", "false", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("condition", "true", "gate", "stop"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let recorder = Recorder::default();
    let summary = Engine::new(
        Arc::new(registry),
        Arc::new(AllowAllPolicy),
        Arc::new(PendingInteractions::new()),
    )
    .execute(&workflow, "run-1", RunControl::new(), &recorder)
    .await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(recorder
        .failed_codes()
        .iter()
        .any(|(_, code)| code == error_codes::LOOP_TIMEOUT));
}

struct SlowBool;

#[async_trait]
impl NodeExecutor for SlowBool {
    async fn execute(&self, _ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        tokio::time::sleep(Duration::from_secs(30)).await;
        Ok(NodeOutput::new().with("boolean", Value::Bool(true)))
    }
}

#[tokio::test]
async fn cancellation_interrupts_a_running_loop() {
    let mut registry = lingxi_runtime::NodeRegistry::builtin();
    registry
        .register(
            lingxi_spec::NodeSpec::new("test.slow_bool", "Slow Bool", "Test")
                .input(PortSpec::new("value", "Value", DataType::Any))
                .output(PortSpec::new("boolean", "Boolean", DataType::Boolean)),
            Arc::new(SlowBool),
        )
        .expect("test node registers");

    let mut workflow = Workflow::new("cancel-loop");
    workflow.nodes.push(number_input("seed", 0.0));
    workflow.nodes.push(gate("gate", 100.0, 60_000.0));
    workflow.nodes.push(node("slow", "test.slow_bool"));
    workflow.nodes.push(node("condition", "core.condition"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "slow", "value"));
    workflow
        .edges
        .push(Edge::new("slow", "boolean", "condition", "condition"));
    workflow
        .edges
        .push(Edge::control("condition", "false", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("condition", "true", "gate", "stop"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let control = RunControl::new();
    let recorder = Recorder::default();
    let engine = Engine::new(
        Arc::new(registry),
        Arc::new(AllowAllPolicy),
        Arc::new(PendingInteractions::new()),
    );
    let started = Instant::now();
    let task = tokio::spawn({
        let workflow = workflow.clone();
        let control = control.clone();
        let recorder = recorder.clone();
        async move { engine.execute(&workflow, "run-1", control, &recorder).await }
    });
    tokio::time::sleep(Duration::from_millis(150)).await;
    control.cancel();
    let summary = tokio::time::timeout(Duration::from_secs(5), task)
        .await
        .expect("cancellation must finish the run")
        .expect("task joins");

    assert_eq!(summary.status, RunStatus::Cancelled);
    assert!(recorder
        .events()
        .iter()
        .any(|event| matches!(event, RunEvent::NodeCancelled { .. })));
    assert!(started.elapsed() < Duration::from_secs(5));
}

struct Failing;

#[async_trait]
impl NodeExecutor for Failing {
    async fn execute(&self, _ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        Err(NodeError::new("test.failure", "intentional failure"))
    }
}

#[tokio::test]
async fn a_node_failure_inside_a_loop_ends_the_run() {
    let mut registry = lingxi_runtime::NodeRegistry::builtin();
    registry
        .register(
            lingxi_spec::NodeSpec::new("test.failing", "Failing", "Test")
                .input(PortSpec::new("value", "Value", DataType::Any))
                .output(PortSpec::new("value", "Value", DataType::Any)),
            Arc::new(Failing),
        )
        .expect("test node registers");

    let mut workflow = Workflow::new("failing-loop");
    workflow.nodes.push(number_input("seed", 0.0));
    workflow.nodes.push(gate("gate", 10.0, 60_000.0));
    workflow.nodes.push(node("fail", "test.failing"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "fail", "value"));
    workflow
        .edges
        .push(Edge::control("fail", "value", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let recorder = Recorder::default();
    let summary = Engine::new(
        Arc::new(registry),
        Arc::new(AllowAllPolicy),
        Arc::new(PendingInteractions::new()),
    )
    .execute(&workflow, "run-1", RunControl::new(), &recorder)
    .await;

    assert_eq!(summary.status, RunStatus::Failed);
    assert!(summary.failed_nodes.contains(&"fail".to_string()));
    assert!(recorder
        .failed_codes()
        .iter()
        .any(|(id, code)| id == "fail" && code == "test.failure"));
    let finished = recorder
        .events()
        .iter()
        .filter(|event| matches!(event, RunEvent::RunFinished { .. }))
        .count();
    assert_eq!(
        finished, 1,
        "a failed run must emit exactly one terminal event"
    );
}
