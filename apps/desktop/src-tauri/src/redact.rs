//! Best-effort secret redaction for run data.
//!
//! This is deliberately conservative: known credential shapes and values under
//! sensitive JSON keys are replaced, while ordinary text is left untouched.
//! Redaction is applied before SQLite writes and before live events reach the
//! webview, never only in the UI.

use lingxi_runtime::RunEvent;
use serde_json::Value;

pub const REDACTED: &str = "[REDACTED]";

pub fn is_sensitive_key(key: &str) -> bool {
    let normalized: String = key
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    matches!(
        normalized.as_str(),
        "token"
            | "accesstoken"
            | "authtoken"
            | "refreshtoken"
            | "idtoken"
            | "apikey"
            | "secret"
            | "clientsecret"
            | "password"
            | "passwd"
            | "authorization"
            | "credential"
            | "credentials"
            | "privatekey"
    ) || normalized.ends_with("token")
        || normalized.ends_with("secret")
        || normalized.ends_with("password")
}

pub fn redact_json(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                if is_sensitive_key(key) {
                    *child = Value::String(REDACTED.to_string());
                } else {
                    redact_json(child);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(redact_json),
        Value::String(text) => *text = redact_text(text),
        _ => {}
    }
}

/// Returns a copy safe for both SQLite and the webview event bridge. The
/// runtime keeps the original values for execution; only the sink payload is
/// redacted.
pub fn redact_event(event: &RunEvent) -> RunEvent {
    let mut event = event.clone();
    match &mut event {
        RunEvent::RunStarted { workflow_name, .. } => {
            *workflow_name = redact_text(workflow_name);
        }
        RunEvent::NodeStarted { label, .. } => {
            *label = redact_text(label);
        }
        RunEvent::NodeFinished { label, outputs, .. } => {
            *label = redact_text(label);
            for (name, value) in outputs.iter_mut() {
                if is_sensitive_key(name) {
                    *value = Value::String(REDACTED.to_string());
                } else {
                    redact_json(value);
                }
            }
        }
        RunEvent::NodeFailed { label, message, .. } => {
            *label = redact_text(label);
            *message = redact_text(message);
        }
        RunEvent::NodeSkipped { label, reason, .. } => {
            *label = redact_text(label);
            *reason = redact_text(reason);
        }
        RunEvent::NodeCancelled { label, .. } => {
            *label = redact_text(label);
        }
        RunEvent::Log { message, .. } => {
            *message = redact_text(message);
        }
        RunEvent::InteractionRequested {
            prompt, options, ..
        } => {
            *prompt = redact_text(prompt);
            for option in options {
                option.value = redact_text(&option.value);
                option.label = redact_text(&option.label);
            }
        }
        RunEvent::InteractionResolved { .. } => {}
        RunEvent::RunFinished { detail, .. } => {
            if let Some(detail) = detail {
                *detail = redact_text(detail);
            }
        }
    }
    if let Some(scope) = event.scope_mut() {
        for frame in scope {
            frame.label = redact_text(&frame.label);
        }
    }
    event
}

pub fn redact_text(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        if let Some((start, end)) = secret_span(input, index) {
            output.push_str(&input[index..start]);
            output.push_str(REDACTED);
            index = end;
            continue;
        }
        let ch = input[index..].chars().next().expect("valid char boundary");
        output.push(ch);
        index += ch.len_utf8();
    }
    output
}

fn secret_span(input: &str, index: usize) -> Option<(usize, usize)> {
    let rest = &input[index..];
    let lower = rest.to_ascii_lowercase();

    if lower.starts_with("bearer ") {
        let value_start = index + "bearer ".len();
        let value_end = consume_token(input, value_start);
        if value_end > value_start + 3 {
            return Some((value_start, value_end));
        }
    }

    for prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-"] {
        if lower.starts_with(prefix) && boundary_before(input, index) {
            let end = consume_token(input, index + prefix.len());
            if end >= index + prefix.len() + 12 {
                return Some((index, end));
            }
        }
    }

    if lower.starts_with("akia") && boundary_before(input, index) {
        let end = consume_token(input, index + 4);
        if end >= index + 4 + 12 {
            return Some((index, end));
        }
    }

    for key in [
        "api_key",
        "apikey",
        "token",
        "api-key",
        "access_token",
        "auth_token",
        "client_secret",
        "password",
        "secret",
        "authorization",
    ] {
        if lower.starts_with(key) && boundary_before(input, index) {
            let after_key = index + key.len();
            let mut cursor = after_key;
            while cursor < input.len() {
                let ch = input[cursor..].chars().next().unwrap();
                if ch == ' ' || ch == '\t' {
                    cursor += ch.len_utf8();
                } else {
                    break;
                }
            }
            let separator = input[cursor..].chars().next();
            if matches!(separator, Some('=') | Some(':')) {
                let mut value_start = cursor + 1;
                while value_start < input.len() {
                    let ch = input[value_start..].chars().next().unwrap();
                    if ch == ' ' || ch == '\t' {
                        value_start += ch.len_utf8();
                    } else {
                        break;
                    }
                }
                if input[value_start..].starts_with(REDACTED) {
                    return None;
                }
                if key == "authorization" {
                    let tail = lower[value_start..].to_string();
                    for scheme in ["bearer ", "basic "] {
                        if tail.starts_with(scheme) {
                            let token_start = value_start + scheme.len();
                            if input[token_start..].starts_with(REDACTED) {
                                return None;
                            }
                            let token_end = consume_token(input, token_start);
                            if token_end > token_start + 3 {
                                return Some((token_start, token_end));
                            }
                        }
                    }
                    let line_end = input[value_start..]
                        .find(['\n', '\r'])
                        .map(|offset| value_start + offset)
                        .unwrap_or(input.len());
                    if line_end > value_start + 2 {
                        return Some((value_start, line_end));
                    }
                }

                let mut value_end = value_start;
                if let Some(quote) = input[value_start..].chars().next() {
                    if quote == '"' || quote == '\'' {
                        value_start += quote.len_utf8();
                        if input[value_start..].starts_with(REDACTED) {
                            return None;
                        }
                        value_end = value_start;
                        while value_end < input.len() {
                            let ch = input[value_end..].chars().next().unwrap();
                            if ch == quote {
                                break;
                            }
                            value_end += ch.len_utf8();
                        }
                    } else {
                        while value_end < input.len() {
                            let ch = input[value_end..].chars().next().unwrap();
                            if ch.is_whitespace()
                                || matches!(ch, ',' | ';' | '&' | '}' | ']' | '"' | '\'')
                            {
                                break;
                            }
                            value_end += ch.len_utf8();
                        }
                    }
                }
                if value_end > value_start + 2 {
                    return Some((value_start, value_end));
                }
            }
        }
    }

    None
}

fn consume_token(input: &str, start: usize) -> usize {
    let mut end = start;
    while end < input.len() {
        let ch = input[end..].chars().next().unwrap();
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | '~' | '+') {
            end += ch.len_utf8();
        } else {
            break;
        }
    }
    end
}

fn boundary_before(input: &str, index: usize) -> bool {
    if index == 0 {
        return true;
    }
    let previous = input[..index].chars().next_back().unwrap();
    !previous.is_ascii_alphanumeric() && previous != '_' && previous != '-'
}

#[cfg(test)]
mod tests {
    use super::*;
    use lingxi_runtime::{LogLevel, RunStatus};
    use serde_json::json;

    #[test]
    fn ordinary_log_text_is_unchanged() {
        let text = "loop iteration 2/3 finished in 12 ms";
        assert_eq!(redact_text(text), text);
    }

    #[test]
    fn bearer_and_api_key_shapes_are_redacted() {
        assert_eq!(
            redact_text("Authorization: Bearer abc.def-123"),
            "Authorization: Bearer [REDACTED]"
        );
        assert_eq!(
            redact_text("key sk-abcdefghijklmnopqrstuv"),
            "key [REDACTED]"
        );
        assert_eq!(redact_text("api_key=supersecret"), "api_key=[REDACTED]");
        assert_eq!(
            redact_text("client_secret: \"very-secret\""),
            "client_secret: \"[REDACTED]\""
        );
    }

    #[test]
    fn sensitive_json_keys_are_redacted_recursively() {
        let mut value = json!({
            "apiKey": "abc",
            "nested": { "access_token": "xyz", "safe": "keep" },
            "items": [{ "password": "p" }]
        });
        redact_json(&mut value);
        assert_eq!(value["apiKey"], REDACTED);
        assert_eq!(value["nested"]["access_token"], REDACTED);
        assert_eq!(value["nested"]["safe"], "keep");
        assert_eq!(value["items"][0]["password"], REDACTED);
    }

    #[test]
    fn live_events_are_redacted_before_forwarding() {
        let log = redact_event(&RunEvent::Log {
            run_id: "run-1".into(),
            seq: 0,
            scope: Vec::new(),
            at_ms: 1,
            level: LogLevel::Info,
            node_id: None,
            message: "token=super-secret".into(),
        });
        let RunEvent::Log { message, .. } = log else {
            panic!("expected log");
        };
        assert_eq!(message, "token=[REDACTED]");

        let finished = redact_event(&RunEvent::NodeFinished {
            run_id: "run-1".into(),
            seq: 1,
            scope: Vec::new(),
            node_id: "n1".into(),
            kind: "core.log".into(),
            label: "token=label-secret".into(),
            outputs: [
                ("apiKey".to_string(), json!("top-level-secret")),
                (
                    "payload".to_string(),
                    json!({"apiKey": "abc", "safe": "keep"}),
                ),
            ]
            .into_iter()
            .collect(),
            duration_ms: 1,
            activation: 1,
            iteration: None,
        });
        let RunEvent::NodeFinished { label, outputs, .. } = finished else {
            panic!("expected node finished");
        };
        assert_eq!(label, "token=[REDACTED]");
        assert_eq!(outputs["apiKey"], REDACTED);
        assert_eq!(outputs["payload"]["apiKey"], REDACTED);
        assert_eq!(outputs["payload"]["safe"], "keep");

        let finished = redact_event(&RunEvent::RunFinished {
            run_id: "run-1".into(),
            seq: 2,
            status: RunStatus::Failed,
            cause: None,
            detail: Some("Authorization: Bearer abcdef".into()),
            duration_ms: 2,
        });
        let RunEvent::RunFinished { detail, .. } = finished else {
            panic!("expected run finished");
        };
        assert_eq!(detail.as_deref(), Some("Authorization: Bearer [REDACTED]"));
    }

    #[test]
    fn redacting_an_already_redacted_event_is_stable() {
        let event = RunEvent::NodeFinished {
            run_id: "run-1".into(),
            seq: 0,
            scope: Vec::new(),
            node_id: "n1".into(),
            kind: "core.log".into(),
            label: "token=label-secret".into(),
            outputs: [
                ("apiKey".to_string(), json!("top-level-secret")),
                (
                    "payload".to_string(),
                    json!({"accessToken": "nested-secret", "safe": "keep"}),
                ),
            ]
            .into_iter()
            .collect(),
            duration_ms: 1,
            activation: 1,
            iteration: None,
        };
        let once = redact_event(&event);
        let twice = redact_event(&once);
        assert_eq!(
            serde_json::to_value(&twice).unwrap(),
            serde_json::to_value(&once).unwrap(),
            "the live sink redacts before the database sink; a second pass must be a no-op"
        );
    }

    #[test]
    fn redaction_is_idempotent() {
        let once = redact_text(
            "token=super-secret; Authorization: Bearer abc.def-123; client_secret: \"very-secret\"",
        );
        assert_eq!(redact_text(&once), once);
        assert_eq!(
            redact_text("token=[REDACTED]"),
            "token=[REDACTED]",
            "already-redacted values must not grow extra brackets"
        );
    }

    #[test]
    fn token_like_but_safe_keys_are_not_redacted() {
        assert!(!is_sensitive_key("tokenCount"));
        assert!(!is_sensitive_key("maxTokens"));
        assert!(is_sensitive_key("maxToken"));
    }
}
