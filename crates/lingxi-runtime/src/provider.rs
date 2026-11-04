//! Provider-independent chat types and the OpenAI-compatible HTTP adapter.
//!
//! The scheduler only knows `ChatProvider`; vendor wire formats live behind
//! this trait. The adapter supports non-streaming and SSE streaming responses,
//! tool calls, usage accounting and cancellation.

use std::collections::BTreeMap;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::assets::AssetStore;
use crate::content::{ContentPart, MessageContent};
use crate::control::RunControl;
use crate::credentials::Secret;
use crate::error::{error_codes, NodeError};
use base64::Engine as _;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub role: MessageRole,
    #[serde(default)]
    pub content: MessageContent,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCall>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl ChatMessage {
    pub fn system(content: impl Into<String>) -> Self {
        Self::text(MessageRole::System, content)
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self::text(MessageRole::User, content)
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self::text(MessageRole::Assistant, content)
    }

    pub fn tool(tool_call_id: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: MessageRole::Tool,
            content: MessageContent::text(content),
            tool_calls: Vec::new(),
            tool_call_id: Some(tool_call_id.into()),
            name: None,
        }
    }

    pub fn text(role: MessageRole, content: impl Into<String>) -> Self {
        Self {
            role,
            content: MessageContent::text(content),
            tool_calls: Vec::new(),
            tool_call_id: None,
            name: None,
        }
    }

    pub fn with_parts(role: MessageRole, parts: Vec<ContentPart>) -> Self {
        Self {
            role,
            content: MessageContent::Parts(parts),
            tool_calls: Vec::new(),
            tool_call_id: None,
            name: None,
        }
    }

    pub fn plain_text(&self) -> String {
        self.content.plain_text()
    }
}

/// Wire protocol spoken by one provider endpoint. The node kind selects a
/// default; users can point any of the three at a compatible local gateway.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProviderProtocol {
    #[default]
    OpenAiChat,
    OpenAiResponses,
    AnthropicMessages,
}

impl ProviderProtocol {
    pub fn as_str(self) -> &'static str {
        match self {
            ProviderProtocol::OpenAiChat => "openai_chat",
            ProviderProtocol::OpenAiResponses => "openai_responses",
            ProviderProtocol::AnthropicMessages => "anthropic_messages",
        }
    }

    pub fn parse(value: &str) -> Result<Self, NodeError> {
        match value {
            "openai_chat" | "openai" | "" => Ok(Self::OpenAiChat),
            "openai_responses" | "responses" => Ok(Self::OpenAiResponses),
            "anthropic_messages" | "anthropic" => Ok(Self::AnthropicMessages),
            other => Err(NodeError::new(
                error_codes::PROVIDER_CONFIG,
                format!("unknown provider protocol {other:?}"),
            )),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ProviderProtocol::OpenAiChat => "OpenAI Chat Completions",
            ProviderProtocol::OpenAiResponses => "OpenAI Responses",
            ProviderProtocol::AnthropicMessages => "Anthropic Messages",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConfig {
    #[serde(default = "default_provider")]
    pub provider_id: String,
    pub base_url: String,
    #[serde(default)]
    pub credential_ref: String,
    #[serde(default)]
    pub organization: String,
    #[serde(default = "default_true")]
    pub supports_reasoning: bool,
    #[serde(default)]
    pub protocol: ProviderProtocol,
    /// Optional manual capability override. It is merged over the conservative
    /// built-in profile and marked with source `manual`.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub capabilities: Value,
}

fn default_provider() -> String {
    "openai".to_string()
}

fn default_true() -> bool {
    true
}

impl ProviderConfig {
    pub fn validate(&self) -> Result<(), NodeError> {
        let url = self.base_url.trim();
        if url.is_empty() {
            return Err(NodeError::new(
                error_codes::PROVIDER_CONFIG,
                "provider base URL must not be empty",
            ));
        }
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(NodeError::new(
                error_codes::PROVIDER_CONFIG,
                "provider base URL must use http or https",
            ));
        }
        Ok(())
    }

    pub fn host(&self) -> String {
        reqwest::Url::parse(self.base_url.trim())
            .ok()
            .and_then(|url| url.host_str().map(|host| host.to_string()))
            .unwrap_or_else(|| self.base_url.clone())
    }

    /// Host plus explicit port. `https` defaults to 443 and `http` to 80, so
    /// an approval for one endpoint cannot silently cover another port.
    pub fn authority(&self) -> String {
        match reqwest::Url::parse(self.base_url.trim()) {
            Ok(url) => {
                let host = url.host_str().unwrap_or_default();
                let port = url.port_or_known_default().unwrap_or(0);
                format!("{host}:{port}")
            }
            Err(_) => self.base_url.clone(),
        }
    }

    /// Stable permission target: protocol, host and port. Adapters disable
    /// automatic redirects, so a credential never crosses this boundary.
    pub fn target(&self) -> String {
        format!("{}://{}", self.protocol.as_str(), self.authority())
    }

    pub fn endpoint(&self) -> String {
        endpoint_for(&self.base_url, self.protocol)
    }
}

pub(crate) fn endpoint_for(base_url: &str, protocol: ProviderProtocol) -> String {
    let base = base_url.trim().trim_end_matches('/');
    let path = match protocol {
        ProviderProtocol::OpenAiChat => "chat/completions",
        ProviderProtocol::OpenAiResponses => "responses",
        ProviderProtocol::AnthropicMessages => "messages",
    };
    if base.ends_with(&format!("/{path}")) {
        return base.to_string();
    }
    if protocol == ProviderProtocol::AnthropicMessages && base.ends_with("/v1") {
        return format!("{base}/{path}");
    }
    if protocol == ProviderProtocol::AnthropicMessages
        && !base.ends_with("/v1")
        && !base.ends_with("/messages")
    {
        return format!("{base}/v1/{path}");
    }
    format!("{base}/{path}")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub temperature: Option<f64>,
    #[serde(default)]
    pub max_tokens: Option<u32>,
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    #[serde(default)]
    pub stream: bool,
    /// OpenAI-style tool definitions. Empty omits the field so local servers
    /// that reject unknown fields keep working.
    #[serde(default)]
    pub tools: Vec<Value>,
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
    /// Server-side Responses conversation state. When set, callers must send
    /// only the new turn, never the full local history as well.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_response_id: Option<String>,
}

fn default_timeout() -> u64 {
    60_000
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatResponse {
    pub text: String,
    pub tool_calls: Vec<ToolCall>,
    pub finish_reason: Option<String>,
    pub usage: TokenUsage,
    /// Provider-supplied reasoning summary. Never mixed into `text`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<String>,
    /// Responses API id, usable as `previous_response_id` for the next turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
}

#[async_trait]
pub trait ChatProvider: Send + Sync {
    /// Runs one completion. `delta` is called with text increments as they
    /// arrive; implementations must not call it after returning.
    async fn complete(
        &self,
        request: ChatRequest,
        cancel: &RunControl,
        delta: &mut (dyn FnMut(String) + Send),
    ) -> Result<ChatResponse, NodeError>;

    async fn list_models(&self) -> Result<Vec<String>, NodeError>;
}

#[async_trait]
pub trait ProviderFactory: Send + Sync {
    async fn create(
        &self,
        config: &ProviderConfig,
        secret: Option<Secret>,
        assets: Arc<AssetStore>,
    ) -> Result<Arc<dyn ChatProvider>, NodeError>;
}

#[derive(Debug, Clone)]
pub struct OpenAiFactory {
    client: reqwest::Client,
}

impl Default for OpenAiFactory {
    fn default() -> Self {
        Self {
            client: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(15))
                // Credentials must never follow a redirect to another origin.
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap_or_default(),
        }
    }
}

#[async_trait]
impl ProviderFactory for OpenAiFactory {
    async fn create(
        &self,
        config: &ProviderConfig,
        secret: Option<Secret>,
        assets: Arc<AssetStore>,
    ) -> Result<Arc<dyn ChatProvider>, NodeError> {
        config.validate()?;
        match config.protocol {
            ProviderProtocol::OpenAiChat => Ok(Arc::new(OpenAiProvider {
                config: config.clone(),
                secret,
                client: self.client.clone(),
                assets,
            })),
            ProviderProtocol::OpenAiResponses => {
                Ok(Arc::new(crate::responses::ResponsesProvider::new(
                    config.clone(),
                    secret,
                    self.client.clone(),
                    assets,
                )))
            }
            ProviderProtocol::AnthropicMessages => {
                Ok(Arc::new(crate::anthropic::AnthropicProvider::new(
                    config.clone(),
                    secret,
                    self.client.clone(),
                    assets,
                )))
            }
        }
    }
}

struct OpenAiProvider {
    config: ProviderConfig,
    secret: Option<Secret>,
    client: reqwest::Client,
    assets: Arc<AssetStore>,
}

impl OpenAiProvider {
    fn endpoint(&self, suffix: &str) -> String {
        if suffix == "chat/completions" {
            return self.config.endpoint();
        }
        let base = self.config.base_url.trim().trim_end_matches('/');
        if base.ends_with("/models") {
            return base.to_string();
        }
        format!("{base}/{suffix}")
    }

    fn headers(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        let builder = builder.header("content-type", "application/json");
        let builder = match &self.secret {
            Some(secret) if !secret.is_empty() => {
                builder.header("authorization", format!("Bearer {}", secret.expose()))
            }
            _ => builder,
        };
        if self.config.organization.trim().is_empty() {
            builder
        } else {
            builder.header("openai-organization", self.config.organization.trim())
        }
    }

    async fn send(
        &self,
        builder: reqwest::RequestBuilder,
        cancel: &RunControl,
    ) -> Result<reqwest::Response, NodeError> {
        let response = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(NodeError::cancelled("model request cancelled")),
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
        let message = match status.as_u16() {
            401 | 403 => "provider rejected the credential (HTTP 401/403)".to_string(),
            429 => "provider rate limit reached (HTTP 429)".to_string(),
            _ => format!("provider returned HTTP {}", status.as_u16()),
        };
        Err(NodeError::new(code, message))
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

#[async_trait]
impl ChatProvider for OpenAiProvider {
    async fn complete(
        &self,
        request: ChatRequest,
        cancel: &RunControl,
        delta: &mut (dyn FnMut(String) + Send),
    ) -> Result<ChatResponse, NodeError> {
        let mut body = json!({
            "model": request.model,
            "messages": encode_messages(&request.messages, &self.assets)?,
            "stream": request.stream,
        });
        if let Some(temperature) = request.temperature {
            body["temperature"] = json!(temperature);
        }
        if let Some(max_tokens) = request.max_tokens {
            body["max_tokens"] = json!(max_tokens);
        }
        if !request.tools.is_empty() {
            body["tools"] = Value::Array(request.tools.clone());
            body["tool_choice"] = json!("auto");
        }
        if request.stream {
            body["stream_options"] = json!({"include_usage": true});
        }
        if let Some(effort) = request.reasoning_effort.as_deref() {
            if !effort.is_empty() && effort != "none" && self.config.supports_reasoning {
                body["reasoning_effort"] = json!(effort);
            }
        }
        let builder = self
            .client
            .post(self.endpoint("chat/completions"))
            .timeout(Duration::from_millis(request.timeout_ms.max(1)))
            .json(&body);
        let response = self.send(self.headers(builder), cancel).await?;

        if !request.stream {
            let value: Value = response.json().await.map_err(invalid_response)?;
            return parse_completion(&value);
        }

        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut text = String::new();
        let mut calls: BTreeMap<u64, ToolCallBuilder> = BTreeMap::new();
        let mut finish_reason = None;
        let mut usage = TokenUsage::default();
        let mut saw_done = false;
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
                if line.is_empty() || line.starts_with(':') {
                    continue;
                }
                let Some(data) = line.strip_prefix("data:") else {
                    continue;
                };
                let data = data.trim();
                if data == "[DONE]" {
                    saw_done = true;
                    continue;
                }
                let value: Value = serde_json::from_str(data).map_err(invalid_response)?;
                if let Some(error) = value.get("error") {
                    return Err(NodeError::new(
                        error_codes::PROVIDER_INVALID_RESPONSE,
                        format!(
                            "provider stream error: {}",
                            error
                                .get("message")
                                .and_then(Value::as_str)
                                .unwrap_or("unknown error")
                        ),
                    ));
                }
                if let Some(raw_usage) = value.get("usage") {
                    usage = parse_usage(raw_usage);
                }
                let Some(choice) = value.get("choices").and_then(|c| c.get(0)) else {
                    continue;
                };
                if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
                    finish_reason = Some(reason.to_string());
                }
                if let Some(content) = choice
                    .get("delta")
                    .and_then(|d| d.get("content"))
                    .and_then(Value::as_str)
                {
                    if !content.is_empty() {
                        text.push_str(content);
                        delta(content.to_string());
                    }
                }
                if let Some(items) = choice
                    .get("delta")
                    .and_then(|d| d.get("tool_calls"))
                    .and_then(Value::as_array)
                {
                    for item in items {
                        let index = item.get("index").and_then(Value::as_u64).unwrap_or(0);
                        let entry = calls.entry(index).or_default();
                        if let Some(id) = item.get("id").and_then(Value::as_str) {
                            entry.id.push_str(id);
                        }
                        if let Some(name) = item
                            .get("function")
                            .and_then(|f| f.get("name"))
                            .and_then(Value::as_str)
                        {
                            entry.name.push_str(name);
                        }
                        if let Some(arguments) = item
                            .get("function")
                            .and_then(|f| f.get("arguments"))
                            .and_then(Value::as_str)
                        {
                            entry.arguments.push_str(arguments);
                        }
                    }
                }
            }
        }
        if !saw_done {
            return Err(NodeError::new(
                error_codes::PROVIDER_INVALID_RESPONSE,
                "provider stream ended before [DONE]",
            ));
        }
        let tool_calls = calls
            .into_values()
            .filter_map(ToolCallBuilder::finish)
            .collect();
        Ok(ChatResponse {
            text,
            tool_calls,
            finish_reason,
            usage,
            reasoning: None,
            response_id: None,
        })
    }

    async fn list_models(&self) -> Result<Vec<String>, NodeError> {
        let builder = self.client.get(self.endpoint("models"));
        let response = self.send(self.headers(builder), &RunControl::new()).await?;
        let value: Value = response.json().await.map_err(invalid_response)?;
        let mut models = value
            .get("data")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("id").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        models.sort();
        Ok(models)
    }
}

#[derive(Default)]
struct ToolCallBuilder {
    id: String,
    name: String,
    arguments: String,
}

impl ToolCallBuilder {
    fn finish(self) -> Option<ToolCall> {
        if self.name.trim().is_empty() {
            return None;
        }
        let arguments = if self.arguments.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(&self.arguments).ok()?
        };
        Some(ToolCall {
            id: if self.id.is_empty() {
                format!("call_{}", self.name)
            } else {
                self.id
            },
            name: self.name,
            arguments,
        })
    }
}

fn encode_messages(messages: &[ChatMessage], assets: &AssetStore) -> Result<Value, NodeError> {
    let mut encoded = Vec::with_capacity(messages.len());
    for message in messages {
        let mut item = json!({
            "role": match message.role {
                MessageRole::System => "system",
                MessageRole::User => "user",
                MessageRole::Assistant => "assistant",
                MessageRole::Tool => "tool",
            },
            "content": encode_content(&message.content, assets)?,
        });
        if !message.tool_calls.is_empty() {
            item["tool_calls"] = Value::Array(
                message
                    .tool_calls
                    .iter()
                    .map(|call| {
                        json!({
                            "id": call.id,
                            "type": "function",
                            "function": {
                                "name": call.name,
                                "arguments": call.arguments.to_string(),
                            }
                        })
                    })
                    .collect(),
            );
        }
        if let Some(id) = &message.tool_call_id {
            item["tool_call_id"] = json!(id);
        }
        if let Some(name) = &message.name {
            item["name"] = json!(name);
        }
        encoded.push(item);
    }
    Ok(Value::Array(encoded))
}

pub(crate) fn audio_format(mime: &str) -> String {
    match mime.rsplit('/').next().unwrap_or("wav") {
        "mpeg" | "mp3" => "mp3".to_string(),
        "x-wav" | "wave" | "wav" => "wav".to_string(),
        other => other.to_string(),
    }
}

fn encode_content(content: &MessageContent, assets: &AssetStore) -> Result<Value, NodeError> {
    let parts = match content {
        MessageContent::Text(text) => return Ok(json!(text)),
        MessageContent::Parts(parts) => parts,
    };
    let mut encoded = Vec::with_capacity(parts.len());
    for part in parts {
        match part {
            ContentPart::Text { text, .. } => encoded.push(json!({"type": "text", "text": text})),
            ContentPart::Image { asset, detail } => {
                let bytes = assets.read(asset)?;
                let data = base64::engine::general_purpose::STANDARD.encode(bytes);
                let mut image = json!({"url": format!("data:{};base64,{}", asset.mime, data)});
                if let Some(detail) = detail {
                    image["detail"] = json!(detail);
                }
                encoded.push(json!({"type": "image_url", "image_url": image}));
            }
            ContentPart::Audio {
                asset,
                mode,
                transcript,
            } => match mode {
                crate::content::AudioMode::Transcribed => encoded.push(json!({
                    "type": "text",
                    "text": format!(
                        "[audio transcript {}{}]\n{}",
                        asset.name,
                        transcript.as_deref().map(|_| "").unwrap_or(" (missing)"),
                        transcript.as_deref().unwrap_or("")
                    )
                })),
                crate::content::AudioMode::Native => {
                    let bytes = assets.read(asset)?;
                    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
                    let format = audio_format(&asset.mime);
                    encoded.push(json!({"type": "input_audio", "input_audio": {"data": data, "format": format}}));
                }
            },
            ContentPart::Video { .. } => {
                return Err(NodeError::new(
                    error_codes::MODEL_UNSUPPORTED_MODALITY,
                    "OpenAI Chat Completions has no native video input; use frame extraction",
                ))
            }
            ContentPart::Document { mode, text, .. } => {
                match mode {
                    crate::content::DocumentMode::Extracted => encoded.push(json!({
                        "type": "text",
                        "text": text.clone().unwrap_or_default()
                    })),
                    crate::content::DocumentMode::Native => return Err(NodeError::new(
                        error_codes::MODEL_UNSUPPORTED_MODALITY,
                        "OpenAI Chat Completions has no native document input; use text extraction",
                    )),
                }
            }
        }
    }
    Ok(Value::Array(encoded))
}

fn parse_completion(value: &Value) -> Result<ChatResponse, NodeError> {
    let choice = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .ok_or_else(|| {
            NodeError::new(
                error_codes::PROVIDER_INVALID_RESPONSE,
                "provider response has no choices",
            )
        })?;
    let message = choice.get("message");
    let text = message
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let mut tool_calls = Vec::new();
    if let Some(items) = message
        .and_then(|m| m.get("tool_calls"))
        .and_then(Value::as_array)
    {
        for item in items {
            let id = item
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or("call")
                .to_string();
            let name = item
                .get("function")
                .and_then(|f| f.get("name"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if name.is_empty() {
                continue;
            }
            let raw = item
                .get("function")
                .and_then(|f| f.get("arguments"))
                .and_then(Value::as_str)
                .unwrap_or("{}");
            let arguments = serde_json::from_str(raw).map_err(|error| {
                NodeError::new(
                    error_codes::PROVIDER_INVALID_RESPONSE,
                    format!("tool call arguments are not valid JSON: {error}"),
                )
            })?;
            tool_calls.push(ToolCall {
                id,
                name,
                arguments,
            });
        }
    }
    Ok(ChatResponse {
        text,
        tool_calls,
        finish_reason: choice
            .get("finish_reason")
            .and_then(Value::as_str)
            .map(str::to_string),
        usage: value.get("usage").map(parse_usage).unwrap_or_default(),
        reasoning: None,
        response_id: None,
    })
}

fn parse_usage(value: &Value) -> TokenUsage {
    TokenUsage {
        prompt_tokens: value
            .get("prompt_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        completion_tokens: value
            .get("completion_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        total_tokens: value
            .get("total_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
    }
}

fn invalid_response(error: impl std::fmt::Display) -> NodeError {
    NodeError::new(
        error_codes::PROVIDER_INVALID_RESPONSE,
        format!("provider response is not valid: {error}"),
    )
}
