//! Sequential topological execution with explicit capability gating.
//!
//! The engine is deliberately small for Phase 0: one run is one task, nodes run
//! one at a time in dependency order, and every observable step is an event.
//! Concurrency, persistence and the full permission layer slot in behind the
//! same traits later.

use std::cmp::Reverse;
use std::collections::{BTreeMap, BinaryHeap, HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;

use lingxi_spec::{validate, Severity, Workflow, COMPOSITE_NODE_KIND};
use serde::Serialize;

use crate::context::NodeContext;
use crate::control::RunControl;
use crate::error::{error_codes, NodeError};
use crate::event::{EventEmitter, EventSink, LogLevel, RunCause, RunEvent, RunStatus};
use crate::interaction::InteractionBroker;
use crate::registry::NodeRegistry;
use crate::services::{RunServices, ServiceConfig};

/// What a node asks before it may touch a resource. Phase 0 ships an allow-all
/// policy, but every executor still goes through this gate so the permission
/// layer cannot be bypassed by adding a node.
#[derive(Debug, Clone, Copy)]
pub struct CapabilityRequest<'a> {
    pub run_id: &'a str,
    pub node_id: &'a str,
    pub kind: &'a str,
    pub capability: &'a str,
}

pub trait CapabilityPolicy: Send + Sync {
    fn authorize(&self, request: &CapabilityRequest<'_>) -> Result<(), NodeError>;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct AllowAllPolicy;

impl CapabilityPolicy for AllowAllPolicy {
    fn authorize(&self, _request: &CapabilityRequest<'_>) -> Result<(), NodeError> {
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunSummary {
    pub run_id: String,
    pub status: RunStatus,
    pub failed_nodes: Vec<String>,
    pub skipped_nodes: Vec<String>,
    pub duration_ms: u64,
}

pub struct Engine {
    pub(crate) registry: Arc<NodeRegistry>,
    pub(crate) policy: Arc<dyn CapabilityPolicy>,
    pub(crate) interactions: Arc<dyn InteractionBroker>,
    pub(crate) services: ServiceConfig,
}

impl Engine {
    pub fn new(
        registry: Arc<NodeRegistry>,
        policy: Arc<dyn CapabilityPolicy>,
        interactions: Arc<dyn InteractionBroker>,
    ) -> Self {
        Self {
            registry,
            policy,
            interactions,
            services: ServiceConfig {
                permissions: Arc::new(crate::permissions::PermissionManager::new()),
                credentials: Arc::new(crate::credentials::BuiltinCredentials),
                skills_root: None,
                assets: Arc::new(crate::assets::AssetStore::new(
                    std::env::temp_dir().join("lingxi-assets"),
                )),
            },
        }
    }

    /// Replaces the host-level services (credentials and skills) while keeping
    /// the registry, capability policy and interaction broker.
    pub fn with_services(
        registry: Arc<NodeRegistry>,
        policy: Arc<dyn CapabilityPolicy>,
        interactions: Arc<dyn InteractionBroker>,
        services: ServiceConfig,
    ) -> Self {
        Self {
            registry,
            policy,
            interactions,
            services,
        }
    }

    pub fn registry(&self) -> &Arc<NodeRegistry> {
        &self.registry
    }

    /// Structural validation using the registry as the source of node specs.
    pub fn validate(&self, workflow: &Workflow) -> lingxi_spec::ValidationReport {
        validate(workflow, self.registry.as_ref())
    }

    pub async fn execute(
        &self,
        workflow: &Workflow,
        run_id: &str,
        control: Arc<RunControl>,
        sink: &dyn EventSink,
    ) -> RunSummary {
        let started = Instant::now();
        let emitter = EventEmitter::new(sink);
        let services = Arc::new(RunServices::new(&self.services));

        emitter.emit(RunEvent::RunStarted {
            run_id: run_id.to_string(),
            seq: 0,
            workflow_id: workflow.id.clone(),
            workflow_name: workflow.name.clone(),
            node_count: workflow.nodes.len(),
        });

        let report = validate(workflow, self.registry.as_ref());
        if !report.ok {
            let detail = report
                .issues
                .iter()
                .filter(|issue| issue.severity == Severity::Error)
                .map(|issue| format!("{}: {}", issue.path, issue.message))
                .collect::<Vec<_>>()
                .join("; ");
            emitter.log(
                run_id,
                LogLevel::Error,
                None,
                format!("workflow rejected before execution: {detail}"),
            );
            let duration_ms = elapsed_ms(started);
            emitter.emit(RunEvent::RunFinished {
                run_id: run_id.to_string(),
                seq: 0,
                status: RunStatus::Failed,
                cause: Some(RunCause::ValidationFailed),
                detail: Some(detail),
                duration_ms,
            });
            return RunSummary {
                run_id: run_id.to_string(),
                status: RunStatus::Failed,
                failed_nodes: Vec::new(),
                skipped_nodes: Vec::new(),
                duration_ms,
            };
        }

        if requires_control_flow(workflow, self.registry.as_ref()) {
            return crate::control_flow::execute(
                self, workflow, run_id, control, &emitter, started, &services,
            )
            .await;
        }

        let order = match execution_order(workflow) {
            Some(order) => order,
            None => {
                let detail = "workflow graph contains a cycle".to_string();
                emitter.log(run_id, LogLevel::Error, None, detail.clone());
                let duration_ms = elapsed_ms(started);
                emitter.emit(RunEvent::RunFinished {
                    run_id: run_id.to_string(),
                    seq: 0,
                    status: RunStatus::Failed,
                    cause: Some(RunCause::EngineError),
                    detail: Some(detail),
                    duration_ms,
                });
                return RunSummary {
                    run_id: run_id.to_string(),
                    status: RunStatus::Failed,
                    failed_nodes: Vec::new(),
                    skipped_nodes: Vec::new(),
                    duration_ms,
                };
            }
        };

        emitter.log(
            run_id,
            LogLevel::Info,
            None,
            format!(
                "run started: {} node(s), {} edge(s)",
                workflow.nodes.len(),
                workflow.edges.len()
            ),
        );

        let mut outputs: HashMap<String, BTreeMap<String, serde_json::Value>> = HashMap::new();
        let mut failed: Vec<String> = Vec::new();
        let mut skipped: Vec<String> = Vec::new();
        let mut unavailable: HashSet<String> = HashSet::new();
        let mut cancelled = false;

        for index in order {
            let node = &workflow.nodes[index];
            if control.is_cancelled() {
                cancelled = true;
                break;
            }

            let Some(spec) = self.registry.spec(&node.kind) else {
                let label = node.display_name(None);
                emitter.emit(RunEvent::NodeFailed {
                    run_id: run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    code: "node.unknown_kind".to_string(),
                    message: format!("node kind {:?} is not registered", node.kind),
                    duration_ms: 0,
                    activation: 1,
                    iteration: None,
                });
                failed.push(node.id.clone());
                unavailable.insert(node.id.clone());
                continue;
            };

            let label = node.display_name(Some(spec));

            if !node.enabled {
                emitter.emit(RunEvent::NodeSkipped {
                    run_id: run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    reason: "node is disabled".to_string(),
                    activation: 0,
                    iteration: None,
                });
                skipped.push(node.id.clone());
                unavailable.insert(node.id.clone());
                continue;
            }

            let blocked_by = workflow
                .incoming(&node.id)
                .map(|edge| edge.source.clone())
                .find(|source| unavailable.contains(source));
            if let Some(source) = blocked_by {
                emitter.emit(RunEvent::NodeSkipped {
                    run_id: run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    reason: format!("upstream node {source} produced no output"),
                    activation: 0,
                    iteration: None,
                });
                skipped.push(node.id.clone());
                unavailable.insert(node.id.clone());
                continue;
            }

            emitter.emit(RunEvent::NodeStarted {
                run_id: run_id.to_string(),
                seq: 0,
                scope: Vec::new(),
                node_id: node.id.clone(),
                kind: node.kind.clone(),
                label: label.clone(),
                activation: 1,
                iteration: None,
            });

            let mut inputs: BTreeMap<String, serde_json::Value> = BTreeMap::new();
            let mut missing_input: Option<String> = None;
            for edge in workflow.incoming(&node.id) {
                match outputs
                    .get(&edge.source)
                    .and_then(|produced| produced.get(&edge.source_port))
                {
                    Some(value) => {
                        inputs.insert(edge.target_port.clone(), value.clone());
                    }
                    None => {
                        missing_input = Some(format!(
                            "no value on port {:?} of node {:?}",
                            edge.source_port, edge.source
                        ));
                        break;
                    }
                }
            }

            if let Some(message) = missing_input {
                emitter.emit(RunEvent::NodeFailed {
                    run_id: run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    code: error_codes::MISSING_INPUT.to_string(),
                    message,
                    duration_ms: 0,
                    activation: 1,
                    iteration: None,
                });
                failed.push(node.id.clone());
                unavailable.insert(node.id.clone());
                continue;
            }

            let mut denied = None;
            for capability in &spec.capabilities {
                let request = CapabilityRequest {
                    run_id,
                    node_id: &node.id,
                    kind: &node.kind,
                    capability,
                };
                if let Err(error) = self.policy.authorize(&request) {
                    denied = Some(error);
                    break;
                }
            }
            if let Some(error) = denied {
                emitter.emit(RunEvent::NodeFailed {
                    run_id: run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    code: error.code,
                    message: error.message,
                    duration_ms: 0,
                    activation: 1,
                    iteration: None,
                });
                failed.push(node.id.clone());
                unavailable.insert(node.id.clone());
                continue;
            }

            let Some(executor) = self.registry.executor(&node.kind) else {
                emitter.emit(RunEvent::NodeFailed {
                    run_id: run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    code: error_codes::EXECUTOR_FAILED.to_string(),
                    message: format!("node kind {:?} has no executor", node.kind),
                    duration_ms: 0,
                    activation: 1,
                    iteration: None,
                });
                failed.push(node.id.clone());
                unavailable.insert(node.id.clone());
                continue;
            };

            let context = NodeContext::new(
                run_id,
                node,
                spec,
                &inputs,
                &workflow.assets,
                control.as_ref(),
                self.interactions.as_ref(),
                services.as_ref(),
                &emitter,
                "",
            );
            let node_started = Instant::now();
            let outcome = tokio::select! {
                biased;
                _ = control.cancelled() => None,
                result = executor.execute(&context) => Some(result),
            };

            match outcome {
                None => {
                    emitter.emit(RunEvent::NodeCancelled {
                        run_id: run_id.to_string(),
                        seq: 0,
                        scope: Vec::new(),
                        node_id: node.id.clone(),
                        kind: node.kind.clone(),
                        label,
                        activation: 1,
                        iteration: None,
                    });
                    unavailable.insert(node.id.clone());
                    cancelled = true;
                    break;
                }
                Some(Ok(output)) => {
                    let duration_ms = elapsed_ms(node_started);
                    emitter.emit(RunEvent::NodeFinished {
                        run_id: run_id.to_string(),
                        seq: 0,
                        scope: Vec::new(),
                        node_id: node.id.clone(),
                        kind: node.kind.clone(),
                        label,
                        outputs: output.outputs.clone(),
                        duration_ms,
                        activation: 1,
                        iteration: None,
                    });
                    outputs.insert(node.id.clone(), output.outputs);
                }
                Some(Err(error)) => {
                    let duration_ms = elapsed_ms(node_started);
                    emitter.emit(RunEvent::NodeFailed {
                        run_id: run_id.to_string(),
                        seq: 0,
                        scope: Vec::new(),
                        node_id: node.id.clone(),
                        kind: node.kind.clone(),
                        label,
                        code: error.code,
                        message: error.message,
                        duration_ms,
                        activation: 1,
                        iteration: None,
                    });
                    failed.push(node.id.clone());
                    unavailable.insert(node.id.clone());
                }
            }
        }

        let status = if cancelled || control.is_cancelled() {
            RunStatus::Cancelled
        } else if failed.is_empty() {
            RunStatus::Completed
        } else {
            RunStatus::Failed
        };
        let cause = match status {
            RunStatus::Completed => None,
            RunStatus::Failed => Some(RunCause::NodeFailed),
            RunStatus::Cancelled => Some(RunCause::Cancelled),
            RunStatus::Interrupted => Some(RunCause::Interrupted),
        };
        let detail = match status {
            RunStatus::Completed => None,
            RunStatus::Failed => Some(format!("failed nodes: {}", failed.join(", "))),
            RunStatus::Cancelled => Some("run cancelled by user".to_string()),
            RunStatus::Interrupted => Some("run interrupted".to_string()),
        };
        let duration_ms = elapsed_ms(started);

        let summary = RunSummary {
            run_id: run_id.to_string(),
            status,
            failed_nodes: failed,
            skipped_nodes: skipped,
            duration_ms,
        };

        emitter.log(
            run_id,
            match status {
                RunStatus::Completed => LogLevel::Info,
                RunStatus::Failed => LogLevel::Error,
                RunStatus::Cancelled | RunStatus::Interrupted => LogLevel::Warn,
            },
            None,
            format!("run finished: {:?} in {} ms", status, duration_ms),
        );
        emitter.emit(RunEvent::RunFinished {
            run_id: run_id.to_string(),
            seq: 0,
            status,
            cause,
            detail,
            duration_ms,
        });

        summary
    }
}

pub(crate) fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis() as u64
}

fn requires_control_flow(workflow: &Workflow, registry: &NodeRegistry) -> bool {
    workflow
        .edges
        .iter()
        .any(|edge| edge.kind == lingxi_spec::EdgeKind::Control)
        || workflow.nodes.iter().any(|node| {
            node.kind == COMPOSITE_NODE_KIND
                || registry
                    .spec(&node.kind)
                    .is_some_and(|spec| spec.control != lingxi_spec::ControlKind::Normal)
        })
}

/// Kahn's algorithm with a stable tie-break on document order. Returns None
/// when the graph contains a cycle (validation reports it first).
fn execution_order(workflow: &Workflow) -> Option<Vec<usize>> {
    let count = workflow.nodes.len();
    let mut index: HashMap<&str, usize> = HashMap::with_capacity(count);
    for (position, node) in workflow.nodes.iter().enumerate() {
        index.entry(node.id.as_str()).or_insert(position);
    }

    let mut indegree = vec![0usize; count];
    let mut adjacency: Vec<Vec<usize>> = vec![Vec::new(); count];
    for edge in &workflow.edges {
        if edge.source == edge.target {
            return None;
        }
        let source = *index.get(edge.source.as_str())?;
        let target = *index.get(edge.target.as_str())?;
        adjacency[source].push(target);
        indegree[target] += 1;
    }

    let mut ready: BinaryHeap<Reverse<usize>> = (0..count)
        .filter(|&i| indegree[i] == 0)
        .map(Reverse)
        .collect();
    let mut order = Vec::with_capacity(count);
    while let Some(Reverse(node)) = ready.pop() {
        order.push(node);
        for &next in &adjacency[node] {
            indegree[next] -= 1;
            if indegree[next] == 0 {
                ready.push(Reverse(next));
            }
        }
    }

    if order.len() == count {
        Some(order)
    } else {
        None
    }
}
