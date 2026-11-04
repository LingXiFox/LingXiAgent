//! Tool definitions, JSON Schema validation and the safe built-in tools.
//! Executors never use a shell or `eval`.

use std::collections::BTreeMap;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::control::RunControl;
use crate::error::{error_codes, NodeError};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: Value,
    #[serde(default = "default_capability")]
    pub capability: String,
    #[serde(default = "default_source")]
    pub source: String,
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
}

fn default_capability() -> String {
    "compute".to_string()
}

fn default_source() -> String {
    "builtin".to_string()
}

fn default_timeout() -> u64 {
    10_000
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolResult {
    pub tool_call_id: String,
    pub name: String,
    pub ok: bool,
    #[serde(default)]
    pub result: Value,
    #[serde(default)]
    pub error: Option<String>,
    pub duration_ms: u64,
}

#[async_trait]
pub trait ToolExecutor: Send + Sync {
    fn definition(&self) -> ToolDefinition;
    async fn execute(&self, arguments: Value, cancel: &RunControl) -> Result<Value, NodeError>;
}

#[derive(Default)]
pub struct BuiltinTools {
    tools: BTreeMap<String, Box<dyn ToolExecutor>>,
}

impl BuiltinTools {
    pub fn new() -> Self {
        let mut tools = Self::default();
        tools.register(Box::new(Calculator));
        tools.register(Box::new(TextTransform));
        tools.register(Box::new(JsonQuery));
        tools
    }

    fn register(&mut self, tool: Box<dyn ToolExecutor>) {
        self.tools.insert(tool.definition().name, tool);
    }

    pub fn definitions(&self, names: &[String]) -> Vec<ToolDefinition> {
        names
            .iter()
            .filter_map(|name| self.tools.get(name.trim()).map(|tool| tool.definition()))
            .collect()
    }

    pub fn names(&self) -> Vec<String> {
        self.tools.keys().cloned().collect()
    }

    pub async fn execute(
        &self,
        name: &str,
        arguments: Value,
        cancel: &RunControl,
    ) -> Result<Value, NodeError> {
        let tool = self.tools.get(name).ok_or_else(|| {
            NodeError::new(
                error_codes::TOOL_UNKNOWN,
                format!("tool {name:?} is not available"),
            )
        })?;
        let definition = tool.definition();
        validate_arguments(&definition.parameters, &arguments)?;
        tool.execute(arguments, cancel).await
    }
}

pub fn validate_arguments(schema: &Value, arguments: &Value) -> Result<(), NodeError> {
    let Some(object) = arguments.as_object() else {
        return Err(NodeError::new(
            error_codes::TOOL_INVALID_ARGUMENTS,
            "tool arguments must be a JSON object",
        ));
    };
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return Ok(());
    };
    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for name in required.iter().filter_map(Value::as_str) {
            if !object.contains_key(name) {
                return Err(NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("tool argument {name:?} is required"),
                ));
            }
        }
    }
    for (name, value) in object {
        let Some(rule) = properties.get(name) else {
            if schema.get("additionalProperties").and_then(Value::as_bool) == Some(false) {
                return Err(NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("tool argument {name:?} is not allowed"),
                ));
            }
            continue;
        };
        validate_value(name, rule, value)?;
    }
    Ok(())
}

fn validate_value(name: &str, rule: &Value, value: &Value) -> Result<(), NodeError> {
    let expected = rule.get("type").and_then(Value::as_str).unwrap_or("any");
    let valid = match expected {
        "string" => value.is_string(),
        "number" => value.is_number(),
        "integer" => value.as_i64().is_some() || value.as_u64().is_some(),
        "boolean" => value.is_boolean(),
        "array" => value.is_array(),
        "object" => value.is_object(),
        _ => true,
    };
    if !valid {
        return Err(NodeError::new(
            error_codes::TOOL_INVALID_ARGUMENTS,
            format!("tool argument {name:?} must be {expected}"),
        ));
    }
    if let Some(options) = rule.get("enum").and_then(Value::as_array) {
        if !options.iter().any(|option| option == value) {
            return Err(NodeError::new(
                error_codes::TOOL_INVALID_ARGUMENTS,
                format!("tool argument {name:?} is not one of the allowed values"),
            ));
        }
    }
    if let (Some(number), Some(max)) = (value.as_f64(), rule.get("maximum").and_then(Value::as_f64))
    {
        if number > max {
            return Err(NodeError::new(
                error_codes::TOOL_INVALID_ARGUMENTS,
                format!("tool argument {name:?} exceeds its maximum"),
            ));
        }
    }
    if let (Some(number), Some(min)) = (value.as_f64(), rule.get("minimum").and_then(Value::as_f64))
    {
        if number < min {
            return Err(NodeError::new(
                error_codes::TOOL_INVALID_ARGUMENTS,
                format!("tool argument {name:?} is below its minimum"),
            ));
        }
    }
    if let Some(text) = value.as_str() {
        if let Some(min) = rule.get("minLength").and_then(Value::as_u64) {
            if text.chars().count() < min as usize {
                return Err(NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("tool argument {name:?} is too short"),
                ));
            }
        }
        if let Some(max) = rule.get("maxLength").and_then(Value::as_u64) {
            if text.chars().count() > max as usize {
                return Err(NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("tool argument {name:?} is too long"),
                ));
            }
        }
    }
    Ok(())
}

struct Calculator;

#[async_trait]
impl ToolExecutor for Calculator {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "calculator".to_string(),
            description: "Evaluates a basic arithmetic expression containing numbers, + - * / and parentheses.".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "expression": {"type": "string", "minLength": 1, "maxLength": 512}
                },
                "required": ["expression"],
                "additionalProperties": false
            }),
            capability: "compute".to_string(),
            source: "builtin".to_string(),
            timeout_ms: 2_000,
        }
    }

    async fn execute(&self, arguments: Value, cancel: &RunControl) -> Result<Value, NodeError> {
        if cancel.is_cancelled() {
            return Err(NodeError::cancelled("calculator cancelled"));
        }
        let expression = arguments
            .get("expression")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let value = evaluate(expression)?;
        Ok(json!({"expression": expression, "value": value}))
    }
}

struct TextTransform;

#[async_trait]
impl ToolExecutor for TextTransform {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "text_transform".to_string(),
            description: "Transforms text: upper, lower, trim, length or replace.".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "operation": {"type": "string", "enum": ["upper", "lower", "trim", "length", "replace"]},
                    "from": {"type": "string"},
                    "to": {"type": "string"}
                },
                "required": ["text", "operation"],
                "additionalProperties": false
            }),
            capability: "compute".to_string(),
            source: "builtin".to_string(),
            timeout_ms: 2_000,
        }
    }

    async fn execute(&self, arguments: Value, cancel: &RunControl) -> Result<Value, NodeError> {
        if cancel.is_cancelled() {
            return Err(NodeError::cancelled("text transform cancelled"));
        }
        let text = arguments
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let operation = arguments
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let result = match operation {
            "upper" => json!(text.to_uppercase()),
            "lower" => json!(text.to_lowercase()),
            "trim" => json!(text.trim()),
            "length" => json!(text.chars().count()),
            "replace" => {
                let from = arguments
                    .get("from")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if from.is_empty() {
                    return Err(NodeError::new(
                        error_codes::TOOL_INVALID_ARGUMENTS,
                        "replace operation requires a non-empty `from`",
                    ));
                }
                let to = arguments
                    .get("to")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                json!(text.replace(from, to))
            }
            other => {
                return Err(NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("unknown text operation {other:?}"),
                ))
            }
        };
        Ok(json!({"operation": operation, "result": result}))
    }
}

struct JsonQuery;

#[async_trait]
impl ToolExecutor for JsonQuery {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "json_query".to_string(),
            description:
                "Reads a value from JSON using a dot path such as user.name or items.0.id."
                    .to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "data": {"type": ["object", "array", "string", "number", "boolean", "null"]},
                    "path": {"type": "string", "minLength": 1}
                },
                "required": ["data", "path"],
                "additionalProperties": false
            }),
            capability: "compute".to_string(),
            source: "builtin".to_string(),
            timeout_ms: 2_000,
        }
    }

    async fn execute(&self, arguments: Value, cancel: &RunControl) -> Result<Value, NodeError> {
        if cancel.is_cancelled() {
            return Err(NodeError::cancelled("json query cancelled"));
        }
        let mut data = arguments.get("data").cloned().unwrap_or(Value::Null);
        if let Some(text) = data.as_str() {
            data = serde_json::from_str(text).map_err(|error| {
                NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("json_query data is not valid JSON: {error}"),
                )
            })?;
        }
        let path = arguments
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut current = &data;
        for segment in path.split('.') {
            if segment.is_empty() {
                return Err(NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    "json_query path contains an empty segment",
                ));
            }
            current = match current {
                Value::Object(map) => map.get(segment).ok_or_else(|| {
                    NodeError::new(
                        error_codes::TOOL_FAILED,
                        format!("json path segment {segment:?} was not found"),
                    )
                })?,
                Value::Array(items) => {
                    let index = segment.parse::<usize>().map_err(|_| {
                        NodeError::new(
                            error_codes::TOOL_INVALID_ARGUMENTS,
                            format!("json path segment {segment:?} is not an array index"),
                        )
                    })?;
                    items.get(index).ok_or_else(|| {
                        NodeError::new(
                            error_codes::TOOL_FAILED,
                            format!("json array index {index} is out of range"),
                        )
                    })?
                }
                _ => {
                    return Err(NodeError::new(
                        error_codes::TOOL_FAILED,
                        format!("json path cannot descend into {segment:?}"),
                    ))
                }
            };
        }
        Ok(json!({"value": current}))
    }
}

/// Recursive-descent arithmetic. Input is capped at 512 bytes and only digits,
/// whitespace, decimal points and operators are accepted.
fn evaluate(expression: &str) -> Result<f64, NodeError> {
    let chars: Vec<char> = expression.chars().collect();
    if chars.len() > 512 {
        return Err(invalid_expression("expression is too long"));
    }
    let mut parser = Parser {
        chars: &chars,
        position: 0,
    };
    let value = parser.expression()?;
    parser.skip_space();
    if parser.position != chars.len() {
        return Err(invalid_expression("unexpected character"));
    }
    if !value.is_finite() {
        return Err(invalid_expression("result is not finite"));
    }
    Ok(value)
}

fn invalid_expression(message: &str) -> NodeError {
    NodeError::new(
        error_codes::TOOL_INVALID_ARGUMENTS,
        format!("invalid arithmetic expression: {message}"),
    )
}

struct Parser<'a> {
    chars: &'a [char],
    position: usize,
}

impl<'a> Parser<'a> {
    fn skip_space(&mut self) {
        while self
            .chars
            .get(self.position)
            .is_some_and(|ch| ch.is_whitespace())
        {
            self.position += 1;
        }
    }

    fn peek(&mut self) -> Option<char> {
        self.skip_space();
        self.chars.get(self.position).copied()
    }

    fn expression(&mut self) -> Result<f64, NodeError> {
        let mut value = self.term()?;
        while let Some(op) = self.peek() {
            if op != '+' && op != '-' {
                break;
            }
            self.position += 1;
            let right = self.term()?;
            value = if op == '+' {
                value + right
            } else {
                value - right
            };
        }
        Ok(value)
    }

    fn term(&mut self) -> Result<f64, NodeError> {
        let mut value = self.factor()?;
        while let Some(op) = self.peek() {
            if op != '*' && op != '/' {
                break;
            }
            self.position += 1;
            let right = self.factor()?;
            if op == '/' {
                if right == 0.0 {
                    return Err(invalid_expression("division by zero"));
                }
                value /= right;
            } else {
                value *= right;
            }
        }
        Ok(value)
    }

    fn factor(&mut self) -> Result<f64, NodeError> {
        match self.peek() {
            Some('+') => {
                self.position += 1;
                self.factor()
            }
            Some('-') => {
                self.position += 1;
                Ok(-self.factor()?)
            }
            Some('(') => {
                self.position += 1;
                let value = self.expression()?;
                if self.peek() != Some(')') {
                    return Err(invalid_expression("missing closing parenthesis"));
                }
                self.position += 1;
                Ok(value)
            }
            Some(ch) if ch.is_ascii_digit() || ch == '.' => {
                let start = self.position;
                while self
                    .chars
                    .get(self.position)
                    .is_some_and(|ch| ch.is_ascii_digit() || *ch == '.')
                {
                    self.position += 1;
                }
                let text: String = self.chars[start..self.position].iter().collect();
                text.parse::<f64>()
                    .map_err(|_| invalid_expression("malformed number"))
            }
            Some(_) => Err(invalid_expression("unexpected token")),
            None => Err(invalid_expression("unexpected end of expression")),
        }
    }
}

pub fn tool_definitions_json(definitions: &[ToolDefinition]) -> Value {
    serde_json::to_value(definitions).unwrap_or_else(|_| Value::Array(Vec::new()))
}

pub fn parse_tool_definitions(value: &Value) -> Result<Vec<ToolDefinition>, NodeError> {
    serde_json::from_value(value.clone()).map_err(|error| {
        NodeError::new(
            error_codes::TOOLSET_UNKNOWN_HANDLE,
            format!("tool definitions are not valid: {error}"),
        )
    })
}

pub fn summarize_arguments(arguments: &Value) -> Map<String, Value> {
    arguments.as_object().cloned().unwrap_or_default()
}
