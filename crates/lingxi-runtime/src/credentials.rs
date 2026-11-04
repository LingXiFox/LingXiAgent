//! Credential references. Workflows never contain secret values: a node stores
//! an opaque reference such as `env:OPENAI_API_KEY` or `keyring:openai`, and
//! the host resolves it at execution time. There is deliberately no plaintext
//! fallback when the OS credential store is unavailable.

use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;

use crate::error::{error_codes, NodeError};

pub const KEYRING_SERVICE: &str = "site.lingxi.desktop.credentials";

#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.trim().is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret([REDACTED])")
    }
}

#[async_trait]
pub trait CredentialResolver: Send + Sync {
    async fn resolve(&self, reference: &str) -> Result<Secret, NodeError>;
    /// Returns whether the reference currently resolves. Never returns the
    /// secret itself.
    async fn status(&self, reference: &str) -> Result<bool, NodeError>;
}

#[derive(Debug, Default)]
pub struct EnvCredentials;

#[async_trait]
impl CredentialResolver for EnvCredentials {
    async fn resolve(&self, reference: &str) -> Result<Secret, NodeError> {
        let name = reference
            .strip_prefix("env:")
            .ok_or_else(|| invalid_reference(reference))?;
        if name.is_empty() {
            return Err(invalid_reference(reference));
        }
        let value = std::env::var(name).map_err(|_| {
            NodeError::new(
                error_codes::PROVIDER_MISSING_CREDENTIAL,
                format!("environment credential {name:?} is not set"),
            )
        })?;
        if value.trim().is_empty() {
            return Err(NodeError::new(
                error_codes::PROVIDER_MISSING_CREDENTIAL,
                format!("environment credential {name:?} is empty"),
            ));
        }
        Ok(Secret::new(value))
    }

    async fn status(&self, reference: &str) -> Result<bool, NodeError> {
        let name = reference
            .strip_prefix("env:")
            .ok_or_else(|| invalid_reference(reference))?;
        Ok(std::env::var(name).is_ok())
    }
}

/// Resolves `env:NAME` and `keyring:NAME`. The keyring is the only writable
/// store; unavailable platforms produce an explicit error.
#[derive(Debug, Default)]
pub struct BuiltinCredentials;

#[async_trait]
impl CredentialResolver for BuiltinCredentials {
    async fn resolve(&self, reference: &str) -> Result<Secret, NodeError> {
        if reference.starts_with("env:") {
            return EnvCredentials.resolve(reference).await;
        }
        let name = reference
            .strip_prefix("keyring:")
            .ok_or_else(|| invalid_reference(reference))?;
        if name.is_empty() {
            return Err(invalid_reference(reference));
        }
        let name = name.to_string();
        let result = tokio::task::spawn_blocking(move || {
            let entry = keyring::Entry::new(KEYRING_SERVICE, &name)
                .map_err(|error| format!("cannot open OS credential store: {error}"))?;
            entry.get_password().map_err(|error| match error {
                keyring::Error::NoEntry => "credential is not configured".to_string(),
                other => format!("cannot read OS credential store: {other}"),
            })
        })
        .await
        .map_err(|error| {
            NodeError::new(
                error_codes::CREDENTIALS_UNAVAILABLE,
                format!("credential task failed: {error}"),
            )
        })?;
        match result {
            Ok(value) if !value.trim().is_empty() => Ok(Secret::new(value)),
            Ok(_) => Err(NodeError::new(
                error_codes::PROVIDER_MISSING_CREDENTIAL,
                "credential exists but is empty",
            )),
            Err(message) => Err(NodeError::new(
                if message.contains("not configured") {
                    error_codes::PROVIDER_MISSING_CREDENTIAL
                } else {
                    error_codes::CREDENTIALS_UNAVAILABLE
                },
                message,
            )),
        }
    }

    async fn status(&self, reference: &str) -> Result<bool, NodeError> {
        if reference.starts_with("env:") {
            return EnvCredentials.status(reference).await;
        }
        let name = reference
            .strip_prefix("keyring:")
            .ok_or_else(|| invalid_reference(reference))?;
        if name.is_empty() {
            return Err(invalid_reference(reference));
        }
        let name = name.to_string();
        tokio::task::spawn_blocking(move || {
            let entry = keyring::Entry::new(KEYRING_SERVICE, &name)
                .map_err(|error| format!("cannot open OS credential store: {error}"))?;
            match entry.get_password() {
                Ok(_) => Ok(true),
                Err(keyring::Error::NoEntry) => Ok(false),
                Err(error) => Err(format!("cannot read OS credential store: {error}")),
            }
        })
        .await
        .map_err(|error| {
            NodeError::new(
                error_codes::CREDENTIALS_UNAVAILABLE,
                format!("credential task failed: {error}"),
            )
        })?
        .map_err(|message| NodeError::new(error_codes::CREDENTIALS_UNAVAILABLE, message))
    }
}

pub async fn set_keyring_secret(name: &str, secret: &str) -> Result<(), NodeError> {
    if name.trim().is_empty() || secret.trim().is_empty() {
        return Err(NodeError::new(
            error_codes::CREDENTIALS_INVALID_REFERENCE,
            "credential name and value must not be empty",
        ));
    }
    let name = name.trim().to_string();
    let secret = secret.to_string();
    tokio::task::spawn_blocking(move || {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &name)
            .map_err(|error| format!("cannot open OS credential store: {error}"))?;
        entry
            .set_password(&secret)
            .map_err(|error| format!("cannot write OS credential store: {error}"))
    })
    .await
    .map_err(|error| {
        NodeError::new(
            error_codes::CREDENTIALS_UNAVAILABLE,
            format!("credential task failed: {error}"),
        )
    })?
    .map_err(|message| NodeError::new(error_codes::CREDENTIALS_UNAVAILABLE, message))
}

pub async fn delete_keyring_secret(name: &str) -> Result<(), NodeError> {
    if name.trim().is_empty() {
        return Err(invalid_reference(name));
    }
    let name = name.trim().to_string();
    tokio::task::spawn_blocking(move || {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &name)
            .map_err(|error| format!("cannot open OS credential store: {error}"))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(format!("cannot delete OS credential: {error}")),
        }
    })
    .await
    .map_err(|error| {
        NodeError::new(
            error_codes::CREDENTIALS_UNAVAILABLE,
            format!("credential task failed: {error}"),
        )
    })?
    .map_err(|message| NodeError::new(error_codes::CREDENTIALS_UNAVAILABLE, message))
}

/// Test and embedding helper: immutable in-memory references.
#[derive(Debug, Default)]
pub struct MemoryCredentials {
    values: std::collections::BTreeMap<String, String>,
}

impl MemoryCredentials {
    pub fn new(values: impl IntoIterator<Item = (String, String)>) -> Self {
        Self {
            values: values.into_iter().collect(),
        }
    }

    pub fn arc(values: impl IntoIterator<Item = (String, String)>) -> Arc<dyn CredentialResolver> {
        Arc::new(Self::new(values))
    }
}

#[async_trait]
impl CredentialResolver for MemoryCredentials {
    async fn resolve(&self, reference: &str) -> Result<Secret, NodeError> {
        self.values.get(reference).map(Secret::new).ok_or_else(|| {
            NodeError::new(
                error_codes::PROVIDER_MISSING_CREDENTIAL,
                format!("credential {reference:?} is not configured"),
            )
        })
    }

    async fn status(&self, reference: &str) -> Result<bool, NodeError> {
        Ok(self.values.contains_key(reference))
    }
}

fn invalid_reference(reference: &str) -> NodeError {
    NodeError::new(
        error_codes::CREDENTIALS_INVALID_REFERENCE,
        format!("credential reference {reference:?} must be \"env:NAME\" or \"keyring:NAME\""),
    )
}
