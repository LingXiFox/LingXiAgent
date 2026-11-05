//! Workspace-backed tools available to agents and tool sets.
//!
//! File mutations use the versioned workspace API. Process execution never
//! goes through a shell and only permits a small, explicit command allowlist.

use std::process::Stdio;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::process::Command;

use crate::control::RunControl;
use crate::error::{error_codes, NodeError};
use crate::tools::ToolDefinition;
use crate::workspace::Workspace;

pub const READ_FILE: &str = "read_file";
pub const WRITE_FILE: &str = "write_file";
pub const LIST_FILES: &str = "list_files";
pub const RUN_COMMAND: &str = "run_command";

const MAX_OUTPUT_BYTES: usize = 64 * 1024;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(120);

pub fn names() -> Vec<String> {
    vec![
        READ_FILE.to_string(),
        WRITE_FILE.to_string(),
        LIST_FILES.to_string(),
        RUN_COMMAND.to_string(),
    ]
}

pub fn definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: READ_FILE.to_string(),
            description: "Read a UTF-8 file inside the task workspace. Returns the content and the version required for a later write.".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {"path": {"type": "string", "minLength": 1}},
                "required": ["path"],
                "additionalProperties": false
            }),
            capability: "filesystem".to_string(),
            source: "workspace".to_string(),
            timeout_ms: 10_000,
        },
        ToolDefinition {
            name: WRITE_FILE.to_string(),
            description: "Write a UTF-8 file inside the task workspace. expectedVersion must be the version from read_file, or \"absent\" for a new file.".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "path": {"type": "string", "minLength": 1},
                    "content": {"type": "string"},
                    "expectedVersion": {"type": "string", "minLength": 1}
                },
                "required": ["path", "content", "expectedVersion"],
                "additionalProperties": false
            }),
            capability: "filesystem".to_string(),
            source: "workspace".to_string(),
            timeout_ms: 10_000,
        },
        ToolDefinition {
            name: LIST_FILES.to_string(),
            description: "List files and directories inside the task workspace.".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "additionalProperties": false
            }),
            capability: "filesystem".to_string(),
            source: "workspace".to_string(),
            timeout_ms: 10_000,
        },
        ToolDefinition {
            name: RUN_COMMAND.to_string(),
            description: "Run an allowlisted build or test command in the task workspace. No shell is used.".to_string(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "command": {"type": "string", "enum": ["cargo", "npm", "pnpm", "node", "python3", "python", "pytest"]},
                    "args": {"type": "array", "items": {"type": "string"}},
                    "cwd": {"type": "string"}
                },
                "required": ["command"],
                "additionalProperties": false
            }),
            capability: "process".to_string(),
            source: "workspace".to_string(),
            timeout_ms: 120_000,
        },
    ]
}

pub fn is_workspace_tool(name: &str) -> bool {
    matches!(name, READ_FILE | WRITE_FILE | LIST_FILES | RUN_COMMAND)
}

pub fn capability(name: &str) -> &'static str {
    if name == RUN_COMMAND {
        "process"
    } else {
        "filesystem"
    }
}

pub async fn execute(
    workspace: &Workspace,
    name: &str,
    arguments: Value,
    cancel: &RunControl,
) -> Result<Value, NodeError> {
    match name {
        READ_FILE => {
            let path = required_string(&arguments, "path")?;
            let snapshot = workspace.read(&path)?;
            serde_json::to_value(snapshot).map_err(|error| {
                NodeError::new(
                    error_codes::TOOL_INVALID_ARGUMENTS,
                    format!("cannot encode file snapshot: {error}"),
                )
            })
        }
        WRITE_FILE => {
            let path = required_string(&arguments, "path")?;
            let content = arguments
                .get("content")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    NodeError::new(
                        error_codes::TOOL_INVALID_ARGUMENTS,
                        "write_file requires a string content",
                    )
                })?;
            let expected = required_string(&arguments, "expectedVersion")?;
            let snapshot = workspace.write(&path, content, &expected)?;
            Ok(json!({
                "path": snapshot.path,
                "version": snapshot.version,
                "bytes": snapshot.bytes
            }))
        }
        LIST_FILES => {
            let path = arguments
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let entries = workspace.list(&path)?;
            Ok(json!({ "entries": entries }))
        }
        RUN_COMMAND => {
            let command = required_string(&arguments, "command")?;
            let args = arguments
                .get("args")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let cwd = arguments.get("cwd").and_then(Value::as_str).unwrap_or("");
            run_command(workspace, &command, &args, cwd, cancel).await
        }
        other => Err(NodeError::new(
            error_codes::TOOL_UNKNOWN,
            format!("unknown workspace tool {other:?}"),
        )),
    }
}

fn required_string(arguments: &Value, field: &str) -> Result<String, NodeError> {
    arguments
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            NodeError::new(
                error_codes::TOOL_INVALID_ARGUMENTS,
                format!("{field} must be a non-empty string"),
            )
        })
}

async fn run_command(
    workspace: &Workspace,
    command: &str,
    args: &[String],
    cwd: &str,
    cancel: &RunControl,
) -> Result<Value, NodeError> {
    if !crate::workspace_tools::definitions()
        .into_iter()
        .find(|definition| definition.name == RUN_COMMAND)
        .and_then(|definition| definition.parameters.get("properties").cloned())
        .and_then(|properties| properties.get("command").cloned())
        .and_then(|command| command.get("enum").cloned())
        .and_then(|values| values.as_array().cloned())
        .map(|values| values.iter().any(|value| value.as_str() == Some(command)))
        .unwrap_or(false)
    {
        return Err(NodeError::new(
            error_codes::CAPABILITY_DENIED,
            format!("command {command:?} is not on the workspace allowlist"),
        ));
    }
    let working_dir = workspace.resolve(cwd)?;
    if !working_dir.is_dir() {
        return Err(NodeError::new(
            error_codes::WORKSPACE_NOT_FOUND,
            format!("working directory {cwd:?} does not exist"),
        ));
    }
    let child = Command::new(command)
        .args(args)
        .current_dir(&working_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| {
            NodeError::new(
                error_codes::TOOL_FAILED,
                format!("cannot start {command:?}: {error}"),
            )
        })?;
    let started = std::time::Instant::now();
    let output = tokio::select! {
        _ = cancel.cancelled() => {
            return Err(NodeError::cancelled("run_command cancelled"));
        }
        result = tokio::time::timeout(COMMAND_TIMEOUT, child.wait_with_output()) => {
            match result {
                Ok(Ok(output)) => output,
                Ok(Err(error)) => return Err(NodeError::new(
                    error_codes::TOOL_FAILED,
                    format!("{command:?} failed: {error}"),
                )),
                Err(_) => {
                    return Err(NodeError::new(
                        error_codes::TOOL_TIMEOUT,
                        format!("{command:?} exceeded {}s", COMMAND_TIMEOUT.as_secs()),
                    ));
                }
            }
        }
    };
    let stdout = truncate(&output.stdout);
    let stderr = truncate(&output.stderr);
    Ok(json!({
        "command": command,
        "args": args,
        "exitCode": output.status.code(),
        "ok": output.status.success(),
        "stdout": stdout,
        "stderr": stderr,
        "durationMs": started.elapsed().as_millis() as u64
    }))
}

fn truncate(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes).to_string();
    if text.len() <= MAX_OUTPUT_BYTES {
        text
    } else {
        let boundary = text
            .char_indices()
            .take_while(|(index, _)| *index <= MAX_OUTPUT_BYTES)
            .last()
            .map(|(index, _)| index)
            .unwrap_or(0);
        format!("{}… [truncated]", &text[..boundary])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::ABSENT_VERSION;

    #[tokio::test]
    async fn file_tools_require_the_read_version() {
        let root = std::env::temp_dir().join(format!("lingxi-wt-{}", uuid::Uuid::new_v4()));
        let workspace = Workspace::open(&root).unwrap();
        let control = RunControl::new();
        let written = execute(
            &workspace,
            WRITE_FILE,
            json!({"path": "a.txt", "content": "one", "expectedVersion": ABSENT_VERSION}),
            &control,
        )
        .await
        .unwrap();
        let version = written["version"].as_str().unwrap().to_string();
        let stale = execute(
            &workspace,
            WRITE_FILE,
            json!({"path": "a.txt", "content": "two", "expectedVersion": ABSENT_VERSION}),
            &control,
        )
        .await
        .unwrap_err();
        assert_eq!(stale.code, error_codes::WORKSPACE_VERSION_CONFLICT);
        execute(
            &workspace,
            WRITE_FILE,
            json!({"path": "a.txt", "content": "two", "expectedVersion": version}),
            &control,
        )
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn commands_outside_the_allowlist_are_rejected() {
        let root = std::env::temp_dir().join(format!("lingxi-wt-{}", uuid::Uuid::new_v4()));
        let workspace = Workspace::open(&root).unwrap();
        let control = RunControl::new();
        let error = execute(
            &workspace,
            RUN_COMMAND,
            json!({"command": "sh", "args": ["-c", "echo hi"]}),
            &control,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, error_codes::CAPABILITY_DENIED);
    }
}
