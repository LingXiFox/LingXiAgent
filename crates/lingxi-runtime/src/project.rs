//! Project references and opaque workspace handles.
//!
//! A workflow never stores an absolute project path. It stores a `ProjectRef`
//! (stable id plus display name); the host resolves that id to a registered
//! project directory and exposes only an opaque `WorkspaceHandle` to nodes.
//! A forged or stale handle is rejected instead of falling back to a path.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{error_codes, NodeError};
use crate::workspace::Workspace;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRef {
    pub project_id: String,
    pub name: String,
}

impl ProjectRef {
    pub fn new(project_id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            project_id: project_id.into(),
            name: name.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceHandle {
    pub handle_id: String,
    pub project: ProjectRef,
    /// Workspace-relative working directory. Empty means the project root.
    pub relative_cwd: String,
}

#[derive(Clone)]
struct CatalogEntry {
    handle: WorkspaceHandle,
    workspace: Arc<Workspace>,
}

/// Host-owned registry of opened projects. One catalog is attached to a run;
/// the runtime can resolve handles from it but can never enumerate raw paths.
#[derive(Default)]
pub struct WorkspaceCatalog {
    entries: RwLock<BTreeMap<String, CatalogEntry>>,
}

impl WorkspaceCatalog {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers an existing directory. The directory is canonicalized; if it
    /// does not exist the call fails instead of creating a project folder.
    pub fn register(
        &self,
        project: ProjectRef,
        root: impl AsRef<Path>,
        relative_cwd: &str,
    ) -> Result<WorkspaceHandle, NodeError> {
        let workspace = Workspace::open_existing(root.as_ref())?;
        self.register_workspace(project, Arc::new(workspace), relative_cwd)
    }

    pub fn register_workspace(
        &self,
        project: ProjectRef,
        workspace: Arc<Workspace>,
        relative_cwd: &str,
    ) -> Result<WorkspaceHandle, NodeError> {
        let relative_cwd = normalize_cwd(relative_cwd);
        workspace.resolve(&relative_cwd)?;
        if !workspace.resolve(&relative_cwd)?.is_dir() {
            return Err(NodeError::new(
                error_codes::WORKSPACE_NOT_FOUND,
                format!("workspace cwd {relative_cwd:?} is not a directory"),
            ));
        }
        let handle_id = handle_id(&project.project_id, workspace.root());
        let handle = WorkspaceHandle {
            handle_id: handle_id.clone(),
            project,
            relative_cwd,
        };
        let mut entries = self
            .entries
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        entries.insert(
            handle_id,
            CatalogEntry {
                handle: handle.clone(),
                workspace,
            },
        );
        Ok(handle)
    }

    pub fn handle(&self, handle_id: &str) -> Option<WorkspaceHandle> {
        self.entries
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(handle_id)
            .map(|entry| entry.handle.clone())
    }

    pub fn workspace(&self, handle_id: &str) -> Option<Arc<Workspace>> {
        self.entries
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(handle_id)
            .map(|entry| Arc::clone(&entry.workspace))
    }

    pub fn workspace_for_project(&self, project_id: &str) -> Option<Arc<Workspace>> {
        self.entries
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .values()
            .find(|entry| entry.handle.project.project_id == project_id)
            .map(|entry| Arc::clone(&entry.workspace))
    }

    pub fn handles(&self) -> Vec<WorkspaceHandle> {
        self.entries
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .values()
            .map(|entry| entry.handle.clone())
            .collect()
    }

    pub fn remove(&self, handle_id: &str) {
        self.entries
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(handle_id);
    }
}

pub fn handle_id(project_id: &str, root: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(project_id.as_bytes());
    hasher.update([0u8]);
    hasher.update(root.to_string_lossy().as_bytes());
    let digest = hasher.finalize();
    format!(
        "ws-{}",
        digest.as_slice()[..12]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

fn normalize_cwd(relative: &str) -> String {
    relative
        .replace('\\', "/")
        .trim()
        .trim_matches('/')
        .to_string()
}

/// Expands a handle into its canonical root and cwd for host-only operations.
/// Runtime nodes must not expose this through ports.
pub fn catalog_workspace_root(catalog: &WorkspaceCatalog, handle: &str) -> Option<PathBuf> {
    catalog.workspace(handle).map(|ws| ws.root().to_path_buf())
}
