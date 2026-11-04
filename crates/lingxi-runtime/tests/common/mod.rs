//! Shared harness for the protocol-level agent tests.
#![allow(dead_code)]

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use lingxi_runtime::agent_template::{standard_agent, AGENT_SUBGRAPH_ID};
use lingxi_runtime::credentials::MemoryCredentials;
use lingxi_runtime::{
    AllowAllPolicy, Engine, EventSink, InteractionBroker, InteractionDecision, InteractionRequest,
    NodeError, RunControl, RunEvent, ServiceConfig,
};
use lingxi_spec::{Edge, Position, Workflow, WorkflowNode, COMPOSITE_NODE_KIND};

pub struct MockProvider {
    child: Child,
    pub base_url: String,
}

impl Drop for MockProvider {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Python is `python3` on Unix and `python` on Windows CI images.
pub fn python_bin() -> &'static str {
    if cfg!(windows) {
        "python"
    } else {
        "python3"
    }
}

pub fn start_mock_provider() -> MockProvider {
    let script = format!(
        "{}/../../fixtures/mock-provider/server.py",
        env!("CARGO_MANIFEST_DIR")
    );
    let mut child = Command::new(python_bin())
        .arg(&script)
        .arg("--port")
        .arg("0")
        .arg("--api-key")
        .arg("test-key")
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("Python is required for the protocol fixture");
    let stdout = child.stdout.take().expect("fixture stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).expect("fixture startup line");
    let port = line
        .trim()
        .strip_prefix("LISTENING ")
        .unwrap_or_else(|| panic!("unexpected fixture output: {line:?}"))
        .parse::<u16>()
        .expect("port");
    MockProvider {
        child,
        base_url: format!("http://127.0.0.1:{port}/v1"),
    }
}

/// Test stand-in for the desktop approval UI.
pub struct ApproveAll;

#[async_trait]
impl InteractionBroker for ApproveAll {
    async fn request(
        &self,
        _request: InteractionRequest,
    ) -> Result<InteractionDecision, NodeError> {
        Ok(InteractionDecision::Approved)
    }

    fn resolve(&self, _request_id: &str, _decision: InteractionDecision) -> bool {
        true
    }
}

/// Test stand-in for a user who denies every approval prompt.
pub struct RejectAll;

#[async_trait]
impl InteractionBroker for RejectAll {
    async fn request(
        &self,
        _request: InteractionRequest,
    ) -> Result<InteractionDecision, NodeError> {
        Ok(InteractionDecision::Rejected)
    }

    fn resolve(&self, _request_id: &str, _decision: InteractionDecision) -> bool {
        true
    }
}

#[derive(Clone, Default)]
pub struct Recorder {
    events: Arc<Mutex<Vec<RunEvent>>>,
}

impl EventSink for Recorder {
    fn emit(&self, event: RunEvent) {
        self.events.lock().expect("recorder poisoned").push(event);
    }
}

impl Recorder {
    pub fn events(&self) -> Vec<RunEvent> {
        self.events.lock().expect("recorder poisoned").clone()
    }

    pub fn logs(&self) -> Vec<(Option<String>, String)> {
        self.events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::Log {
                    node_id, message, ..
                } => Some((node_id, message)),
                _ => None,
            })
            .collect()
    }

    pub fn node_starts(&self, node_id: &str) -> Vec<RunEvent> {
        self.events()
            .into_iter()
            .filter(
                |event| matches!(event, RunEvent::NodeStarted { node_id: id, .. } if id == node_id),
            )
            .collect()
    }

    pub fn finished(&self, node_id: &str) -> Option<serde_json::Map<String, serde_json::Value>> {
        self.events().into_iter().find_map(|event| match event {
            RunEvent::NodeFinished {
                node_id: id,
                outputs,
                ..
            } if id == node_id => Some(outputs.into_iter().collect()),
            _ => None,
        })
    }
}

pub fn node(id: &str, kind: &str, label: &str) -> WorkflowNode {
    let mut entry = WorkflowNode::new(id, kind, Position::default());
    entry.label = Some(label.to_string());
    entry
}

pub fn text_input(id: &str, text: &str) -> WorkflowNode {
    let mut entry = node(id, "core.text_input", "Input");
    entry
        .params
        .insert("text".into(), serde_json::Value::from(text));
    entry
}

pub fn composite(id: &str, subgraph_id: &str) -> WorkflowNode {
    let mut entry = node(id, COMPOSITE_NODE_KIND, "Agent");
    entry.subgraph_id = Some(subgraph_id.to_string());
    entry
}

pub fn log_node(id: &str, prefix: &str) -> WorkflowNode {
    let mut entry = node(id, "core.log", "Answer");
    entry
        .params
        .insert("prefix".into(), serde_json::Value::from(prefix));
    entry
}

/// Root workflow with a single standard agent and a final answer log.
pub fn agent_workflow(model: &str, provider_url: &str, stream: bool) -> Workflow {
    let mut agent = standard_agent();
    configure_agent(&mut agent, model, provider_url, stream);

    let mut workflow = Workflow::new("agent e2e");
    workflow.nodes = vec![
        text_input("input", "Calculate 128 * 256, then tell me the result."),
        composite("agent", AGENT_SUBGRAPH_ID),
        log_node("answer", "answer: "),
    ];
    workflow
        .edges
        .push(Edge::new("input", "text", "agent", "text"));
    workflow
        .edges
        .push(Edge::control("input", "text", "agent", "start"));
    workflow
        .edges
        .push(Edge::new("agent", "answer", "answer", "value"));
    workflow.subgraphs.insert(AGENT_SUBGRAPH_ID.into(), agent);
    workflow
}

pub fn configure_agent(
    agent: &mut lingxi_spec::Subgraph,
    model: &str,
    provider_url: &str,
    stream: bool,
) {
    for inner in &mut agent.workflow.nodes {
        match inner.kind.as_str() {
            "core.provider" => {
                inner
                    .params
                    .insert("baseUrl".into(), serde_json::Value::from(provider_url));
                inner
                    .params
                    .insert("credentialRef".into(), serde_json::Value::from("test-key"));
            }
            "core.model" => {
                inner
                    .params
                    .insert("model".into(), serde_json::Value::from(model));
                inner
                    .params
                    .insert("stream".into(), serde_json::Value::from(stream));
            }
            _ => {}
        }
    }
}

pub fn engine(skills_root: Option<std::path::PathBuf>) -> Engine {
    engine_with_interactions(skills_root, Arc::new(ApproveAll))
}

pub fn engine_with_interactions(
    skills_root: Option<std::path::PathBuf>,
    interactions: Arc<dyn InteractionBroker>,
) -> Engine {
    engine_with_assets(skills_root, interactions, test_assets())
}

pub fn engine_with_assets(
    skills_root: Option<std::path::PathBuf>,
    interactions: Arc<dyn InteractionBroker>,
    assets: Arc<lingxi_runtime::AssetStore>,
) -> Engine {
    Engine::with_services(
        Arc::new(lingxi_runtime::NodeRegistry::builtin()),
        Arc::new(AllowAllPolicy),
        interactions,
        ServiceConfig {
            permissions: Arc::new(lingxi_runtime::permissions::PermissionManager::new()),
            credentials: MemoryCredentials::arc(vec![(
                "test-key".to_string(),
                "test-key".to_string(),
            )]),
            skills_root,
            assets,
        },
    )
}

pub fn test_assets() -> Arc<lingxi_runtime::AssetStore> {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    let root = std::env::temp_dir().join(format!(
        "lingxi-test-assets-{}-{unique}",
        std::process::id()
    ));
    Arc::new(lingxi_runtime::AssetStore::new(root))
}

pub async fn run(
    engine: &Engine,
    workflow: &Workflow,
    run_id: &str,
) -> (Recorder, std::sync::Arc<RunControl>) {
    let recorder = Recorder::default();
    let control = RunControl::new();
    let _ = engine
        .execute(workflow, run_id, control.clone(), &recorder)
        .await;
    (recorder, control)
}

pub fn require_valid(engine: &Engine, workflow: &Workflow) {
    let report = engine.validate(workflow);
    assert!(
        report.ok,
        "workflow must be valid: {:#?}",
        report
            .issues
            .iter()
            .map(|issue| format!("{} {} {}", issue.code, issue.path, issue.message))
            .collect::<Vec<_>>()
    );
}

pub fn fixture_path(relative: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}
