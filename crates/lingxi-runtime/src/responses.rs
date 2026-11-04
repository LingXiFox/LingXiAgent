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

/// OpenAI Responses API adapter. It keeps server-side conversation state
/// explicit: a response id is returned to the caller and sent back as
/// `previous_response_id`, never silently duplicated with local history.
pub struct ResponsesProvider {
    config: ProviderConfig,
    secret: Option<Secret>,
    client: reqwest::Client,
    assets: Arc<AssetStore>,
}

impl ResponsesProvider {
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
        let builder = builder.header("content-type", "application/json");
        match &self.secret {
            Some(secret) if !secret.is_empty() => {
                builder.header("authorization", format!("Bearer {}", secret.expose()))
            }
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
            _ = cancel.cancelled() => return Err(NodeError::cancelled("responses request cancelled")),
            result = builder.send() => result.map_err(network_error)?,
        };
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        Err(status_error(status))
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
        format!("invalid Responses payload: {error}"),
    )
}

fn status_error(status: reqwest::StatusCode) -> NodeError {
    let code = if status == reqwest::StatusCode::UNAUTHORIZED
        || status == reqwest::StatusCode::FORBIDDEN
    {
        error_codes::PROVIDER_AUTH
    } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        error_codes::PROVIDER_RATE_LIMITED
    } else {
        error_codes::PROVIDER_HTTP
    };
    let detail = match status.as_u16() {
        401 | 403 => "provider rejected the credential (HTTP 401/403)".to_string(),
        429 => "provider rate limit reached (HTTP 429)".to_string(),
        other => format!("provider returned HTTP {other}"),
    };
    NodeError::new(code, detail)
}

fn encode_input(messages: &[ChatMessage], assets: &AssetStore) -> Result<Vec<Value>, NodeError> {
    let mut items = Vec::new();
    for message in messages {
        match message.role {
            MessageRole::Tool => {
                items.push(json!({
                    "type": "function_call_output",
                    "call_id": message.tool_call_id.clone().unwrap_or_default(),
                    "output": message.content.plain_text(),
                }));
            }
            MessageRole::Assistant if !message.tool_calls.is_empty() => {
                if !message.content.is_empty() {
                    items.push(json!({
                        "type": "message",
                        "role": "assistant",
                        "content": encode_content(&message.content, assets)?,
                    }));
                }
                for call in &message.tool_calls {
                    items.push(json!({
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.arguments.to_string(),
                    }));
                }
            }
            _ => {
                let role = match message.role {
                    MessageRole::System => "system",
                    MessageRole::Assistant => "assistant",
                    _ => "user",
                };
                items.push(json!({
                    "type": "message",
                    "role": role,
                    "content": encode_content(&message.content, assets)?,
                }));
            }
        }
    }
    Ok(items)
}

fn encode_content(content: &MessageContent, assets: &AssetStore) -> Result<Value, NodeError> {
    let parts = match content {
        MessageContent::Text(text) => return Ok(json!([{"type": "input_text", "text": text}])),
        MessageContent::Parts(parts) => parts,
    };
    let mut encoded = Vec::new();
    for part in parts {
        match part {
            ContentPart::Text { text, .. } => {
                encoded.push(json!({"type": "input_text", "text": text}))
            }
            ContentPart::Image { asset, detail } => {
                let bytes = assets.read(asset)?;
                let data = base64::engine::general_purpose::STANDARD.encode(bytes);
                let mut image = json!({
                    "type": "input_image",
                    "image_url": format!("data:{};base64,{}", asset.mime, data),
                });
                if let Some(detail) = detail {
                    image["detail"] = json!(detail);
                }
                encoded.push(image);
            }
            ContentPart::Audio {
                asset,
                mode,
                transcript,
            } => match mode {
                crate::content::AudioMode::Transcribed => encoded.push(json!({
                    "type": "input_text",
                    "text": format!(
                        "[audio transcript {}]\n{}",
                        asset.name,
                        transcript.as_deref().unwrap_or("")
                    ),
                })),
                crate::content::AudioMode::Native => {
                    let bytes = assets.read(asset)?;
                    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
                    let format = crate::provider::audio_format(&asset.mime);
                    encoded.push(json!({
                        "type": "input_audio",
                        "input_audio": {"data": data, "format": format},
                    }));
                }
            },
            ContentPart::Video { .. } => {
                return Err(NodeError::new(
                    error_codes::MODEL_UNSUPPORTED_MODALITY,
                    "Responses API has no native video input in this build; use frame extraction",
                ))
            }
            ContentPart::Document { mode, text, .. } => match mode {
                crate::content::DocumentMode::Extracted => encoded.push(json!({
                    "type": "input_text",
                    "text": text.clone().unwrap_or_default(),
                })),
                crate::content::DocumentMode::Native => {
                    let _ = &assets;
                    return Err(NodeError::new(
                        error_codes::MODEL_UNSUPPORTED_MODALITY,
                        "Responses API document input is not enabled; use text extraction",
                    ));
                }
            },
        }
    }
    Ok(Value::Array(encoded))
}

#[async_trait]
impl ChatProvider for ResponsesProvider {
    async fn complete(
        &self,
        request: ChatRequest,
        cancel: &RunControl,
        delta: &mut (dyn FnMut(String) + Send),
    ) -> Result<ChatResponse, NodeError> {
        let mut body = json!({
            "model": request.model,
            "input": encode_input(&request.messages, &self.assets)?,
            "stream": request.stream,
        });
        if let Some(temperature) = request.temperature {
            body["temperature"] = json!(temperature);
        }
        if let Some(max_tokens) = request.max_tokens {
            body["max_output_tokens"] = json!(max_tokens);
        }
        if !request.tools.is_empty() {
            let tools = request
                .tools
                .iter()
                .map(|tool| {
                    let mut function = json!({
                        "type": "function",
                        "name": tool.pointer("/function/name").and_then(Value::as_str).unwrap_or("tool"),
                        "description": tool.pointer("/function/description").and_then(Value::as_str).unwrap_or(""),
                        "parameters": tool.pointer("/function/parameters").cloned().unwrap_or_else(|| json!({"type":"object"})),
                    });
                    if let Some(name) = tool.pointer("/function/name").and_then(Value::as_str) {
                        function["name"] = json!(name);
                    }
                    function
                })
                .collect::<Vec<_>>();
            body["tools"] = Value::Array(tools);
        }
        if let Some(previous) = request.previous_response_id.as_deref() {
            body["previous_response_id"] = json!(previous);
        }
        if let Some(effort) = request.reasoning_effort.as_deref() {
            if !effort.is_empty() && effort != "none" && self.config.supports_reasoning {
                body["reasoning"] = json!({"effort": effort, "summary": "auto"});
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
            return parse_response(&value);
        }

        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut text = String::new();
        let mut reasoning = String::new();
        let mut calls: BTreeMap<String, Value> = BTreeMap::new();
        let mut call_ids_by_item: BTreeMap<String, String> = BTreeMap::new();
        let mut usage = TokenUsage::default();
        let mut response_id = None;
        let mut finish_reason = None;
        let mut saw_completed = false;
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
                if data.is_empty() || data == "[DONE]" {
                    continue;
                }
                let value: Value = serde_json::from_str(data).map_err(invalid_response)?;
                let kind = value
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                match kind {
                    "response.output_text.delta" => {
                        if let Some(chunk) = value.get("delta").and_then(Value::as_str) {
                            text.push_str(chunk);
                            delta(chunk.to_string());
                        }
                    }
                    "response.reasoning_summary_text.delta" => {
                        if let Some(chunk) = value.get("delta").and_then(Value::as_str) {
                            reasoning.push_str(chunk);
                        }
                    }
                    "response.output_item.added" | "response.output_item.done" => {
                        if let Some(item) = value.get("item") {
                            if item.get("type").and_then(Value::as_str) == Some("function_call") {
                                let key = item
                                    .get("call_id")
                                    .or_else(|| item.get("id"))
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string();
                                if let Some(item_id) = item.get("id").and_then(Value::as_str) {
                                    call_ids_by_item.insert(item_id.to_string(), key.clone());
                                }
                                calls.insert(key, item.clone());
                            }
                        }
                    }
                    "response.function_call_arguments.delta" => {
                        if let (Some(id), Some(chunk)) = (
                            value.get("item_id").and_then(Value::as_str),
                            value.get("delta").and_then(Value::as_str),
                        ) {
                            let key = call_ids_by_item
                                .get(id)
                                .cloned()
                                .unwrap_or_else(|| id.to_string());
                            let entry = calls.entry(key.clone()).or_insert_with(|| json!({}));
                            if !entry.is_object() {
                                *entry = json!({});
                            }
                            if entry.get("id").is_none() {
                                entry["id"] = json!(key);
                            }
                            let current =
                                entry.get("arguments").and_then(Value::as_str).unwrap_or("");
                            entry["arguments"] = json!(format!("{current}{chunk}"));
                        }
                    }
                    "response.completed" => {
                        saw_completed = true;
                        if let Some(response) = value.get("response") {
                            response_id = response
                                .get("id")
                                .and_then(Value::as_str)
                                .map(str::to_string);
                            finish_reason = response
                                .get("status")
                                .and_then(Value::as_str)
                                .map(str::to_string);
                            if let Some(raw) = response.get("usage") {
                                usage = parse_usage(raw);
                            }
                            if let Some(output) = response.get("output").and_then(Value::as_array) {
                                for item in output {
                                    if item.get("type").and_then(Value::as_str)
                                        == Some("function_call")
                                    {
                                        let key = item
                                            .get("call_id")
                                            .or_else(|| item.get("id"))
                                            .and_then(Value::as_str)
                                            .unwrap_or("")
                                            .to_string();
                                        calls.insert(key, item.clone());
                                    }
                                }
                            }
                        }
                    }
                    "response.failed" | "error" => {
                        let message = value
                            .pointer("/response/error/message")
                            .or_else(|| value.pointer("/error/message"))
                            .and_then(Value::as_str)
                            .unwrap_or("provider reported a failed response");
                        return Err(NodeError::new(
                            error_codes::PROVIDER_INVALID_RESPONSE,
                            message,
                        ));
                    }
                    _ => {}
                }
            }
        }
        if !saw_completed {
            return Err(NodeError::new(
                error_codes::PROVIDER_INVALID_RESPONSE,
                "Responses stream ended before response.completed",
            ));
        }
        let tool_calls = calls
            .into_values()
            .filter_map(|item| {
                let name = item.get("name").and_then(Value::as_str)?.to_string();
                let arguments = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("{}");
                let arguments = serde_json::from_str(arguments).unwrap_or_else(|_| json!({}));
                let id = item
                    .get("call_id")
                    .or_else(|| item.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                Some(ToolCall {
                    id,
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
            response_id,
        })
    }

    async fn list_models(&self) -> Result<Vec<String>, NodeError> {
        // The Responses API shares /v1/models with Chat Completions.
        let url = format!(
            "{}/models",
            self.config.base_url.trim().trim_end_matches('/')
        );
        let response = self
            .send(self.headers(self.client.get(url)), &RunControl::new())
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

fn parse_usage(raw: &Value) -> TokenUsage {
    let prompt = raw
        .get("input_tokens")
        .or_else(|| raw.get("prompt_tokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let completion = raw
        .get("output_tokens")
        .or_else(|| raw.get("completion_tokens"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    TokenUsage {
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: prompt + completion,
    }
}

fn parse_response(value: &Value) -> Result<ChatResponse, NodeError> {
    let mut text = String::new();
    let mut reasoning = String::new();
    let mut tool_calls = Vec::new();
    if let Some(output) = value.get("output").and_then(Value::as_array) {
        for item in output {
            match item.get("type").and_then(Value::as_str) {
                Some("message") => {
                    if let Some(parts) = item.get("content").and_then(Value::as_array) {
                        for part in parts {
                            if part.get("type").and_then(Value::as_str) == Some("output_text") {
                                if let Some(chunk) = part.get("text").and_then(Value::as_str) {
                                    text.push_str(chunk);
                                }
                            }
                        }
                    }
                }
                Some("function_call") => {
                    let name = item
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    let arguments = item
                        .get("arguments")
                        .and_then(Value::as_str)
                        .unwrap_or("{}");
                    tool_calls.push(ToolCall {
                        id: item
                            .get("call_id")
                            .or_else(|| item.get("id"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        name,
                        arguments: serde_json::from_str(arguments).unwrap_or_else(|_| json!({})),
                    });
                }
                Some("reasoning") => {
                    if let Some(summary) = item.get("summary").and_then(Value::as_array) {
                        for part in summary {
                            if let Some(chunk) = part.get("text").and_then(Value::as_str) {
                                reasoning.push_str(chunk);
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    Ok(ChatResponse {
        text,
        tool_calls,
        finish_reason: value
            .get("status")
            .and_then(Value::as_str)
            .map(str::to_string),
        usage: value.get("usage").map(parse_usage).unwrap_or_default(),
        reasoning: if reasoning.is_empty() {
            None
        } else {
            Some(reasoning)
        },
        response_id: value.get("id").and_then(Value::as_str).map(str::to_string),
    })
}
