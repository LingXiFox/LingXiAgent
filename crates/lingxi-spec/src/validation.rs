//! Structural validation of a workflow document. Validation is pure: it never
//! executes nodes and it never mutates the document.

use crate::model::{
    AssetRef, EdgeKind, Subgraph, Workflow, WorkflowNode, COMPOSITE_NODE_KIND,
    SUPPORTED_SCHEMA_VERSIONS,
};
use crate::node::{ControlKind, NodeSpec, ParamKind, ParamSpec};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

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
    pub const SUBGRAPH_DUPLICATE_ID: &str = "subgraph.duplicate_id";
    pub const SUBGRAPH_UNKNOWN_REFERENCE: &str = "subgraph.unknown_reference";
    pub const SUBGRAPH_INVALID_PORT: &str = "subgraph.invalid_port";
    pub const SUBGRAPH_INVALID_BINDING: &str = "subgraph.invalid_binding";
    pub const SUBGRAPH_UNSUPPORTED_VERSION: &str = "subgraph.unsupported_version";
    pub const SUBGRAPH_RECURSIVE_REFERENCE: &str = "subgraph.recursive_reference";
    pub const SUBGRAPH_NESTED_DEFINITIONS: &str = "subgraph.nested_definitions";
    pub const SUBGRAPH_NESTED_LOOP_UNSUPPORTED: &str = "subgraph.nested_loop_unsupported";
    pub const ASSET_UNKNOWN: &str = "asset.unknown";
    pub const ASSET_INVALID: &str = "asset.invalid";
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

/// Validation entry point. `1.0` documents load with empty subgraph maps;
/// `core.composite` nodes derive their ports from the root definitions.
pub fn validate(workflow: &Workflow, resolver: &dyn NodeKindResolver) -> ValidationReport {
    let mut issues = Vec::new();
    let specs = composite_specs(workflow);
    let context = ValidationContext {
        resolver,
        subgraphs: &workflow.subgraphs,
        specs,
        assets: &workflow.assets,
    };

    validate_assets(workflow, &mut issues);
    validate_workflow(workflow, &context, "", &HashSet::new(), &mut issues);
    validate_subgraphs(workflow, &context, &mut issues);
    validate_recursive_references(workflow, &mut issues);

    ValidationReport::new(workflow, issues)
}

struct ValidationContext<'a> {
    resolver: &'a dyn NodeKindResolver,
    subgraphs: &'a BTreeMap<String, Subgraph>,
    /// Keyed by the root map key, which is what `subgraphId` resolves against.
    specs: BTreeMap<String, NodeSpec>,
    /// The root asset table; subgraph workflows resolve ids through it.
    assets: &'a BTreeMap<String, AssetRef>,
}

impl ValidationContext<'_> {
    fn spec(&self, node: &WorkflowNode) -> Option<&NodeSpec> {
        if node.kind == COMPOSITE_NODE_KIND {
            let id = node.subgraph_id.as_deref()?;
            self.specs.get(id)
        } else {
            self.resolver.node_spec(&node.kind)
        }
    }
}

/// Builds the dynamic node specs for every root subgraph definition. The
/// runtime uses the same function so validation and execution cannot drift.
pub fn composite_specs(workflow: &Workflow) -> BTreeMap<String, NodeSpec> {
    workflow
        .subgraphs
        .iter()
        .map(|(key, subgraph)| {
            let mut spec = NodeSpec::new(COMPOSITE_NODE_KIND, &subgraph.name, "Composite");
            spec.description = format!(
                "Composite of {} node(s), defined by subgraph {:?}",
                subgraph.workflow.nodes.len(),
                subgraph.id
            );
            spec.inputs = subgraph
                .inputs
                .iter()
                .map(|input| input.port.clone())
                .collect();
            spec.outputs = subgraph
                .outputs
                .iter()
                .map(|output| output.port.clone())
                .collect();
            (key.clone(), spec)
        })
        .collect()
}

fn join_path(prefix: &str, suffix: &str) -> String {
    if prefix.is_empty() {
        suffix.to_string()
    } else {
        format!("{prefix}.{suffix}")
    }
}

fn validate_workflow(
    workflow: &Workflow,
    context: &ValidationContext<'_>,
    prefix: &str,
    provided: &HashSet<(&str, &str)>,
    issues: &mut Vec<ValidationIssue>,
) {
    if !SUPPORTED_SCHEMA_VERSIONS.contains(&workflow.schema_version.as_str()) {
        issues.push(ValidationIssue::error(
            codes::UNSUPPORTED_SCHEMA,
            join_path(prefix, "schemaVersion"),
            format!(
                "unsupported schema version {:?}, expected one of {:?}",
                workflow.schema_version, SUPPORTED_SCHEMA_VERSIONS
            ),
        ));
    }

    if workflow.nodes.is_empty() {
        issues.push(ValidationIssue::warning(
            codes::EMPTY_WORKFLOW,
            join_path(prefix, "nodes"),
            "workflow has no nodes",
        ));
    }

    let mut seen_ids: HashSet<&str> = HashSet::new();
    for (index, node) in workflow.nodes.iter().enumerate() {
        let path = join_path(prefix, &format!("nodes[{index}]"));
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

        if node.kind == COMPOSITE_NODE_KIND {
            match node.subgraph_id.as_deref() {
                Some(id) if context.subgraphs.contains_key(id) => {}
                Some(id) => issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_UNKNOWN_REFERENCE,
                    format!("{path}.subgraphId"),
                    format!("composite node references unknown subgraph {id:?}"),
                )),
                None => issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_UNKNOWN_REFERENCE,
                    format!("{path}.subgraphId"),
                    "composite node must set subgraphId",
                )),
            }
            continue;
        }

        match context.spec(node) {
            None => issues.push(ValidationIssue::error(
                codes::UNKNOWN_KIND,
                format!("{path}.kind"),
                format!("unknown node kind {:?}", node.kind),
            )),
            Some(spec) => {
                validate_params(node, spec, context.assets, &path, issues);
                if spec.control == ControlKind::LoopGate {
                    validate_gate_budget(node, index, &path, issues);
                }
            }
        }
    }

    validate_edges(workflow, context, prefix, provided, issues);
    validate_control_flow(workflow, context, prefix, provided, issues);
}

fn validate_subgraphs(
    root: &Workflow,
    context: &ValidationContext<'_>,
    issues: &mut Vec<ValidationIssue>,
) {
    let mut seen_ids: HashMap<&str, &str> = HashMap::new();
    for (key, subgraph) in &root.subgraphs {
        let base = format!("subgraphs.{key}");
        if subgraph.id.trim().is_empty() || subgraph.id != *key {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_DUPLICATE_ID,
                format!("{base}.id"),
                format!(
                    "subgraph map key {key:?} must equal a non-empty definition id, got {:?}",
                    subgraph.id
                ),
            ));
        }
        if let Some(previous) = seen_ids.insert(subgraph.id.as_str(), key.as_str()) {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_DUPLICATE_ID,
                format!("{base}.id"),
                format!(
                    "subgraph id {:?} is already defined by map key {previous:?}",
                    subgraph.id
                ),
            ));
        }
        if subgraph.version != crate::model::SUBGRAPH_VERSION {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_UNSUPPORTED_VERSION,
                format!("{base}.version"),
                format!(
                    "unsupported subgraph version {}, expected {}",
                    subgraph.version,
                    crate::model::SUBGRAPH_VERSION
                ),
            ));
        }
        if !subgraph.workflow.subgraphs.is_empty() {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_NESTED_DEFINITIONS,
                format!("{base}.workflow.subgraphs"),
                "subgraph definitions must live on the root workflow",
            ));
        }

        let provided: HashSet<(&str, &str)> = subgraph
            .inputs
            .iter()
            .flat_map(|input| input.targets.iter())
            .map(|binding| (binding.node_id.as_str(), binding.port.as_str()))
            .collect();
        validate_workflow(
            &subgraph.workflow,
            context,
            &format!("{base}.workflow"),
            &provided,
            issues,
        );
        validate_subgraph_ports(subgraph, &base, issues);
        validate_subgraph_bindings(subgraph, context, &base, issues);
    }
}

fn validate_subgraph_ports(subgraph: &Subgraph, base: &str, issues: &mut Vec<ValidationIssue>) {
    let mut input_names: HashSet<&str> = HashSet::new();
    for (index, input) in subgraph.inputs.iter().enumerate() {
        let path = format!("{base}.inputs[{index}].port");
        if input.port.name.trim().is_empty() {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_PORT,
                format!("{path}.name"),
                "subgraph input port name must not be empty",
            ));
        } else if !input_names.insert(input.port.name.as_str()) {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_PORT,
                format!("{path}.name"),
                format!("duplicate subgraph input port {:?}", input.port.name),
            ));
        }
        if input.port.required && input.targets.is_empty() {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_BINDING,
                format!("{base}.inputs[{index}].targets"),
                format!(
                    "required subgraph input {:?} has no internal target",
                    input.port.name
                ),
            ));
        }
    }

    let mut output_names: HashSet<&str> = HashSet::new();
    for (index, output) in subgraph.outputs.iter().enumerate() {
        let path = format!("{base}.outputs[{index}].port");
        if output.port.name.trim().is_empty() {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_PORT,
                format!("{path}.name"),
                "subgraph output port name must not be empty",
            ));
        } else if !output_names.insert(output.port.name.as_str()) {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_PORT,
                format!("{path}.name"),
                format!("duplicate subgraph output port {:?}", output.port.name),
            ));
        }
    }
}

fn validate_subgraph_bindings(
    subgraph: &Subgraph,
    context: &ValidationContext<'_>,
    base: &str,
    issues: &mut Vec<ValidationIssue>,
) {
    let mut targets: HashSet<(&str, &str)> = HashSet::new();
    for (index, input) in subgraph.inputs.iter().enumerate() {
        for (target_index, binding) in input.targets.iter().enumerate() {
            let path = format!("{base}.inputs[{index}].targets[{target_index}]");
            let Some(node) = subgraph.workflow.node(&binding.node_id) else {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_BINDING,
                    format!("{path}.nodeId"),
                    format!(
                        "subgraph input {:?} targets missing internal node {:?}",
                        input.port.name, binding.node_id
                    ),
                ));
                continue;
            };
            let Some(spec) = context.spec(node) else {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_BINDING,
                    format!("{path}.nodeId"),
                    format!(
                        "subgraph input {:?} targets node {:?} with no resolvable spec",
                        input.port.name, binding.node_id
                    ),
                ));
                continue;
            };
            let Some(port) = spec.input_port(&binding.port) else {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_BINDING,
                    format!("{path}.port"),
                    format!(
                        "internal node {:?} has no input port {:?}",
                        binding.node_id, binding.port
                    ),
                ));
                continue;
            };
            if port.control != input.port.control {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_PORT,
                    format!("{path}.port"),
                    format!(
                        "subgraph input {:?} control={} does not match internal port control={}",
                        input.port.name, input.port.control, port.control
                    ),
                ));
            }
            if !port.data_type.accepts(input.port.data_type) {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_PORT,
                    format!("{path}.port"),
                    format!(
                        "internal port {:?} expects {}, but subgraph input {:?} provides {}",
                        binding.port, port.data_type, input.port.name, input.port.data_type
                    ),
                ));
            }
            if subgraph
                .workflow
                .edges
                .iter()
                .any(|edge| edge.target == binding.node_id && edge.target_port == binding.port)
            {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_BINDING,
                    path.clone(),
                    format!(
                        "internal input {:?}.{:?} already has an internal edge; external input cannot also drive it",
                        binding.node_id, binding.port
                    ),
                ));
            }
            if !targets.insert((binding.node_id.as_str(), binding.port.as_str())) {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_INVALID_BINDING,
                    path,
                    format!(
                        "internal input {:?}.{:?} is bound more than once",
                        binding.node_id, binding.port
                    ),
                ));
            }
        }
    }

    for (index, output) in subgraph.outputs.iter().enumerate() {
        let path = format!("{base}.outputs[{index}].source");
        let Some(node) = subgraph.workflow.node(&output.source.node_id) else {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_BINDING,
                format!("{path}.nodeId"),
                format!(
                    "subgraph output {:?} sources missing internal node {:?}",
                    output.port.name, output.source.node_id
                ),
            ));
            continue;
        };
        let Some(spec) = context.spec(node) else {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_BINDING,
                format!("{path}.nodeId"),
                format!(
                    "subgraph output {:?} sources node {:?} with no resolvable spec",
                    output.port.name, output.source.node_id
                ),
            ));
            continue;
        };
        let Some(port) = spec.output_port(&output.source.port) else {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_BINDING,
                format!("{path}.port"),
                format!(
                    "internal node {:?} has no output port {:?}",
                    output.source.node_id, output.source.port
                ),
            ));
            continue;
        };
        if port.control != output.port.control {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_PORT,
                format!("{path}.port"),
                format!(
                    "subgraph output {:?} control={} does not match internal port control={}",
                    output.port.name, output.port.control, port.control
                ),
            ));
        }
        if !output.port.data_type.accepts(port.data_type) {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_INVALID_PORT,
                format!("{path}.port"),
                format!(
                    "subgraph output {:?} expects {}, but internal port {:?} emits {}",
                    output.port.name, output.port.data_type, output.source.port, port.data_type
                ),
            ));
        }
    }
}

fn validate_recursive_references(root: &Workflow, issues: &mut Vec<ValidationIssue>) {
    let mut reported: HashSet<String> = HashSet::new();
    for key in root.subgraphs.keys() {
        let mut path = vec![key.clone()];
        walk_recursive_references(root, key, &mut path, &mut reported, issues);
    }
}

fn walk_recursive_references(
    root: &Workflow,
    key: &str,
    path: &mut Vec<String>,
    reported: &mut HashSet<String>,
    issues: &mut Vec<ValidationIssue>,
) {
    let Some(subgraph) = root.subgraphs.get(key) else {
        return;
    };
    for (index, node) in subgraph.workflow.nodes.iter().enumerate() {
        if node.kind != COMPOSITE_NODE_KIND {
            continue;
        }
        let Some(reference) = node.subgraph_id.as_deref() else {
            continue;
        };
        if path.iter().any(|existing| existing == reference) {
            let marker = format!("{key}->{reference}");
            if reported.insert(marker) {
                issues.push(ValidationIssue::error(
                    codes::SUBGRAPH_RECURSIVE_REFERENCE,
                    format!("subgraphs.{key}.workflow.nodes[{index}].subgraphId"),
                    format!("subgraph {key:?} recursively references {reference:?}"),
                ));
            }
            continue;
        }
        if root.subgraphs.contains_key(reference) {
            path.push(reference.to_string());
            walk_recursive_references(root, reference, path, reported, issues);
            path.pop();
        }
    }
}

fn subgraph_has_loop_gate(
    context: &ValidationContext<'_>,
    id: &str,
    visiting: &mut HashSet<String>,
) -> bool {
    let Some(subgraph) = context.subgraphs.get(id) else {
        return false;
    };
    if !visiting.insert(id.to_string()) {
        return false;
    }
    let mut found = false;
    for node in &subgraph.workflow.nodes {
        if node.kind == COMPOSITE_NODE_KIND {
            if let Some(nested) = node.subgraph_id.as_deref() {
                if subgraph_has_loop_gate(context, nested, visiting) {
                    found = true;
                    break;
                }
            }
        } else if context
            .spec(node)
            .is_some_and(|spec| spec.control == ControlKind::LoopGate)
        {
            found = true;
            break;
        }
    }
    visiting.remove(id);
    found
}

fn validate_params(
    node: &crate::model::WorkflowNode,
    spec: &NodeSpec,
    assets: &BTreeMap<String, AssetRef>,
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
            Some(value) => check_param_value(param, value, assets, path, issues),
        }
    }
}

fn check_param_value(
    param: &ParamSpec,
    value: &Value,
    assets: &BTreeMap<String, AssetRef>,
    path: &str,
    issues: &mut Vec<ValidationIssue>,
) {
    let issue_path = format!("{path}.params.{}", param.name);
    if param.kind == ParamKind::Asset {
        validate_asset_param(param, value, assets, &issue_path, issues);
        return;
    }
    let type_ok = match param.kind {
        ParamKind::Text | ParamKind::TextArea | ParamKind::Select => value.is_string(),
        ParamKind::Number => value.is_number(),
        ParamKind::Boolean => value.is_boolean(),
        ParamKind::Asset => true,
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

/// Asset params hold an ordered list of asset ids. The binary itself lives in
/// the asset store, so only the reference is validated here.
fn validate_asset_param(
    param: &ParamSpec,
    value: &Value,
    assets: &BTreeMap<String, AssetRef>,
    issue_path: &str,
    issues: &mut Vec<ValidationIssue>,
) {
    let Some(items) = value.as_array() else {
        issues.push(ValidationIssue::error(
            codes::PARAM_TYPE_MISMATCH,
            issue_path,
            format!("parameter {:?} expects an array of asset ids", param.name),
        ));
        return;
    };
    for (index, item) in items.iter().enumerate() {
        let Some(id) = item.as_str() else {
            issues.push(ValidationIssue::error(
                codes::PARAM_TYPE_MISMATCH,
                format!("{issue_path}[{index}]"),
                format!("parameter {:?} expects asset id strings", param.name),
            ));
            continue;
        };
        if !assets.contains_key(id) {
            issues.push(ValidationIssue::error(
                codes::ASSET_UNKNOWN,
                format!("{issue_path}[{index}]"),
                format!("parameter {:?} references unknown asset {id:?}", param.name),
            ));
        }
    }
}

fn validate_assets(workflow: &Workflow, issues: &mut Vec<ValidationIssue>) {
    for (key, asset) in &workflow.assets {
        let path = format!("assets.{key}");
        if asset.id != *key {
            issues.push(ValidationIssue::error(
                codes::ASSET_INVALID,
                format!("{path}.id"),
                format!("asset map key {key:?} must equal its id {:?}", asset.id),
            ));
        }
        if let Err(message) = asset.validate() {
            issues.push(ValidationIssue::error(codes::ASSET_INVALID, path, message));
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
    context: &ValidationContext<'_>,
    prefix: &str,
    provided: &HashSet<(&str, &str)>,
    issues: &mut Vec<ValidationIssue>,
) {
    let mut edge_ids: HashSet<&str> = HashSet::new();
    let mut input_slots: HashMap<(&str, &str), usize> = HashMap::new();
    let mut edge_keys: HashSet<(&str, &str, &str, &str)> = HashSet::new();

    for (index, edge) in workflow.edges.iter().enumerate() {
        let path = join_path(prefix, &format!("edges[{index}]"));
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
        let source_spec = context.spec(source_node);
        let target_spec = context.spec(target_node);

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
                join_path(prefix, &format!("nodes[?].inputs.{port}")),
                format!("input port {port:?} of node {target:?} accepts a single connection"),
            ));
        }
    }

    for (index, node) in workflow.nodes.iter().enumerate() {
        let Some(spec) = context.spec(node) else {
            continue;
        };
        for port in &spec.inputs {
            if !port.required {
                continue;
            }
            let connected = provided.contains(&(node.id.as_str(), port.name.as_str()))
                || workflow
                    .edges
                    .iter()
                    .any(|edge| edge.target == node.id && edge.target_port == port.name);
            if !connected {
                issues.push(ValidationIssue::error(
                    codes::UNCONNECTED_INPUT,
                    join_path(prefix, &format!("nodes[{index}].inputs.{}", port.name)),
                    format!("required input port {:?} is not connected", port.name),
                ));
            }
        }
    }
}

fn validate_control_flow(
    workflow: &Workflow,
    context: &ValidationContext<'_>,
    prefix: &str,
    provided: &HashSet<(&str, &str)>,
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

        let nested_loops: Vec<&str> = component
            .iter()
            .filter_map(|&node| {
                let candidate = &workflow.nodes[node];
                if candidate.kind != COMPOSITE_NODE_KIND {
                    return None;
                }
                let id = candidate.subgraph_id.as_deref()?;
                subgraph_has_loop_gate(context, id, &mut HashSet::new())
                    .then_some(candidate.id.as_str())
            })
            .collect();
        if !nested_loops.is_empty() {
            issues.push(ValidationIssue::error(
                codes::SUBGRAPH_NESTED_LOOP_UNSUPPORTED,
                join_path(prefix, "edges"),
                format!(
                    "cycle contains composite node(s) whose definitions contain a loop gate: {}",
                    nested_loops.join(", ")
                ),
            ));
        }

        let gates: Vec<usize> = component
            .iter()
            .copied()
            .filter(|&node| {
                context
                    .spec(&workflow.nodes[node])
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
                join_path(prefix, "edges"),
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
                join_path(prefix, "edges"),
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
                join_path(prefix, &format!("nodes[{gate}].kind")),
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
                join_path(prefix, &format!("nodes[{gate}].outputs.exit")),
                format!(
                    "loop gate {:?} has no exit edge leaving the cycle",
                    gate_node.id
                ),
            ));
        }

        let has_start = provided.contains(&(gate_node.id.as_str(), "start"))
            || workflow
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
                join_path(prefix, &format!("nodes[{gate}].inputs")),
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
    prefix: &str,
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
                join_path(prefix, &format!("nodes[{index}].params.{name}")),
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
