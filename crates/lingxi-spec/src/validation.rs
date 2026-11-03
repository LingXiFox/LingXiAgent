//! Structural validation of a workflow document. Validation is pure: it never
//! executes nodes and it never mutates the document.

use crate::model::{EdgeKind, Workflow, SCHEMA_VERSION};
use crate::node::{ControlKind, NodeSpec, ParamKind, ParamSpec};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};

/// Stable machine-readable issue codes. The frontend may map them to localized
/// copy; the wire contract is the code, never the message text.
pub mod codes {
    pub const UNSUPPORTED_SCHEMA: &str = "schema.unsupported_version";
    pub const EMPTY_WORKFLOW: &str = "workflow.empty";
    pub const DUPLICATE_NODE_ID: &str = "node.duplicate_id";
    pub const EMPTY_NODE_ID: &str = "node.empty_id";
    pub const UNKNOWN_KIND: &str = "node.unknown_kind";
    pub const INVALID_POSITION: &str = "node.invalid_position";
    pub const PARAM_MISSING: &str = "param.missing";
    pub const PARAM_TYPE_MISMATCH: &str = "param.type_mismatch";
    pub const PARAM_INVALID_OPTION: &str = "param.invalid_option";
    pub const PARAM_UNKNOWN: &str = "param.unknown";
    pub const DUPLICATE_EDGE_ID: &str = "edge.duplicate_id";
    pub const SELF_LOOP: &str = "edge.self_loop";
    pub const DANGLING_SOURCE: &str = "edge.dangling_source";
    pub const DANGLING_TARGET: &str = "edge.dangling_target";
    pub const UNKNOWN_PORT: &str = "edge.unknown_port";
    pub const TYPE_MISMATCH: &str = "edge.type_mismatch";
    pub const INPUT_CONFLICT: &str = "edge.input_conflict";
    pub const DUPLICATE_EDGE: &str = "edge.duplicate";
    pub const UNCONNECTED_INPUT: &str = "port.unconnected";
    pub const CYCLE: &str = "graph.cycle";
    pub const CONTROL_REQUIRED: &str = "edge.control_required";
    pub const LOOP_MULTIPLE_GATES: &str = "loop.multiple_gates";
    pub const LOOP_UNCONTROLLED_CYCLE: &str = "loop.uncontrolled_cycle";
    pub const LOOP_NO_EXIT_PATH: &str = "loop.no_exit_path";
    pub const LOOP_MISSING_TRIGGER: &str = "loop.missing_trigger";
    pub const LOOP_INVALID_BUDGET: &str = "loop.invalid_budget";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidationIssue {
    pub code: String,
    pub severity: Severity,
    pub path: String,
    pub message: String,
}

impl ValidationIssue {
    pub fn error(code: &str, path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            severity: Severity::Error,
            path: path.into(),
            message: message.into(),
        }
    }

    pub fn warning(code: &str, path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            severity: Severity::Warning,
            path: path.into(),
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidationReport {
    pub ok: bool,
    pub schema_version: String,
    pub node_count: usize,
    pub edge_count: usize,
    pub errors: usize,
    pub warnings: usize,
    pub issues: Vec<ValidationIssue>,
}

impl ValidationReport {
    pub fn new(workflow: &Workflow, issues: Vec<ValidationIssue>) -> Self {
        let errors = issues
            .iter()
            .filter(|issue| issue.severity == Severity::Error)
            .count();
        let warnings = issues.len() - errors;
        Self {
            ok: errors == 0,
            schema_version: workflow.schema_version.clone(),
            node_count: workflow.nodes.len(),
            edge_count: workflow.edges.len(),
            errors,
            warnings,
            issues,
        }
    }
}

/// Implemented by the runtime registry and by test catalogs.
pub trait NodeKindResolver {
    fn node_spec(&self, kind: &str) -> Option<&NodeSpec>;
}

pub fn validate(workflow: &Workflow, resolver: &dyn NodeKindResolver) -> ValidationReport {
    let mut issues = Vec::new();

    if workflow.schema_version != SCHEMA_VERSION {
        issues.push(ValidationIssue::error(
            codes::UNSUPPORTED_SCHEMA,
            "schemaVersion",
            format!(
                "unsupported schema version {:?}, expected {:?}",
                workflow.schema_version, SCHEMA_VERSION
            ),
        ));
    }

    if workflow.nodes.is_empty() {
        issues.push(ValidationIssue::warning(
            codes::EMPTY_WORKFLOW,
            "nodes",
            "workflow has no nodes",
        ));
    }

    let mut seen_ids: HashSet<&str> = HashSet::new();
    for (index, node) in workflow.nodes.iter().enumerate() {
        let path = format!("nodes[{index}]");
        if node.id.trim().is_empty() {
            issues.push(ValidationIssue::error(
                codes::EMPTY_NODE_ID,
                format!("{path}.id"),
                "node id must not be empty",
            ));
        } else if !seen_ids.insert(node.id.as_str()) {
            issues.push(ValidationIssue::error(
                codes::DUPLICATE_NODE_ID,
                format!("{path}.id"),
                format!("duplicate node id {:?}", node.id),
            ));
        }

        if !node.position.x.is_finite() || !node.position.y.is_finite() {
            issues.push(ValidationIssue::error(
                codes::INVALID_POSITION,
                format!("{path}.position"),
                "node position must be finite",
            ));
        }

        match resolver.node_spec(&node.kind) {
            None => issues.push(ValidationIssue::error(
                codes::UNKNOWN_KIND,
                format!("{path}.kind"),
                format!("unknown node kind {:?}", node.kind),
            )),
            Some(spec) => {
                validate_params(node, spec, &path, &mut issues);
                if spec.control == ControlKind::LoopGate {
                    validate_gate_budget(node, index, &mut issues);
                }
            }
        }
    }

    validate_edges(workflow, resolver, &mut issues);
    validate_control_flow(workflow, resolver, &mut issues);

    ValidationReport::new(workflow, issues)
}

fn validate_params(
    node: &crate::model::WorkflowNode,
    spec: &NodeSpec,
    path: &str,
    issues: &mut Vec<ValidationIssue>,
) {
    for key in node.params.keys() {
        if spec.param_spec(key).is_none() {
            issues.push(ValidationIssue::warning(
                codes::PARAM_UNKNOWN,
                format!("{path}.params.{key}"),
                format!(
                    "parameter {key:?} is not declared by node kind {:?}",
                    spec.kind
                ),
            ));
        }
    }

    for param in &spec.params {
        let value = node
            .params
            .get(&param.name)
            .or(param.default_value.as_ref());
        match value {
            None => {
                if param.required {
                    issues.push(ValidationIssue::error(
                        codes::PARAM_MISSING,
                        format!("{path}.params.{}", param.name),
                        format!("required parameter {:?} is missing", param.name),
                    ));
                }
            }
            Some(value) => check_param_value(param, value, path, issues),
        }
    }
}

fn check_param_value(
    param: &ParamSpec,
    value: &Value,
    path: &str,
    issues: &mut Vec<ValidationIssue>,
) {
    let issue_path = format!("{path}.params.{}", param.name);
    let type_ok = match param.kind {
        ParamKind::Text | ParamKind::TextArea | ParamKind::Select => value.is_string(),
        ParamKind::Number => value.is_number(),
        ParamKind::Boolean => value.is_boolean(),
    };
    if !type_ok {
        issues.push(ValidationIssue::error(
            codes::PARAM_TYPE_MISMATCH,
            issue_path,
            format!(
                "parameter {:?} expects kind {:?}, got {}",
                param.name,
                param.kind,
                json_type_name(value)
            ),
        ));
        return;
    }

    if param.kind == ParamKind::Select {
        if let Some(raw) = value.as_str() {
            if !param.options.iter().any(|option| option.value == raw) {
                issues.push(ValidationIssue::error(
                    codes::PARAM_INVALID_OPTION,
                    format!("{path}.params.{}", param.name),
                    format!(
                        "parameter {:?} does not accept option {:?}",
                        param.name, raw
                    ),
                ));
            }
        }
    }
}

fn json_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn validate_edges(
    workflow: &Workflow,
    resolver: &dyn NodeKindResolver,
    issues: &mut Vec<ValidationIssue>,
) {
    let mut edge_ids: HashSet<&str> = HashSet::new();
    let mut input_slots: HashMap<(&str, &str), usize> = HashMap::new();
    let mut edge_keys: HashSet<(&str, &str, &str, &str)> = HashSet::new();

    for (index, edge) in workflow.edges.iter().enumerate() {
        let path = format!("edges[{index}]");
        if !edge_ids.insert(edge.id.as_str()) {
            issues.push(ValidationIssue::error(
                codes::DUPLICATE_EDGE_ID,
                format!("{path}.id"),
                format!("duplicate edge id {:?}", edge.id),
            ));
        }

        if edge.source == edge.target {
            issues.push(ValidationIssue::error(
                codes::SELF_LOOP,
                path.clone(),
                "an edge may not connect a node to itself",
            ));
        }

        let source_node = workflow.node(&edge.source);
        let target_node = workflow.node(&edge.target);
        if source_node.is_none() {
            issues.push(ValidationIssue::error(
                codes::DANGLING_SOURCE,
                format!("{path}.source"),
                format!("edge source {:?} does not exist", edge.source),
            ));
        }
        if target_node.is_none() {
            issues.push(ValidationIssue::error(
                codes::DANGLING_TARGET,
                format!("{path}.target"),
                format!("edge target {:?} does not exist", edge.target),
            ));
        }

        let slot_key = (edge.target.as_str(), edge.target_port.as_str());
        *input_slots.entry(slot_key).or_insert(0) += 1;
        let edge_key = (
            edge.source.as_str(),
            edge.source_port.as_str(),
            edge.target.as_str(),
            edge.target_port.as_str(),
        );
        if !edge_keys.insert(edge_key) {
            issues.push(ValidationIssue::error(
                codes::DUPLICATE_EDGE,
                path.clone(),
                "duplicate connection between the same ports",
            ));
        }

        let (Some(source_node), Some(target_node)) = (source_node, target_node) else {
            continue;
        };
        let source_spec = resolver.node_spec(&source_node.kind);
        let target_spec = resolver.node_spec(&target_node.kind);

        if let Some(spec) = source_spec {
            if spec.output_port(&edge.source_port).is_none() {
                issues.push(ValidationIssue::error(
                    codes::UNKNOWN_PORT,
                    format!("{path}.sourcePort"),
                    format!(
                        "node kind {:?} has no output port {:?}",
                        spec.kind, edge.source_port
                    ),
                ));
            }
        }
        if let Some(spec) = target_spec {
            if spec.input_port(&edge.target_port).is_none() {
                issues.push(ValidationIssue::error(
                    codes::UNKNOWN_PORT,
                    format!("{path}.targetPort"),
                    format!(
                        "node kind {:?} has no input port {:?}",
                        spec.kind, edge.target_port
                    ),
                ));
            }
        }

        if let (Some(source_spec), Some(target_spec)) = (source_spec, target_spec) {
            if let (Some(output), Some(input)) = (
                source_spec.output_port(&edge.source_port),
                target_spec.input_port(&edge.target_port),
            ) {
                if !input.data_type.accepts(output.data_type) {
                    issues.push(ValidationIssue::error(
                        codes::TYPE_MISMATCH,
                        path.clone(),
                        format!(
                            "port {:?} expects {}, but {:?} emits {}",
                            edge.target_port, input.data_type, edge.source_port, output.data_type
                        ),
                    ));
                }
                if (output.control || input.control) && edge.kind != EdgeKind::Control {
                    issues.push(ValidationIssue::error(
                        codes::CONTROL_REQUIRED,
                        format!("{path}.kind"),
                        format!(
                            "connection {:?} -> {:?} uses a control port and must be a control edge",
                            edge.source_port, edge.target_port
                        ),
                    ));
                }
            }
        }
    }

    for ((target, port), count) in input_slots {
        if count > 1 {
            issues.push(ValidationIssue::error(
                codes::INPUT_CONFLICT,
                format!("nodes[?].inputs.{port}"),
                format!("input port {port:?} of node {target:?} accepts a single connection"),
            ));
        }
    }

    for (index, node) in workflow.nodes.iter().enumerate() {
        let Some(spec) = resolver.node_spec(&node.kind) else {
            continue;
        };
        for port in &spec.inputs {
            if !port.required {
                continue;
            }
            let connected = workflow
                .edges
                .iter()
                .any(|edge| edge.target == node.id && edge.target_port == port.name);
            if !connected {
                issues.push(ValidationIssue::error(
                    codes::UNCONNECTED_INPUT,
                    format!("nodes[{index}].inputs.{}", port.name),
                    format!("required input port {:?} is not connected", port.name),
                ));
            }
        }
    }
}

fn validate_control_flow(
    workflow: &Workflow,
    resolver: &dyn NodeKindResolver,
    issues: &mut Vec<ValidationIssue>,
) {
    let count = workflow.nodes.len();
    let mut index: HashMap<&str, usize> = HashMap::with_capacity(count);
    for (position, node) in workflow.nodes.iter().enumerate() {
        index.entry(node.id.as_str()).or_insert(position);
    }

    let mut adjacency: Vec<Vec<usize>> = vec![Vec::new(); count];
    for edge in &workflow.edges {
        if let (Some(&source), Some(&target)) = (
            index.get(edge.source.as_str()),
            index.get(edge.target.as_str()),
        ) {
            adjacency[source].push(target);
        }
    }

    let components = strongly_connected_components(&adjacency);
    let mut component_of = vec![usize::MAX; count];
    for (component_id, component) in components.iter().enumerate() {
        for &node in component {
            component_of[node] = component_id;
        }
    }

    for (component_id, component) in components.iter().enumerate() {
        let cyclic = component.len() > 1
            || component
                .first()
                .is_some_and(|&node| adjacency[node].contains(&node));
        if !cyclic {
            continue;
        }

        let gates: Vec<usize> = component
            .iter()
            .copied()
            .filter(|&node| {
                resolver
                    .node_spec(&workflow.nodes[node].kind)
                    .is_some_and(|spec| spec.control == ControlKind::LoopGate)
            })
            .collect();

        if gates.is_empty() {
            let names: BTreeSet<&str> = component
                .iter()
                .map(|&node| workflow.nodes[node].id.as_str())
                .collect();
            issues.push(ValidationIssue::error(
                codes::CYCLE,
                "edges",
                format!(
                    "graph contains an uncontrolled cycle involving nodes: {}",
                    names.into_iter().collect::<Vec<_>>().join(", ")
                ),
            ));
            continue;
        }
        if gates.len() > 1 {
            let names: BTreeSet<&str> = gates
                .iter()
                .map(|&node| workflow.nodes[node].id.as_str())
                .collect();
            issues.push(ValidationIssue::error(
                codes::LOOP_MULTIPLE_GATES,
                "edges",
                format!(
                    "cycle contains more than one loop gate: {}",
                    names.into_iter().collect::<Vec<_>>().join(", ")
                ),
            ));
            continue;
        }

        let gate = gates[0];
        let gate_node = &workflow.nodes[gate];
        if has_cycle_without(component, gate, &adjacency) {
            issues.push(ValidationIssue::error(
                codes::LOOP_UNCONTROLLED_CYCLE,
                format!("nodes[{gate}].kind"),
                format!(
                    "cycle still contains a feedback path after removing loop gate {:?}",
                    gate_node.id
                ),
            ));
        }

        let has_exit = workflow.outgoing(&gate_node.id).any(|edge| {
            edge.source_port == "exit"
                && index
                    .get(edge.target.as_str())
                    .is_some_and(|&target| component_of[target] != component_id)
        });
        if !has_exit {
            issues.push(ValidationIssue::error(
                codes::LOOP_NO_EXIT_PATH,
                format!("nodes[{gate}].outputs.exit"),
                format!(
                    "loop gate {:?} has no exit edge leaving the cycle",
                    gate_node.id
                ),
            ));
        }

        let has_start = workflow
            .incoming(&gate_node.id)
            .any(|edge| edge.target_port == "start");
        let has_next = workflow
            .incoming(&gate_node.id)
            .any(|edge| edge.target_port == "next");
        if !has_start || !has_next {
            let missing = match (has_start, has_next) {
                (false, false) => "start and next",
                (false, true) => "start",
                (true, false) => "next",
                (true, true) => unreachable!(),
            };
            issues.push(ValidationIssue::error(
                codes::LOOP_MISSING_TRIGGER,
                format!("nodes[{gate}].inputs"),
                format!(
                    "loop gate {:?} is missing the {missing} trigger",
                    gate_node.id
                ),
            ));
        }
    }
}

fn validate_gate_budget(
    node: &crate::model::WorkflowNode,
    index: usize,
    issues: &mut Vec<ValidationIssue>,
) {
    for (name, maximum) in [
        ("maxIterations", 1_000_000u64),
        ("timeoutMs", 86_400_000u64),
    ] {
        // NodeSpec defaults prefill the editor, but a serialized loop must carry
        // an explicit budget. A missing parameter is not silently replaced.
        let value = node.params.get(name);
        let valid = value
            .and_then(positive_integer)
            .is_some_and(|value| value <= maximum);
        if !valid {
            issues.push(ValidationIssue::error(
                codes::LOOP_INVALID_BUDGET,
                format!("nodes[{index}].params.{name}"),
                format!(
                    "loop gate parameter {name:?} must be set to an integer between 1 and {maximum}"
                ),
            ));
        }
    }
}

fn positive_integer(value: &Value) -> Option<u64> {
    if let Some(value) = value.as_u64() {
        return (value > 0).then_some(value);
    }
    let value = value.as_f64()?;
    if value >= 1.0 && value.fract() == 0.0 {
        Some(value as u64)
    } else {
        None
    }
}

fn has_cycle_without(component: &[usize], gate: usize, adjacency: &[Vec<usize>]) -> bool {
    let members: HashSet<usize> = component
        .iter()
        .copied()
        .filter(|&node| node != gate)
        .collect();
    let mut indegree = vec![0usize; adjacency.len()];
    for &source in &members {
        for &target in &adjacency[source] {
            if members.contains(&target) {
                indegree[target] += 1;
            }
        }
    }
    let mut queue: VecDeque<usize> = members
        .iter()
        .copied()
        .filter(|&node| indegree[node] == 0)
        .collect();
    let mut visited = 0usize;
    while let Some(node) = queue.pop_front() {
        visited += 1;
        for &target in &adjacency[node] {
            if !members.contains(&target) {
                continue;
            }
            indegree[target] -= 1;
            if indegree[target] == 0 {
                queue.push_back(target);
            }
        }
    }
    visited < members.len()
}

/// Iterative Kosaraju. Iterative on purpose: validation must not overflow the
/// stack on large imported workflows.
fn strongly_connected_components(adjacency: &[Vec<usize>]) -> Vec<Vec<usize>> {
    let count = adjacency.len();
    let mut visited = vec![false; count];
    let mut order = Vec::with_capacity(count);

    for start in 0..count {
        if visited[start] {
            continue;
        }
        visited[start] = true;
        let mut stack = vec![(start, 0usize)];
        while let Some((node, next)) = stack.last_mut() {
            if *next < adjacency[*node].len() {
                let target = adjacency[*node][*next];
                *next += 1;
                if !visited[target] {
                    visited[target] = true;
                    stack.push((target, 0));
                }
            } else {
                order.push(*node);
                stack.pop();
            }
        }
    }

    let mut reverse = vec![Vec::new(); count];
    for (source, targets) in adjacency.iter().enumerate() {
        for &target in targets {
            reverse[target].push(source);
        }
    }

    let mut assigned = vec![false; count];
    let mut components = Vec::new();
    for &start in order.iter().rev() {
        if assigned[start] {
            continue;
        }
        assigned[start] = true;
        let mut component = Vec::new();
        let mut stack = vec![start];
        while let Some(node) = stack.pop() {
            component.push(node);
            for &source in &reverse[node] {
                if !assigned[source] {
                    assigned[source] = true;
                    stack.push(source);
                }
            }
        }
        component.sort_unstable();
        components.push(component);
    }
    components
}
