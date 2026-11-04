//! Model capability model. Capabilities are evidence, not guesses: every value
//! carries where it came from, and `Unknown` blocks the corresponding input
//! instead of being silently treated as supported.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::content::{AudioMode, ContentPart, DocumentMode, VideoMode};
use crate::error::{error_codes, NodeError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Support {
    Native,
    Preprocessed,
    Unsupported,
    #[default]
    Unknown,
}

impl Support {
    pub fn is_available(self) -> bool {
        matches!(self, Support::Native | Support::Preprocessed)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Support::Native => "native",
            Support::Preprocessed => "preprocessed",
            Support::Unsupported => "unsupported",
            Support::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum CapabilitySource {
    Builtin,
    ProviderList,
    Manual,
    Probe,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningLevel {
    Off,
    Auto,
    Low,
    Medium,
    High,
    Xhigh,
}

impl ReasoningLevel {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "" | "none" | "off" => Some(ReasoningLevel::Off),
            "auto" => Some(ReasoningLevel::Auto),
            "low" | "minimal" => Some(ReasoningLevel::Low),
            "medium" => Some(ReasoningLevel::Medium),
            "high" => Some(ReasoningLevel::High),
            "xhigh" | "max" => Some(ReasoningLevel::Xhigh),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ReasoningLevel::Off => "off",
            ReasoningLevel::Auto => "auto",
            ReasoningLevel::Low => "low",
            ReasoningLevel::Medium => "medium",
            ReasoningLevel::High => "high",
            ReasoningLevel::Xhigh => "xhigh",
        }
    }

    pub fn enabled(self) -> bool {
        self != ReasoningLevel::Off && self != ReasoningLevel::Auto
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InputCapabilities {
    pub text: Support,
    pub image: Support,
    pub audio: Support,
    pub video: Support,
    pub document: Support,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_images: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_file_size: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub supported_media_types: Vec<String>,
}

impl Default for InputCapabilities {
    fn default() -> Self {
        Self {
            text: Support::Native,
            image: Support::Unknown,
            audio: Support::Unknown,
            video: Support::Unknown,
            document: Support::Unknown,
            max_images: None,
            max_file_size: None,
            supported_media_types: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct OutputCapabilities {
    pub text: Support,
    pub image: Support,
    pub audio: Support,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FeatureCapabilities {
    pub streaming: Support,
    pub tool_calling: Support,
    pub reasoning: Support,
    pub structured_output: Support,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ModelLimits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_context_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCapabilities {
    pub input: InputCapabilities,
    pub output: OutputCapabilities,
    pub features: FeatureCapabilities,
    pub limits: ModelLimits,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasoning_levels: Vec<ReasoningLevel>,
    pub source: CapabilitySource,
}

impl Default for ModelCapabilities {
    fn default() -> Self {
        Self {
            input: InputCapabilities::default(),
            output: OutputCapabilities {
                text: Support::Native,
                image: Support::Unsupported,
                audio: Support::Unsupported,
            },
            features: FeatureCapabilities {
                streaming: Support::Unknown,
                tool_calling: Support::Unknown,
                reasoning: Support::Unknown,
                structured_output: Support::Unknown,
            },
            limits: ModelLimits::default(),
            reasoning_levels: Vec::new(),
            source: CapabilitySource::Unknown,
        }
    }
}

impl ModelCapabilities {
    /// Conservative built-in inference. A model list alone is not evidence of
    /// media support, so unrecognized ids stay `Unknown` for media features.
    pub fn infer(protocol: &str, model: &str) -> Self {
        let id = model.to_ascii_lowercase();
        let mut profile = ModelCapabilities::default();
        let is_claude = id.contains("claude");
        let is_openai = id.starts_with("gpt-") || id.starts_with('o') && id.len() <= 6;
        let is_mock = id.starts_with("mock-");
        let vision = is_claude
            || id.contains("gpt-4o")
            || id.contains("gpt-4.1")
            || id.contains("gpt-5")
            || id.contains("o3")
            || id.contains("o4")
            || id.contains("vision")
            || id == "mock-vision";
        let document = is_claude && protocol == "anthropic_messages";
        let audio_native = id.contains("audio");
        let reasoning =
            is_claude || id.contains("gpt-5") || id.starts_with('o') || id.contains("reasoning");

        if is_claude {
            profile.output.text = Support::Native;
            profile.output.image = Support::Unsupported;
            profile.output.audio = Support::Unsupported;
            profile.features.streaming = Support::Native;
            profile.features.tool_calling = Support::Native;
            profile.features.reasoning = if reasoning {
                Support::Native
            } else {
                Support::Unsupported
            };
            profile.limits.max_context_tokens = Some(200_000);
            profile.limits.max_output_tokens = Some(8192);
            profile.reasoning_levels = vec![
                ReasoningLevel::Off,
                ReasoningLevel::Auto,
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::Xhigh,
            ];
        } else if is_openai {
            profile.output.text = Support::Native;
            profile.features.streaming = Support::Native;
            profile.features.tool_calling = Support::Native;
            profile.features.structured_output = Support::Native;
            profile.features.reasoning = if reasoning {
                Support::Native
            } else {
                Support::Unsupported
            };
            profile.limits.max_context_tokens = Some(if id.contains("gpt-4o") {
                128_000
            } else {
                200_000
            });
            profile.limits.max_output_tokens = Some(16_384);
            profile.reasoning_levels = if reasoning {
                vec![
                    ReasoningLevel::Off,
                    ReasoningLevel::Auto,
                    ReasoningLevel::Low,
                    ReasoningLevel::Medium,
                    ReasoningLevel::High,
                    ReasoningLevel::Xhigh,
                ]
            } else {
                vec![ReasoningLevel::Off]
            };
        } else if is_mock {
            profile.output.text = Support::Native;
            profile.features.streaming = Support::Native;
            profile.features.tool_calling = Support::Native;
            profile.features.reasoning = if reasoning {
                Support::Native
            } else {
                Support::Unsupported
            };
            profile.reasoning_levels = if reasoning {
                vec![
                    ReasoningLevel::Off,
                    ReasoningLevel::Auto,
                    ReasoningLevel::Low,
                    ReasoningLevel::Medium,
                    ReasoningLevel::High,
                ]
            } else {
                vec![ReasoningLevel::Off]
            };
            profile.limits.max_context_tokens = Some(32_768);
            profile.limits.max_output_tokens = Some(4096);
        } else {
            // Local and unknown OpenAI-compatible models: text + streaming/tool
            // calling are conventionally available, media is not proven.
            profile.output.text = Support::Native;
            profile.features.streaming = Support::Native;
            profile.features.tool_calling = Support::Native;
            profile.source = CapabilitySource::Builtin;
            return profile;
        }

        if vision {
            profile.input.image = Support::Native;
            profile.input.max_images = Some(16);
            profile.input.supported_media_types = vec![
                "image/png".to_string(),
                "image/jpeg".to_string(),
                "image/webp".to_string(),
                "image/gif".to_string(),
            ];
        } else {
            profile.input.image = Support::Unknown;
        }
        if document {
            profile.input.document = Support::Native;
            profile
                .input
                .supported_media_types
                .push("application/pdf".to_string());
        } else {
            profile.input.document = Support::Preprocessed;
        }
        profile.input.audio = if audio_native {
            Support::Native
        } else {
            Support::Preprocessed
        };
        // No built-in protocol claims native video. Frame extraction is the
        // only honest path until a provider documents video input.
        profile.input.video = Support::Preprocessed;
        profile.source = CapabilitySource::Builtin;
        profile
    }

    pub fn with_overrides(self, overrides: &Value) -> Result<Self, NodeError> {
        if overrides.is_null() {
            return Ok(self);
        }
        let mut merged: Value = serde_json::to_value(&self).map_err(|error| {
            NodeError::new(
                error_codes::MODEL_UNKNOWN_CAPABILITY,
                format!("capabilities are not serializable: {error}"),
            )
        })?;
        merge_json(&mut merged, overrides);
        let mut parsed: ModelCapabilities = serde_json::from_value(merged).map_err(|error| {
            NodeError::new(
                error_codes::MODEL_UNKNOWN_CAPABILITY,
                format!("capability override is invalid: {error}"),
            )
        })?;
        parsed.source = CapabilitySource::Manual;
        Ok(parsed)
    }

    /// Checks the modalities a message actually needs after mode selection.
    /// Transcribed audio and extracted documents are text and are not checked
    /// against the native audio/document capability.
    pub fn check_parts(&self, parts: &[ContentPart]) -> Result<(), NodeError> {
        let mut images = 0u32;
        for part in parts {
            match part {
                ContentPart::Text { .. } => {
                    require(self.input.text, "text")?;
                }
                ContentPart::Image { .. } => {
                    require(self.input.image, "image")?;
                    images += 1;
                }
                ContentPart::Audio { mode, .. } => match mode {
                    AudioMode::Native => require(self.input.audio, "audio")?,
                    AudioMode::Transcribed => require(self.input.text, "transcribed audio")?,
                },
                ContentPart::Video { mode, .. } => match mode {
                    VideoMode::Native => require(self.input.video, "video")?,
                    VideoMode::Frames => require(self.input.image, "video frames")?,
                },
                ContentPart::Document { mode, .. } => match mode {
                    DocumentMode::Native => require(self.input.document, "document")?,
                    DocumentMode::Extracted => require(self.input.text, "document text")?,
                },
            }
        }
        if let Some(max) = self.input.max_images {
            if images > max {
                return Err(NodeError::new(
                    error_codes::MODEL_UNSUPPORTED_MODALITY,
                    format!("model accepts at most {max} images per request, got {images}"),
                ));
            }
        }
        Ok(())
    }

    pub fn check_reasoning(&self, level: ReasoningLevel) -> Result<(), NodeError> {
        if level == ReasoningLevel::Off {
            return Ok(());
        }
        if self.features.reasoning != Support::Native {
            return Err(NodeError::new(
                error_codes::MODEL_UNSUPPORTED_REASONING,
                format!(
                    "model does not declare native reasoning support (source: {:?})",
                    self.source
                ),
            ));
        }
        if !self.reasoning_levels.is_empty() && !self.reasoning_levels.contains(&level) {
            return Err(NodeError::new(
                error_codes::MODEL_UNSUPPORTED_REASONING,
                format!("model does not support reasoning level {}", level.as_str()),
            ));
        }
        Ok(())
    }
}

fn require(support: Support, label: &str) -> Result<(), NodeError> {
    match support {
        Support::Native | Support::Preprocessed => Ok(()),
        Support::Unsupported => Err(NodeError::new(
            error_codes::MODEL_UNSUPPORTED_MODALITY,
            format!("model does not support {label} input"),
        )),
        Support::Unknown => Err(NodeError::new(
            error_codes::MODEL_UNKNOWN_CAPABILITY,
            format!(
                "model support for {label} is unknown; configure capabilities in the provider node"
            ),
        )),
    }
}

fn merge_json(base: &mut Value, overrides: &Value) {
    match (base, overrides) {
        (Value::Object(base), Value::Object(overrides)) => {
            for (key, value) in overrides {
                match base.get_mut(key) {
                    Some(slot) => merge_json(slot, value),
                    None => {
                        base.insert(key.clone(), value.clone());
                    }
                }
            }
        }
        (slot, value) => *slot = value.clone(),
    }
}
