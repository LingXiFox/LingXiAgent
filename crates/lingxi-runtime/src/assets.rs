//! Content-addressed local asset store.
//!
//! Workflow documents reference assets by id/digest only. Importing a file
//! copies it once into `<data-dir>/assets/<sha256>`; the immutable blob is
//! shared by every workflow and composite template that references it.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use lingxi_spec::{AssetKind, AssetRef};
use sha2::{Digest, Sha256};

use crate::error::{error_codes, NodeError};

/// 128 MiB. Large enough for short screen recordings, small enough that a
/// mistaken directory pick cannot exhaust memory.
pub const MAX_ASSET_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct AssetStore {
    root: PathBuf,
}

impl AssetStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn import_path(
        &self,
        path: &Path,
        kind: AssetKind,
        source: &str,
    ) -> Result<AssetRef, NodeError> {
        let metadata = fs::metadata(path).map_err(|error| {
            NodeError::new(
                error_codes::ASSET_READ,
                format!("cannot read {}: {error}", path.display()),
            )
        })?;
        if !metadata.is_file() {
            return Err(NodeError::new(
                error_codes::ASSET_READ,
                format!("{} is not a regular file", path.display()),
            ));
        }
        if metadata.len() > MAX_ASSET_BYTES {
            return Err(NodeError::new(
                error_codes::ASSET_TOO_LARGE,
                format!("asset is larger than {} bytes", MAX_ASSET_BYTES),
            ));
        }
        let bytes = fs::read(path).map_err(|error| {
            NodeError::new(
                error_codes::ASSET_READ,
                format!("cannot read {}: {error}", path.display()),
            )
        })?;
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("asset")
            .to_string();
        self.import_bytes(&name, kind, source, bytes, None)
    }

    pub fn import_bytes(
        &self,
        name: &str,
        kind: AssetKind,
        source: &str,
        bytes: Vec<u8>,
        mime: Option<&str>,
    ) -> Result<AssetRef, NodeError> {
        if bytes.is_empty() {
            return Err(NodeError::new(error_codes::ASSET_EMPTY, "asset is empty"));
        }
        if bytes.len() as u64 > MAX_ASSET_BYTES {
            return Err(NodeError::new(
                error_codes::ASSET_TOO_LARGE,
                format!("asset is larger than {} bytes", MAX_ASSET_BYTES),
            ));
        }
        let mime = mime
            .map(str::to_string)
            .or_else(|| infer::get(&bytes).map(|kind| kind.mime_type().to_string()))
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        let digest = hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let id = format!("asset-{digest}");
        fs::create_dir_all(&self.root).map_err(|error| {
            NodeError::new(
                error_codes::ASSET_IO,
                format!("cannot create asset directory: {error}"),
            )
        })?;
        let destination = self.root.join(&digest);
        if !destination.is_file() {
            let temp = self
                .root
                .join(format!("{digest}.tmp-{}", uuid::Uuid::new_v4()));
            let mut file = fs::File::create(&temp).map_err(|error| {
                NodeError::new(
                    error_codes::ASSET_IO,
                    format!("cannot write asset: {error}"),
                )
            })?;
            file.write_all(&bytes).map_err(|error| {
                NodeError::new(
                    error_codes::ASSET_IO,
                    format!("cannot write asset: {error}"),
                )
            })?;
            file.sync_all().ok();
            fs::rename(&temp, &destination).map_err(|error| {
                let _ = fs::remove_file(&temp);
                NodeError::new(
                    error_codes::ASSET_IO,
                    format!("cannot commit asset: {error}"),
                )
            })?;
        }
        Ok(AssetRef {
            id,
            name: name.to_string(),
            mime,
            size: bytes.len() as u64,
            sha256: digest,
            kind,
            source: source.to_string(),
            metadata: Default::default(),
        })
    }

    /// Resolves a content-addressed id without needing the workflow's asset table.
    /// Used by preview commands and provider encoders that only carry ids.
    pub fn path_by_id(&self, id: &str) -> Result<PathBuf, NodeError> {
        let digest = id.strip_prefix("asset-").ok_or_else(|| {
            NodeError::new(
                error_codes::ASSET_INVALID,
                format!("invalid asset id {id:?}"),
            )
        })?;
        if digest.len() != 64 || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(NodeError::new(
                error_codes::ASSET_INVALID,
                format!("invalid asset id {id:?}"),
            ));
        }
        Ok(self.root.join(digest))
    }

    pub fn read_by_id(&self, id: &str) -> Result<Vec<u8>, NodeError> {
        let path = self.path_by_id(id)?;
        fs::read(&path).map_err(|error| {
            NodeError::new(
                error_codes::ASSET_MISSING,
                format!("asset {id} is missing from the local store: {error}"),
            )
        })
    }

    pub fn path(&self, asset: &AssetRef) -> Result<PathBuf, NodeError> {
        if asset.sha256.len() != 64 || !asset.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(NodeError::new(
                error_codes::ASSET_INVALID,
                "asset digest is invalid",
            ));
        }
        Ok(self.root.join(&asset.sha256))
    }

    pub fn read(&self, asset: &AssetRef) -> Result<Vec<u8>, NodeError> {
        let path = self.path(asset)?;
        let bytes = fs::read(&path).map_err(|error| {
            NodeError::new(
                error_codes::ASSET_MISSING,
                format!(
                    "asset {} is missing from the local store: {error}",
                    asset.id
                ),
            )
        })?;
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        let digest = hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        if digest != asset.sha256 {
            return Err(NodeError::new(
                error_codes::ASSET_INVALID,
                format!("asset {} failed its integrity check", asset.id),
            ));
        }
        Ok(bytes)
    }
}
