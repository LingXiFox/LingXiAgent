use lingxi_spec::{NodeSpec, WorkflowNode};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::control::RunControl;
use crate::error::{error_codes, NodeError};
use crate::event::{unix_millis, EventSink, LogLevel, RunEvent};
use crate::interaction::{
    InteractionBroker, InteractionDecision, InteractionOption, InteractionRequest,
};

const INTERACTION_TIMEOUT: Duration = Duration::from_secs(300);

/// Everything a node executor may touch. The context is the only bridge to the
/// run: no executor gets direct access to the workflow, the event bus or the UI.
pub struct NodeContext<'a> {
    pub run_id: &'a str,
    pub node: &'a WorkflowNode,
    pub spec: &'a NodeSpec,
    pub inputs: &'a BTreeMap<String, Value>,
    pub control: &'a RunControl,
    pub broker: &'a dyn InteractionBroker,
    pub sink: &'a dyn EventSink,
    seq: &'a AtomicU64,
}

impl<'a> NodeContext<'a> {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        run_id: &'a str,
        node: &'a WorkflowNode,
        spec: &'a NodeSpec,
        inputs: &'a BTreeMap<String, Value>,
        control: &'a RunControl,
        broker: &'a dyn InteractionBroker,
        sink: &'a dyn EventSink,
        seq: &'a AtomicU64,
    ) -> Self {
        Self {
            run_id,
            node,
            spec,
            inputs,
            control,
            broker,
            sink,
            seq,
        }
    }

    /// Resolves a parameter, falling back to the declared default.
    pub fn param(&self, name: &str) -> Option<&Value> {
        self.node.params.get(name).or_else(|| {
            self.spec
                .param_spec(name)
                .and_then(|p| p.default_value.as_ref())
        })
    }

    pub fn string_param(&self, name: &str) -> Result<&str, NodeError> {
        match self.param(name) {
            Some(Value::String(value)) => Ok(value),
            Some(other) => Err(NodeError::new(
                error_codes::INVALID_PARAM,
                format!(
                    "parameter {name:?} expects text, got {}",
                    crate::error::json_type_name(other)
                ),
            )),
            None => Err(NodeError::new(
                error_codes::INVALID_PARAM,
                format!("parameter {name:?} is missing"),
            )),
        }
    }

    pub fn number_param(&self, name: &str) -> Result<f64, NodeError> {
        match self.param(name) {
            Some(Value::Number(number)) => number.as_f64().ok_or_else(|| {
                NodeError::new(
                    error_codes::INVALID_PARAM,
                    format!("parameter {name:?} is not representable as f64"),
                )
            }),
            Some(other) => Err(NodeError::new(
                error_codes::INVALID_PARAM,
                format!(
                    "parameter {name:?} expects a number, got {}",
                    crate::error::json_type_name(other)
                ),
            )),
            None => Err(NodeError::new(
                error_codes::INVALID_PARAM,
                format!("parameter {name:?} is missing"),
            )),
        }
    }

    pub fn bool_param(&self, name: &str) -> Result<bool, NodeError> {
        match self.param(name) {
            Some(Value::Bool(value)) => Ok(*value),
            Some(other) => Err(NodeError::new(
                error_codes::INVALID_PARAM,
                format!(
                    "parameter {name:?} expects a boolean, got {}",
                    crate::error::json_type_name(other)
                ),
            )),
            None => Err(NodeError::new(
                error_codes::INVALID_PARAM,
                format!("parameter {name:?} is missing"),
            )),
        }
    }

    pub fn input(&self, name: &str) -> Option<&Value> {
        self.inputs.get(name)
    }

    pub fn text_input(&self, name: &str) -> Result<String, NodeError> {
        match self.inputs.get(name) {
            Some(Value::String(value)) => Ok(value.clone()),
            Some(other) => Err(NodeError::new(
                error_codes::INVALID_INPUT,
                format!(
                    "input {name:?} expects text, got {}",
                    crate::error::json_type_name(other)
                ),
            )),
            None => Err(NodeError::new(
                error_codes::MISSING_INPUT,
                format!("input {name:?} has no value"),
            )),
        }
    }

    pub fn number_input(&self, name: &str) -> Result<f64, NodeError> {
        match self.inputs.get(name) {
            Some(Value::Number(number)) => number.as_f64().ok_or_else(|| {
                NodeError::new(
                    error_codes::INVALID_INPUT,
                    format!("input {name:?} is not representable as f64"),
                )
            }),
            Some(other) => Err(NodeError::new(
                error_codes::INVALID_INPUT,
                format!(
                    "input {name:?} expects a number, got {}",
                    crate::error::json_type_name(other)
                ),
            )),
            None => Err(NodeError::new(
                error_codes::MISSING_INPUT,
                format!("input {name:?} has no value"),
            )),
        }
    }

    pub fn log(&self, level: LogLevel, message: impl Into<String>) {
        self.sink.emit(RunEvent::Log {
            run_id: self.run_id.to_string(),
            seq: self.seq.fetch_add(1, Ordering::Relaxed),
            at_ms: unix_millis(),
            level,
            node_id: Some(self.node.id.clone()),
            message: message.into(),
        });
    }

    pub fn check_cancelled(&self) -> Result<(), NodeError> {
        if self.control.is_cancelled() {
            Err(NodeError::cancelled("run was cancelled"))
        } else {
            Ok(())
        }
    }

    /// Asks the host a question and waits for the answer. Emits the paired
    /// interaction events so the UI never has to guess request state.
    pub async fn request_interaction(
        &self,
        prompt: impl Into<String>,
        options: Vec<InteractionOption>,
    ) -> Result<InteractionDecision, NodeError> {
        let prompt = prompt.into();
        let request_id = format!(
            "{}:{}:{}",
            self.run_id,
            self.node.id,
            self.seq.fetch_add(1, Ordering::Relaxed)
        );

        self.sink.emit(RunEvent::InteractionRequested {
            run_id: self.run_id.to_string(),
            request_id: request_id.clone(),
            node_id: self.node.id.clone(),
            prompt: prompt.clone(),
            options: options.clone(),
        });

        let request = InteractionRequest {
            request_id: request_id.clone(),
            run_id: self.run_id.to_string(),
            node_id: self.node.id.clone(),
            prompt,
            options,
        };

        let outcome = tokio::select! {
            biased;
            _ = self.control.cancelled() => Err(NodeError::cancelled("run cancelled while waiting for interaction")),
            result = tokio::time::timeout(INTERACTION_TIMEOUT, self.broker.request(request)) => {
                match result {
                    Ok(Ok(decision)) => Ok(decision),
                    Ok(Err(error)) => Err(error),
                    Err(_) => Err(NodeError::new(
                        error_codes::INTERACTION_TIMEOUT,
                        "interaction timed out after 300 seconds",
                    )),
                }
            }
        };

        if let Ok(decision) = &outcome {
            self.sink.emit(RunEvent::InteractionResolved {
                run_id: self.run_id.to_string(),
                request_id,
                node_id: self.node.id.clone(),
                decision: *decision,
            });
        }

        outcome
    }
}
