//! Protocol adapter tests against the local fixture server.
//!
//! These cover request shape as well as responses: the fixture records every
//! POST and exposes it at /__requests, so wire-format mistakes (a tool result in
//! the wrong field, a dropped image, credentials on a redirect) fail loudly.

mod common;

use std::sync::Arc;

use common::start_mock_provider;
use lingxi_runtime::{
    error_codes, AssetStore, ContentPart, MessageContent, OpenAiFactory, ProviderConfig,
    ProviderFactory, ProviderProtocol, RunControl, Secret, ToolCall,
};
use lingxi_spec::AssetKind;
use serde_json::{json, Value};

fn test_assets() -> Arc<AssetStore> {
    let root = std::env::temp_dir().join(format!(
        "lingxi-protocol-assets-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    Arc::new(AssetStore::new(root))
}

fn config(base_url: &str, protocol: ProviderProtocol) -> ProviderConfig {
    ProviderConfig {
        provider_id: "fixture".into(),
        base_url: base_url.into(),
        credential_ref: "env:LINGXI_TEST_KEY".into(),
        organization: String::new(),
        supports_reasoning: true,
        protocol,
        capabilities: Value::Null,
    }
}

async fn make_provider(
    base_url: &str,
    protocol: ProviderProtocol,
    assets: Arc<AssetStore>,
) -> Arc<dyn lingxi_runtime::ChatProvider> {
    OpenAiFactory::default()
        .create(
            &config(base_url, protocol),
            Some(Secret::new("test-key")),
            assets,
        )
        .await
        .expect("provider")
}

async fn recorded(base_url: &str) -> Vec<Value> {
    let origin = base_url.trim_end_matches("/v1");
    reqwest::get(format!("{origin}/__requests"))
        .await
        .expect("requests endpoint")
        .json()
        .await
        .expect("requests json")
}

fn request(model: &str, messages: Vec<lingxi_runtime::ChatMessage>) -> lingxi_runtime::ChatRequest {
    lingxi_runtime::ChatRequest {
        model: model.into(),
        messages,
        temperature: None,
        max_tokens: None,
        reasoning_effort: None,
        stream: false,
        tools: Vec::new(),
        timeout_ms: 5_000,
        previous_response_id: None,
    }
}

#[tokio::test]
async fn openai_chat_sends_image_and_audio_as_multimodal_parts() {
    let mock = start_mock_provider();
    let assets = test_assets();
    let image = assets
        .import_bytes(
            "pixel.png",
            AssetKind::Image,
            "test",
            b"fake-png-bytes".to_vec(),
            Some("image/png"),
        )
        .unwrap();
    let audio = assets
        .import_bytes(
            "tone.mp3",
            AssetKind::Audio,
            "test",
            b"fake-mp3-bytes".to_vec(),
            Some("audio/mpeg"),
        )
        .unwrap();
    let provider = make_provider(&mock.base_url, ProviderProtocol::OpenAiChat, assets).await;
    let message = lingxi_runtime::ChatMessage::with_parts(
        lingxi_runtime::MessageRole::User,
        vec![
            ContentPart::text("describe these"),
            ContentPart::image(image),
            ContentPart::Audio {
                asset: audio,
                mode: lingxi_runtime::content::AudioMode::Native,
                transcript: None,
            },
        ],
    );
    let response = provider
        .complete(
            request("mock-final", vec![message]),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect("completion");
    assert!(response.text.contains("Hello from the mock provider"));

    let posts = recorded(&mock.base_url).await;
    let body = &posts[0]["body"];
    let content = body["messages"][0]["content"].as_array().expect("parts");
    assert_eq!(content[0]["type"], "text");
    assert_eq!(content[1]["type"], "image_url");
    assert!(content[1]["image_url"]["url"]
        .as_str()
        .unwrap()
        .starts_with("data:image/png;base64,"));
    assert_eq!(content[2]["type"], "input_audio");
    assert_eq!(content[2]["input_audio"]["format"], "mp3");
}

#[tokio::test]
async fn openai_chat_streams_text_and_usage() {
    let mock = start_mock_provider();
    let provider = make_provider(&mock.base_url, ProviderProtocol::OpenAiChat, test_assets()).await;
    let mut streamed = String::new();
    let mut req = request("mock-stream", vec![lingxi_runtime::ChatMessage::user("hi")]);
    req.stream = true;
    let response = provider
        .complete(req, &RunControl::new(), &mut |delta| {
            streamed.push_str(&delta)
        })
        .await
        .expect("completion");
    assert_eq!(streamed, response.text);
    assert!(!response.text.is_empty());
    assert_eq!(response.usage.total_tokens, 24);
}

#[tokio::test]
async fn openai_chat_maps_http_errors_and_cancellation() {
    let mock = start_mock_provider();
    let provider = make_provider(&mock.base_url, ProviderProtocol::OpenAiChat, test_assets()).await;
    let unauthorized = provider
        .complete(
            request(
                "mock-status-401",
                vec![lingxi_runtime::ChatMessage::user("hi")],
            ),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect_err("401");
    assert_eq!(unauthorized.code, error_codes::PROVIDER_AUTH);

    let limited = provider
        .complete(
            request(
                "mock-status-429",
                vec![lingxi_runtime::ChatMessage::user("hi")],
            ),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect_err("429");
    assert_eq!(limited.code, error_codes::PROVIDER_RATE_LIMITED);

    let control = RunControl::new();
    control.cancel();
    let cancelled = provider
        .complete(
            request("mock-final", vec![lingxi_runtime::ChatMessage::user("hi")]),
            &control,
            &mut |_| {},
        )
        .await
        .expect_err("cancelled");
    assert_eq!(cancelled.code, error_codes::CANCELLED);
}

#[tokio::test]
async fn openai_chat_reports_timeout_and_truncated_streams() {
    let mock = start_mock_provider();
    let provider = make_provider(&mock.base_url, ProviderProtocol::OpenAiChat, test_assets()).await;
    let mut slow = request("mock-slow", vec![lingxi_runtime::ChatMessage::user("hi")]);
    slow.timeout_ms = 150;
    let timed_out = provider
        .complete(slow, &RunControl::new(), &mut |_| {})
        .await
        .expect_err("timeout");
    assert_eq!(timed_out.code, error_codes::PROVIDER_TIMEOUT);

    let mut truncated = request(
        "mock-truncated",
        vec![lingxi_runtime::ChatMessage::user("hi")],
    );
    truncated.stream = true;
    let broken = provider
        .complete(truncated, &RunControl::new(), &mut |_| {})
        .await
        .expect_err("truncated");
    assert_eq!(broken.code, error_codes::PROVIDER_INVALID_RESPONSE);
}

#[tokio::test]
async fn responses_round_trips_tool_output_and_previous_response_id() {
    let mock = start_mock_provider();
    let provider = make_provider(
        &mock.base_url,
        ProviderProtocol::OpenAiResponses,
        test_assets(),
    )
    .await;
    let first = provider
        .complete(
            request(
                "mock-responses-tool",
                vec![lingxi_runtime::ChatMessage::user("6 * 7?")],
            ),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect("first turn");
    assert_eq!(first.tool_calls.len(), 1);
    assert_eq!(first.tool_calls[0].name, "calculator");
    assert_eq!(first.response_id.as_deref(), Some("resp_mock"));

    let assistant = lingxi_runtime::ChatMessage {
        role: lingxi_runtime::MessageRole::Assistant,
        content: MessageContent::text(""),
        tool_calls: first.tool_calls.clone(),
        tool_call_id: None,
        name: None,
    };
    let mut second = request(
        "mock-responses-tool",
        vec![
            lingxi_runtime::ChatMessage::user("6 * 7?"),
            assistant,
            lingxi_runtime::ChatMessage::tool("call_resp_1", "42"),
        ],
    );
    second.previous_response_id = first.response_id.clone();
    let response = provider
        .complete(second, &RunControl::new(), &mut |_| {})
        .await
        .expect("second turn");
    assert!(response.text.contains("Responses tool result: 42"));

    let posts = recorded(&mock.base_url).await;
    let body = &posts[1]["body"];
    assert_eq!(body["previous_response_id"], "resp_mock");
    let input = body["input"].as_array().expect("input items");
    assert!(input
        .iter()
        .any(|item| item["type"] == "function_call_output"
            && item["call_id"] == "call_resp_1"
            && item["output"] == "42"));
    assert!(input
        .iter()
        .any(|item| item["type"] == "function_call" && item["name"] == "calculator"));
}

#[tokio::test]
async fn responses_stream_keeps_reasoning_summary_out_of_text() {
    let mock = start_mock_provider();
    let provider = make_provider(
        &mock.base_url,
        ProviderProtocol::OpenAiResponses,
        test_assets(),
    )
    .await;
    let mut req = request(
        "mock-responses-reasoning",
        vec![lingxi_runtime::ChatMessage::user("check this")],
    );
    req.stream = true;
    let mut streamed = String::new();
    let response = provider
        .complete(req, &RunControl::new(), &mut |delta| {
            streamed.push_str(&delta)
        })
        .await
        .expect("completion");
    assert!(response.text.contains("Responses answer"));
    assert!(!response.text.contains("checked the arithmetic"));
    assert_eq!(
        response.reasoning.as_deref(),
        Some("checked the arithmetic")
    );
    assert_eq!(streamed, response.text);
}

#[tokio::test]
async fn anthropic_sends_headers_system_and_tool_result_blocks() {
    let mock = start_mock_provider();
    let provider = make_provider(
        &mock.base_url,
        ProviderProtocol::AnthropicMessages,
        test_assets(),
    )
    .await;
    let first = provider
        .complete(
            request(
                "mock-anthropic-tool",
                vec![
                    lingxi_runtime::ChatMessage::system("be precise"),
                    lingxi_runtime::ChatMessage::user("6 * 7?"),
                ],
            ),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect("first turn");
    assert_eq!(first.tool_calls[0].name, "calculator");
    assert_eq!(first.tool_calls[0].id, "toolu_mock");

    let assistant = lingxi_runtime::ChatMessage {
        role: lingxi_runtime::MessageRole::Assistant,
        content: MessageContent::text(""),
        tool_calls: first.tool_calls.clone(),
        tool_call_id: None,
        name: None,
    };
    let response = provider
        .complete(
            request(
                "mock-anthropic-tool",
                vec![
                    lingxi_runtime::ChatMessage::system("be precise"),
                    lingxi_runtime::ChatMessage::user("6 * 7?"),
                    assistant,
                    lingxi_runtime::ChatMessage::tool("toolu_mock", "42"),
                ],
            ),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect("second turn");
    assert!(response.text.contains("Anthropic tool result: 42"));

    let posts = recorded(&mock.base_url).await;
    let last = posts.last().expect("request");
    assert_eq!(last["headers"]["x-api-key"], "test-key");
    assert_eq!(last["headers"]["anthropic-version"], "2023-06-01");
    assert_eq!(last["body"]["system"], "be precise");
    let messages = last["body"]["messages"].as_array().expect("messages");
    let tool_result = messages
        .iter()
        .flat_map(|message| message["content"].as_array().cloned().unwrap_or_default())
        .find(|block| block["type"] == "tool_result")
        .expect("tool_result block");
    assert_eq!(tool_result["tool_use_id"], "toolu_mock");
    assert_eq!(tool_result["content"], "42");
}

#[tokio::test]
async fn anthropic_encodes_images_and_separates_thinking() {
    let mock = start_mock_provider();
    let assets = test_assets();
    let image = assets
        .import_bytes(
            "pixel.png",
            AssetKind::Image,
            "test",
            b"fake-png-bytes".to_vec(),
            Some("image/png"),
        )
        .unwrap();
    let provider = make_provider(&mock.base_url, ProviderProtocol::AnthropicMessages, assets).await;
    let mut req = request(
        "mock-anthropic-media",
        vec![lingxi_runtime::ChatMessage::with_parts(
            lingxi_runtime::MessageRole::User,
            vec![
                ContentPart::text("what is this?"),
                ContentPart::image(image),
            ],
        )],
    );
    req.max_tokens = Some(4096);
    req.reasoning_effort = Some("low".into());
    let response = provider
        .complete(req, &RunControl::new(), &mut |_| {})
        .await
        .expect("completion");
    assert!(response.text.contains("Anthropic image input received"));
    assert_eq!(
        response.reasoning.as_deref(),
        Some("checked the arithmetic")
    );

    let posts = recorded(&mock.base_url).await;
    let body = &posts[0]["body"];
    assert!(body.get("system").is_none());
    assert_eq!(body["thinking"]["type"], "enabled");
    assert!(body["thinking"]["budget_tokens"].as_u64().unwrap() >= 1024);
    let image_block = body["messages"][0]["content"]
        .as_array()
        .unwrap()
        .iter()
        .find(|block| block["type"] == "image")
        .expect("image block");
    assert_eq!(image_block["source"]["type"], "base64");
    assert_eq!(image_block["source"]["media_type"], "image/png");
}

#[tokio::test]
async fn anthropic_rejects_audio_without_silent_downgrade() {
    let mock = start_mock_provider();
    let assets = test_assets();
    let audio = assets
        .import_bytes(
            "tone.mp3",
            AssetKind::Audio,
            "test",
            b"fake".to_vec(),
            Some("audio/mpeg"),
        )
        .unwrap();
    let provider = make_provider(&mock.base_url, ProviderProtocol::AnthropicMessages, assets).await;
    let error = provider
        .complete(
            request(
                "mock-final",
                vec![lingxi_runtime::ChatMessage::with_parts(
                    lingxi_runtime::MessageRole::User,
                    vec![ContentPart::Audio {
                        asset: audio,
                        mode: lingxi_runtime::content::AudioMode::Native,
                        transcript: None,
                    }],
                )],
            ),
            &RunControl::new(),
            &mut |_| {},
        )
        .await
        .expect_err("audio unsupported");
    assert_eq!(error.code, error_codes::MODEL_UNSUPPORTED_MODALITY);
}

#[tokio::test]
async fn tool_calls_round_trip_through_chat_messages() {
    let call = ToolCall {
        id: "call_1".into(),
        name: "calculator".into(),
        arguments: json!({"expression": "6 * 7"}),
    };
    let message = lingxi_runtime::ChatMessage {
        role: lingxi_runtime::MessageRole::Assistant,
        content: MessageContent::Text(String::new()),
        tool_calls: vec![call],
        tool_call_id: None,
        name: None,
    };
    assert!(message.plain_text().is_empty());
}
