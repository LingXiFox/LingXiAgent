use lingxi_spec::validation::{codes, validate};
use lingxi_spec::{
    AssetKind, AssetRef, DataType, NodeSpec, ParamSpec, Position, StaticCatalog, Workflow,
    WorkflowNode,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;

fn catalog() -> StaticCatalog {
    StaticCatalog::with([NodeSpec::new("test.image", "Image", "Input")
        .param(ParamSpec::asset("assetIds", "Images"))
        .output(lingxi_spec::PortSpec::new(
            "image",
            "Image",
            DataType::Image,
        ))])
}

fn asset_ref() -> AssetRef {
    AssetRef {
        id: format!("asset-{}", "a".repeat(64)),
        name: "pixel.png".to_string(),
        mime: "image/png".to_string(),
        size: 68,
        sha256: "a".repeat(64),
        kind: AssetKind::Image,
        source: "picker".to_string(),
        metadata: BTreeMap::new(),
    }
}

#[test]
fn asset_reference_round_trips_without_inline_bytes() {
    let mut workflow = Workflow::new("media");
    let asset = asset_ref();
    let mut node = WorkflowNode::new("image", "test.image", Position::default());
    node.params
        .insert("assetIds".into(), json!([asset.id.clone()]));
    workflow.nodes.push(node);
    workflow.assets.insert(asset.id.clone(), asset.clone());

    let document = serde_json::to_value(&workflow).expect("serialize");
    assert_eq!(document["schemaVersion"], "1.2");
    assert_eq!(document["assets"][&asset.id]["mime"], "image/png");
    assert!(document["assets"][&asset.id].get("path").is_none());
    assert!(document["assets"][&asset.id].get("data").is_none());

    let restored: Workflow = serde_json::from_value(document).expect("deserialize");
    assert_eq!(restored.assets[&asset.id], asset);
    assert_eq!(restored, workflow);
}

#[test]
fn documents_without_an_asset_table_still_load() {
    let document = json!({
        "schemaVersion": "1.1",
        "id": "wf-old",
        "name": "old",
        "nodes": [{
            "id": "n1",
            "kind": "test.image",
            "position": { "x": 0.0, "y": 0.0 }
        }],
        "edges": []
    });
    let workflow: Workflow = serde_json::from_value(document).expect("deserialize");
    assert!(workflow.assets.is_empty());
    assert!(validate(&workflow, &catalog()).ok);
}

#[test]
fn a_param_may_reference_a_declared_asset() {
    let mut workflow = Workflow::new("media");
    let asset = asset_ref();
    let mut node = WorkflowNode::new("image", "test.image", Position::default());
    node.params
        .insert("assetIds".into(), json!([asset.id.clone()]));
    workflow.nodes.push(node);
    workflow.assets.insert(asset.id.clone(), asset);

    let report = validate(&workflow, &catalog());
    assert!(report.ok, "{:?}", report.issues);
}

#[test]
fn an_unknown_asset_reference_is_rejected() {
    let mut workflow = Workflow::new("media");
    let mut node = WorkflowNode::new("image", "test.image", Position::default());
    node.params.insert("assetIds".into(), json!(["missing"]));
    workflow.nodes.push(node);

    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        report.issues.iter().any(|i| i.code == codes::ASSET_UNKNOWN),
        "{:?}",
        report.issues
    );
}

#[test]
fn an_asset_with_a_bad_digest_is_rejected() {
    let mut workflow = Workflow::new("media");
    let mut asset = asset_ref();
    asset.sha256 = "not-a-digest".to_string();
    let mut node = WorkflowNode::new("image", "test.image", Position::default());
    node.params
        .insert("assetIds".into(), Value::Array(vec![json!(asset.id)]));
    workflow.nodes.push(node);
    workflow.assets.insert(asset.id.clone(), asset);

    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        report.issues.iter().any(|i| i.code == codes::ASSET_INVALID),
        "{:?}",
        report.issues
    );
}

#[test]
fn the_asset_map_key_must_equal_the_asset_id() {
    let mut workflow = Workflow::new("media");
    workflow.assets.insert("renamed".to_string(), asset_ref());

    let report = validate(&workflow, &catalog());
    assert!(!report.ok);
    assert!(
        report.issues.iter().any(|i| i.code == codes::ASSET_INVALID),
        "{:?}",
        report.issues
    );
}
