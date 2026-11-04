//! Built-in standard ReAct agent, expressed purely as a composite subgraph.
//!
//! The runtime has no agent loop. This definition wires ordinary nodes into
//! the loop, so users can expand and change every part of it in the canvas.

use std::collections::BTreeMap;

use lingxi_spec::{
    DataType, Edge, PortBinding, PortSpec, Position, Subgraph, SubgraphInput, SubgraphOutput,
    Workflow, WorkflowNode,
};
use serde_json::{json, Value};

pub const AGENT_SUBGRAPH_ID: &str = "sg-agent-react";
pub const AGENT_TEMPLATE_NAME: &str = "标准 ReAct Agent";

fn node(id: &str, kind: &str, label: &str, x: f64, y: f64, params: Value) -> WorkflowNode {
    let mut entry = WorkflowNode::new(id, kind, Position { x, y });
    entry.label = Some(label.to_string());
    entry.params = params
        .as_object()
        .map(|map| {
            map.iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect::<BTreeMap<String, Value>>()
        })
        .unwrap_or_default();
    entry
}

/// The standard ReAct graph:
///
/// prompt -> loop gate -> model -> condition
///    true  -> tool dispatcher -> context -> gate.next
///    false -> gate.stop -> log (final answer)
pub fn standard_agent() -> Subgraph {
    let mut workflow = Workflow::new(AGENT_TEMPLATE_NAME);
    workflow.nodes = vec![
        node(
            "prompt",
            "core.prompt",
            "Prompt",
            40.0,
            220.0,
            json!({
                "system": "You are a concise, helpful assistant. Use the provided tools when a calculation or transformation is needed.",
                "user": "{{input}}",
                "variables": "{}"
            }),
        ),
        node(
            "gate",
            "core.loop_gate",
            "Agent Loop",
            320.0,
            120.0,
            json!({ "maxIterations": 8, "timeoutMs": 120000 }),
        ),
        node(
            "model",
            "core.model",
            "Model",
            600.0,
            220.0,
            json!({
                "model": "gpt-4o-mini",
                "temperature": 0.2,
                "maxTokens": 1024,
                "reasoningEffort": "none",
                "stream": true,
                "timeoutMs": 60000,
                "maxCalls": 8,
                "maxTotalTokens": 0
            }),
        ),
        node(
            "condition",
            "core.condition",
            "Has Tool Calls?",
            880.0,
            220.0,
            json!({}),
        ),
        node(
            "dispatch",
            "core.tool_dispatch",
            "Tool Dispatcher",
            1140.0,
            360.0,
            json!({}),
        ),
        node(
            "context",
            "core.context",
            "Conversation",
            880.0,
            520.0,
            json!({ "maxMessages": 60, "maxTokens": 24000, "overflow": "trim_oldest" }),
        ),
        node(
            "log",
            "core.log",
            "Final Answer",
            1140.0,
            120.0,
            json!({ "prefix": "" }),
        ),
        node(
            "provider",
            "core.provider",
            "Provider",
            40.0,
            520.0,
            json!({
                "providerId": "openai",
                "baseUrl": "http://127.0.0.1:11434/v1",
                "credentialRef": "env:OPENAI_API_KEY",
                "organization": "",
                "supportsReasoning": true
            }),
        ),
        node(
            "toolset",
            "core.tool_set",
            "Tool Set",
            320.0,
            620.0,
            json!({ "builtins": "calculator,text_transform,json_query" }),
        ),
    ];

    workflow.edges = vec![
        Edge::control("prompt", "done", "gate", "start"),
        Edge::control("gate", "continue", "model", "run"),
        Edge::new("prompt", "messages", "model", "messages"),
        Edge::new("model", "assistant", "context", "assistant"),
        Edge::new("prompt", "messages", "context", "messages"),
        Edge::new("provider", "provider", "model", "provider"),
        Edge::new("toolset", "toolset", "model", "toolset"),
        Edge::new("toolset", "toolset", "dispatch", "toolset"),
        Edge::new("model", "hasToolCalls", "condition", "condition"),
        Edge::new("model", "text", "condition", "payload"),
        Edge::new("model", "text", "log", "value"),
        Edge::new("model", "toolCalls", "dispatch", "calls"),
        Edge::control("condition", "true", "dispatch", "run"),
        Edge::control("condition", "false", "gate", "stop"),
        Edge::control("dispatch", "done", "context", "run"),
        Edge::new("dispatch", "results", "context", "toolResults"),
        Edge::new("context", "context", "gate", "value"),
        Edge::new("gate", "value", "model", "context"),
        Edge::control("context", "done", "gate", "next"),
        Edge::control("gate", "exit", "log", "run"),
    ];

    let mut subgraph = Subgraph::new(AGENT_SUBGRAPH_ID, AGENT_TEMPLATE_NAME, workflow);
    subgraph.description = Some(
        "Provider + Prompt + Context + ToolSet model loop with explicit tool dispatch.".into(),
    );
    subgraph.inputs = vec![
        SubgraphInput {
            port: PortSpec::new("start", "Start", DataType::Any).control(),
            targets: vec![PortBinding::new("prompt", "run")],
        },
        SubgraphInput {
            port: PortSpec::new("text", "Input", DataType::Any),
            targets: vec![PortBinding::new("prompt", "input")],
        },
    ];
    subgraph.outputs = vec![SubgraphOutput {
        port: PortSpec::new("answer", "Answer", DataType::Text),
        source: PortBinding::new("log", "text"),
    }];
    subgraph
}
