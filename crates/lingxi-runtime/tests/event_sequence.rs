//! Verifies that every observable event carries a contiguous per-run sequence.

use std::sync::{Arc, Mutex};

use lingxi_runtime::{
    AllowAllPolicy, Engine, EventSink, PendingInteractions, RunControl, RunEvent, RunStatus,
};
use lingxi_spec::{Edge, Position, Workflow, WorkflowNode};

#[derive(Clone, Default)]
struct Recorder {
    events: Arc<Mutex<Vec<RunEvent>>>,
}

impl EventSink for Recorder {
    fn emit(&self, event: RunEvent) {
        self.events.lock().expect("recorder poisoned").push(event);
    }
}

fn chain() -> Workflow {
    let mut workflow = Workflow::new("sequence");
    let mut input = WorkflowNode::new("t1", "core.text_input", Position::default());
    input
        .params
        .insert("text".to_string(), serde_json::Value::from("hello"));
    workflow.nodes.push(input);
    workflow.nodes.push(WorkflowNode::new(
        "up",
        "core.text_uppercase",
        Position::default(),
    ));
    workflow.edges.push(Edge::new("t1", "text", "up", "text"));
    workflow
}

async fn run(recorder: &Recorder) -> Vec<u64> {
    let engine = Engine::new(
        Arc::new(lingxi_runtime::NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
        Arc::new(PendingInteractions::new()),
    );
    let summary = engine
        .execute(&chain(), "run-seq", RunControl::new(), recorder)
        .await;
    assert_eq!(summary.status, RunStatus::Completed);
    recorder
        .events
        .lock()
        .expect("recorder poisoned")
        .iter()
        .map(RunEvent::seq)
        .collect()
}

#[tokio::test]
async fn every_event_gets_a_contiguous_sequence() {
    let recorder = Recorder::default();
    let seqs = run(&recorder).await;

    assert!(seqs.len() > 4, "expected several events, got {seqs:?}");
    assert_eq!(seqs.first().copied(), Some(0));
    assert_eq!(seqs, (0..seqs.len() as u64).collect::<Vec<_>>());
}

#[tokio::test]
async fn sequence_restarts_for_each_run() {
    let recorder = Recorder::default();
    let first = run(&recorder).await;
    recorder.events.lock().expect("recorder poisoned").clear();
    let second = run(&recorder).await;

    assert_eq!(first, second);
    assert_eq!(first.first().copied(), Some(0));
}
