//! End-to-end protocol tests for the standard ReAct agent composite.
//!
//! The provider is a real HTTP server speaking the OpenAI wire protocol; only
//! the answers are scripted. Nothing in the runtime or the desktop shell is
//! mocked, so the loop, tool dispatcher, context store and scheduler all run
//! for real.

mod common;

use common::*;
use lingxi_runtime::{RunEvent, RunStatus};
use lingxi_spec::Edge;

#[tokio::test]
async fn a_real_react_loop_calls_a_tool_and_returns_the_final_answer() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-calculator", &provider.base_url, false);
    let engine = engine(None);
    require_valid(&engine, &workflow);

    let recorder = Recorder::default();
    let summary = engine
        .execute(
            &workflow,
            "run-agent",
            lingxi_runtime::RunControl::new(),
            &recorder,
        )
        .await;

    let events = recorder.events();
    let tool_started = events
        .iter()
        .find_map(|event| match event {
            RunEvent::ToolStarted {
                tool_name,
                arguments,
                ..
            } => Some((tool_name.clone(), arguments.clone())),
            _ => None,
        })
        .expect("the model must request a tool");
    assert_eq!(tool_started.0, "calculator");
    assert!(tool_started.1.contains("128 * 256"), "{:?}", tool_started.1);

    let tool_finished = events
        .iter()
        .find_map(|event| match event {
            RunEvent::ToolFinished {
                ok,
                result,
                tool_name,
                ..
            } if tool_name == "calculator" => Some((*ok, result.clone())),
            _ => None,
        })
        .expect("the dispatcher must finish the tool call");
    assert!(tool_finished.0, "calculator should succeed");
    assert!(
        tool_finished.1.contains("32768"),
        "calculator result: {}",
        tool_finished.1
    );

    assert_eq!(
        recorder.node_starts("model").len(),
        2,
        "one tool turn and one final turn"
    );
    let logs = recorder.logs();
    assert!(
        logs.iter()
            .any(|(node, message)| node == &Some("log".to_string())
                && message.contains("The answer is")
                && message.contains("32768")),
        "inner final answer missing: {logs:?}"
    );
    assert!(
        logs.iter()
            .any(|(node, message)| node == &Some("answer".to_string())
                && message.contains("The answer is")
                && message.contains("32768")),
        "composite output missing: {logs:?}"
    );
    assert_eq!(summary.status, RunStatus::Completed, "{summary:?}");
}

#[tokio::test]
async fn the_agent_accepts_streamed_model_output() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-stream", &provider.base_url, true);
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-stream").await;
    let events = recorder.events();
    let deltas = events
        .iter()
        .filter(|event| matches!(event, RunEvent::ModelDelta { .. }))
        .count();
    assert!(deltas > 0, "streaming must emit model.delta events");
    let logs = recorder.logs();
    assert!(
        logs.iter()
            .any(|(node, message)| node == &Some("answer".to_string())
                && message.contains("Hello from the mock provider.")),
        "{logs:?}"
    );
    assert!(matches!(
        events.last(),
        Some(RunEvent::RunFinished {
            status: RunStatus::Completed,
            ..
        })
    ));
}

#[tokio::test]
async fn one_response_with_two_tool_calls_executes_both() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-multi-tool", &provider.base_url, false);
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-multi").await;
    let finished: Vec<(String, bool)> = recorder
        .events()
        .into_iter()
        .filter_map(|event| match event {
            RunEvent::ToolFinished { tool_name, ok, .. } => Some((tool_name, ok)),
            _ => None,
        })
        .collect();
    assert_eq!(finished.len(), 2, "{finished:?}");
    assert!(finished.iter().all(|(_, ok)| *ok));
    assert_eq!(finished[0].0, "calculator");
    assert_eq!(finished[1].0, "text_transform");
    let logs = recorder.logs();
    assert!(
        logs.iter()
            .any(|(node, message)| node == &Some("answer".to_string())
                && message.contains("Both calculations are complete.")),
        "{logs:?}"
    );
}

#[tokio::test]
async fn invalid_tool_arguments_become_a_tool_error_not_a_dead_loop() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-bad-args", &provider.base_url, false);
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-bad-args").await;
    let failed = recorder
        .events()
        .into_iter()
        .find_map(|event| match event {
            RunEvent::ToolFinished { ok, error, .. } => Some((ok, error)),
            _ => None,
        })
        .expect("tool event");
    assert!(!failed.0);
    assert!(
        failed.1.unwrap_or_default().contains("expression"),
        "error must name the invalid argument"
    );
    assert_eq!(recorder.node_starts("model").len(), 2);
    assert!(recorder.logs().iter().any(|(node, message)| {
        node == &Some("answer".to_string()) && message.contains("Tool rejected")
    }));
}

#[tokio::test]
async fn an_unknown_tool_is_reported_to_the_model_then_answered() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-unknown-tool", &provider.base_url, false);
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-unknown").await;
    let error = recorder
        .events()
        .into_iter()
        .find_map(|event| match event {
            RunEvent::ToolFinished {
                ok: false, error, ..
            } => error,
            _ => None,
        })
        .expect("unknown tool error");
    assert!(error.contains("no tool named"), "{error}");
    assert!(recorder.logs().iter().any(|(node, message)| {
        node == &Some("answer".to_string()) && message.contains("Tool was not available.")
    }));
}

#[tokio::test]
async fn repeated_tool_requests_stop_at_the_model_call_budget() {
    let provider = start_mock_provider();
    let mut workflow = agent_workflow("mock-always-tool", &provider.base_url, false);
    let agent = workflow
        .subgraphs
        .get_mut(lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID)
        .expect("agent");
    for inner in &mut agent.workflow.nodes {
        if inner.kind == "core.model" {
            inner
                .params
                .insert("maxCalls".into(), serde_json::Value::from(2));
        }
    }
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let recorder = Recorder::default();
    let summary = engine
        .execute(
            &workflow,
            "run-budget",
            lingxi_runtime::RunControl::new(),
            &recorder,
        )
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    let codes: Vec<String> = recorder
        .events()
        .into_iter()
        .filter_map(|event| match event {
            RunEvent::NodeFailed { code, .. } => Some(code),
            _ => None,
        })
        .collect();
    assert!(
        codes.iter().any(|code| code == "budget.calls_exhausted"),
        "{codes:?}"
    );
}

#[tokio::test]
async fn provider_http_errors_map_to_stable_codes() {
    let provider = start_mock_provider();
    for (model, expected) in [
        ("mock-status-401", "provider.auth"),
        ("mock-status-429", "provider.rate_limited"),
        ("mock-status-500", "provider.http"),
    ] {
        let workflow = agent_workflow(model, &provider.base_url, false);
        let engine = engine(None);
        require_valid(&engine, &workflow);
        let recorder = Recorder::default();
        let summary = engine
            .execute(
                &workflow,
                &format!("run-{model}"),
                lingxi_runtime::RunControl::new(),
                &recorder,
            )
            .await;
        assert_eq!(summary.status, RunStatus::Failed, "{model}");
        let codes: Vec<String> = recorder
            .events()
            .into_iter()
            .filter_map(|event| match event {
                RunEvent::NodeFailed { code, .. } => Some(code),
                _ => None,
            })
            .collect();
        assert!(
            codes.iter().any(|code| code == expected),
            "{model}: {codes:?}"
        );
    }
}

#[tokio::test]
async fn a_missing_credential_fails_before_the_network_call() {
    let provider = start_mock_provider();
    let mut workflow = agent_workflow("mock-final", &provider.base_url, false);
    let agent = workflow
        .subgraphs
        .get_mut(lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID)
        .expect("agent");
    for inner in &mut agent.workflow.nodes {
        if inner.kind == "core.provider" {
            inner
                .params
                .insert("credentialRef".into(), serde_json::Value::from("missing"));
        }
    }
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let recorder = Recorder::default();
    let summary = engine
        .execute(
            &workflow,
            "run-missing-key",
            lingxi_runtime::RunControl::new(),
            &recorder,
        )
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    let codes: Vec<String> = recorder
        .events()
        .into_iter()
        .filter_map(|event| match event {
            RunEvent::NodeFailed { code, .. } => Some(code),
            _ => None,
        })
        .collect();
    assert!(
        codes
            .iter()
            .any(|code| code == "provider.missing_credential"),
        "{codes:?}"
    );
}

#[tokio::test]
async fn a_slow_provider_times_out_with_a_stable_code() {
    let provider = start_mock_provider();
    let mut workflow = agent_workflow("mock-slow", &provider.base_url, false);
    let agent = workflow
        .subgraphs
        .get_mut(lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID)
        .expect("agent");
    for inner in &mut agent.workflow.nodes {
        if inner.kind == "core.model" {
            inner
                .params
                .insert("timeoutMs".into(), serde_json::Value::from(300));
        }
    }
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let recorder = Recorder::default();
    let started = std::time::Instant::now();
    let summary = engine
        .execute(
            &workflow,
            "run-timeout",
            lingxi_runtime::RunControl::new(),
            &recorder,
        )
        .await;
    assert_eq!(summary.status, RunStatus::Failed);
    assert!(started.elapsed().as_secs() < 3);
    let codes: Vec<String> = recorder
        .events()
        .into_iter()
        .filter_map(|event| match event {
            RunEvent::NodeFailed { code, .. } => Some(code),
            _ => None,
        })
        .collect();
    assert!(
        codes.iter().any(|code| code == "provider.timeout"),
        "{codes:?}"
    );
}

#[tokio::test]
async fn cancelling_during_a_model_call_finishes_as_cancelled() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-slow", &provider.base_url, false);
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let recorder = Recorder::default();
    let control = lingxi_runtime::RunControl::new();
    let canceller = control.clone();
    let task = {
        let workflow = workflow.clone();
        let recorder = recorder.clone();
        tokio::spawn(async move {
            engine
                .execute(&workflow, "run-cancel", control, &recorder)
                .await
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    canceller.cancel();
    let summary = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .expect("cancel must interrupt the provider request")
        .expect("task join");
    assert_eq!(summary.status, RunStatus::Cancelled, "{summary:?}");
    assert!(recorder.events().iter().any(|event| matches!(
        event,
        RunEvent::NodeCancelled { node_id, .. } if node_id == "model"
    )));
}

#[tokio::test]
async fn two_agent_instances_keep_contexts_and_budgets_separate() {
    let provider = start_mock_provider();
    let mut workflow = lingxi_spec::Workflow::new("two agents");
    workflow.nodes = vec![
        text_input("input-a", "First task: 128 * 256"),
        text_input("input-b", "Second task: 128 * 256"),
        composite("agent-a", lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID),
        composite("agent-b", lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID),
        log_node("answer-a", "a: "),
        log_node("answer-b", "b: "),
    ];
    workflow
        .edges
        .push(Edge::new("input-a", "text", "agent-a", "text"));
    workflow
        .edges
        .push(Edge::control("input-a", "text", "agent-a", "start"));
    workflow
        .edges
        .push(Edge::new("input-b", "text", "agent-b", "text"));
    workflow
        .edges
        .push(Edge::control("input-b", "text", "agent-b", "start"));
    workflow
        .edges
        .push(Edge::new("agent-a", "answer", "answer-a", "value"));
    workflow
        .edges
        .push(Edge::new("agent-b", "answer", "answer-b", "value"));
    let mut agent = lingxi_runtime::agent_template::standard_agent();
    configure_agent(&mut agent, "mock-calculator", &provider.base_url, false);
    workflow.subgraphs.insert(
        lingxi_runtime::agent_template::AGENT_SUBGRAPH_ID.into(),
        agent,
    );

    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-two-agents").await;

    let scopes: Vec<String> = recorder
        .events()
        .into_iter()
        .filter_map(|event| match event {
            RunEvent::NodeFinished {
                node_id,
                scope,
                outputs,
                ..
            } if node_id == "context" => {
                let handle = outputs
                    .get("handle")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default()
                    .to_string();
                Some(format!("{}:{handle}", scope[0].instance_id))
            }
            _ => None,
        })
        .collect();
    assert_eq!(scopes.len(), 2, "{scopes:?}");
    assert_ne!(scopes[0], scopes[1], "contexts must be independent");
    assert!(scopes.iter().any(|scope| scope.starts_with("agent-a:")));
    assert!(scopes.iter().any(|scope| scope.starts_with("agent-b:")));

    let logs = recorder.logs();
    for node in ["answer-a", "answer-b"] {
        assert!(
            logs.iter()
                .any(|(id, message)| id == &Some(node.to_string())
                    && message.contains("The answer is")),
            "{node}: {logs:?}"
        );
    }
}

#[tokio::test]
async fn a_truncated_provider_stream_fails_with_a_stable_code() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-truncated", &provider.base_url, true);
    let engine = engine(None);
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-truncated").await;
    let events = recorder.events();
    assert!(matches!(
        events.last(),
        Some(RunEvent::RunFinished {
            status: RunStatus::Failed,
            ..
        })
    ));
    let failed: Vec<(String, String)> = events
        .into_iter()
        .filter_map(|event| match event {
            RunEvent::NodeFailed { node_id, code, .. } => Some((node_id, code)),
            _ => None,
        })
        .collect();
    assert!(
        failed
            .iter()
            .any(|(node, code)| node == "model" && code == "provider.invalid_response"),
        "truncated stream must surface provider.invalid_response: {failed:?}"
    );
}

#[tokio::test]
async fn rejecting_network_access_fails_the_run_before_the_model_call() {
    let provider = start_mock_provider();
    let workflow = agent_workflow("mock-calculator", &provider.base_url, false);
    let engine = engine_with_interactions(None, std::sync::Arc::new(RejectAll));
    require_valid(&engine, &workflow);
    let (recorder, _) = run(&engine, &workflow, "run-denied").await;
    let events = recorder.events();
    assert!(matches!(
        events.last(),
        Some(RunEvent::RunFinished {
            status: RunStatus::Failed,
            ..
        })
    ));
    let failed = events
        .iter()
        .find_map(|event| match event {
            RunEvent::NodeFailed { node_id, code, .. } if node_id == "model" => Some(code.clone()),
            _ => None,
        })
        .expect("the model node must fail");
    assert_eq!(failed, "capability.denied");
    assert!(!events
        .iter()
        .any(|event| matches!(event, RunEvent::ModelDelta { .. })));
    assert!(!events
        .iter()
        .any(|event| matches!(event, RunEvent::ToolStarted { .. })));
}
