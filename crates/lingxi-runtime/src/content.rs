//! Protocol-neutral content. A message either holds plain text (the common
//! case) or an ordered list of parts. Binary media is always an AssetRef; the
//! bytes are resolved from the local asset store only at encoding time, so a
//! workflow document never embeds base64.

use lingxi_spec::AssetRef;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AudioMode {
    #[default]
    Native,
    Transcribed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum VideoMode {
    #[default]
    Native,
    Frames,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DocumentMode {
    #[default]
    Native,
    Extracted,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoFrame {
    pub asset: AssetRef,
    pub timestamp_ms: u64,
}

/// One piece of a multimodal message. Every variant is explicit about how the
/// content was produced, so a transcript or extracted PDF page is never
/// presented to the model (or the user) as native audio/video/document.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentPart {
    Text {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<String>,
    },
    Image {
        asset: AssetRef,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    Audio {
        asset: AssetRef,
        #[serde(default)]
        mode: AudioMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        transcript: Option<String>,
    },
    Video {
        asset: AssetRef,
        #[serde(default)]
        mode: VideoMode,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        frames: Vec<VideoFrame>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        time_range: Option<(u64, u64)>,
    },
    Document {
        asset: AssetRef,
        #[serde(default)]
        mode: DocumentMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        pages: Vec<u32>,
    },
}

impl ContentPart {
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text {
            text: text.into(),
            source: None,
        }
    }

    pub fn labeled_text(origin: &str, text: impl Into<String>) -> Self {
        Self::Text {
            text: text.into(),
            source: Some(origin.to_string()),
        }
    }

    pub fn image(asset: AssetRef) -> Self {
        Self::Image {
            asset,
            detail: None,
        }
    }

    pub fn asset(&self) -> Option<&AssetRef> {
        match self {
            ContentPart::Text { .. } => None,
            ContentPart::Image { asset, .. }
            | ContentPart::Audio { asset, .. }
            | ContentPart::Video { asset, .. }
            | ContentPart::Document { asset, .. } => Some(asset),
        }
    }

    /// Turns an explicitly preprocessed part into what a provider can accept:
    /// transcripts and extracted pages become labelled text, sampled frames
    /// become labelled image parts. Native variants stay untouched so an
    /// unsupported modality fails instead of silently degrading.
    pub fn flatten(self) -> Vec<ContentPart> {
        match self {
            ContentPart::Audio {
                asset,
                mode,
                transcript,
            } => match mode {
                AudioMode::Native => vec![ContentPart::Audio {
                    asset,
                    mode,
                    transcript,
                }],
                AudioMode::Transcribed => vec![ContentPart::labeled_text(
                    &format!("audio transcript: {}", asset.name),
                    transcript.unwrap_or_default(),
                )],
            },
            ContentPart::Video {
                asset,
                mode,
                frames,
                time_range,
            } => match mode {
                VideoMode::Native => vec![ContentPart::Video {
                    asset,
                    mode,
                    frames,
                    time_range,
                }],
                VideoMode::Frames => {
                    let mut parts = Vec::new();
                    for frame in frames {
                        parts.push(ContentPart::labeled_text(
                            &format!("video frame at {} ms", frame.timestamp_ms),
                            format!("frame from {} at {} ms", asset.name, frame.timestamp_ms),
                        ));
                        parts.push(ContentPart::Image {
                            asset: frame.asset,
                            detail: Some("auto".into()),
                        });
                    }
                    parts
                }
            },
            ContentPart::Document {
                asset,
                mode,
                text,
                pages,
            } => match mode {
                DocumentMode::Native => vec![ContentPart::Document {
                    asset,
                    mode,
                    text,
                    pages,
                }],
                DocumentMode::Extracted => vec![ContentPart::labeled_text(
                    &format!("document text: {} pages {:?}", asset.name, pages),
                    text.unwrap_or_default(),
                )],
            },
            other => vec![other],
        }
    }

    pub fn text_content(&self) -> Option<&str> {
        match self {
            ContentPart::Text { text, .. } => Some(text),
            _ => None,
        }
    }
}

/// Wire-compatible with the Phase 1.4 message shape: a string content still
/// deserializes as `Text`, so old workflow documents and SQLite rows load.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MessageContent {
    Text(String),
    Parts(Vec<ContentPart>),
}

impl Default for MessageContent {
    fn default() -> Self {
        Self::Text(String::new())
    }
}

impl MessageContent {
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text(text.into())
    }

    pub fn parts(parts: Vec<ContentPart>) -> Self {
        Self::Parts(parts)
    }

    pub fn as_parts(&self) -> &[ContentPart] {
        match self {
            MessageContent::Parts(parts) => parts,
            MessageContent::Text(_) => &[],
        }
    }

    /// Plain text only. Media contributes a short label for prompts that only
    /// accept text; provider adapters must use `as_parts` instead.
    pub fn plain_text(&self) -> String {
        match self {
            MessageContent::Text(text) => text.clone(),
            MessageContent::Parts(parts) => parts
                .iter()
                .filter_map(ContentPart::text_content)
                .collect::<Vec<_>>()
                .join("\n"),
        }
    }

    pub fn is_empty(&self) -> bool {
        match self {
            MessageContent::Text(text) => text.trim().is_empty(),
            MessageContent::Parts(parts) => parts.is_empty(),
        }
    }

    pub fn char_count(&self) -> usize {
        match self {
            MessageContent::Text(text) => text.chars().count(),
            MessageContent::Parts(parts) => parts
                .iter()
                .map(|part| match part {
                    ContentPart::Text { text, .. } => text.chars().count(),
                    _ => 0,
                })
                .sum(),
        }
    }
}
