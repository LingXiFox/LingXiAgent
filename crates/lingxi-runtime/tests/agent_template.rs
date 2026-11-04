use std::collections::BTreeMap;

use lingxi_runtime::agent_template::{standard_agent, AGENT_SUBGRAPH_ID};
use lingxi_runtime::NodeRegistry;
use lingxi_spec::{validate, Position, Workflow, WorkflowNode, COMPOSITE_NODE_KIND};

#[test]
fn the_standard_agent_template_is_statically_valid() {
    let mut root = Workflow::new("agent");
    let mut node = WorkflowNode::new("agent", COMPOSITE_NODE_KIND, Position::default());
    node.subgraph_id = Some(AGENT_SUBGRAPH_ID.to_string());
    root.nodes.push(node);
    let mut subgraphs = BTreeMap::new();
    subgraphs.insert(AGENT_SUBGRAPH_ID.to_string(), standard_agent());
    root.subgraphs = subgraphs;

    let registry = NodeRegistry::builtin();
    let report = validate(&root, &registry);
    assert!(
        report.ok,
        "standard agent template failed validation: {:?}",
        report.issues
    );
    assert_eq!(report.node_count, 1);
}
