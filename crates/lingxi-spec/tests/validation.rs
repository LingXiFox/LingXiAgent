use lingxi_spec::validation::{codes, validate, Severity};
use lingxi_spec::{
    DataType, Edge, NodeSpec, ParamOption, ParamSpec, PortSpec, Position, StaticCatalog, Workflow,
    WorkflowNode,
};
use serde_json::{json, Value};

fn catalog() -> StaticCatalog {
    StaticCatalog::with([
        NodeSpec::new("test.text", "Text", "Input").output(PortSpec::new(
            "text",
            "Text",
            DataType::Text,
        )),
        NodeSpec::new("test.number", "Number", "Input").output(PortSpec::new(
            "number",
            "Number",
            DataType::Number,
        )),
        NodeSpec::new("test.add", "Add", "Math")
            .input(PortSpec::new("a", "A", DataType::Number).required())
            .input(PortSpec::new("b", "B", DataType::Number).required())
            .output(PortSpec::new("number", "Number", DataType::Number)),
        NodeSpec::new("test.mode", "Mode", "Config").param(ParamSpec::select(
            "mode",
            "Mode",
            "fast",
            vec![
                ParamOption {
                    value: "fast".to_string(),
                    label: "Fast".to_string(),
                },
                ParamOption {
                    value: "safe".to_string(),
                    label: "Safe".to_string(),
                },
            ],
        )),
    ])
}

fn node(id: &str, kind: &str) -> WorkflowNode {
    WorkflowNode::new(id, kind, Position::default())
}

fn codes_of(report: &lingxi_spec::ValidationReport) -> Vec<&str> {
    report
        .issues
        .iter()
        .map(|issue| issue.code.as_str())
        .collect()
}

#[test]
fn workflow_round_trips_through_json_with_camel_case_keys() {
    let mut workflow = Workflow::new("demo");
    let mut input = node("t1", "test.text");
    input.params.insert("text".into(), Value::from("hello"));
    workflow.nodes.push(input);
    workflow.nodes.push(node("add", "test.add"));
    workflow.edges.push(Edge::new("t1", "text", "add", "a"));

    let json = serde_json::to_value(&workflow).expect("serialize");
    assert_eq!(json["schemaVersion"], "1.0");
    assert_eq!(json["nodes"][0]["id"], "t1");
    assert_eq!(json["edges"][0]["sourcePort"], "text");
    assert_eq!(json["edges"][0]["targetPort"], "a");

    let restored: Workflow = serde_json::from_value(json).expect("deserialize");
    assert_eq!(restored, workflow);
}

#[test]
fn unknown_fields_in_a_document_are_ignored() {
    let document = json!({
        "schemaVersion": "1.0",
        "id": "wf-1",
        "name": "imported",
        "nodes": [{ "id": "n1", "kind": "test.text", "position": { "x": 1.0, "y": 2.0 }, "futureField": true }],
        "edges": [],
        "futureTopLevel": { "anything": 1 }
    });
    let workflow: Workflow = serde_json::from_value(document).expect("deserialize");
    assert_eq!(workflow.nodes.len(), 1);
    assert!(workflow.edges.is_empty());
    assert!(workflow.viewport.is_none());
}

#[test]
fn empty_workflow_only_warns() {
    // A blank document is what the editor starts with, so it must stay saveable.
    let report = validate(&Workflow::new("empty"), &catalog());
    assert!(report.ok);
    assert_eq!(report.warnings, 1);
    let issue = report
        .issues
        .iter()
        .find(|issue| issue.code == codes::EMPTY_WORKFLOW)
        .expect("empty workflow warning");
    assert_eq!(issue.severity, Severity::Warning);
}

#[test]
fn cyclic_graphs_are_rejected() {
    let mut workflow = Workflow::new("cycle");
    workflow.nodes.push(node("a", "test.text"));
    workflow.nodes.push(node("b", "test.text"));
    workflow.edges.push(Edge::new("a", "text", "b", "text"));
    // test.text has no inputs, so build the cycle through a node kind with
    // an Any input instead.
    let mut catalog = catalog();
    catalog.insert(
        NodeSpec::new("test.passthrough", "Pass", "Flow")
            .input(PortSpec::new("value", "Value", DataType::Any).required())
            .output(PortSpec::new("value", "Value", DataType::Any)),
    );
    let mut workflow = Workflow::new("cycle");
    workflow.nodes.push(node("a", "test.passthrough"));
    workflow.nodes.push(node("b", "test.passthrough"));
    workflow.edges.push(Edge::new("a", "value", "b", "value"));
    workflow.edges.push(Edge::new("b", "value", "a", "value"));

    let report = validate(&workflow, &catalog);
    assert!(!report.ok);
    assert!(codes_of(&report).contains(&codes::CYCLE));
}

#[test]
fn type_mismatched_edges_are_rejected() {
    let mut workflow = Workflow::new("types");
    workflow.nodes.push(node("t1", "test.text"));
    workflow.nodes.push(node("add", "test.add"));
    workflow.edges.push(Edge::new("t1", "text", "add", "a"));

    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    let issue = report
        .issues
        .iter()
        .find(|issue| issue.code == codes::TYPE_MISMATCH)
        .expect("type mismatch issue");
    assert_eq!(issue.severity, Severity::Error);
    assert!(codes_of(&report).contains(&codes::UNCONNECTED_INPUT));
}

#[test]
fn edges_must_use_declared_ports() {
    let mut workflow = Workflow::new("ports");
    workflow.nodes.push(node("t1", "test.text"));
    workflow.nodes.push(node("add", "test.add"));
    workflow.edges.push(Edge::new("t1", "nope", "add", "a"));
    workflow
        .edges
        .push(Edge::new("t1", "text", "add", "missing"));

    let report = validate(&workflow, &catalog());
    let unknown_port_count = report
        .issues
        .iter()
        .filter(|issue| issue.code == codes::UNKNOWN_PORT)
        .count();
    assert_eq!(unknown_port_count, 2);
}

#[test]
fn one_edge_per_input_slot_is_enforced() {
    let mut workflow = Workflow::new("conflict");
    workflow.nodes.push(node("t1", "test.number"));
    workflow.nodes.push(node("t2", "test.number"));
    workflow.nodes.push(node("add", "test.add"));
    workflow.edges.push(Edge::new("t1", "number", "add", "a"));
    workflow.edges.push(Edge::new("t2", "number", "add", "a"));

    let report = validate(&workflow, &catalog());
    assert!(codes_of(&report).contains(&codes::INPUT_CONFLICT));
}

#[test]
fn self_loops_and_dangling_edges_are_reported() {
    let mut workflow = Workflow::new("broken");
    workflow.nodes.push(node("t1", "test.text"));
    workflow.edges.push(Edge::new("t1", "text", "t1", "text"));
    workflow
        .edges
        .push(Edge::new("ghost", "text", "t1", "text"));

    let report = validate(&workflow, &catalog());
    let codes = codes_of(&report);
    assert!(codes.contains(&codes::SELF_LOOP));
    assert!(codes.contains(&codes::DANGLING_SOURCE));
}

#[test]
fn select_parameters_reject_values_outside_the_option_list() {
    let mut workflow = Workflow::new("params");
    let mut mode = node("mode", "test.mode");
    mode.params.insert("mode".into(), Value::from("turbo"));
    workflow.nodes.push(mode);

    let report = validate(&workflow, &catalog());
    assert!(codes_of(&report).contains(&codes::PARAM_INVALID_OPTION));

    workflow.nodes[0]
        .params
        .insert("mode".into(), Value::from("safe"));
    let report = validate(&workflow, &catalog());
    assert!(report.ok, "unexpected issues: {:?}", report.issues);
}

#[test]
fn unknown_parameters_are_warnings_not_errors() {
    let mut workflow = Workflow::new("params");
    let mut text = node("t1", "test.text");
    text.params.insert("obsolete".into(), Value::from(1));
    workflow.nodes.push(text);

    let report = validate(&workflow, &catalog());
    assert!(report.ok);
    assert_eq!(report.warnings, 1);
}

#[test]
fn duplicate_node_ids_are_rejected() {
    let mut workflow = Workflow::new("dupes");
    workflow.nodes.push(node("same", "test.text"));
    workflow.nodes.push(node("same", "test.text"));

    let report = validate(&workflow, &catalog());
    assert!(codes_of(&report).contains(&codes::DUPLICATE_NODE_ID));
}
