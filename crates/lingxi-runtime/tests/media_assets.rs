mod common;

use std::collections::BTreeMap;

use common::{engine_with_assets, run, ApproveAll};
use lingxi_runtime::{
    content::{DocumentMode, VideoMode},
    AssetStore, ContentPart, ModelCapabilities, ReasoningLevel, Support,
};
use lingxi_spec::{AssetKind, AssetRef, Edge, Position, Workflow, WorkflowNode};
use serde_json::Value;

const PIXEL_PNG: &[u8] = include_bytes!("fixtures/pixel.png");

fn store() -> AssetStore {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    AssetStore::new(std::env::temp_dir().join(format!(
        "lingxi-media-assets-{}-{unique}",
        std::process::id()
    )))
}

fn placeholder_asset() -> AssetRef {
    serde_json::from_value(serde_json::json!({
        "id": format!("asset-{}", "a".repeat(64)),
        "name": "placeholder.png",
        "mime": "image/png",
        "size": 12,
        "sha256": "a".repeat(64),
        "kind": "image",
        "source": "test"
    }))
    .expect("asset fixture")
}

/// Media nodes start from a control port, so the fixture feeds them from a
/// counter. This mirrors how a real workflow drives an input node and keeps
/// the test focused on media behaviour instead of scheduler roots.
fn driven(media: WorkflowNode) -> Workflow {
    let media_id = media.id.clone();
    let mut seed = WorkflowNode::new("seed", "core.number_input", Position::default());
    seed.params.insert("value".into(), Value::from(0.0));
    let mut counter = WorkflowNode::new("driver", "core.counter", Position::default());
    counter
        .params
        .insert("threshold".into(), Value::from(100.0));
    let mut workflow = Workflow::new("media");
    workflow.nodes = vec![seed, counter, media];
    workflow
        .edges
        .push(Edge::new("seed", "number", "driver", "value"));
    workflow
        .edges
        .push(Edge::control("driver", "done", &media_id, "run"));
    workflow
}

#[test]
fn asset_store_is_content_addressed_and_rejects_unknown_ids() {
    let store = store();
    let first = store
        .import_bytes(
            "pixel.png",
            AssetKind::Image,
            "test",
            PIXEL_PNG.to_vec(),
            None,
        )
        .expect("import");
    let second = store
        .import_bytes(
            "copy.png",
            AssetKind::Image,
            "test",
            PIXEL_PNG.to_vec(),
            None,
        )
        .expect("import duplicate bytes");
    assert_eq!(first.id, second.id, "identical bytes share one asset id");
    assert_eq!(store.read(&first).expect("read"), PIXEL_PNG);
    assert_eq!(store.read_by_id(&first.id).expect("read by id"), PIXEL_PNG);
    assert_eq!(
        store.read_by_id("asset-not-a-digest").unwrap_err().code,
        lingxi_runtime::error_codes::ASSET_INVALID
    );
    assert_eq!(
        store
            .read_by_id(&format!("asset-{}", "0".repeat(64)))
            .unwrap_err()
            .code,
        lingxi_runtime::error_codes::ASSET_MISSING
    );
}

#[test]
fn model_capabilities_refuse_unproven_modalities() {
    let anthropic = ModelCapabilities::infer("anthropic_messages", "claude-sonnet-4-5");
    assert_eq!(anthropic.input.document, Support::Native);
    assert_eq!(anthropic.input.audio, Support::Preprocessed);
    assert_eq!(anthropic.input.video, Support::Preprocessed);

    let local = ModelCapabilities::infer("openai_chat", "local-llama");
    assert_eq!(local.input.image, Support::Unknown);
    let rejected = local
        .check_parts(&[ContentPart::image(placeholder_asset())])
        .expect_err("unknown image support must fail closed");
    assert_eq!(
        rejected.code,
        lingxi_runtime::error_codes::MODEL_UNKNOWN_CAPABILITY
    );

    let frames = ModelCapabilities::infer("openai_chat", "gpt-4o");
    frames
        .check_parts(&[ContentPart::Video {
            asset: placeholder_asset(),
            mode: VideoMode::Frames,
            frames: vec![],
            time_range: None,
        }])
        .expect("frame extraction degrades to image input");
    assert_eq!(
        frames
            .check_reasoning(ReasoningLevel::High)
            .unwrap_err()
            .code,
        lingxi_runtime::error_codes::MODEL_UNSUPPORTED_REASONING
    );
}

#[tokio::test]
async fn image_input_node_emits_multimodal_parts_for_a_real_file() {
    let store = store();
    let asset = store
        .import_bytes(
            "pixel.png",
            AssetKind::Image,
            "test",
            PIXEL_PNG.to_vec(),
            None,
        )
        .expect("import");
    let mut node = WorkflowNode::new(
        "image",
        lingxi_runtime::media::IMAGE_KIND,
        Position::default(),
    );
    node.params
        .insert("assets".into(), Value::from(vec![asset.id.clone()]));
    let mut assets = BTreeMap::new();
    assets.insert(asset.id.clone(), asset);
    let mut workflow = driven(node);
    workflow.assets = assets;

    let engine = engine_with_assets(
        None,
        std::sync::Arc::new(ApproveAll),
        std::sync::Arc::new(store),
    );
    common::require_valid(&engine, &workflow);
    let (recorder, _control) = run(&engine, &workflow, "run-image").await;
    let outputs = recorder.finished("image").unwrap_or_else(|| {
        for event in recorder.events() {
            match event {
                lingxi_runtime::RunEvent::NodeFailed {
                    node_id,
                    code,
                    message,
                    ..
                } => println!("FAIL {node_id} {code} {message}"),
                lingxi_runtime::RunEvent::RunFinished { status, detail, .. } => {
                    println!("RUN {status:?} {detail:?}")
                }
                _ => {}
            }
        }
        panic!("image node finished")
    });
    let parts: Vec<ContentPart> = serde_json::from_value(outputs["parts"].clone()).expect("parts");
    assert_eq!(parts.len(), 1);
    assert!(
        matches!(&parts[0], ContentPart::Image { asset, .. } if asset.id == asset_id(&outputs))
    );
    assert_eq!(outputs["count"].as_u64(), Some(1));
    assert!(outputs["summary"]
        .as_str()
        .unwrap_or_default()
        .contains("pixel.png"));
}

fn asset_id(outputs: &serde_json::Map<String, Value>) -> String {
    outputs["images"]
        .as_array()
        .and_then(|items| items.first())
        .and_then(Value::as_str)
        .expect("image output carries its asset id")
        .to_string()
}

#[tokio::test]
async fn document_input_node_extracts_text_with_explicit_mode() {
    let path = std::env::temp_dir().join(format!("lingxi-doc-{}.txt", std::process::id()));
    std::fs::write(&path, "first line\nsecond line").expect("write fixture");
    let store = store();
    let asset = store
        .import_path(&path, AssetKind::Document, "test")
        .expect("import document");
    let _ = std::fs::remove_file(&path);

    let mut node = WorkflowNode::new(
        "doc",
        lingxi_runtime::media::DOCUMENT_KIND,
        Position::default(),
    );
    node.params
        .insert("assets".into(), Value::from(vec![asset.id.clone()]));
    node.params.insert("mode".into(), Value::from("extracted"));
    let mut assets = BTreeMap::new();
    assets.insert(asset.id.clone(), asset);
    let mut workflow = driven(node);
    workflow.assets = assets;

    let engine = engine_with_assets(
        None,
        std::sync::Arc::new(ApproveAll),
        std::sync::Arc::new(store),
    );
    common::require_valid(&engine, &workflow);
    let (recorder, _control) = run(&engine, &workflow, "run-doc").await;
    let outputs = recorder.finished("doc").expect("document node finished");
    let parts: Vec<ContentPart> = serde_json::from_value(outputs["parts"].clone()).expect("parts");
    assert!(
        matches!(&parts[0], ContentPart::Document { mode: DocumentMode::Extracted, text: Some(text), .. } if text.contains("first line"))
    );
    assert!(outputs["text"]
        .as_str()
        .unwrap_or_default()
        .contains("second line"));
}

#[tokio::test]
async fn context_preserves_requested_media_order_before_text() {
    let store = store();
    let asset = store
        .import_bytes(
            "pixel.png",
            AssetKind::Image,
            "test",
            PIXEL_PNG.to_vec(),
            None,
        )
        .expect("import");
    let mut image = WorkflowNode::new(
        "image",
        lingxi_runtime::media::IMAGE_KIND,
        Position::default(),
    );
    image
        .params
        .insert("assets".into(), Value::from(vec![asset.id.clone()]));
    let mut text = WorkflowNode::new("text", "core.text_input", Position::default());
    text.params
        .insert("text".into(), Value::from("describe the pixels"));
    let mut prompt = WorkflowNode::new(
        "prompt",
        lingxi_runtime::agent::PROMPT_KIND,
        Position::default(),
    );
    prompt.params.insert("system".into(), Value::from("system"));
    let mut context = WorkflowNode::new(
        "ctx",
        lingxi_runtime::agent::CONTEXT_KIND,
        Position::default(),
    );
    context
        .params
        .insert("partOrder".into(), Value::from("image,text"));

    let mut workflow = driven(image);
    // One driver activation is enough to exercise ordering; the shared
    // fixture defaults to a longer loop for its own tests.
    workflow.nodes[1]
        .params
        .insert("threshold".into(), Value::from(1.0));
    // The context needs a first prompt; chain driver -> prompt -> image.
    workflow
        .edges
        .retain(|edge| !(edge.source == "driver" && edge.target == "image"));
    workflow.nodes.push(text);
    workflow.nodes.push(prompt);
    workflow.nodes.push(context);
    workflow
        .edges
        .push(Edge::new("text", "text", "prompt", "input"));
    workflow
        .edges
        .push(Edge::control("driver", "done", "prompt", "run"));
    workflow
        .edges
        .push(Edge::control("prompt", "done", "image", "run"));
    workflow
        .edges
        .push(Edge::new("prompt", "messages", "ctx", "messages"));
    workflow
        .edges
        .push(Edge::new("text", "text", "ctx", "text"));
    workflow
        .edges
        .push(Edge::new("image", "parts", "ctx", "image"));
    workflow
        .edges
        .push(Edge::control("image", "done", "ctx", "run"));
    let mut assets = BTreeMap::new();
    assets.insert(asset.id.clone(), asset);
    workflow.assets = assets;

    let engine = engine_with_assets(
        None,
        std::sync::Arc::new(ApproveAll),
        std::sync::Arc::new(store),
    );
    common::require_valid(&engine, &workflow);
    let (recorder, _control) = run(&engine, &workflow, "run-context-order").await;
    let outputs = recorder.finished("ctx").unwrap_or_else(|| {
        for event in recorder.events() {
            if let lingxi_runtime::RunEvent::NodeFailed {
                node_id,
                code,
                message,
                ..
            } = event
            {
                println!("FAIL {node_id} {code} {message}");
            }
        }
        panic!("context node finished");
    });
    let parts: Vec<ContentPart> = serde_json::from_value(outputs["parts"].clone()).expect("parts");
    assert_eq!(
        parts.len(),
        2,
        "context must emit image then text: {parts:?}"
    );
    assert!(
        matches!(&parts[0], ContentPart::Image { .. }),
        "image must come first: {parts:?}"
    );
    assert!(matches!(&parts[1], ContentPart::Text { text, .. } if text == "describe the pixels"));
}
