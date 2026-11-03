//! Node registry: the single place where a kind name is bound to its spec and
//! its executor. Plugins register here; the engine never hard-codes a kind.

use async_trait::async_trait;
use lingxi_spec::{NodeKindResolver, NodeSpec};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::Arc;

use crate::context::NodeContext;
use crate::error::{NodeError, RegistryError};

#[derive(Debug, Clone, Default)]
pub struct NodeOutput {
    pub outputs: BTreeMap<String, Value>,
}

impl NodeOutput {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with(mut self, port: impl Into<String>, value: Value) -> Self {
        self.outputs.insert(port.into(), value);
        self
    }
}

#[async_trait]
pub trait NodeExecutor: Send + Sync {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError>;
}

struct Entry {
    spec: NodeSpec,
    executor: Arc<dyn NodeExecutor>,
}

#[derive(Default)]
pub struct NodeRegistry {
    entries: BTreeMap<String, Entry>,
}

impl NodeRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn builtin() -> Self {
        let mut registry = Self::new();
        crate::builtin::register(&mut registry);
        registry
    }

    pub fn register(
        &mut self,
        spec: NodeSpec,
        executor: Arc<dyn NodeExecutor>,
    ) -> Result<(), RegistryError> {
        if spec.kind.trim().is_empty() {
            return Err(RegistryError::EmptyKind);
        }
        if self.entries.contains_key(&spec.kind) {
            return Err(RegistryError::DuplicateKind {
                kind: spec.kind.clone(),
            });
        }
        self.entries
            .insert(spec.kind.clone(), Entry { spec, executor });
        Ok(())
    }

    pub fn spec(&self, kind: &str) -> Option<&NodeSpec> {
        self.entries.get(kind).map(|entry| &entry.spec)
    }

    pub fn executor(&self, kind: &str) -> Option<Arc<dyn NodeExecutor>> {
        self.entries.get(kind).map(|entry| entry.executor.clone())
    }

    pub fn specs(&self) -> Vec<&NodeSpec> {
        self.entries.values().map(|entry| &entry.spec).collect()
    }

    pub fn kinds(&self) -> Vec<&str> {
        self.entries.keys().map(String::as_str).collect()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

impl NodeKindResolver for NodeRegistry {
    fn node_spec(&self, kind: &str) -> Option<&NodeSpec> {
        self.spec(kind)
    }
}
