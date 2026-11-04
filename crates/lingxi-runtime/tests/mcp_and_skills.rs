//! MCP and Skills protocol tests. Both fixtures speak real protocols over
//! real processes; only their answers are scripted.

mod common;

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};

use common::*;
use lingxi_runtime::{McpManager, McpStdioConfig, RunControl};
use lingxi_spec::{DataType, Edge, PortBinding, PortSpec, SubgraphInput};
use serde_json::json;

struct HttpMcpFixture {
    child: Child,
    url: String,
}

impl Drop for HttpMcpFixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_http_mcp() -> HttpMcpFixture {
    let script = fixture_path("fixtures/mock-mcp/server.py");
    let mut child = Command::new(python_bin())
        .arg(script)
        .arg("--http")
        .arg("--port")
        .arg("0")
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("Python is required for the MCP fixture");
    let stdout = child.stdout.take().expect("stdout");
    let mut line = String::new();
    BufReader::new(stdout)
        .read_line(&mut line)
        .expect("startup line");
    let port = line
        .trim()
        .strip_prefix("LISTENING ")
        .unwrap_or_else(|| panic!("unexpected fixture output: {line:?}"))
        .parse::<u16>()
        .expect("port");
    HttpMcpFixture {
        child,
        url: format!("http://127.0.0.1:{port}/mcp"),
    }
}

#[tokio::test]
async fn mcp_stdio_lists_and_calls_tools_over_json_rpc() {
    let manager = McpManager::new();
    let config = McpStdioConfig {
        command: python_bin().into(),
        args: vec![fixture_path("fixtures/mock-mcp/server.py")
            .display()
            .to_string()],
        env: Default::default(),
        cwd: None,
    };
    let definitions = manager
        .connect_stdio("stdio-1", "local", &config)
        .await
        .expect("stdio MCP connection");
    assert_eq!(definitions.len(), 2);
    assert!(definitions
        .iter()
        .any(|tool| tool.name == "mcp__local__echo"));
    assert_eq!(manager.transport_kind("stdio-1"), Some("stdio"));

    let result = manager
        .call(
            "stdio-1",
            "mcp__local__echo",
            json!({"text": "hello stdio"}),
            &RunControl::new(),
        )
        .await
        .expect("echo call");
    assert_eq!(result["structuredContent"]["echo"], "hello stdio");
    manager.disconnect("stdio-1");
    assert_eq!(manager.connection_count(), 0);
}

#[tokio::test]
async fn mcp_streamable_http_lists_and_calls_tools() {
    let fixture = start_http_mcp();
    let manager = McpManager::new();
    let definitions = manager
        .connect_http(
            "http-1",
            "remote",
            &lingxi_runtime::McpHttpConfig {
                url: fixture.url.clone(),
                credential_ref: None,
            },
            None,
        )
        .await
        .expect("http MCP connection");
    assert_eq!(definitions.len(), 2);
    assert!(definitions
        .iter()
        .any(|tool| tool.name == "mcp__remote__add"));
    let result = manager
        .call(
            "http-1",
            "mcp__remote__add",
            json!({"a": 20, "b": 22}),
            &RunControl::new(),
        )
        .await
        .expect("add call");
    assert_eq!(result["structuredContent"]["sum"], 42);
    assert_eq!(manager.transport_kind("http-1"), Some("http"));
}

#[tokio::test]
async fn the_agent_calls_an_mcp_tool_end_to_end() {
    let provider = start_mock_provider();
    let mut workflow = agent_workflow("mock-mcp", &provider.base_url, false);
    let agent = workflow
        .subgraphs
        .get_mut(lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID)
        .expect("agent");
    let mut mcp = lingxi_spec::WorkflowNode::new(
        "mcp",
        "core.mcp_server",
        lingxi_spec::Position { x: 40.0, y: 760.0 },
    );
    mcp.label = Some("MCP".into());
    mcp.params.insert("transport".into(), json!("stdio"));
    mcp.params.insert("namespace".into(), json!("local"));
    mcp.params.insert("command".into(), json!(python_bin()));
    mcp.params.insert(
        "args".into(),
        json!(fixture_path("fixtures/mock-mcp/server.py")
            .display()
            .to_string()),
    );
    agent.workflow.nodes.push(mcp);
    agent
        .workflow
        .edges
        .push(Edge::new("mcp", "mcp", "toolset", "mcp"));

    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-mcp").await;
    let tool = recorder
        .events()
        .into_iter()
        .find_map(|event| match event {
            lingxi_runtime::RunEvent::ToolFinished {
                tool_name,
                ok,
                result,
                ..
            } if tool_name.starts_with("mcp__") => Some((tool_name, ok, result)),
            _ => None,
        })
        .expect("MCP tool call");
    assert_eq!(tool.0, "mcp__local__echo");
    assert!(tool.1, "{}", tool.2);
    assert!(tool.2.contains("hello mcp"), "{}", tool.2);
    assert!(recorder.logs().iter().any(|(node, message)| {
        node == &Some("answer".to_string()) && message.contains("MCP tool returned")
    }));
}

#[tokio::test]
async fn the_agent_uses_skill_instructions_as_system_context() {
    let provider = start_mock_provider();
    let mut workflow = lingxi_spec::Workflow::new("skill agent");
    let mut skill = lingxi_spec::WorkflowNode::new(
        "skill",
        "core.skill",
        lingxi_spec::Position { x: 20.0, y: 160.0 },
    );
    skill.label = Some("Skill".into());
    skill.params.insert("skillId".into(), json!("text-stats"));
    workflow.nodes = vec![
        text_input("input", "Summarize this text."),
        skill,
        composite("agent", lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID),
        log_node("answer", "answer: "),
    ];
    workflow
        .edges
        .push(Edge::new("input", "text", "agent", "text"));
    workflow
        .edges
        .push(Edge::control("skill", "done", "agent", "start"));
    workflow
        .edges
        .push(Edge::new("skill", "skill", "agent", "skill"));
    workflow
        .edges
        .push(Edge::new("agent", "answer", "answer", "value"));

    let mut agent = lingxi_runtime::agent_template::standard_agent();
    configure_agent(&mut agent, "mock-skill", &provider.base_url, false);
    agent.inputs.push(SubgraphInput {
        port: PortSpec::new("skill", "Skill", DataType::Text),
        targets: vec![PortBinding::new("prompt", "skill")],
    });
    workflow.subgraphs.insert(
        lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID.into(),
        agent,
    );

    let engine = engine(Some(fixture_path("fixtures/skills")));
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-skill").await;
    let logs = recorder.logs();
    assert!(
        logs.iter()
            .any(|(node, message)| node == &Some("answer".to_string())
                && message.contains("Skill loaded: text-stats")),
        "{logs:?}"
    );
}

#[tokio::test]
async fn an_mcp_server_crash_after_discovery_surfaces_a_stable_code() {
    let manager = McpManager::new();
    let config = McpStdioConfig {
        command: python_bin().into(),
        args: vec![
            fixture_path("fixtures/mock-mcp/server.py")
                .display()
                .to_string(),
            "--crash-after-list".into(),
        ],
        env: Default::default(),
        cwd: None,
    };
    let definitions = manager
        .connect_stdio("stdio-crash", "local", &config)
        .await
        .expect("discovery still succeeds");
    assert_eq!(definitions.len(), 2);

    let error = manager
        .call(
            "stdio-crash",
            "mcp__local__echo",
            json!({"text": "unreachable"}),
            &RunControl::new(),
        )
        .await
        .expect_err("a dead server cannot answer");
    assert_eq!(error.code, "mcp.crashed", "{}", error.message);
    manager.disconnect("stdio-crash");
}
