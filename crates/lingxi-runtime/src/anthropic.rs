use crate::assets::AssetStore;
use crate::content::{ContentPart, MessageContent};
use crate::control::RunControl;
use crate::credentials::Secret;
use crate::error::{error_codes, NodeError};
use crate::provider::{
    ChatMessage, ChatProvider, ChatRequest, ChatResponse, MessageRole, ProviderConfig, TokenUsage,
    ToolCall,
};
use async_trait::async_trait;
use base64::Engine as _;
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

const ANTHROPIC_VERSION: &str = "2023-06-01";

/// Anthropic Messages adapter. Tool results are encoded as `tool_result`
/// blocks inside a user message, which is the only shape the API accepts.
pub struct AnthropicProvider {
    config: ProviderConfig,
    secret: Option<Secret>,
    client: reqwest::Client,
    assets: Arc<AssetStore>,
}

impl AnthropicProvider {
    pub fn new(
        config: ProviderConfig,
        secret: Option<Secret>,
        client: reqwest::Client,
        assets: Arc<AssetStore>,
    ) -> Self {
        Self {
            config,
            secret,
            client,
            assets,
        }
    }

    fn headers(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        let builder = builder
            .header("content-type", "application/json")
            .header("anthropic-version", ANTHROPIC_VERSION);
        match &self.secret {
            Some(secret) if !secret.is_empty() => builder.header("x-api-key", secret.expose()),
            _ => builder,
        }
    }

    async fn send(
        &self,
        builder: reqwest::RequestBuilder,
        cancel: &RunControl,
    ) -> Result<reqwest::Response, NodeError> {
        let response = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(NodeError::cancelled("messages request cancelled")),
            result = builder.send() => result.map_err(network_error)?,
        };
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let code = if status == reqwest::StatusCode::UNAUTHORIZED
            || status == reqwest::StatusCode::FORBIDDEN
        {
            error_codes::PROVIDER_AUTH
        } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            error_codes::PROVIDER_RATE_LIMITED
        } else {
            error_codes::PROVIDER_HTTP
        };
        Err(NodeError::new(
            code,
            format!("provider returned HTTP {}", status.as_u16()),
        ))
    }
}

fn network_error(error: reqwest::Error) -> NodeError {
    if error.is_timeout() {
        NodeError::new(error_codes::PROVIDER_TIMEOUT, "provider request timed out")
    } else {
        NodeError::new(
            error_codes::PROVIDER_NETWORK,
            format!("provider request failed: {error}"),
        )
    }
}

fn invalid_response(error: impl std::fmt::Display) -> NodeError {
    NodeError::new(
        error_codes::PROVIDER_INVALID_RESPONSE,
        format!("invalid Messages payload: {error}"),
    )
}

fn encode_parts(content: &MessageContent, assets: &AssetStore) -> Result<Vec<Value>, NodeError> {
    let mut blocks = Vec::new();
    let parts = match content {
        MessageContent::Text(text) => return Ok(vec![json!({"type": "text", "text": text})]),
        MessageContent::Parts(parts) => parts,
    };
    for part in parts {
        match part {
            ContentPart::Text { text, .. } => blocks.push(json!({"type": "text", "text": text})),
            ContentPart::Image { asset, .. } => {
                let bytes = assets.read(asset)?;
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": asset.mime,
                        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                    }
                }));
            }
            ContentPart::Document {
                asset, mode, text, ..
            } => match mode {
                crate::content::DocumentMode::Extracted => blocks.push(json!({
                    "type": "text",
                    "text": text.clone().unwrap_or_default(),
                })),
                crate::content::DocumentMode::Native => {
                    let bytes = assets.read(asset)?;
                    blocks.push(json!({
                        "type": "document",
                        "source": {
                            "type": "base64",
                            "media_type": asset.mime,
                            "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                        }
                    }));
                }
            },
            ContentPart::Audio { .. } => {
                return Err(NodeError::new(
                    error_codes::MODEL_UNSUPPORTED_MODALITY,
                    "Anthropic Messages has no native audio input; enable transcription",
                ))
            }
            ContentPart::Video { .. } => {
                return Err(NodeError::new(
                    error_codes::MODEL_UNSUPPORTED_MODALITY,
                    "Anthropic Messages has no native video input; use frame extraction",
                ))
            }
        }
    }
    Ok(blocks)
}

fn encode_messages(
    messages: &[ChatMessage],
    assets: &AssetStore,
) -> Result<(Option<String>, Vec<Value>), NodeError> {
    let mut system = Vec::new();
    let mut encoded: Vec<Value> = Vec::new();
    for message in messages {
        if message.role == MessageRole::System {
            system.push(message.content.plain_text());
            continue;
        }
        let mut blocks = Vec::new();
        if message.role == MessageRole::Tool {
            blocks.push(json!({
                "type": "tool_result",
                "tool_use_id": message.tool_call_id.clone().unwrap_or_default(),
                "content": message.content.plain_text(),
            }));
            encoded.push(json!({"role": "user", "content": blocks}));
            continue;
        }
        if message.role == MessageRole::Assistant {
            if !message.content.is_empty() {
                blocks.extend(encode_parts(&message.content, assets)?);
            }
            for call in &message.tool_calls {
                blocks.push(json!({
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": call.arguments,
                }));
            }
        } else {
            blocks.extend(encode_parts(&message.content, assets)?);
        }
        if blocks.is_empty() {
            continue;
        }
        let role = if message.role == MessageRole::Assistant {
            "assistant"
        } else {
            "user"
        };
        // Merge consecutive turns of the same role. The Messages API requires
        // alternation, and tool results naturally continue the user turn.
        if let Some(last) = encoded.last_mut() {
            if last.get("role").and_then(Value::as_str) == Some(role) {
                if let Some(existing) = last.get_mut("content").and_then(Value::as_array_mut) {
                    existing.extend(blocks);
                    continue;
                }
            }
        }
        encoded.push(json!({"role": role, "content": blocks}));
    }
    let system = if system.is_empty() {
        None
    } else {
        Some(system.join("\n\n"))
    };
    Ok((system, encoded))
}

fn thinking_budget(effort: &str, max_tokens: u32) -> Option<u32> {
    let desired = match effort {
        "low" => 1_024,
        "medium" => 4_096,
        "high" => 8_192,
        "xhigh" => 16_000,
        _ => return None,
    };
    // Anthropic requires the budget to leave room for the answer.
    if max_tokens <= desired + 512 {
        return None;
    }
    Some(desired)
}

fn tools_from_openai(tools: &[Value]) -> Vec<Value> {
    tools
        .iter()
        .filter_map(|tool| {
            let function = tool.get("function").unwrap_or(tool);
            let name = function.get("name").and_then(Value::as_str)?;
            Some(json!({
                "name": name,
                "description": function.get("description").and_then(Value::as_str).unwrap_or(""),
                "input_schema": function.get("parameters").cloned().unwrap_or_else(|| json!({"type": "object"})),
            }))
        })
        .collect()
}

fn parse_usage(raw: &Value) -> TokenUsage {
    let prompt = raw.get("input_tokens").and_then(Value::as_u64).unwrap_or(0);
    let completion = raw
        .get("output_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    TokenUsage {
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: prompt + completion,
    }
}

#[async_trait]
impl ChatProvider for AnthropicProvider {
    async fn complete(
        &self,
        request: ChatRequest,
        cancel: &RunControl,
        delta: &mut (dyn FnMut(String) + Send),
    ) -> Result<ChatResponse, NodeError> {
        let (system, messages) = encode_messages(&request.messages, &self.assets)?;
        let max_tokens = request.max_tokens.unwrap_or(1_024);
        let mut body = json!({
            "model": request.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "stream": request.stream,
        });
        if let Some(system) = system {
            body["system"] = json!(system);
        }
        if let Some(temperature) = request.temperature {
            body["temperature"] = json!(temperature);
        }
        if !request.tools.is_empty() {
            body["tools"] = Value::Array(tools_from_openai(&request.tools));
        }
        if let Some(effort) = request.reasoning_effort.as_deref() {
            if self.config.supports_reasoning {
                if let Some(budget) = thinking_budget(effort, max_tokens) {
                    body["thinking"] = json!({"type": "enabled", "budget_tokens": budget});
                } else if matches!(effort, "low" | "medium" | "high" | "xhigh") {
                    return Err(NodeError::new(
                        error_codes::MODEL_UNSUPPORTED_REASONING,
                        format!("max_tokens {max_tokens} leaves no room for Anthropic thinking budget '{effort}'"),
                    ));
                }
            }
        }
        let builder = self
            .client
            .post(self.config.endpoint())
            .timeout(Duration::from_millis(request.timeout_ms.max(1)))
            .json(&body);
        let response = self.send(self.headers(builder), cancel).await?;
        if !request.stream {
            let value: Value = response.json().await.map_err(invalid_response)?;
            return parse_message(&value);
        }

        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut text = String::new();
        let mut reasoning = String::new();
        let mut calls: BTreeMap<u64, Value> = BTreeMap::new();
        let mut usage = TokenUsage::default();
        let mut finish_reason = None;
        let mut stopped = false;
        loop {
            let next = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(NodeError::cancelled("streaming model request cancelled")),
                chunk = stream.next() => chunk,
            };
            let Some(chunk) = next else { break };
            let chunk = chunk.map_err(network_error)?;
            buffer.push_str(&String::from_utf8_lossy(&chunk));
            while let Some(position) = buffer.find('\n') {
                let line = buffer[..position].trim().to_string();
                buffer.drain(..=position);
                let Some(data) = line.strip_prefix("data:") else {
                    continue;
                };
                let data = data.trim();
                if data.is_empty() {
                    continue;
                }
                let value: Value = serde_json::from_str(data).map_err(invalid_response)?;
                let kind = value
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                match kind {
                    "message_start" => {
                        if let Some(raw) = value.pointer("/message/usage") {
                            usage = parse_usage(raw);
                        }
                    }
                    "content_block_start" => {
                        let index = value.get("index").and_then(Value::as_u64).unwrap_or(0);
                        if let Some(block) = value.get("content_block") {
                            if block.get("type").and_then(Value::as_str) == Some("tool_use") {
                                calls.insert(index, block.clone());
                            }
                        }
                    }
                    "content_block_delta" => {
                        let index = value.get("index").and_then(Value::as_u64).unwrap_or(0);
                        if let Some(delta_value) = value.get("delta") {
                            match delta_value.get("type").and_then(Value::as_str) {
                                Some("text_delta") => {
                                    if let Some(chunk) =
                                        delta_value.get("text").and_then(Value::as_str)
                                    {
                                        text.push_str(chunk);
                                        delta(chunk.to_string());
                                    }
                                }
                                Some("thinking_delta") => {
                                    if let Some(chunk) =
                                        delta_value.get("thinking").and_then(Value::as_str)
                                    {
                                        reasoning.push_str(chunk);
                                    }
                                }
                                Some("input_json_delta") => {
                                    if let Some(chunk) =
                                        delta_value.get("partial_json").and_then(Value::as_str)
                                    {
                                        let entry = calls
                                            .entry(index)
                                            .or_insert_with(|| json!({"type":"tool_use"}));
                                        let current = entry
                                            .get("_partial")
                                            .and_then(Value::as_str)
                                            .unwrap_or("");
                                        entry["_partial"] = json!(format!("{current}{chunk}"));
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                    "message_delta" => {
                        if let Some(reason) =
                            value.pointer("/delta/stop_reason").and_then(Value::as_str)
                        {
                            finish_reason = Some(reason.to_string());
                        }
                        if let Some(raw) = value.get("usage") {
                            usage.completion_tokens = raw
                                .get("output_tokens")
                                .and_then(Value::as_u64)
                                .unwrap_or(usage.completion_tokens);
                            usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
                        }
                    }
                    "message_stop" => stopped = true,
                    "error" => {
                        let message = value
                            .pointer("/error/message")
                            .and_then(Value::as_str)
                            .unwrap_or("provider stream error");
                        return Err(NodeError::new(
                            error_codes::PROVIDER_INVALID_RESPONSE,
                            message,
                        ));
                    }
                    _ => {}
                }
            }
        }
        if !stopped {
            return Err(NodeError::new(
                error_codes::PROVIDER_INVALID_RESPONSE,
                "Messages stream ended before message_stop",
            ));
        }
        let tool_calls = calls
            .into_values()
            .filter_map(|block| {
                let name = block.get("name").and_then(Value::as_str)?.to_string();
                let arguments = block
                    .get("_partial")
                    .and_then(Value::as_str)
                    .filter(|raw| !raw.trim().is_empty())
                    .and_then(|raw| serde_json::from_str(raw).ok())
                    .or_else(|| block.get("input").filter(|value| !value.is_null()).cloned())
                    .unwrap_or_else(|| json!({}));
                Some(ToolCall {
                    id: block
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    name,
                    arguments,
                })
            })
            .collect();
        Ok(ChatResponse {
            text,
            tool_calls,
            finish_reason,
            usage,
            reasoning: if reasoning.is_empty() {
                None
            } else {
                Some(reasoning)
            },
            response_id: None,
        })
    }

    async fn list_models(&self) -> Result<Vec<String>, NodeError> {
        let base = self.config.base_url.trim().trim_end_matches('/');
        let base = if base.ends_with("/v1") {
            base.to_string()
        } else {
            format!("{base}/v1")
        };
        let response = self
            .send(
                self.headers(self.client.get(format!("{base}/models"))),
                &RunControl::new(),
            )
            .await?;
        let value: Value = response.json().await.map_err(invalid_response)?;
        Ok(value
            .get("data")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("id").and_then(Value::as_str).map(str::to_string))
                    .collect()
            })
            .unwrap_or_default())
    }
}

fn parse_message(value: &Value) -> Result<ChatResponse, NodeError> {
    let mut text = String::new();
    let mut reasoning = String::new();
    let mut tool_calls = Vec::new();
    if let Some(blocks) = value.get("content").and_then(Value::as_array) {
        for block in blocks {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    if let Some(chunk) = block.get("text").and_then(Value::as_str) {
                        text.push_str(chunk);
                    }
                }
                Some("thinking") => {
                    if let Some(chunk) = block.get("thinking").and_then(Value::as_str) {
                        reasoning.push_str(chunk);
                    }
                }
                Some("tool_use") => tool_calls.push(ToolCall {
                    id: block
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    name: block
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    arguments: block.get("input").cloned().unwrap_or_else(|| json!({})),
                }),
                _ => {}
            }
        }
    }
    Ok(ChatResponse {
        text,
        tool_calls,
        finish_reason: value
            .get("stop_reason")
            .and_then(Value::as_str)
            .map(str::to_string),
        usage: value.get("usage").map(parse_usage).unwrap_or_default(),
        reasoning: if reasoning.is_empty() {
            None
        } else {
            Some(reasoning)
        },
        response_id: None,
    })
}
