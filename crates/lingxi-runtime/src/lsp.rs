//! Minimal LSP client used by the agent capability layer.
//!
//! The client speaks JSON-RPC over stdio and deliberately implements only the
//! operations the workbench needs today: initialize, diagnostics and document
//! symbols. It never uses a shell, so the command is a single executable plus
//! an argument vector. Starting a language server is authorised as a process
//! capability by the caller.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

use crate::error::{error_codes, NodeError};
use crate::workspace::Workspace;

const DIAGNOSTIC_TIMEOUT: Duration = Duration::from_secs(5);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LspDiagnostic {
    pub message: String,
    pub severity: Option<u64>,
    pub line: u64,
    pub column: u64,
    pub source: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LspSymbol {
    pub name: String,
    pub kind: u64,
    pub line: u64,
    pub column: u64,
}

#[derive(Debug, Clone)]
pub struct LspConfig {
    pub command: String,
    pub args: Vec<String>,
    pub root: PathBuf,
}

impl LspConfig {
    pub fn new(command: impl Into<String>, args: Vec<String>, root: PathBuf) -> Self {
        Self {
            command: command.into(),
            args,
            root,
        }
    }

    pub fn validate(&self) -> Result<(), NodeError> {
        if self.command.trim().is_empty() {
            return Err(NodeError::new(
                error_codes::LSP_NOT_FOUND,
                "language server command is empty",
            ));
        }
        if self.command.contains('/') || self.command.contains('\\') {
            return Err(NodeError::new(
                error_codes::LSP_NOT_FOUND,
                "language server command must be a program name, not a path",
            ));
        }
        Ok(())
    }
}

pub struct LspClient {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
    root: PathBuf,
    diagnostics: HashMap<String, Vec<LspDiagnostic>>,
}

impl LspClient {
    pub async fn spawn(config: &LspConfig) -> Result<Self, NodeError> {
        config.validate()?;
        std::fs::create_dir_all(&config.root).map_err(|error| {
            NodeError::new(
                error_codes::LSP_NOT_FOUND,
                format!("cannot create language server root: {error}"),
            )
        })?;
        let mut child = Command::new(&config.command)
            .args(&config.args)
            .current_dir(&config.root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| {
                NodeError::new(
                    error_codes::LSP_NOT_FOUND,
                    format!("cannot start language server {:?}: {error}", config.command),
                )
            })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            NodeError::new(error_codes::LSP_PROTOCOL, "language server stdin is closed")
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            NodeError::new(
                error_codes::LSP_PROTOCOL,
                "language server stdout is closed",
            )
        })?;
        let root = config
            .root
            .canonicalize()
            .unwrap_or_else(|_| config.root.clone());
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            next_id: 1,
            root,
            diagnostics: HashMap::new(),
        })
    }

    pub async fn initialize(&mut self) -> Result<Value, NodeError> {
        let params = json!({
            "processId": null,
            "clientInfo": {"name": "lingxi-agent", "version": "0.1.0"},
            "rootUri": file_uri(&self.root),
            "capabilities": {
                "textDocument": {
                    "publishDiagnostics": {"relatedInformation": false},
                    "documentSymbol": {"hierarchicalDocumentSymbolSupport": true}
                }
            }
        });
        let result = self.request("initialize", params).await?;
        self.notify("initialized", json!({})).await?;
        Ok(result)
    }

    pub async fn diagnostics(
        &mut self,
        workspace: &Workspace,
        path: &str,
    ) -> Result<Vec<LspDiagnostic>, NodeError> {
        let uri = self.open(workspace, path).await?;
        let result = timeout(DIAGNOSTIC_TIMEOUT, async {
            loop {
                let message = self.read_message().await?;
                self.observe(&message);
                if let Some(diagnostics) = self.diagnostics.get(&uri) {
                    return Ok(diagnostics.clone());
                }
            }
        })
        .await;
        match result {
            Ok(Ok(diagnostics)) => Ok(diagnostics),
            Ok(Err(error)) => Err(error),
            Err(_) => Ok(Vec::new()),
        }
    }

    pub async fn symbols(
        &mut self,
        workspace: &Workspace,
        path: &str,
    ) -> Result<Vec<LspSymbol>, NodeError> {
        self.open(workspace, path).await?;
        let result = self
            .request(
                "textDocument/documentSymbol",
                json!({"textDocument": {"uri": file_uri(&self.root.join(path))}}),
            )
            .await?;
        Ok(parse_symbols(&result))
    }

    async fn open(&mut self, workspace: &Workspace, path: &str) -> Result<String, NodeError> {
        let snapshot = workspace.read(path)?;
        let absolute = self.root.join(path);
        let uri = file_uri(&absolute);
        let language_id = language_id(path);
        self.notify(
            "textDocument/didOpen",
            json!({
                "textDocument": {
                    "uri": uri,
                    "languageId": language_id,
                    "version": 1,
                    "text": snapshot.content
                }
            }),
        )
        .await?;
        Ok(uri)
    }

    pub async fn shutdown(mut self) {
        let _ = self.request("shutdown", Value::Null).await;
        let _ = self.notify("exit", Value::Null).await;
        let _ = timeout(SHUTDOWN_TIMEOUT, self.child.wait()).await;
        let _ = self.child.start_kill();
    }

    async fn request(&mut self, method: &str, params: Value) -> Result<Value, NodeError> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
            .await?;
        loop {
            let message = self.read_message().await?;
            if message.get("id").and_then(Value::as_u64) == Some(id) {
                if let Some(error) = message.get("error") {
                    return Err(NodeError::new(
                        error_codes::LSP_PROTOCOL,
                        format!("language server rejected {method}: {error}"),
                    ));
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
            if message.get("id").is_some() && message.get("method").is_some() {
                self.answer_server_request(&message).await?;
                continue;
            }
            self.observe(&message);
        }
    }

    async fn notify(&mut self, method: &str, params: Value) -> Result<(), NodeError> {
        self.send(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .await
    }

    async fn answer_server_request(&mut self, message: &Value) -> Result<(), NodeError> {
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let response = match method {
            "workspace/configuration" => {
                let count = message
                    .pointer("/params/items")
                    .and_then(Value::as_array)
                    .map(Vec::len)
                    .unwrap_or(0);
                json!({"jsonrpc": "2.0", "id": id, "result": vec![Value::Null; count]})
            }
            "window/workDoneProgress/create" => {
                json!({"jsonrpc": "2.0", "id": id, "result": Value::Null})
            }
            _ => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": -32601, "message": format!("unsupported request {method}")}
            }),
        };
        self.send(&response).await
    }

    fn observe(&mut self, message: &Value) {
        if message.get("method").and_then(Value::as_str) != Some("textDocument/publishDiagnostics")
        {
            return;
        }
        let Some(params) = message.get("params") else {
            return;
        };
        let Some(uri) = params.get("uri").and_then(Value::as_str) else {
            return;
        };
        let diagnostics = params
            .get("diagnostics")
            .and_then(Value::as_array)
            .map(|items| items.iter().map(parse_diagnostic).collect())
            .unwrap_or_default();
        self.diagnostics.insert(uri.to_string(), diagnostics);
    }

    async fn send(&mut self, message: &Value) -> Result<(), NodeError> {
        let body = serde_json::to_vec(message)
            .map_err(|error| NodeError::new(error_codes::LSP_PROTOCOL, error.to_string()))?;
        let header = format!("Content-Length: {}\r\n\r\n", body.len());
        self.stdin
            .write_all(header.as_bytes())
            .await
            .map_err(protocol_io)?;
        self.stdin.write_all(&body).await.map_err(protocol_io)?;
        self.stdin.flush().await.map_err(protocol_io)
    }

    async fn read_message(&mut self) -> Result<Value, NodeError> {
        let mut content_length: Option<usize> = None;
        loop {
            let mut line = String::new();
            let read = self
                .stdout
                .read_line(&mut line)
                .await
                .map_err(protocol_io)?;
            if read == 0 {
                return Err(NodeError::new(
                    error_codes::LSP_PROTOCOL,
                    "language server closed its stdout",
                ));
            }
            let line = line.trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                break;
            }
            if let Some(value) = line.strip_prefix("Content-Length:") {
                content_length = value.trim().parse::<usize>().ok();
            }
        }
        let length = content_length.ok_or_else(|| {
            NodeError::new(error_codes::LSP_PROTOCOL, "missing Content-Length header")
        })?;
        let mut buffer = vec![0_u8; length];
        self.stdout
            .read_exact(&mut buffer)
            .await
            .map_err(protocol_io)?;
        serde_json::from_slice(&buffer)
            .map_err(|error| NodeError::new(error_codes::LSP_PROTOCOL, error.to_string()))
    }
}

impl Drop for LspClient {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

fn protocol_io(error: std::io::Error) -> NodeError {
    NodeError::new(
        error_codes::LSP_PROTOCOL,
        format!("language server I/O failed: {error}"),
    )
}

fn parse_diagnostic(value: &Value) -> LspDiagnostic {
    LspDiagnostic {
        message: value
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        severity: value.get("severity").and_then(Value::as_u64),
        line: value
            .pointer("/range/start/line")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        column: value
            .pointer("/range/start/character")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        source: value
            .get("source")
            .and_then(Value::as_str)
            .map(str::to_string),
    }
}

fn parse_symbols(value: &Value) -> Vec<LspSymbol> {
    let mut symbols = Vec::new();
    if let Some(items) = value.as_array() {
        for item in items {
            collect_symbol(item, &mut symbols);
        }
    }
    symbols
}

fn collect_symbol(value: &Value, symbols: &mut Vec<LspSymbol>) {
    let Some(name) = value.get("name").and_then(Value::as_str) else {
        return;
    };
    let kind = value.get("kind").and_then(Value::as_u64).unwrap_or(0);
    let range = value
        .pointer("/range/start")
        .or_else(|| value.pointer("/location/range/start"));
    let line = range
        .and_then(|start| start.get("line"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let column = range
        .and_then(|start| start.get("character"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    symbols.push(LspSymbol {
        name: name.to_string(),
        kind,
        line,
        column,
    });
    if let Some(children) = value.get("children").and_then(Value::as_array) {
        for child in children {
            collect_symbol(child, symbols);
        }
    }
}

fn language_id(path: &str) -> &'static str {
    match Path::new(path).extension().and_then(|value| value.to_str()) {
        Some("rs") => "rust",
        Some("ts") | Some("tsx") => "typescript",
        Some("js") | Some("jsx") => "javascript",
        Some("py") => "python",
        Some("go") => "go",
        Some("json") => "json",
        _ => "plaintext",
    }
}

fn file_uri(path: &Path) -> String {
    let mut encoded = String::from("file://");
    for byte in path.to_string_lossy().as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(*byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}
