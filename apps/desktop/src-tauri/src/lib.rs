mod commands;
mod store;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use lingxi_runtime::{
    AllowAllPolicy, CapabilityPolicy, Engine, InteractionBroker, NodeRegistry, PendingInteractions,
    RunControl,
};
use tauri::Manager;

pub struct AppState {
    pub registry: Arc<NodeRegistry>,
    pub engine: Arc<Engine>,
    pub interactions: Arc<PendingInteractions>,
    pub runs: Arc<Mutex<HashMap<String, Arc<RunControl>>>>,
    pub store: store::WorkflowStore,
}

impl AppState {
    fn new(data_dir: std::path::PathBuf) -> Self {
        let registry = Arc::new(NodeRegistry::builtin());
        let interactions = Arc::new(PendingInteractions::new());
        let broker: Arc<dyn InteractionBroker> = interactions.clone();
        let policy: Arc<dyn CapabilityPolicy> = Arc::new(AllowAllPolicy);
        let engine = Arc::new(Engine::new(registry.clone(), policy, broker));
        Self {
            registry,
            engine,
            interactions,
            runs: Arc::new(Mutex::new(HashMap::new())),
            store: store::WorkflowStore::new(data_dir.join("workflows")),
        }
    }
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let data_dir = app
                .path()
                .app_data_dir()
                .map_err(|error| format!("cannot resolve app data directory: {error}"))?;
            app.manage(AppState::new(data_dir));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_node_specs,
            commands::validate_workflow,
            commands::run_workflow,
            commands::stop_workflow,
            commands::respond_interaction,
            commands::workflow_list,
            commands::save_workflow,
            commands::load_workflow,
            commands::delete_workflow,
        ])
        .run(tauri::generate_context!())
        .expect("failed to start LingXi desktop shell");
}
