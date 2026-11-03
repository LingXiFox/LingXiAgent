use lingxi_spec::{
    validate, ControlKind, DataType, Edge, NodeSpec, ParamSpec, PortSpec, Position, StaticCatalog,
    Workflow, WorkflowNode,
};

fn specs() -> StaticCatalog {
    StaticCatalog::with(vec![
        NodeSpec::new("test.seed", "Seed", "Test").output(PortSpec::new(
            "number",
            "Number",
            DataType::Number,
        )),
        NodeSpec::new("core.counter", "Counter", "Logic")
            .input(PortSpec::new("value", "Value", DataType::Number))
            .output(PortSpec::new("number", "Number", DataType::Number))
            .output(PortSpec::new("done", "Done", DataType::Boolean)),
        NodeSpec::new("core.condition", "Condition", "Control")
            .control(ControlKind::Branch)
            .input(PortSpec::new("condition", "Condition", DataType::Boolean).required())
            .input(PortSpec::new("payload", "Payload", DataType::Any))
            .output(PortSpec::new("true", "True", DataType::Any).control())
            .output(PortSpec::new("false", "False", DataType::Any).control()),
        NodeSpec::new("core.loop_gate", "Loop Gate", "Control")
            .control(ControlKind::LoopGate)
            .input(PortSpec::new("start", "Start", DataType::Any).control())
            .input(PortSpec::new("next", "Next", DataType::Any).control())
            .input(PortSpec::new("stop", "Stop", DataType::Any).control())
            .output(PortSpec::new("continue", "Continue", DataType::Any).control())
            .output(PortSpec::new("exit", "Exit", DataType::Any).control())
            .param(ParamSpec::number("maxIterations", "Max iterations", 10.0))
            .param(ParamSpec::number("timeoutMs", "Timeout (ms)", 60_000.0)),
        NodeSpec::new("core.log", "Log", "Output")
            .input(PortSpec::new("value", "Value", DataType::Any).required()),
    ])
}

fn node(id: &str, kind: &str) -> WorkflowNode {
    WorkflowNode::new(id, kind, Position::default())
}

fn gate(id: &str, max_iterations: f64) -> WorkflowNode {
    let mut gate = node(id, "core.loop_gate");
    gate.params
        .insert("maxIterations".to_string(), max_iterations.into());
    gate.params.insert("timeoutMs".to_string(), 60_000.0.into());
    gate
}

fn has(report: &lingxi_spec::ValidationReport, code: &str) -> bool {
    report.issues.iter().any(|issue| issue.code == code)
}

#[test]
fn a_loop_without_an_exit_edge_is_rejected() {
    let mut workflow = Workflow::new("no-exit");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(gate("gate", 10.0));
    workflow.nodes.push(node("counter", "core.counter"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "counter", "value"));
    workflow
        .edges
        .push(Edge::control("counter", "number", "gate", "next"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(has(&report, "loop.no_exit_path"), "{:?}", report.issues);
}

#[test]
fn a_feedback_path_that_bypasses_the_gate_is_rejected() {
    let mut workflow = Workflow::new("bypass");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(gate("gate", 10.0));
    workflow.nodes.push(node("counter", "core.counter"));
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
        .push(Edge::control("condition", "false", "counter", "value"));
    workflow
        .edges
        .push(Edge::control("condition", "true", "gate", "stop"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(
        has(&report, "loop.uncontrolled_cycle"),
        "{:?}",
        report.issues
    );
}

#[test]
fn a_zero_iteration_budget_is_rejected() {
    let mut workflow = Workflow::new("zero-budget");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(gate("gate", 0.0));
    workflow.nodes.push(node("counter", "core.counter"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "counter", "value"));
    workflow
        .edges
        .push(Edge::control("counter", "number", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(has(&report, "loop.invalid_budget"), "{:?}", report.issues);
}

#[test]
fn a_gate_without_an_explicit_budget_is_rejected() {
    let mut workflow = Workflow::new("missing-budget");
    workflow.nodes.push(node("seed", "test.seed"));
    let mut budgetless = node("gate", "core.loop_gate");
    budgetless
        .params
        .insert("timeoutMs".to_string(), 60_000.0.into());
    workflow.nodes.push(budgetless);
    workflow.nodes.push(node("counter", "core.counter"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "counter", "value"));
    workflow
        .edges
        .push(Edge::control("counter", "number", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(has(&report, "loop.invalid_budget"), "{:?}", report.issues);
}

#[test]
fn an_acyclic_gate_without_a_budget_is_rejected() {
    let mut workflow = Workflow::new("acyclic-missing-budget");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(node("gate", "core.loop_gate"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "gate", "start"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(has(&report, "loop.invalid_budget"), "{:?}", report.issues);
}

#[test]
fn a_gate_without_a_start_trigger_is_rejected() {
    let mut workflow = Workflow::new("missing-start");
    workflow.nodes.push(gate("gate", 10.0));
    workflow.nodes.push(node("counter", "core.counter"));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::control("gate", "continue", "counter", "value"));
    workflow
        .edges
        .push(Edge::control("counter", "number", "gate", "next"));
    workflow
        .edges
        .push(Edge::control("gate", "exit", "log", "value"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(has(&report, "loop.missing_trigger"), "{:?}", report.issues);
}

#[test]
fn a_control_port_requires_a_control_edge() {
    let mut workflow = Workflow::new("data-on-control-port");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(gate("gate", 10.0));
    workflow
        .edges
        .push(Edge::new("seed", "number", "gate", "start"));

    let report = validate(&workflow, &specs());
    assert!(!report.ok);
    assert!(has(&report, "edge.control_required"), "{:?}", report.issues);
}

#[test]
fn edges_without_a_kind_deserialize_as_data_edges() {
    let document = serde_json::json!({
        "schemaVersion": "1.0",
        "id": "legacy",
        "name": "legacy",
        "nodes": [
            {"id": "a", "kind": "test.seed", "position": {"x": 0.0, "y": 0.0}},
            {"id": "b", "kind": "core.counter", "position": {"x": 1.0, "y": 0.0}}
        ],
        "edges": [
            {"id": "a:number->b:value", "source": "a", "sourcePort": "number", "target": "b", "targetPort": "value"}
        ]
    });
    let workflow: Workflow = serde_json::from_value(document).expect("legacy workflow parses");
    assert_eq!(workflow.edges[0].kind, lingxi_spec::EdgeKind::Data);
}
