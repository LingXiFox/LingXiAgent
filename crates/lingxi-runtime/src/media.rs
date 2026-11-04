//! Multimodal input nodes.
//!
//! The frontend only chooses files and stores asset ids. Reading, validating,
//! extracting and frame sampling all happen here, in Rust. Protocol encoders
//! receive ContentPart values; no node ever sends a local path to a provider.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use async_trait::async_trait;
use lingxi_spec::node::DataType;
use lingxi_spec::{AssetKind, AssetRef, NodeSpec, ParamOption, ParamSpec, PortSpec};
use serde_json::{json, Value};

use crate::assets::AssetStore;
use crate::content::{AudioMode, ContentPart, DocumentMode, VideoFrame, VideoMode};
use crate::context::NodeContext;
use crate::error::{error_codes, NodeError};
use crate::event::LogLevel;
use crate::registry::{NodeExecutor, NodeOutput};

pub const IMAGE_KIND: &str = "core.input.image";
pub const AUDIO_KIND: &str = "core.input.audio";
pub const VIDEO_KIND: &str = "core.input.video";
pub const DOCUMENT_KIND: &str = "core.input.document";

const CATEGORY: &str = "Media";

pub fn register(registry: &mut crate::registry::NodeRegistry) {
    registry
        .register(image_spec(), std::sync::Arc::new(ImageInputNode))
        .expect("media node kinds are unique");
    registry
        .register(audio_spec(), std::sync::Arc::new(AudioInputNode))
        .expect("media node kinds are unique");
    registry
        .register(video_spec(), std::sync::Arc::new(VideoInputNode))
        .expect("media node kinds are unique");
    registry
        .register(document_spec(), std::sync::Arc::new(DocumentInputNode))
        .expect("media node kinds are unique");
}

fn image_spec() -> NodeSpec {
    NodeSpec::new(IMAGE_KIND, "Image Input", CATEGORY)
        .description("Selects local images and emits ordered multimodal image parts.")
        .input(control_port("run", "Run"))
        .output(json_port("parts", "Content Parts"))
        .output(json_port("images", "Image Assets"))
        .output(PortSpec::new("count", "Count", DataType::Number))
        .output(text_port("summary", "Summary"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::asset("assets", "Images"))
        .param(ParamSpec::number("maxDimension", "Max dimension (px)", 2048.0).help(
            "Larger images are resized in Rust before they are sent to the model. Use 0 to disable.",
        ))
        .param(ParamSpec::select(
            "detail",
            "Image Detail",
            "auto",
            vec![
                ParamOption::new("auto", "Auto"),
                ParamOption::new("low", "Low"),
                ParamOption::new("high", "High"),
            ],
        ))
}

fn audio_spec() -> NodeSpec {
    NodeSpec::new(AUDIO_KIND, "Audio Input", CATEGORY)
        .description("Selects local audio. Native audio is sent only to models that declare support; otherwise an explicit transcript is required.")
        .input(control_port("run", "Run"))
        .output(json_port("parts", "Content Parts"))
        .output(json_port("assets", "Audio Assets"))
        .output(PortSpec::new("count", "Count", DataType::Number))
        .output(text_port("summary", "Summary"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::asset("assets", "Audio Files"))
        .param(
            ParamSpec::select(
                "mode",
                "Audio Mode",
                "native",
                vec![
                    ParamOption::new("native", "Native audio"),
                    ParamOption::new("transcribed", "Transcript text"),
                ],
            )
            .help(
                "Transcribed mode never calls a hidden service: provide a transcript or fail explicitly.",
            ),
        )
        .param(ParamSpec::text_area("transcript", "Transcript", ""))
}

fn video_spec() -> NodeSpec {
    NodeSpec::new(VIDEO_KIND, "Video Input", CATEGORY)
        .description("Selects a local video. Frame mode extracts timestamped images with ffmpeg; native video is never faked.")
        .input(control_port("run", "Run"))
        .output(json_port("parts", "Content Parts"))
        .output(json_port("frames", "Extracted Frames"))
        .output(PortSpec::new("count", "Frame Count", DataType::Number))
        .output(text_port("summary", "Summary"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::asset("assets", "Video Files"))
        .param(ParamSpec::select(
            "mode",
            "Video Mode",
            "frames",
            vec![
                ParamOption::new("frames", "Extract frames"),
                ParamOption::new("native", "Native video"),
            ],
        ))
        .param(ParamSpec::number("frameIntervalMs", "Frame interval (ms)", 1000.0))
        .param(ParamSpec::number("maxFrames", "Max frames", 8.0))
        .param(ParamSpec::number("startMs", "Start (ms)", 0.0))
        .param(ParamSpec::number("endMs", "End (ms)", 0.0).help("0 means to the end of the clip."))
}

fn document_spec() -> NodeSpec {
    NodeSpec::new(DOCUMENT_KIND, "Document Input", CATEGORY)
        .description("Selects PDF, DOCX, TXT or Markdown. Extracted mode reports page markers and warns about lost layout.")
        .input(control_port("run", "Run"))
        .output(json_port("parts", "Content Parts"))
        .output(text_port("text", "Extracted Text"))
        .output(PortSpec::new("pages", "Pages", DataType::Number))
        .output(text_port("summary", "Summary"))
        .output(control_port("done", "Done"))
        .param(ParamSpec::asset("assets", "Documents"))
        .param(ParamSpec::select(
            "mode",
            "Document Mode",
            "extracted",
            vec![
                ParamOption::new("extracted", "Extract text"),
                ParamOption::new("native", "Native document"),
            ],
        ))
}

fn control_port(name: &str, label: &str) -> PortSpec {
    PortSpec::new(name, label, DataType::Any).control()
}

fn text_port(name: &str, label: &str) -> PortSpec {
    PortSpec::new(name, label, DataType::Text)
}

fn json_port(name: &str, label: &str) -> PortSpec {
    PortSpec::new(name, label, DataType::Json)
}

fn asset_ids(ctx: &NodeContext<'_>, param: &str) -> Result<Vec<String>, NodeError> {
    match ctx.param(param) {
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str().map(str::to_string).ok_or_else(|| {
                    NodeError::new(
                        error_codes::ASSET_INVALID,
                        format!("{param} must contain asset ids"),
                    )
                })
            })
            .collect(),
        Some(Value::Null) | None => Ok(Vec::new()),
        Some(_) => Err(NodeError::new(
            error_codes::ASSET_INVALID,
            format!("{param} must be an array of asset ids"),
        )),
    }
}

fn resolve<'a>(ctx: &'a NodeContext<'_>, id: &str) -> Result<&'a AssetRef, NodeError> {
    let asset = ctx.assets.get(id).ok_or_else(|| {
        NodeError::new(
            error_codes::ASSET_MISSING,
            format!("asset {id} is not declared in this workflow"),
        )
    })?;
    Ok(asset)
}

fn require_kind(asset: &AssetRef, kind: AssetKind) -> Result<(), NodeError> {
    if asset.kind != kind {
        return Err(NodeError::new(
            error_codes::ASSET_INVALID,
            format!(
                "asset {} is {:?}, expected {:?}",
                asset.id, asset.kind, kind
            ),
        ));
    }
    Ok(())
}

fn empty_message(kind: &str) -> NodeError {
    NodeError::new(
        error_codes::MISSING_INPUT,
        format!("select at least one {kind} asset"),
    )
}

struct ImageInputNode;

#[async_trait]
impl NodeExecutor for ImageInputNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let ids = asset_ids(ctx, "assets")?;
        if ids.is_empty() {
            return Err(empty_message("image"));
        }
        let detail = ctx.string_param("detail")?.to_string();
        let max_dimension = ctx.number_param("maxDimension")? as u32;
        let store = ctx.services.assets.as_ref();
        let mut parts = Vec::new();
        let mut images = Vec::new();
        let mut names = Vec::new();
        for id in ids {
            let asset = resolve(ctx, &id)?;
            require_kind(asset, AssetKind::Image)?;
            let path = store.path(asset)?;
            // Assets are stored content-addressed and therefore have no file
            // extension; the format must come from the file signature.
            let reader = image::ImageReader::open(&path)
                .map_err(|error| {
                    NodeError::new(
                        error_codes::ASSET_INVALID,
                        format!("cannot read image {}: {error}", asset.name),
                    )
                })?
                .with_guessed_format()
                .map_err(|error| {
                    NodeError::new(
                        error_codes::ASSET_INVALID,
                        format!("cannot read image {}: {error}", asset.name),
                    )
                })?;
            let (width, height) = reader.into_dimensions().map_err(|error| {
                NodeError::new(
                    error_codes::ASSET_INVALID,
                    format!("cannot read image {}: {error}", asset.name),
                )
            })?;
            let (provider_asset, width, height, note) =
                if max_dimension > 0 && (width > max_dimension || height > max_dimension) {
                    let resized = resize_image(store, asset, max_dimension)?;
                    (
                        resized.clone(),
                        resized_width(&resized)?,
                        resized_height(&resized)?,
                        format!("resized from {width}x{height}"),
                    )
                } else {
                    (asset.clone(), width, height, "original".to_string())
                };
            ctx.log(
                LogLevel::Info,
                format!(
                    "image {} · {}x{} · {} · {note}",
                    asset.name, width, height, asset.mime
                ),
            );
            parts.push(ContentPart::Image {
                asset: provider_asset.clone(),
                detail: Some(detail.clone()),
            });
            images.push(Value::String(provider_asset.id));
            names.push(asset.name.clone());
        }
        let count = parts.len();
        let summary = format!("{count} image(s): {}", names.join(", "));
        ctx.log(LogLevel::Info, summary.clone());
        Ok(NodeOutput::new()
            .with("parts", serde_json::to_value(&parts).unwrap_or(Value::Null))
            .with("images", Value::Array(images))
            .with("count", Value::from(count))
            .with("summary", Value::String(summary))
            .with("done", Value::Bool(true)))
    }
}

fn resized_width(asset: &AssetRef) -> Result<u32, NodeError> {
    asset
        .metadata
        .get("width")
        .and_then(Value::as_u64)
        .map(|value| value as u32)
        .ok_or_else(|| NodeError::new(error_codes::ASSET_INVALID, "derived image has no width"))
}

fn resized_height(asset: &AssetRef) -> Result<u32, NodeError> {
    asset
        .metadata
        .get("height")
        .and_then(Value::as_u64)
        .map(|value| value as u32)
        .ok_or_else(|| NodeError::new(error_codes::ASSET_INVALID, "derived image has no height"))
}

/// Resizes an image to a bounded long edge and stores the derived blob in the
/// same content-addressed store. The derived id is runtime-only; workflows keep
/// referencing the original file, so a reload is always reproducible.
fn resize_image(
    store: &AssetStore,
    asset: &AssetRef,
    max_dimension: u32,
) -> Result<AssetRef, NodeError> {
    let source = store.path(asset)?;
    let image = image::ImageReader::open(&source)
        .map_err(|error| {
            NodeError::new(
                error_codes::MEDIA_PROCESSING,
                format!("cannot decode image {}: {error}", asset.name),
            )
        })?
        .with_guessed_format()
        .map_err(|error| {
            NodeError::new(
                error_codes::MEDIA_PROCESSING,
                format!("cannot decode image {}: {error}", asset.name),
            )
        })?
        .decode()
        .map_err(|error| {
            NodeError::new(
                error_codes::MEDIA_PROCESSING,
                format!("cannot decode image {}: {error}", asset.name),
            )
        })?;
    let resized = image.resize(
        max_dimension,
        max_dimension,
        image::imageops::FilterType::Lanczos3,
    );
    let temp = store
        .root()
        .join(format!("resize-{}.png", uuid::Uuid::new_v4()));
    resized
        .save_with_format(&temp, image::ImageFormat::Png)
        .map_err(|error| {
            NodeError::new(
                error_codes::MEDIA_PROCESSING,
                format!("cannot write resized image: {error}"),
            )
        })?;
    let mut derived = store.import_path(
        &temp,
        AssetKind::Image,
        &format!("resized from {}", asset.id),
    )?;
    let _ = fs::remove_file(&temp);
    derived
        .metadata
        .insert("width".into(), json!(resized.width()));
    derived
        .metadata
        .insert("height".into(), json!(resized.height()));
    Ok(derived)
}

struct AudioInputNode;

#[async_trait]
impl NodeExecutor for AudioInputNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let ids = asset_ids(ctx, "assets")?;
        if ids.is_empty() {
            return Err(empty_message("audio"));
        }
        let mode = match ctx.string_param("mode")? {
            "native" => AudioMode::Native,
            "transcribed" => AudioMode::Transcribed,
            other => {
                return Err(NodeError::new(
                    error_codes::INVALID_PARAM,
                    format!("unknown audio mode {other:?}"),
                ))
            }
        };
        let transcript = ctx.string_param("transcript")?.trim().to_string();
        if mode == AudioMode::Transcribed && transcript.is_empty() {
            return Err(NodeError::new(
                error_codes::MEDIA_PROCESSING,
                "transcribed audio needs an explicit transcript; no hidden transcription service is configured",
            ));
        }
        let mut parts = Vec::new();
        let mut refs = Vec::new();
        let mut names = Vec::new();
        for id in ids {
            let asset = resolve(ctx, &id)?;
            require_kind(asset, AssetKind::Audio)?;
            if mode == AudioMode::Native {
                ctx.log(
                    LogLevel::Info,
                    format!("audio {} · {} · native", asset.name, asset.mime),
                );
            } else {
                ctx.log(
                    LogLevel::Warn,
                    format!("audio {} · transcript path (not native audio)", asset.name),
                );
            }
            parts.push(ContentPart::Audio {
                asset: asset.clone(),
                mode,
                transcript: (mode == AudioMode::Transcribed).then(|| transcript.clone()),
            });
            refs.push(Value::String(asset.id.clone()));
            names.push(asset.name.clone());
        }
        let count = parts.len();
        let summary = format!("{count} audio file(s): {}", names.join(", "));
        ctx.log(LogLevel::Info, summary.clone());
        Ok(NodeOutput::new()
            .with("parts", serde_json::to_value(&parts).unwrap_or(Value::Null))
            .with("assets", Value::Array(refs))
            .with("count", Value::from(count))
            .with("summary", Value::String(summary))
            .with("done", Value::Bool(true)))
    }
}

struct VideoInputNode;

#[async_trait]
impl NodeExecutor for VideoInputNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let ids = asset_ids(ctx, "assets")?;
        if ids.is_empty() {
            return Err(empty_message("video"));
        }
        let mode = match ctx.string_param("mode")? {
            "native" => VideoMode::Native,
            "frames" => VideoMode::Frames,
            other => {
                return Err(NodeError::new(
                    error_codes::INVALID_PARAM,
                    format!("unknown video mode {other:?}"),
                ))
            }
        };
        let interval = ctx.number_param("frameIntervalMs")?.max(100.0) as u64;
        let max_frames = ctx.number_param("maxFrames")?.max(1.0) as usize;
        let start = ctx.number_param("startMs")?.max(0.0) as u64;
        let end = ctx.number_param("endMs")?.max(0.0) as u64;
        let store = ctx.services.assets.clone();
        let mut parts = Vec::new();
        let mut all_frames = Vec::new();
        for id in ids {
            let asset = resolve(ctx, &id)?.clone();
            require_kind(&asset, AssetKind::Video)?;
            match mode {
                VideoMode::Native => {
                    ctx.log(
                        LogLevel::Warn,
                        format!(
                            "video {} · native mode; unsupported models reject this instead of silently downgrading",
                            asset.name
                        ),
                    );
                    parts.push(ContentPart::Video {
                        asset: asset.clone(),
                        mode,
                        frames: Vec::new(),
                        time_range: None,
                    });
                }
                VideoMode::Frames => {
                    let frames = tokio::task::spawn_blocking({
                        let store = store.clone();
                        let asset = asset.clone();
                        move || extract_frames(&store, &asset, interval, max_frames, start, end)
                    })
                    .await
                    .map_err(|error| {
                        NodeError::new(
                            error_codes::MEDIA_PROCESSING,
                            format!("frame extraction task failed: {error}"),
                        )
                    })??;
                    ctx.log(
                        LogLevel::Info,
                        format!(
                            "video {} · extracted {} frame(s) every {}ms",
                            asset.name,
                            frames.len(),
                            interval
                        ),
                    );
                    for frame in &frames {
                        all_frames.push(json!({
                            "asset": frame.asset.id,
                            "timestampMs": frame.timestamp_ms,
                        }));
                    }
                    let range = end.checked_sub(start).map(|duration| {
                        (
                            start,
                            if duration == 0 {
                                start + interval * frames.len() as u64
                            } else {
                                end
                            },
                        )
                    });
                    parts.push(ContentPart::Video {
                        asset: asset.clone(),
                        mode,
                        frames,
                        time_range: range,
                    });
                }
            }
        }
        let frame_count = all_frames.len();
        let summary = match mode {
            VideoMode::Frames => format!(
                "{} video(s) · {frame_count} frame(s), each labelled with a timestamp",
                parts.len()
            ),
            VideoMode::Native => format!(
                "{} native video(s) · capability checked before request",
                parts.len()
            ),
        };
        ctx.log(LogLevel::Info, summary.clone());
        Ok(NodeOutput::new()
            .with("parts", serde_json::to_value(&parts).unwrap_or(Value::Null))
            .with("frames", Value::Array(all_frames))
            .with("count", Value::from(frame_count))
            .with("summary", Value::String(summary))
            .with("done", Value::Bool(true)))
    }
}

fn extract_frames(
    store: &AssetStore,
    asset: &AssetRef,
    interval_ms: u64,
    max_frames: usize,
    start_ms: u64,
    end_ms: u64,
) -> Result<Vec<VideoFrame>, NodeError> {
    let input = store.path(asset)?;
    let temp = store
        .root()
        .join(format!("frames-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&temp).map_err(|error| {
        NodeError::new(
            error_codes::ASSET_IO,
            format!("cannot create frame directory: {error}"),
        )
    })?;
    let pattern = temp.join("frame-%05d.png");
    let fps = 1000.0 / interval_ms as f64;
    let mut command = Command::new("ffmpeg");
    command
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("error")
        .arg("-y")
        .arg("-ss")
        .arg(format!("{:.3}", start_ms as f64 / 1000.0))
        .arg("-i")
        .arg(&input);
    if end_ms > start_ms {
        command
            .arg("-t")
            .arg(format!("{:.3}", (end_ms - start_ms) as f64 / 1000.0));
    }
    command
        .arg("-vf")
        .arg(format!("fps={fps:.6}"))
        .arg("-frames:v")
        .arg(max_frames.to_string())
        .arg(&pattern);
    let output = command.output().map_err(|error| {
        let _ = fs::remove_dir_all(&temp);
        if error.kind() == std::io::ErrorKind::NotFound {
            NodeError::new(
                error_codes::MEDIA_TOOL_MISSING,
                "ffmpeg is required for frame extraction but was not found on PATH",
            )
        } else {
            NodeError::new(
                error_codes::MEDIA_PROCESSING,
                format!("cannot start ffmpeg: {error}"),
            )
        }
    })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let _ = fs::remove_dir_all(&temp);
        return Err(NodeError::new(
            error_codes::MEDIA_PROCESSING,
            format!("ffmpeg frame extraction failed: {stderr}"),
        ));
    }
    let mut files: Vec<PathBuf> = fs::read_dir(&temp)
        .map_err(|error| {
            NodeError::new(
                error_codes::MEDIA_PROCESSING,
                format!("cannot list frames: {error}"),
            )
        })?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("png"))
        .collect();
    files.sort();
    if files.is_empty() {
        let _ = fs::remove_dir_all(&temp);
        return Err(NodeError::new(
            error_codes::MEDIA_PROCESSING,
            "ffmpeg produced no frames; check the time range and video file",
        ));
    }
    let mut frames = Vec::new();
    for (index, path) in files.iter().enumerate() {
        let imported =
            store.import_path(path, AssetKind::Image, &format!("frame from {}", asset.id))?;
        frames.push(VideoFrame {
            asset: imported,
            timestamp_ms: start_ms + index as u64 * interval_ms,
        });
    }
    let _ = fs::remove_dir_all(&temp);
    Ok(frames)
}

struct DocumentInputNode;

#[async_trait]
impl NodeExecutor for DocumentInputNode {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError> {
        let ids = asset_ids(ctx, "assets")?;
        if ids.is_empty() {
            return Err(empty_message("document"));
        }
        let mode = match ctx.string_param("mode")? {
            "native" => DocumentMode::Native,
            "extracted" => DocumentMode::Extracted,
            other => {
                return Err(NodeError::new(
                    error_codes::INVALID_PARAM,
                    format!("unknown document mode {other:?}"),
                ))
            }
        };
        let store = ctx.services.assets.clone();
        let mut parts = Vec::new();
        let mut texts = Vec::new();
        let mut total_pages = 0u32;
        for id in ids {
            let asset = resolve(ctx, &id)?.clone();
            require_kind(&asset, AssetKind::Document)?;
            if mode == DocumentMode::Native {
                ctx.log(
                    LogLevel::Info,
                    format!("document {} · native document part", asset.name),
                );
                parts.push(ContentPart::Document {
                    asset: asset.clone(),
                    mode,
                    text: None,
                    pages: Vec::new(),
                });
                continue;
            }
            let path = store.path(&asset)?;
            let (text, pages) = tokio::task::spawn_blocking({
                let path = path.clone();
                let name = asset.name.clone();
                move || extract_document(&path, &name)
            })
            .await
            .map_err(|error| {
                NodeError::new(
                    error_codes::MEDIA_PROCESSING,
                    format!("document extraction task failed: {error}"),
                )
            })??;
            ctx.log(
                LogLevel::Warn,
                format!(
                    "document {} · extracted {} page(s); images, tables and layout are not preserved",
                    asset.name, pages
                ),
            );
            total_pages += pages;
            texts.push(text.clone());
            parts.push(ContentPart::Document {
                asset: asset.clone(),
                mode,
                text: Some(text),
                pages: (1..=pages).collect(),
            });
        }
        let text = texts.join("\n\n");
        let summary = format!(
            "{} document(s) · {} page(s) · extracted text mode",
            parts.len(),
            total_pages
        );
        ctx.log(LogLevel::Info, summary.clone());
        Ok(NodeOutput::new()
            .with("parts", serde_json::to_value(&parts).unwrap_or(Value::Null))
            .with("text", Value::String(text))
            .with("pages", Value::from(total_pages))
            .with("summary", Value::String(summary))
            .with("done", Value::Bool(true)))
    }
}

fn extract_document(path: &Path, name: &str) -> Result<(String, u32), NodeError> {
    // Content-addressed assets have no extension on disk, so the original
    // file name decides which extractor runs.
    let extension = Path::new(name)
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match extension.as_str() {
        "pdf" => {
            let raw = pdf_extract::extract_text(path).map_err(|error| {
                NodeError::new(
                    error_codes::MEDIA_PROCESSING,
                    format!("PDF text extraction failed for {name}: {error}"),
                )
            })?;
            let pages: Vec<&str> = raw.split('\u{c}').collect();
            let page_count = pages.len().max(1) as u32;
            let mut text = String::new();
            for (index, page) in pages.iter().enumerate() {
                text.push_str(&format!("\n[page {}]\n", index + 1));
                text.push_str(page);
            }
            Ok((text, page_count))
        }
        "docx" => {
            let file = fs::File::open(path).map_err(|error| {
                NodeError::new(
                    error_codes::ASSET_READ,
                    format!("cannot open DOCX {name}: {error}"),
                )
            })?;
            let mut archive = zip::ZipArchive::new(file).map_err(|error| {
                NodeError::new(
                    error_codes::MEDIA_PROCESSING,
                    format!("cannot read DOCX archive {name}: {error}"),
                )
            })?;
            let mut xml = String::new();
            {
                use std::io::Read;
                let mut document = archive.by_name("word/document.xml").map_err(|error| {
                    NodeError::new(
                        error_codes::MEDIA_PROCESSING,
                        format!("DOCX {name} has no word/document.xml: {error}"),
                    )
                })?;
                document.read_to_string(&mut xml).map_err(|error| {
                    NodeError::new(
                        error_codes::MEDIA_PROCESSING,
                        format!("cannot read DOCX document.xml: {error}"),
                    )
                })?;
            }
            let text = docx_text(&xml)?;
            Ok((text, 1))
        }
        "txt" | "md" | "markdown" => {
            let text = fs::read_to_string(path).map_err(|error| {
                NodeError::new(
                    error_codes::ASSET_READ,
                    format!("cannot read text document {name}: {error}"),
                )
            })?;
            Ok((text, 1))
        }
        other => Err(NodeError::new(
            error_codes::MEDIA_PROCESSING,
            format!("unsupported document extension {other:?}; use PDF, DOCX, TXT or Markdown"),
        )),
    }
}

fn docx_text(xml: &str) -> Result<String, NodeError> {
    use quick_xml::events::Event;
    let mut reader = quick_xml::Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let mut text = String::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) => {
                if event.name().as_ref() == "w:p" && !text.ends_with('\n') {
                    text.push('\n');
                }
            }
            Ok(Event::Empty(event)) => {
                if matches!(event.name().as_ref(), "w:br" | "w:tab") {
                    text.push(if event.name().as_ref() == "w:tab" {
                        '\t'
                    } else {
                        '\n'
                    });
                }
            }
            Ok(Event::Text(value)) => {
                let decoded = quick_xml::escape::unescape(value.as_ref()).map_err(|error| {
                    NodeError::new(
                        error_codes::MEDIA_PROCESSING,
                        format!("DOCX text is not valid UTF-8: {error}"),
                    )
                })?;
                text.push_str(&decoded);
            }
            Ok(Event::End(event)) => {
                if event.name().as_ref() == "w:p" && !text.ends_with('\n') {
                    text.push('\n');
                }
            }
            Ok(Event::Eof) => break,
            Err(error) => {
                return Err(NodeError::new(
                    error_codes::MEDIA_PROCESSING,
                    format!("cannot parse DOCX XML: {error}"),
                ))
            }
            _ => {}
        }
    }
    Ok(text.trim().to_string())
}

#[allow(dead_code)]
fn _asset_metadata(asset: &AssetRef) -> BTreeMap<String, Value> {
    asset.metadata.clone()
}
