//! Token/activation scheduler for workflows that contain control edges or
//! control nodes. The acyclic Kahn path in `engine.rs` stays untouched so
//! ordinary Phase 0 workflows keep their exact behavior.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use lingxi_spec::{
    composite_specs, ControlKind, EdgeKind, NodeSpec, Subgraph, Workflow, COMPOSITE_NODE_KIND,
};
use serde_json::Value;

use crate::context::NodeContext;
use crate::control::RunControl;
use crate::engine::{elapsed_ms, CapabilityRequest, Engine, RunSummary};
use crate::error::{error_codes, NodeError};
use crate::event::{EventEmitter, LogLevel, RunCause, RunEvent, RunStatus, ScopeFrame};
use crate::registry::NodeOutput;
use crate::services::RunServices;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ready {
    Wait,
    Go,
    Blocked,
}

#[derive(Debug, Clone, Copy)]
struct LoopState {
    gate: usize,
    iteration: u32,
    deadline: Instant,
}

struct Scheduler<'a> {
    engine: &'a Engine,
    workflow: &'a Workflow,
    run_id: &'a str,
    control: &'a RunControl,
    services: &'a RunServices,
    emitter: EventEmitter<'a>,
    subgraphs: &'a BTreeMap<String, Subgraph>,
    composite_specs: Arc<BTreeMap<String, NodeSpec>>,
    parent_deadline: Option<Instant>,
    scope: String,
    seeds: BTreeMap<(String, String), Value>,
    index: HashMap<String, usize>,
    incoming: Vec<Vec<usize>>,
    outgoing: Vec<Vec<usize>>,
    tokens: HashMap<String, Value>,
    // Data edges are latched. This tracks edges whose value changed since the
    // last activation of their target, so data-only nodes can re-evaluate on
    // new upstream output without re-running on every scheduler pass.
    fresh_data: HashSet<String>,
    inactive: HashSet<String>,
    queue: VecDeque<usize>,
    queued: HashSet<usize>,
    settled: HashSet<usize>,
    fired_sources: HashSet<usize>,
    activations: Vec<u64>,
    latest_outputs: HashMap<String, BTreeMap<String, Value>>,
    failed: Vec<String>,
    skipped: Vec<String>,
    first_failure: Option<NodeError>,
    cancelled: bool,
    timed_out: bool,
    loop_state: Option<LoopState>,
    current_iteration: Option<u32>,
}

pub(crate) async fn execute(
    engine: &Engine,
    workflow: &Workflow,
    run_id: &str,
    control: Arc<RunControl>,
    emitter: &EventEmitter<'_>,
    started: Instant,
    services: &RunServices,
) -> RunSummary {
    emitter.log(
        run_id,
        LogLevel::Info,
        None,
        format!(
            "run started: {} node(s), {} edge(s), control flow",
            workflow.nodes.len(),
            workflow.edges.len()
        ),
    );

    let composite_specs = Arc::new(composite_specs(workflow));
    let mut scheduler = Scheduler::new(
        engine,
        workflow,
        run_id,
        control.as_ref(),
        services,
        emitter.fork(),
        &workflow.subgraphs,
        composite_specs,
        None,
        String::new(),
    );
    scheduler.prepare();
    scheduler.run().await;
    scheduler.finish(started)
}

impl<'a> Scheduler<'a> {
    #[allow(clippy::too_many_arguments)]
    fn new(
        engine: &'a Engine,
        workflow: &'a Workflow,
        run_id: &'a str,
        control: &'a RunControl,
        services: &'a RunServices,
        emitter: EventEmitter<'a>,
        subgraphs: &'a BTreeMap<String, Subgraph>,
        composite_specs: Arc<BTreeMap<String, NodeSpec>>,
        parent_deadline: Option<Instant>,
        scope: String,
    ) -> Self {
        let mut index = HashMap::with_capacity(workflow.nodes.len());
        for (position, node) in workflow.nodes.iter().enumerate() {
            index.entry(node.id.clone()).or_insert(position);
        }
        let mut incoming = vec![Vec::new(); workflow.nodes.len()];
        let mut outgoing = vec![Vec::new(); workflow.nodes.len()];
        for (edge_index, edge) in workflow.edges.iter().enumerate() {
            if let Some(&source) = index.get(&edge.source) {
                outgoing[source].push(edge_index);
            }
            if let Some(&target) = index.get(&edge.target) {
                incoming[target].push(edge_index);
            }
        }
        Self {
            engine,
            workflow,
            run_id,
            control,
            services,
            emitter,
            subgraphs,
            composite_specs,
            parent_deadline,
            scope,
            seeds: BTreeMap::new(),
            index,
            incoming,
            outgoing,
            tokens: HashMap::new(),
            fresh_data: HashSet::new(),
            inactive: HashSet::new(),
            queue: VecDeque::new(),
            queued: HashSet::new(),
            settled: HashSet::new(),
            fired_sources: HashSet::new(),
            activations: vec![0; workflow.nodes.len()],
            latest_outputs: HashMap::new(),
            failed: Vec::new(),
            skipped: Vec::new(),
            first_failure: None,
            cancelled: false,
            timed_out: false,
            loop_state: None,
            current_iteration: None,
        }
    }

    fn prepare(&mut self) {
        for index in 0..self.workflow.nodes.len() {
            if !self.workflow.nodes[index].enabled {
                self.skip_node(index, "node is disabled");
            }
        }
    }

    async fn run(&mut self) {
        loop {
            if self.control.is_cancelled() {
                self.cancelled = true;
                break;
            }
            if self.loop_expired() {
                if self.loop_state.is_some() {
                    self.fail_loop_timeout();
                } else {
                    self.timed_out = true;
                }
                break;
            }

            self.enqueue_ready();
            let Some(index) = self.queue.pop_front() else {
                break;
            };
            self.queued.remove(&index);
            if self.settled.contains(&index) {
                continue;
            }
            match self.evaluate(index) {
                Ready::Blocked => {
                    self.skip_node(index, "no active input path");
                    continue;
                }
                Ready::Wait => continue,
                Ready::Go => {}
            }

            let inputs = self.consume_inputs(index);
            let role = self.role(index);
            let keep_going = if role == ControlKind::LoopGate {
                self.handle_gate(index, inputs)
            } else if self.is_composite(index) {
                self.run_composite(index, inputs).await
            } else {
                self.run_node(index, inputs).await
            };
            if !keep_going {
                break;
            }
        }

        self.settle_unreached();
    }

    fn finish(&mut self, started: Instant) -> RunSummary {
        let status = if self.cancelled {
            RunStatus::Cancelled
        } else if self.failed.is_empty() {
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
            RunStatus::Failed => Some(format!("failed nodes: {}", self.failed.join(", "))),
            RunStatus::Cancelled => Some("run cancelled by user".to_string()),
            RunStatus::Interrupted => Some("run interrupted".to_string()),
        };
        let duration_ms = elapsed_ms(started);
        self.emitter.log(
            self.run_id,
            match status {
                RunStatus::Completed => LogLevel::Info,
                RunStatus::Failed => LogLevel::Error,
                RunStatus::Cancelled | RunStatus::Interrupted => LogLevel::Warn,
            },
            None,
            format!("run finished: {:?} in {} ms", status, duration_ms),
        );
        self.emitter.emit(RunEvent::RunFinished {
            run_id: self.run_id.to_string(),
            seq: 0,
            status,
            cause,
            detail,
            duration_ms,
        });
        RunSummary {
            run_id: self.run_id.to_string(),
            status,
            failed_nodes: self.failed.clone(),
            skipped_nodes: self.skipped.clone(),
            duration_ms,
        }
    }

    fn role(&self, index: usize) -> ControlKind {
        self.spec(index)
            .map(|spec| spec.control)
            .unwrap_or(ControlKind::Normal)
    }

    fn spec(&self, index: usize) -> Option<&NodeSpec> {
        let node = &self.workflow.nodes[index];
        if node.kind == COMPOSITE_NODE_KIND {
            node.subgraph_id
                .as_deref()
                .and_then(|id| self.composite_specs.get(id))
        } else {
            self.engine.registry.spec(&node.kind)
        }
    }

    fn is_composite(&self, index: usize) -> bool {
        self.workflow.nodes[index].kind == COMPOSITE_NODE_KIND
    }

    fn deadline(&self) -> Option<Instant> {
        match (
            self.loop_state.map(|state| state.deadline),
            self.parent_deadline,
        ) {
            (Some(inner), Some(outer)) => Some(inner.min(outer)),
            (Some(inner), None) => Some(inner),
            (None, outer) => outer,
        }
    }

    fn label(&self, index: usize) -> String {
        self.workflow.nodes[index].display_name(self.spec(index))
    }

    fn iteration(&self) -> Option<u32> {
        self.current_iteration
    }

    fn enqueue_ready(&mut self) {
        for index in 0..self.workflow.nodes.len() {
            if self.settled.contains(&index) || self.queued.contains(&index) {
                continue;
            }
            match self.evaluate(index) {
                Ready::Go => {
                    self.queued.insert(index);
                    self.queue.push_back(index);
                }
                // A node that already ran at least once is dormant, not
                // unreachable: a loop gate can still reopen one of its inputs
                // in a later iteration. Skipping it here would deactivate the
                // output edges it just produced.
                Ready::Blocked if self.activations[index] == 0 => {
                    self.skip_node(index, "no active input path")
                }
                Ready::Blocked => {}
                Ready::Wait => {}
            }
        }
    }

    fn evaluate(&self, index: usize) -> Ready {
        let incoming = &self.incoming[index];
        let node_id = &self.workflow.nodes[index].id;
        let activation = self.activations[index];
        let seeded_any = self.seeds.keys().any(|(target, _)| target == node_id);
        if incoming.is_empty() {
            // A node without internal edges and without a subgraph seed is a
            // constant source. A seeded node is also ready on its first
            // activation even when the subgraph binds the port without an
            // internal edge.
            return if activation == 0 && !self.fired_sources.contains(&index) {
                Ready::Go
            } else {
                Ready::Wait
            };
        }

        let spec = self.spec(index);
        let seeded_control = self.seeds.keys().any(|(target, port)| {
            target == node_id
                && spec
                    .and_then(|spec| spec.input_port(port))
                    .is_some_and(|port| port.control)
        });
        let mut has_control = seeded_control;
        let mut control_token = seeded_control;
        let mut any_data = false;
        let mut any_fresh = false;
        let mut data_pending = false;
        let mut required_data_inactive = false;
        let mut any_active_path = false;

        for &edge_index in incoming {
            let edge = &self.workflow.edges[edge_index];
            let inactive = self.inactive.contains(&edge.id);
            // A subgraph input binding feeds an internal port without an
            // internal edge. Treat that seed exactly like a delivered value.
            let seeded = self
                .seeds
                .keys()
                .any(|(target, port)| target == node_id && port == &edge.target_port);
            let token = self.tokens.contains_key(&edge.id) || seeded;
            any_active_path |= !inactive;
            if edge.kind == EdgeKind::Control {
                has_control = true;
                control_token |= token;
            } else {
                any_data |= token;
                any_fresh |= self.fresh_data.contains(&edge.id) || seeded;
                data_pending |= !token && !inactive;
                let required = spec
                    .and_then(|spec| spec.input_port(&edge.target_port))
                    .is_some_and(|port| port.required);
                required_data_inactive |= required && inactive;
            }
        }

        if required_data_inactive {
            return if activation == 0 {
                Ready::Blocked
            } else {
                Ready::Wait
            };
        }
        if has_control {
            // Control edges are one-shot triggers. Data edges are latched, so
            // an already-run node waits for its next control activation instead
            // of re-running because a value is still present.
            if control_token {
                Ready::Go
            } else if activation > 0 {
                Ready::Wait
            } else if !any_active_path {
                Ready::Blocked
            } else {
                Ready::Wait
            }
        } else if activation == 0 {
            if (any_data || seeded_any) && !data_pending {
                Ready::Go
            } else if !any_active_path {
                Ready::Blocked
            } else {
                Ready::Wait
            }
        } else if any_fresh && !data_pending {
            // A fresh upstream value makes a data-only node re-evaluate, e.g.
            // a condition fed by a counter inside a loop.
            Ready::Go
        } else if !any_active_path {
            Ready::Blocked
        } else {
            Ready::Wait
        }
    }

    fn consume_inputs(&mut self, index: usize) -> BTreeMap<String, Value> {
        let mut inputs = BTreeMap::new();
        for edge_index in self.incoming[index].clone() {
            let edge = &self.workflow.edges[edge_index];
            let value = self.tokens.get(&edge.id).cloned().or_else(|| {
                self.seeds
                    .get(&(edge.target.clone(), edge.target_port.clone()))
                    .cloned()
            });
            if let Some(value) = value {
                inputs.insert(edge.target_port.clone(), value);
            }
            if edge.kind == EdgeKind::Control {
                // A control token is an event: consuming it keeps the edge
                // armed for the next activation. Data values stay latched for
                // every activation that reads them.
                self.tokens.remove(&edge.id);
            } else {
                self.fresh_data.remove(&edge.id);
            }
        }
        let node_id = self.workflow.nodes[index].id.clone();
        let spec = self.spec(index);
        let seed_keys: Vec<_> = self
            .seeds
            .keys()
            .filter(|(target, _)| target == &node_id)
            .cloned()
            .collect();
        let control_ports: Vec<String> = spec
            .map(|spec| {
                spec.inputs
                    .iter()
                    .filter(|port| port.control)
                    .map(|port| port.name.clone())
                    .collect()
            })
            .unwrap_or_default();
        for key in seed_keys {
            let control = control_ports.iter().any(|port| port == &key.1);
            if control {
                if let Some(value) = self.seeds.remove(&key) {
                    inputs.insert(key.1, value);
                }
            } else if let Some(value) = self.seeds.get(&key) {
                inputs.insert(key.1.clone(), value.clone());
            }
        }
        inputs
    }

    fn propagate_outputs(&mut self, index: usize, outputs: &BTreeMap<String, Value>) {
        // A loop gate emits different ports on different activations. An absent
        // output means "not yet", not "inactive": the exit edge must stay
        // pending until the gate finally emits it, otherwise the node behind
        // the exit would be skipped during the first iteration.
        let defer_absent = self.role(index) == ControlKind::LoopGate;
        for edge_index in self.outgoing[index].clone() {
            let edge = &self.workflow.edges[edge_index];
            if let Some(value) = outputs.get(&edge.source_port) {
                self.inactive.remove(&edge.id);
                self.tokens.insert(edge.id.clone(), value.clone());
                if edge.kind == EdgeKind::Data {
                    self.fresh_data.insert(edge.id.clone());
                }
            } else if defer_absent {
                continue;
            } else if edge.kind == EdgeKind::Data {
                // A missing data output clears the previous latch; it must not
                // deactivate the branch because the value may appear later.
                self.tokens.remove(&edge.id);
                self.fresh_data.remove(&edge.id);
            } else {
                self.deactivate_edge(edge_index);
            }
        }
    }

    fn deactivate_outgoing(&mut self, index: usize) {
        for edge_index in self.outgoing[index].clone() {
            self.deactivate_edge(edge_index);
        }
    }

    fn deactivate_edge(&mut self, edge_index: usize) {
        let edge = &self.workflow.edges[edge_index];
        let id = edge.id.clone();
        let target = self.index.get(&edge.target).copied();
        if self.inactive.insert(id) {
            if let Some(target) = target {
                if !self.settled.contains(&target)
                    && self.activations[target] == 0
                    && self.evaluate(target) == Ready::Blocked
                {
                    self.skip_node(target, "no active input path");
                }
            }
        }
    }

    fn skip_node(&mut self, index: usize, reason: impl Into<String>) {
        if !self.settled.insert(index) {
            return;
        }
        let node = &self.workflow.nodes[index];
        self.emitter.emit(RunEvent::NodeSkipped {
            run_id: self.run_id.to_string(),
            seq: 0,
            scope: Vec::new(),
            node_id: node.id.clone(),
            kind: node.kind.clone(),
            label: self.label(index),
            reason: reason.into(),
            activation: self.activations[index],
            iteration: self.iteration(),
        });
        let id = node.id.clone();
        if !self.skipped.contains(&id) {
            self.skipped.push(id);
        }
        self.deactivate_outgoing(index);
    }

    async fn run_composite(&mut self, index: usize, inputs: BTreeMap<String, Value>) -> bool {
        let node_id = self.workflow.nodes[index].id.clone();
        let kind = self.workflow.nodes[index].kind.clone();
        self.activations[index] += 1;
        let activation = self.activations[index];
        let iteration = self.iteration();
        if self.incoming[index].is_empty() {
            self.fired_sources.insert(index);
        }

        let Some(spec) = self.spec(index).cloned() else {
            let id = self.workflow.nodes[index]
                .subgraph_id
                .clone()
                .unwrap_or_default();
            self.fail_started(
                index,
                activation,
                iteration,
                NodeError::new(
                    error_codes::SUBGRAPH_UNKNOWN_REFERENCE,
                    format!("composite node references unknown subgraph {id:?}"),
                ),
                0,
            );
            return true;
        };
        let Some(subgraph_id) = self.workflow.nodes[index].subgraph_id.clone() else {
            self.fail_started(
                index,
                activation,
                iteration,
                NodeError::new(
                    error_codes::SUBGRAPH_UNKNOWN_REFERENCE,
                    "composite node has no subgraphId",
                ),
                0,
            );
            return true;
        };
        let Some(subgraph) = self.subgraphs.get(&subgraph_id).cloned() else {
            self.fail_started(
                index,
                activation,
                iteration,
                NodeError::new(
                    error_codes::SUBGRAPH_UNKNOWN_REFERENCE,
                    format!("composite node references unknown subgraph {subgraph_id:?}"),
                ),
                0,
            );
            return true;
        };

        let label = self.workflow.nodes[index].display_name(Some(&spec));
        self.emitter.emit(RunEvent::NodeStarted {
            run_id: self.run_id.to_string(),
            seq: 0,
            scope: Vec::new(),
            node_id: node_id.clone(),
            kind,
            label: label.clone(),
            activation,
            iteration,
        });

        for input in &subgraph.inputs {
            if input.port.required && !inputs.contains_key(&input.port.name) {
                self.fail_started(
                    index,
                    activation,
                    iteration,
                    NodeError::new(
                        error_codes::MISSING_INPUT,
                        format!(
                            "composite input {:?} is required but no value was provided",
                            input.port.name
                        ),
                    ),
                    0,
                );
                return true;
            }
        }

        let mut seeds = BTreeMap::new();
        for input in &subgraph.inputs {
            let Some(value) = inputs.get(&input.port.name) else {
                continue;
            };
            for target in &input.targets {
                seeds.insert((target.node_id.clone(), target.port.clone()), value.clone());
            }
        }

        let frame = ScopeFrame {
            instance_id: node_id.clone(),
            subgraph_id,
            label: label.clone(),
        };
        let scoped = self.emitter.scoped(frame);
        let started = Instant::now();
        let mut inner = Scheduler::new(
            self.engine,
            &subgraph.workflow,
            self.run_id,
            self.control,
            self.services,
            scoped,
            self.subgraphs,
            Arc::clone(&self.composite_specs),
            self.deadline(),
            if self.scope.is_empty() {
                node_id.clone()
            } else {
                format!("{}/{}", self.scope, node_id)
            },
        );
        inner.seeds = seeds;
        inner.prepare();
        Box::pin(inner.run()).await;
        let duration_ms = elapsed_ms(started);

        if inner.cancelled || self.control.is_cancelled() {
            self.emitter.emit(RunEvent::NodeCancelled {
                run_id: self.run_id.to_string(),
                seq: 0,
                scope: Vec::new(),
                node_id,
                kind: self.workflow.nodes[index].kind.clone(),
                label,
                activation,
                iteration,
            });
            self.cancelled = true;
            return false;
        }

        if inner.timed_out || !inner.failed.is_empty() {
            let error = inner.first_failure.clone().unwrap_or_else(|| {
                NodeError::new(
                    error_codes::LOOP_TIMEOUT,
                    "composite execution exceeded its deadline",
                )
            });
            self.fail_started(index, activation, iteration, error, duration_ms);
            return true;
        }

        let mut outputs = BTreeMap::new();
        for output in &subgraph.outputs {
            if let Some(value) = inner
                .latest_outputs
                .get(&output.source.node_id)
                .and_then(|produced| produced.get(&output.source.port))
            {
                outputs.insert(output.port.name.clone(), value.clone());
            }
        }
        self.emitter.emit(RunEvent::NodeFinished {
            run_id: self.run_id.to_string(),
            seq: 0,
            scope: Vec::new(),
            node_id: node_id.clone(),
            kind: self.workflow.nodes[index].kind.clone(),
            label,
            outputs: outputs.clone(),
            duration_ms,
            activation,
            iteration,
        });
        self.latest_outputs.insert(node_id, outputs.clone());
        self.propagate_outputs(index, &outputs);
        true
    }

    async fn run_node(&mut self, index: usize, inputs: BTreeMap<String, Value>) -> bool {
        let node = &self.workflow.nodes[index];
        self.activations[index] += 1;
        let activation = self.activations[index];
        let iteration = self.iteration();
        if self.incoming[index].is_empty() {
            self.fired_sources.insert(index);
        }

        let Some(spec) = self.spec(index) else {
            self.fail_started(
                index,
                activation,
                iteration,
                NodeError::new(
                    "node.unknown_kind",
                    format!("node kind {:?} is not registered", node.kind),
                ),
                0,
            );
            return true;
        };
        let label = self.label(index);
        self.emitter.emit(RunEvent::NodeStarted {
            run_id: self.run_id.to_string(),
            seq: 0,
            scope: Vec::new(),
            node_id: node.id.clone(),
            kind: node.kind.clone(),
            label: label.clone(),
            activation,
            iteration,
        });

        for port in &spec.inputs {
            if port.required && !port.control && !inputs.contains_key(&port.name) {
                let error = NodeError::new(
                    error_codes::MISSING_INPUT,
                    format!("required input {:?} was not provided", port.name),
                );
                self.fail_started(index, activation, iteration, error, 0);
                return true;
            }
        }

        for capability in &spec.capabilities {
            let request = CapabilityRequest {
                run_id: self.run_id,
                node_id: &node.id,
                kind: &node.kind,
                capability,
            };
            if let Err(error) = self.engine.policy.authorize(&request) {
                self.fail_started(index, activation, iteration, error, 0);
                return true;
            }
        }

        let Some(executor) = self.engine.registry.executor(&node.kind) else {
            self.fail_started(
                index,
                activation,
                iteration,
                NodeError::new(
                    error_codes::EXECUTOR_FAILED,
                    format!("node kind {:?} has no executor", node.kind),
                ),
                0,
            );
            return true;
        };

        let context = NodeContext::new(
            self.run_id,
            node,
            spec,
            &inputs,
            &self.workflow.assets,
            self.control,
            self.engine.interactions.as_ref(),
            self.services,
            &self.emitter,
            &self.scope,
        );
        let deadline = self.deadline();
        let node_started = Instant::now();

        enum Outcome {
            Result(Result<NodeOutput, NodeError>),
            Cancelled,
            TimedOut,
        }

        let outcome = if let Some(deadline) = deadline {
            tokio::select! {
                biased;
                _ = self.control.cancelled() => Outcome::Cancelled,
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)) => Outcome::TimedOut,
                result = executor.execute(&context) => Outcome::Result(result),
            }
        } else {
            tokio::select! {
                biased;
                _ = self.control.cancelled() => Outcome::Cancelled,
                result = executor.execute(&context) => Outcome::Result(result),
            }
        };

        match outcome {
            Outcome::Cancelled => {
                self.emitter.emit(RunEvent::NodeCancelled {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    activation,
                    iteration,
                });
                self.cancelled = true;
                false
            }
            Outcome::TimedOut => {
                let error = NodeError::new(
                    error_codes::LOOP_TIMEOUT,
                    format!("loop timeout exceeded while running node {:?}", node.id),
                );
                self.fail_started(
                    index,
                    activation,
                    iteration,
                    error,
                    elapsed_ms(node_started),
                );
                self.loop_state = None;
                false
            }
            Outcome::Result(Ok(output)) => {
                let duration_ms = elapsed_ms(node_started);
                self.emitter.emit(RunEvent::NodeFinished {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label,
                    outputs: output.outputs.clone(),
                    duration_ms,
                    activation,
                    iteration,
                });
                self.latest_outputs
                    .insert(node.id.clone(), output.outputs.clone());
                self.propagate_outputs(index, &output.outputs);
                true
            }
            Outcome::Result(Err(error)) => {
                self.fail_started(
                    index,
                    activation,
                    iteration,
                    error,
                    elapsed_ms(node_started),
                );
                true
            }
        }
    }

    fn fail_started(
        &mut self,
        index: usize,
        activation: u64,
        iteration: Option<u32>,
        error: NodeError,
        duration_ms: u64,
    ) {
        if self.first_failure.is_none() {
            self.first_failure = Some(error.clone());
        }
        let node = &self.workflow.nodes[index];
        self.emitter.emit(RunEvent::NodeFailed {
            run_id: self.run_id.to_string(),
            seq: 0,
            scope: Vec::new(),
            node_id: node.id.clone(),
            kind: node.kind.clone(),
            label: self.label(index),
            code: error.code,
            message: error.message,
            duration_ms,
            activation,
            iteration,
        });
        self.settled.insert(index);
        let id = node.id.clone();
        if !self.failed.contains(&id) {
            self.failed.push(id);
        }
        self.deactivate_outgoing(index);
    }

    fn handle_gate(&mut self, index: usize, inputs: BTreeMap<String, Value>) -> bool {
        let node = &self.workflow.nodes[index];
        self.activations[index] += 1;
        let activation = self.activations[index];
        let Some(_spec) = self.spec(index) else {
            self.fail_started(
                index,
                activation,
                self.iteration(),
                NodeError::new("node.unknown_kind", "loop gate kind is not registered"),
                0,
            );
            return true;
        };
        let (max_iterations, timeout_ms) = match gate_budget(node) {
            Ok(budget) => budget,
            Err(error) => {
                let iteration = self.iteration();
                self.emitter.emit(RunEvent::NodeStarted {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    activation,
                    iteration,
                });
                self.fail_started(index, activation, iteration, error, 0);
                return true;
            }
        };

        let trigger = if inputs.contains_key("stop") {
            "stop"
        } else if inputs.contains_key("start") {
            "start"
        } else if inputs.contains_key("next") {
            "next"
        } else {
            let error = NodeError::new(
                error_codes::LOOP_MISSING_TRIGGER,
                "loop gate activated without a start, next or stop trigger",
            );
            let iteration = self.iteration();
            self.emitter.emit(RunEvent::NodeStarted {
                run_id: self.run_id.to_string(),
                seq: 0,
                scope: Vec::new(),
                node_id: node.id.clone(),
                kind: node.kind.clone(),
                label: self.label(index),
                activation,
                iteration,
            });
            self.fail_started(index, activation, iteration, error, 0);
            return true;
        };
        let payload = inputs
            .get("stop")
            .or_else(|| inputs.get("start"))
            .or_else(|| inputs.get("next"))
            .cloned()
            .unwrap_or(Value::Null);

        match trigger {
            "start" => {
                if self.loop_state.is_some() {
                    let iteration = self.iteration();
                    self.emitter.emit(RunEvent::NodeStarted {
                        run_id: self.run_id.to_string(),
                        seq: 0,
                        scope: Vec::new(),
                        node_id: node.id.clone(),
                        kind: node.kind.clone(),
                        label: self.label(index),
                        activation,
                        iteration,
                    });
                    self.fail_started(
                        index,
                        activation,
                        iteration,
                        NodeError::new(
                            error_codes::LOOP_INVALID_STATE,
                            "loop gate started while another loop is active",
                        ),
                        0,
                    );
                    return true;
                }
                let now = Instant::now();
                let deadline = now + Duration::from_millis(timeout_ms);
                self.loop_state = Some(LoopState {
                    gate: index,
                    iteration: 1,
                    deadline,
                });
                self.current_iteration = Some(1);
                self.emitter.emit(RunEvent::NodeStarted {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    activation,
                    iteration: Some(1),
                });
                let mut outputs = BTreeMap::from([("continue".to_string(), payload.clone())]);
                if let Some(value) = inputs.get("value") {
                    outputs.insert("value".to_string(), value.clone());
                }
                self.emitter.emit(RunEvent::NodeFinished {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    outputs: outputs.clone(),
                    duration_ms: 0,
                    activation,
                    iteration: Some(1),
                });
                self.propagate_outputs(index, &outputs);
                self.emitter.log(
                    self.run_id,
                    LogLevel::Info,
                    Some(node.id.clone()),
                    format!(
                        "loop started: max {max_iterations} iteration(s), timeout {timeout_ms} ms"
                    ),
                );
                true
            }
            "next" => {
                let Some(mut state) = self.loop_state else {
                    let iteration = self.iteration();
                    self.emitter.emit(RunEvent::NodeStarted {
                        run_id: self.run_id.to_string(),
                        seq: 0,
                        scope: Vec::new(),
                        node_id: node.id.clone(),
                        kind: node.kind.clone(),
                        label: self.label(index),
                        activation,
                        iteration,
                    });
                    self.fail_started(
                        index,
                        activation,
                        iteration,
                        NodeError::new(
                            error_codes::LOOP_INVALID_STATE,
                            "loop gate received next before start",
                        ),
                        0,
                    );
                    return true;
                };
                let next = state.iteration + 1;
                if Instant::now() >= state.deadline {
                    self.fail_gate_timeout(index, activation, state.iteration);
                    return false;
                }
                if u64::from(next) > max_iterations {
                    self.emitter.emit(RunEvent::NodeStarted {
                        run_id: self.run_id.to_string(),
                        seq: 0,
                        scope: Vec::new(),
                        node_id: node.id.clone(),
                        kind: node.kind.clone(),
                        label: self.label(index),
                        activation,
                        iteration: Some(state.iteration),
                    });
                    self.fail_started(
                        index,
                        activation,
                        Some(state.iteration),
                        NodeError::new(
                            error_codes::LOOP_BUDGET_EXHAUSTED,
                            format!(
                                "loop budget exhausted after {} of {max_iterations} iteration(s)",
                                state.iteration
                            ),
                        ),
                        0,
                    );
                    self.loop_state = None;
                    return false;
                }
                state.iteration = next;
                self.loop_state = Some(state);
                self.current_iteration = Some(next);
                self.emitter.emit(RunEvent::NodeStarted {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    activation,
                    iteration: Some(next),
                });
                let mut outputs = BTreeMap::from([("continue".to_string(), payload.clone())]);
                if let Some(value) = inputs.get("value") {
                    outputs.insert("value".to_string(), value.clone());
                }
                self.emitter.emit(RunEvent::NodeFinished {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    outputs: outputs.clone(),
                    duration_ms: 0,
                    activation,
                    iteration: Some(next),
                });
                self.propagate_outputs(index, &outputs);
                self.emitter.log(
                    self.run_id,
                    LogLevel::Info,
                    Some(node.id.clone()),
                    format!("loop iteration {next}/{max_iterations}"),
                );
                true
            }
            "stop" => {
                let iteration = self.loop_state.map(|state| state.iteration).unwrap_or(0);
                self.emitter.emit(RunEvent::NodeStarted {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    activation,
                    iteration: Some(iteration),
                });
                let mut outputs = BTreeMap::from([("exit".to_string(), payload.clone())]);
                if let Some(value) = inputs.get("value") {
                    outputs.insert("value".to_string(), value.clone());
                }
                self.emitter.emit(RunEvent::NodeFinished {
                    run_id: self.run_id.to_string(),
                    seq: 0,
                    scope: Vec::new(),
                    node_id: node.id.clone(),
                    kind: node.kind.clone(),
                    label: self.label(index),
                    outputs: outputs.clone(),
                    duration_ms: 0,
                    activation,
                    iteration: Some(iteration),
                });
                self.emitter.log(
                    self.run_id,
                    LogLevel::Info,
                    Some(node.id.clone()),
                    format!("loop exited after {iteration} iteration(s)"),
                );
                self.loop_state = None;
                self.current_iteration = Some(iteration);
                self.propagate_outputs(index, &outputs);
                true
            }
            _ => unreachable!(),
        }
    }

    fn fail_gate_timeout(&mut self, index: usize, activation: u64, iteration: u32) {
        self.emitter.emit(RunEvent::NodeStarted {
            run_id: self.run_id.to_string(),
            seq: 0,
            scope: Vec::new(),
            node_id: self.workflow.nodes[index].id.clone(),
            kind: self.workflow.nodes[index].kind.clone(),
            label: self.label(index),
            activation,
            iteration: Some(iteration),
        });
        self.fail_started(
            index,
            activation,
            Some(iteration),
            NodeError::new(
                error_codes::LOOP_TIMEOUT,
                format!("loop timeout exceeded at iteration {iteration}"),
            ),
            0,
        );
        self.loop_state = None;
        self.current_iteration = Some(iteration);
    }

    fn loop_expired(&self) -> bool {
        self.deadline()
            .is_some_and(|deadline| Instant::now() >= deadline)
    }

    fn fail_loop_timeout(&mut self) {
        if let Some(state) = self.loop_state {
            let activation = self.activations[state.gate] + 1;
            self.activations[state.gate] = activation;
            self.fail_gate_timeout(state.gate, activation, state.iteration);
        }
    }

    fn settle_unreached(&mut self) {
        for index in 0..self.workflow.nodes.len() {
            if self.settled.contains(&index) || self.activations[index] > 0 {
                continue;
            }
            self.skip_node(index, "no activation path in this run");
        }
    }
}

fn gate_budget(node: &lingxi_spec::WorkflowNode) -> Result<(u64, u64), NodeError> {
    let max_iterations = node
        .params
        .get("maxIterations")
        .and_then(positive_integer)
        .ok_or_else(|| {
            NodeError::new(
                error_codes::LOOP_INVALID_BUDGET,
                "loop gate requires an explicit integer maxIterations >= 1",
            )
        })?;
    let timeout_ms = node
        .params
        .get("timeoutMs")
        .and_then(positive_integer)
        .ok_or_else(|| {
            NodeError::new(
                error_codes::LOOP_INVALID_BUDGET,
                "loop gate requires an explicit integer timeoutMs >= 1",
            )
        })?;
    Ok((max_iterations, timeout_ms))
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
