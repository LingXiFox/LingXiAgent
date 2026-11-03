//! Built-in node kinds. They are ordinary registry entries: nothing in the
//! engine knows these names, and plugins register through the same API.

use async_trait::async_trait;
use lingxi_spec::{capabilities, DataType, NodeSpec, ParamSpec, PortSpec};
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

fn display_value(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => "null".to_string(),
        other => other.to_string(),
    }
}
