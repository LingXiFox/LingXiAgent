//! Minimal MCP client: newline-delimited stdio and Streamable HTTP transports.
//!
//! Only the client side of the protocol is implemented. Connections are owned
//! by a run; every tool call is an ordinary JSON-RPC request with an id, and a
//! crashed server surfaces as a stable error instead of hanging the agent.

use std::collections::{HashMap, VecDeque};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tokio::time::timeout;

use crate::control::RunControl;
use crate::credentials::Secret;
use crate::error::{error_codes, NodeError};
use crate::tools::ToolDefinition;

pub const MCP_PROTOCOL_VERSION: &str = "2024-11-05";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpStdioConfig {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpHttpConfig {
    pub url: String,
    #[serde(default)]
    pub credential_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpTool {
    pub name: String,
    pub qualified_name: String,
    pub description: String,
    pub input_schema: Value,
}

#[async_trait]
trait Transport: Send + Sync {
    async fn request(&self, method: &str, params: Value) -> Result<Value, NodeError>;
    async fn notify(&self, method: &str, params: Value) -> Result<(), NodeError>;
    fn transport_kind(&self) -> &'static str;
}

struct StdioTransport {
    process: Mutex<Child>,
    stdin: Mutex<ChildStdin>,
    stdout: Mutex<BufReader<ChildStdout>>,
    next_id: AtomicU64,
    stderr_tail: Arc<StdMutex<VecDeque<String>>>,
}

impl StdioTransport {
    async fn spawn(config: &McpStdioConfig) -> Result<Self, NodeError> {
        if config.command.trim().is_empty() {
            return Err(NodeError::new(
                error_codes::MCP_CONNECT,
                "MCP stdio command is empty",
            ));
        }
        let mut command = Command::new(&config.command);
        command
            .args(&config.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        for (key, value) in &config.env {
            command.env(key, value);
        }
        if let Some(cwd) = &config.cwd {
            command.current_dir(cwd);
        }
        let mut child = command.spawn().map_err(|error| {
            NodeError::new(
                error_codes::MCP_CONNECT,
                format!("failed to start MCP server {:?}: {error}", config.command),
            )
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            NodeError::new(error_codes::MCP_CONNECT, "MCP server stdin is unavailable")
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            NodeError::new(error_codes::MCP_CONNECT, "MCP server stdout is unavailable")
        })?;
        let stderr_tail = Arc::new(StdMutex::new(VecDeque::new()));
        if let Some(stderr) = child.stderr.take() {
            let tail = Arc::clone(&stderr_tail);
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let mut tail = tail.lock().unwrap_or_else(|poison| poison.into_inner());
                    if tail.len() >= 20 {
                        tail.pop_front();
                    }
                    tail.push_back(line);
                }
            });
        }
        Ok(Self {
            process: Mutex::new(child),
            stdin: Mutex::new(stdin),
            stdout: Mutex::new(BufReader::new(stdout)),
            next_id: AtomicU64::new(1),
            stderr_tail,
        })
    }

    fn crash_error(&self, context: &str) -> NodeError {
        let tail = self
            .stderr_tail
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .iter()
            .cloned()
            .collect::<Vec<_>>()
            .join(" | ");
        let detail = if tail.is_empty() {
            String::new()
        } else {
            format!("; stderr: {tail}")
        };
        NodeError::new(
            error_codes::MCP_CRASHED,
            format!("MCP server {context}{detail}"),
        )
    }
}

impl Drop for StdioTransport {
    fn drop(&mut self) {
        if let Ok(mut process) = self.process.try_lock() {
            let _ = process.start_kill();
        }
    }
}

#[async_trait]
impl Transport for StdioTransport {
    async fn request(&self, method: &str, params: Value) -> Result<Value, NodeError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let message = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        {
            let mut stdin = self.stdin.lock().await;
            let mut line = serde_json::to_string(&message)
                .map_err(|error| NodeError::new(error_codes::MCP_PROTOCOL, error.to_string()))?;
            line.push('\n');
            stdin.write_all(line.as_bytes()).await.map_err(|error| {
                NodeError::new(
                    error_codes::MCP_CRASHED,
                    format!("failed to write to MCP server: {error}"),
                )
            })?;
            stdin.flush().await.map_err(|error| {
                NodeError::new(
                    error_codes::MCP_CRASHED,
                    format!("failed to flush MCP server stdin: {error}"),
                )
            })?;
        }

        let mut stdout = self.stdout.lock().await;
        loop {
            let mut line = String::new();
            let read = timeout(REQUEST_TIMEOUT, stdout.read_line(&mut line))
                .await
                .map_err(|_| {
                    NodeError::new(
                        error_codes::MCP_TIMEOUT,
                        format!("MCP request {method:?} timed out"),
                    )
                })?;
            let read = match read {
                Ok(read) => read,
                Err(error) => {
                    return Err(self
                        .crash_error(&format!("stdout failed while reading {method:?}: {error}")))
                }
            };
            if read == 0 {
                return Err(self.crash_error(&format!("exited while handling {method:?}")));
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let message: Value = serde_json::from_str(trimmed).map_err(|error| {
                NodeError::new(
                    error_codes::MCP_PROTOCOL,
                    format!("MCP server sent invalid JSON: {error}"),
                )
            })?;
            if message.get("id").and_then(Value::as_u64) != Some(id) {
                // Notifications and server-initiated requests are ignored by
                // this client. Servers we start do not call back into us.
                continue;
            }
            return parse_result(message);
        }
    }

    async fn notify(&self, method: &str, params: Value) -> Result<(), NodeError> {
        let message = json!({"jsonrpc": "2.0", "method": method, "params": params});
        let mut stdin = self.stdin.lock().await;
        let mut line = serde_json::to_string(&message)
            .map_err(|error| NodeError::new(error_codes::MCP_PROTOCOL, error.to_string()))?;
        line.push('\n');
        stdin.write_all(line.as_bytes()).await.map_err(|error| {
            NodeError::new(
                error_codes::MCP_CRASHED,
                format!("failed to notify MCP server: {error}"),
            )
        })?;
        stdin.flush().await.map_err(|error| {
            NodeError::new(
                error_codes::MCP_CRASHED,
                format!("failed to flush MCP server stdin: {error}"),
            )
        })
    }

    fn transport_kind(&self) -> &'static str {
        "stdio"
    }
}

struct HttpTransport {
    client: reqwest::Client,
    url: String,
    authorization: Option<String>,
    session: Mutex<Option<String>>,
    next_id: AtomicU64,
}

impl HttpTransport {
    fn new(url: String, secret: Option<Secret>) -> Result<Self, NodeError> {
        let parsed = reqwest::Url::parse(&url).map_err(|error| {
            NodeError::new(
                error_codes::MCP_CONNECT,
                format!("invalid MCP HTTP URL: {error}"),
            )
        })?;
        if !matches!(parsed.scheme(), "http" | "https") {
            return Err(NodeError::new(
                error_codes::MCP_CONNECT,
                "MCP HTTP URL must use http or https",
            ));
        }
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|error| NodeError::new(error_codes::MCP_CONNECT, error.to_string()))?;
        Ok(Self {
            client,
            url,
            authorization: secret.map(|secret| format!("Bearer {}", secret.expose())),
            session: Mutex::new(None),
            next_id: AtomicU64::new(1),
        })
    }

    async fn post(&self, message: &Value) -> Result<Option<Value>, NodeError> {
        let mut request = self
            .client
            .post(&self.url)
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .json(message);
        if let Some(authorization) = &self.authorization {
            request = request.header("authorization", authorization);
        }
        if let Some(session) = self.session.lock().await.clone() {
            request = request.header("mcp-session-id", session);
        }
        let response = request.send().await.map_err(|error| {
            if error.is_timeout() {
                NodeError::new(
                    error_codes::MCP_TIMEOUT,
                    format!("MCP HTTP request timed out: {error}"),
                )
            } else {
                NodeError::new(
                    error_codes::MCP_CONNECT,
                    format!("MCP HTTP request failed: {error}"),
                )
            }
        })?;
        if let Some(session) = response
            .headers()
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
        {
            *self.session.lock().await = Some(session.to_string());
        }
        if !response.status().is_success() {
            return Err(NodeError::new(
                error_codes::MCP_CONNECT,
                format!("MCP HTTP server returned {}", response.status()),
            ));
        }
        let content_type = response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
            .to_string();
        if content_type.contains("text/event-stream") {
            let body = response.text().await.map_err(|error| {
                NodeError::new(
                    error_codes::MCP_PROTOCOL,
                    format!("failed to read MCP SSE: {error}"),
                )
            })?;
            for line in body.lines() {
                let Some(data) = line.strip_prefix("data:") else {
                    continue;
                };
                let data = data.trim();
                if data.is_empty() {
                    continue;
                }
                let value: Value = serde_json::from_str(data).map_err(|error| {
                    NodeError::new(
                        error_codes::MCP_PROTOCOL,
                        format!("MCP SSE contained invalid JSON: {error}"),
                    )
                })?;
                if value.get("id").is_some() {
                    return Ok(Some(value));
                }
            }
            return Ok(None);
        }
        if response.status().as_u16() == 202 {
            return Ok(None);
        }
        let body = response.text().await.map_err(|error| {
            NodeError::new(
                error_codes::MCP_PROTOCOL,
                format!("failed to read MCP response: {error}"),
            )
        })?;
        if body.trim().is_empty() {
            return Ok(None);
        }
        serde_json::from_str(&body).map(Some).map_err(|error| {
            NodeError::new(
                error_codes::MCP_PROTOCOL,
                format!("MCP server sent invalid JSON: {error}"),
            )
        })
    }
}

#[async_trait]
impl Transport for HttpTransport {
    async fn request(&self, method: &str, params: Value) -> Result<Value, NodeError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let message = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let response = self.post(&message).await?.ok_or_else(|| {
            NodeError::new(
                error_codes::MCP_PROTOCOL,
                format!("MCP HTTP response for {method:?} had no JSON-RPC reply"),
            )
        })?;
        parse_result(response)
    }

    async fn notify(&self, method: &str, params: Value) -> Result<(), NodeError> {
        let message = json!({"jsonrpc": "2.0", "method": method, "params": params});
        self.post(&message).await?;
        Ok(())
    }

    fn transport_kind(&self) -> &'static str {
        "http"
    }
}

fn parse_result(message: Value) -> Result<Value, NodeError> {
    if let Some(error) = message.get("error") {
        let code = error.get("code").and_then(Value::as_i64).unwrap_or(0);
        let text = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown MCP error");
        return Err(NodeError::new(
            error_codes::MCP_PROTOCOL,
            format!("MCP error {code}: {text}"),
        ));
    }
    Ok(message.get("result").cloned().unwrap_or(Value::Null))
}

struct Connection {
    transport: Arc<dyn Transport>,
    tools: Vec<McpTool>,
    namespace: String,
}

#[derive(Default)]
pub struct McpManager {
    connections: StdMutex<HashMap<String, Arc<Connection>>>,
}

impl McpManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn connect_stdio(
        &self,
        handle: &str,
        namespace: &str,
        config: &McpStdioConfig,
    ) -> Result<Vec<ToolDefinition>, NodeError> {
        let transport = Arc::new(StdioTransport::spawn(config).await?);
        self.finish_connect(handle, namespace, transport).await
    }

    pub async fn connect_http(
        &self,
        handle: &str,
        namespace: &str,
        config: &McpHttpConfig,
        secret: Option<Secret>,
    ) -> Result<Vec<ToolDefinition>, NodeError> {
        let transport = Arc::new(HttpTransport::new(config.url.clone(), secret)?);
        self.finish_connect(handle, namespace, transport).await
    }

    async fn finish_connect(
        &self,
        handle: &str,
        namespace: &str,
        transport: Arc<dyn Transport>,
    ) -> Result<Vec<ToolDefinition>, NodeError> {
        let initialize = transport
            .request(
                "initialize",
                json!({
                    "protocolVersion": MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "lingxi-agent", "version": env!("CARGO_PKG_VERSION")}
                }),
            )
            .await?;
        if initialize
            .get("protocolVersion")
            .and_then(Value::as_str)
            .is_none()
        {
            return Err(NodeError::new(
                error_codes::MCP_PROTOCOL,
                "MCP initialize response is missing protocolVersion",
            ));
        }
        transport
            .notify("notifications/initialized", json!({}))
            .await?;
        let listed = transport.request("tools/list", json!({})).await?;
        let entries = listed
            .get("tools")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut tools = Vec::with_capacity(entries.len());
        let mut seen = std::collections::HashSet::new();
        for entry in entries {
            let name = entry
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if name.is_empty() || !seen.insert(name.clone()) {
                return Err(NodeError::new(
                    error_codes::MCP_PROTOCOL,
                    "MCP server returned an empty or duplicate tool name",
                ));
            }
            tools.push(McpTool {
                qualified_name: qualified_name(namespace, &name),
                name,
                description: entry
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                input_schema: entry
                    .get("inputSchema")
                    .cloned()
                    .unwrap_or_else(|| json!({"type": "object", "properties": {}})),
            });
        }
        let mut definitions = Vec::with_capacity(tools.len());
        for tool in &tools {
            definitions.push(ToolDefinition {
                name: tool.qualified_name.clone(),
                description: format!("[MCP {namespace}] {}", tool.description),
                parameters: tool.input_schema.clone(),
                capability: "mcp".to_string(),
                source: format!("mcp:{handle}"),
                timeout_ms: 30_000,
            });
        }
        let connection = Arc::new(Connection {
            transport,
            tools,
            namespace: namespace.to_string(),
        });
        self.connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .insert(handle.to_string(), connection);
        Ok(definitions)
    }

    pub fn transport_kind(&self, handle: &str) -> Option<&'static str> {
        self.connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get(handle)
            .map(|connection| connection.transport.transport_kind())
    }

    pub async fn call(
        &self,
        handle: &str,
        qualified: &str,
        arguments: Value,
        cancel: &RunControl,
    ) -> Result<Value, NodeError> {
        let connection = self
            .connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get(handle)
            .cloned()
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::MCP_CONNECT,
                    format!("MCP connection {handle:?} is not open"),
                )
            })?;
        let tool = connection
            .tools
            .iter()
            .find(|tool| tool.qualified_name == qualified)
            .cloned()
            .ok_or_else(|| {
                NodeError::new(
                    error_codes::MCP_PROTOCOL,
                    format!("MCP server has no tool {qualified:?}"),
                )
            })?;

        let request = connection.transport.request(
            "tools/call",
            json!({"name": tool.name, "arguments": arguments}),
        );
        let response = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(NodeError::cancelled("MCP tool call cancelled")),
            result = timeout(Duration::from_secs(30), request) => {
                match result {
                    Err(_) => return Err(NodeError::new(
                        error_codes::MCP_TIMEOUT,
                        format!("MCP tool {:?} timed out", tool.name),
                    )),
                    Ok(Err(error)) => return Err(error),
                    Ok(Ok(value)) => value,
                }
            }
        };

        if response.get("isError").and_then(Value::as_bool) == Some(true) {
            let text = content_text(&response);
            return Err(NodeError::new(
                error_codes::TOOL_FAILED,
                if text.is_empty() {
                    format!("MCP tool {:?} reported an error", tool.name)
                } else {
                    text
                },
            ));
        }
        Ok(json!({
            "content": response.get("content").cloned().unwrap_or(Value::Null),
            "structuredContent": response.get("structuredContent").cloned().unwrap_or(Value::Null)
        }))
    }

    pub fn disconnect(&self, handle: &str) {
        self.connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .remove(handle);
    }

    pub fn disconnect_all(&self) {
        self.connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clear();
    }

    pub fn connection_count(&self) -> usize {
        self.connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .len()
    }

    pub fn namespace(&self, handle: &str) -> Option<String> {
        self.connections
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get(handle)
            .map(|connection| connection.namespace.clone())
    }
}

fn content_text(response: &Value) -> String {
    response
        .get("content")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

pub fn qualified_name(namespace: &str, tool: &str) -> String {
    format!("mcp__{}__{tool}", sanitize(namespace))
}

pub fn sanitize(namespace: &str) -> String {
    let mut out = String::new();
    for ch in namespace.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' {
            out.push(ch.to_ascii_lowercase());
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let trimmed = out.trim_matches('_').to_string();
    if trimmed.is_empty() {
        "server".to_string()
    } else {
        trimmed
    }
}

/// Reads a warning stream without blocking. Used by tests to prove that a
/// crashed child does not leak file descriptors.
pub async fn drain_stderr(mut reader: tokio::process::ChildStderr) -> String {
    let mut buffer = String::new();
    let _ = reader.read_to_string(&mut buffer).await;
    buffer
}
