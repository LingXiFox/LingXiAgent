//! Built-in node kinds. They are ordinary registry entries: nothing in the
//! engine knows these names, and plugins register through the same API.

use async_trait::async_trait;
use lingxi_spec::{capabilities, ControlKind, DataType, NodeSpec, ParamSpec, PortSpec};
use serde_json::Value;
use std::sync::Arc;

use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::event::LogLevel;
use crate::interaction::{InteractionDecision, InteractionOption};
use crate::registry::{NodeExecutor, NodeOutput, NodeRegistry};

pub fn register(registry: &mut NodeRegistry) {
    registry
        .register(text_input_spec(), Arc::new(TextInput))
        .expect("built-in node kinds are unique");
    registry
        .register(number_input_spec(), Arc::new(NumberInput))
        .expect("built-in node kinds are unique");
    registry
        .register(uppercase_spec(), Arc::new(Uppercase))
        .expect("built-in node kinds are unique");
    registry
        .register(concat_spec(), Arc::new(Concat))
        .expect("built-in node kinds are unique");
    registry
        .register(number_add_spec(), Arc::new(NumberAdd))
        .expect("built-in node kinds are unique");
    registry
        .register(log_spec(), Arc::new(LogNode))
        .expect("built-in node kinds are unique");
    registry
        .register(approval_spec(), Arc::new(Approval))
        .expect("built-in node kinds are unique");
    registry
        .register(boolean_input_spec(), Arc::new(BooleanInput))
        .expect("built-in node kinds are unique");
    registry
        .register(condition_spec(), Arc::new(Condition))
        .expect("built-in node kinds are unique");
    registry
        .register(loop_gate_spec(), Arc::new(LoopGatePlaceholder))
        .expect("built-in node kinds are unique");
    registry
        .register(counter_spec(), Arc::new(Counter))
        .expect("built-in node kinds are unique");
}

pub fn text_input_spec() -> NodeSpec {
    NodeSpec::new("core.text_input", "Text Input", "Input")
        .description("Emits a fixed text value.")
        .param(ParamSpec::text_area("text", "Text", ""))
        .output(PortSpec::new("text", "Text", DataType::Text))
}

pub fn number_input_spec() -> NodeSpec {
    NodeSpec::new("core.number_input", "Number Input", "Input")
        .description("Emits a fixed number.")
        .param(ParamSpec::number("value", "Value", 0.0))
        .output(PortSpec::new("number", "Number", DataType::Number))
}

pub fn uppercase_spec() -> NodeSpec {
    NodeSpec::new("core.text_uppercase", "Uppercase", "Text")
        .description("Converts the incoming text to upper case.")
        .input(PortSpec::new("text", "Text", DataType::Text).required())
        .output(PortSpec::new("text", "Text", DataType::Text))
}

pub fn concat_spec() -> NodeSpec {
    NodeSpec::new("core.text_concat", "Concat", "Text")
        .description("Joins two text inputs with an optional separator.")
        .input(PortSpec::new("a", "A", DataType::Text).required())
        .input(PortSpec::new("b", "B", DataType::Text).required())
        .param(ParamSpec::text("separator", "Separator", ""))
        .output(PortSpec::new("text", "Text", DataType::Text))
}

pub fn number_add_spec() -> NodeSpec {
    NodeSpec::new("core.number_add", "Add", "Number")
        .description("Adds two numbers.")
        .input(PortSpec::new("a", "A", DataType::Number).required())
        .input(PortSpec::new("b", "B", DataType::Number).required())
        .output(PortSpec::new("number", "Number", DataType::Number))
}

pub fn log_spec() -> NodeSpec {
    NodeSpec::new("core.log", "Log", "Output")
        .description("Writes the incoming value to the run log.")
        .input(PortSpec::new("value", "Value", DataType::Any).required())
        .param(ParamSpec::text("prefix", "Prefix", ""))
}

pub fn approval_spec() -> NodeSpec {
    NodeSpec::new("core.approval", "Approval Gate", "Control")
        .description("Blocks the run until the user approves or rejects the step.")
        .capability(capabilities::INTERACTION)
        .input(PortSpec::new("payload", "Payload", DataType::Any))
        .output(PortSpec::new("payload", "Payload", DataType::Any))
        .param(ParamSpec::text_area(
            "prompt",
            "Prompt",
            "Approve this step?",
        ))
}

pub fn boolean_input_spec() -> NodeSpec {
    NodeSpec::new("core.boolean_input", "Boolean Input", "Input")
        .description("Emits a fixed boolean value.")
        .param(ParamSpec::boolean("value", "Value", false))
        .output(PortSpec::new("boolean", "Boolean", DataType::Boolean))
}

pub fn condition_spec() -> NodeSpec {
    NodeSpec::new("core.condition", "Condition", "Control")
        .description("Routes the payload to exactly one Boolean branch.")
        .control(ControlKind::Branch)
        .input(PortSpec::new("condition", "Condition", DataType::Boolean).required())
        .input(PortSpec::new("payload", "Payload", DataType::Any))
        .output(PortSpec::new("true", "True", DataType::Any).control())
        .output(PortSpec::new("false", "False", DataType::Any).control())
}

pub fn loop_gate_spec() -> NodeSpec {
    NodeSpec::new("core.loop_gate", "Loop Gate", "Control")
        .description("Drives a user-defined loop with an iteration and time budget.")
        .control(ControlKind::LoopGate)
        .input(PortSpec::new("start", "Start", DataType::Any).control())
        .input(PortSpec::new("next", "Next", DataType::Any).control())
        .input(PortSpec::new("stop", "Stop", DataType::Any).control())
        .output(PortSpec::new("continue", "Continue", DataType::Any).control())
        .output(PortSpec::new("exit", "Exit", DataType::Any).control())
        .param(
            ParamSpec::number("maxIterations", "Max iterations", 10.0)
                .help("Hard iteration budget; the run fails when it is exhausted."),
        )
        .param(
            ParamSpec::number("timeoutMs", "Timeout (ms)", 60_000.0)
                .help("Hard wall-clock budget for the whole loop."),
        )
}

pub fn counter_spec() -> NodeSpec {
    NodeSpec::new("core.counter", "Counter", "Logic")
        .description("Increments the incoming value and reports when a threshold is reached.")
        .input(PortSpec::new("value", "Value", DataType::Number))
        .output(PortSpec::new("number", "Number", DataType::Number))
        .output(PortSpec::new("done", "Done", DataType::Boolean))
        .param(ParamSpec::number("start", "Start", 0.0))
        .param(ParamSpec::number("step", "Step", 1.0))
        .param(ParamSpec::number("threshold", "Threshold", 3.0))
}

struct TextInput;

#[async_trait]
impl NodeExecutor for TextInput {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let text = ctx.string_param("text")?.to_string();
        Ok(NodeOutput::new().with("text", Value::String(text)))
    }
}

struct NumberInput;

#[async_trait]
impl NodeExecutor for NumberInput {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let value = ctx.number_param("value")?;
        Ok(NodeOutput::new().with("number", Value::from(value)))
    }
}

struct Uppercase;

#[async_trait]
impl NodeExecutor for Uppercase {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let text = ctx.text_input("text")?;
        Ok(NodeOutput::new().with("text", Value::String(text.to_uppercase())))
    }
}

struct Concat;

#[async_trait]
impl NodeExecutor for Concat {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let a = ctx.text_input("a")?;
        let b = ctx.text_input("b")?;
        let separator = ctx.string_param("separator")?.to_string();
        Ok(NodeOutput::new().with("text", Value::String(format!("{a}{separator}{b}"))))
    }
}

struct NumberAdd;

#[async_trait]
impl NodeExecutor for NumberAdd {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let a = ctx.number_input("a")?;
        let b = ctx.number_input("b")?;
        Ok(NodeOutput::new().with("number", Value::from(a + b)))
    }
}

struct LogNode;

#[async_trait]
impl NodeExecutor for LogNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let value = ctx.input("value").ok_or_else(|| {
            NodeError::new(error_codes::MISSING_INPUT, "input \"value\" has no value")
        })?;
        let prefix = ctx.string_param("prefix")?.to_string();
        ctx.log(LogLevel::Info, format!("{prefix}{}", display_value(value)));
        Ok(NodeOutput::new())
    }
}

struct Approval;

#[async_trait]
impl NodeExecutor for Approval {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let prompt = ctx.string_param("prompt")?.to_string();
        let decision = ctx
            .request_interaction(
                prompt,
                vec![
                    InteractionOption {
                        value: "approve".to_string(),
                        label: "Approve".to_string(),
                    },
                    InteractionOption {
                        value: "reject".to_string(),
                        label: "Reject".to_string(),
                    },
                ],
            )
            .await?;
        match decision {
            InteractionDecision::Approved => Ok(NodeOutput::new().with(
                "payload",
                ctx.input("payload").cloned().unwrap_or(Value::Null),
            )),
            InteractionDecision::Rejected => Err(NodeError::new(
                error_codes::INTERACTION_DENIED,
                "approval was rejected",
            )),
        }
    }
}

struct BooleanInput;

#[async_trait]
impl NodeExecutor for BooleanInput {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let value = ctx.bool_param("value")?;
        Ok(NodeOutput::new().with("boolean", Value::Bool(value)))
    }
}

struct Condition;

#[async_trait]
impl NodeExecutor for Condition {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let condition = match ctx.input("condition") {
            Some(Value::Bool(value)) => *value,
            Some(other) => {
                return Err(NodeError::new(
                    error_codes::INVALID_INPUT,
                    format!(
                        "input \"condition\" expects boolean, got {}",
                        crate::error::json_type_name(other)
                    ),
                ))
            }
            None => {
                return Err(NodeError::new(
                    error_codes::MISSING_INPUT,
                    "input \"condition\" has no value",
                ))
            }
        };
        let payload = ctx.input("payload").cloned().unwrap_or(Value::Null);
        let port = if condition { "true" } else { "false" };
        Ok(NodeOutput::new().with(port, payload))
    }
}

/// The engine intercepts this kind before executor lookup. Registering a
/// placeholder keeps the registry contract uniform for every declared spec.
struct LoopGatePlaceholder;

#[async_trait]
impl NodeExecutor for LoopGatePlaceholder {
    async fn execute(&self, _ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        Err(NodeError::new(
            error_codes::EXECUTOR_FAILED,
            "loop gate must be driven by the engine loop controller",
        ))
    }
}

struct Counter;

#[async_trait]
impl NodeExecutor for Counter {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        ctx.check_cancelled()?;
        let current = match ctx.input("value") {
            Some(Value::Number(number)) => number.as_f64().ok_or_else(|| {
                NodeError::new(
                    error_codes::INVALID_INPUT,
                    "input \"value\" is not a number",
                )
            })?,
            Some(other) => {
                return Err(NodeError::new(
                    error_codes::INVALID_INPUT,
                    format!(
                        "input \"value\" expects a number, got {}",
                        crate::error::json_type_name(other)
                    ),
                ))
            }
            None => ctx.number_param("start")?,
        };
        let step = ctx.number_param("step")?;
        let threshold = ctx.number_param("threshold")?;
        let next = current + step;
        Ok(NodeOutput::new()
            .with("number", Value::from(next))
            .with("done", Value::Bool(next >= threshold)))
    }
}

fn display_value(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => "null".to_string(),
        other => other.to_string(),
    }
}
