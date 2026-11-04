use lingxi_spec::{
    validate, ControlKind, DataType, Edge, NodeSpec, ParamSpec, PortBinding, PortSpec, Position,
    StaticCatalog, Subgraph, SubgraphInput, SubgraphOutput, Workflow, WorkflowNode,
    COMPOSITE_NODE_KIND,
};

fn catalog() -> StaticCatalog {
    StaticCatalog::with(vec![
        NodeSpec::new("test.seed", "Seed", "Test").output(PortSpec::new(
            "number",
            "Number",
            DataType::Number,
        )),
        NodeSpec::new("test.text", "Text", "Test").output(PortSpec::new(
            "text",
            "Text",
            DataType::Text,
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

fn gate(id: &str) -> WorkflowNode {
    let mut gate = node(id, "core.loop_gate");
    gate.params.insert("maxIterations".to_string(), 10.0.into());
    gate.params.insert("timeoutMs".to_string(), 60_000.0.into());
    gate
}

fn composite(id: &str, subgraph_id: &str) -> WorkflowNode {
    let mut node = node(id, COMPOSITE_NODE_KIND);
    node.subgraph_id = Some(subgraph_id.to_string());
    node
}

fn simple_subgraph(id: &str) -> Subgraph {
    let mut inner = Workflow::new("inner");
    inner.nodes.push(node("counter", "core.counter"));
    let mut subgraph = Subgraph {
        id: id.to_string(),
        version: 1,
        name: "Counter wrapper".to_string(),
        description: None,
        workflow: inner,
        inputs: vec![SubgraphInput {
            port: PortSpec::new("value", "Value", DataType::Number).required(),
            targets: vec![PortBinding::new("counter", "value")],
        }],
        outputs: vec![SubgraphOutput {
            port: PortSpec::new("number", "Number", DataType::Number),
            source: PortBinding::new("counter", "number"),
        }],
    };
    subgraph.inputs.shrink_to_fit();
    subgraph
}

fn loop_subgraph(id: &str) -> Subgraph {
    let mut inner = Workflow::new("inner loop");
    inner.nodes.push(node("seed", "test.seed"));
    inner.nodes.push(gate("gate"));
    inner.nodes.push(node("counter", "core.counter"));
    inner.nodes.push(node("condition", "core.condition"));
    inner.nodes.push(node("log", "core.log"));
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
    Subgraph {
        id: id.to_string(),
        version: 1,
        name: "Loop wrapper".to_string(),
        description: None,
        workflow: inner,
        inputs: Vec::new(),
        outputs: Vec::new(),
    }
}

fn has(report: &lingxi_spec::ValidationReport, code: &str) -> bool {
    report.issues.iter().any(|issue| issue.code == code)
}

fn outer_with_composite(subgraph_id: &str) -> Workflow {
    let mut workflow = Workflow::new("outer");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(composite("comp", subgraph_id));
    workflow.nodes.push(node("log", "core.log"));
    workflow
        .edges
        .push(Edge::new("seed", "number", "comp", "value"));
    workflow
        .edges
        .push(Edge::new("comp", "number", "log", "value"));
    workflow
}

#[test]
fn a_composite_with_mapped_ports_validates() {
    let mut workflow = outer_with_composite("sg-counter");
    workflow
        .subgraphs
        .insert("sg-counter".into(), simple_subgraph("sg-counter"));
    let report = validate(&workflow, &catalog());
    assert!(report.ok, "{:?}", report.issues);
}

#[test]
fn a_map_key_that_disagrees_with_the_definition_id_is_rejected() {
    let mut workflow = outer_with_composite("sg-counter");
    workflow
        .subgraphs
        .insert("alias".into(), simple_subgraph("sg-counter"));
    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(has(&report, "subgraph.duplicate_id"), "{:?}", report.issues);
}

#[test]
fn an_unknown_subgraph_reference_is_rejected() {
    let workflow = outer_with_composite("missing");
    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        has(&report, "subgraph.unknown_reference"),
        "{:?}",
        report.issues
    );
}

#[test]
fn nested_definitions_are_rejected() {
    let mut subgraph = simple_subgraph("sg-counter");
    let mut stray = Workflow::new("stray");
    stray.nodes.push(node("counter", "core.counter"));
    subgraph
        .workflow
        .subgraphs
        .insert("stray".into(), simple_subgraph("stray"));
    let mut workflow = outer_with_composite("sg-counter");
    workflow.subgraphs.insert("sg-counter".into(), subgraph);
    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        has(&report, "subgraph.nested_definitions"),
        "{:?}",
        report.issues
    );
}

#[test]
fn a_recursive_subgraph_reference_is_rejected() {
    let mut workflow = Workflow::new("recursive");
    let mut subgraph = simple_subgraph("sg-loop");
    subgraph.workflow.nodes.push(composite("inner", "sg-loop"));
    workflow.subgraphs.insert("sg-loop".into(), subgraph);
    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        has(&report, "subgraph.recursive_reference"),
        "{:?}",
        report.issues
    );
}

#[test]
fn a_binding_to_an_internal_port_with_an_incoming_edge_is_rejected() {
    let mut workflow = outer_with_composite("sg-counter");
    let mut subgraph = simple_subgraph("sg-counter");
    subgraph.workflow.nodes.push(node("seed", "test.seed"));
    subgraph
        .workflow
        .edges
        .push(Edge::new("seed", "number", "counter", "value"));
    workflow.subgraphs.insert("sg-counter".into(), subgraph);
    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        has(&report, "subgraph.invalid_binding"),
        "{:?}",
        report.issues
    );
}

#[test]
fn a_control_edge_through_composite_with_an_internal_loop_is_rejected() {
    let mut workflow = Workflow::new("outer loop");
    workflow.nodes.push(composite("comp", "sg-loop"));
    workflow.nodes.push(node("counter", "core.counter"));
    workflow
        .edges
        .push(Edge::new("comp", "number", "counter", "value"));
    workflow
        .edges
        .push(Edge::new("counter", "number", "comp", "value"));
    workflow
        .subgraphs
        .insert("sg-loop".into(), loop_subgraph("sg-loop"));
    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        has(&report, "subgraph.nested_loop_unsupported"),
        "{:?}",
        report.issues
    );
}

#[test]
fn a_composite_containing_a_loop_validates_when_the_outer_graph_is_acyclic() {
    let mut workflow = Workflow::new("wrapped loop");
    workflow.nodes.push(composite("comp", "sg-loop"));
    workflow
        .subgraphs
        .insert("sg-loop".into(), loop_subgraph("sg-loop"));
    let report = validate(&workflow, &catalog());
    assert!(report.ok, "{:?}", report.issues);
}

#[test]
fn a_composite_loop_gate_may_be_triggered_by_a_subgraph_input() {
    // The UI creates this shape when a loop is grouped: the external seed
    // becomes a composite input binding, so the inner gate has no start edge.
    let mut subgraph = loop_subgraph("sg-loop");
    subgraph
        .workflow
        .edges
        .retain(|edge| !(edge.target == "gate" && edge.target_port == "start"));
    subgraph.inputs.push(SubgraphInput {
        port: PortSpec::new("start", "Start", DataType::Any).control(),
        targets: vec![PortBinding::new("gate", "start")],
    });
    let mut workflow = Workflow::new("wrapped loop with external trigger");
    workflow.nodes.push(node("seed", "test.seed"));
    workflow.nodes.push(composite("comp", "sg-loop"));
    workflow
        .edges
        .push(Edge::control("seed", "number", "comp", "start"));
    workflow.subgraphs.insert("sg-loop".into(), subgraph);
    let report = validate(&workflow, &catalog());
    assert!(report.ok, "{:?}", report.issues);
}
