mod commands;
mod fsutil;
mod policy;
mod redact;
mod runs;
mod single_instance;
mod store;
mod templates;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use lingxi_runtime::{
    CapabilityPolicy, CredentialResolver, Engine, InteractionBroker, NodeRegistry,
    PendingInteractions, RunControl, ServiceConfig,
};
use tauri::Manager;

use crate::runs::RunDatabase;
use crate::single_instance::InstanceLock;

pub struct AppState {
    pub registry: Arc<NodeRegistry>,
    pub engine: Arc<Engine>,
    pub interactions: Arc<PendingInteractions>,
    pub credentials: Arc<dyn CredentialResolver>,
    pub skills_root: Option<std::path::PathBuf>,
    pub runs: Arc<Mutex<HashMap<String, Arc<RunControl>>>>,
    pub store: store::WorkflowStore,
    pub templates: templates::TemplateStore,
    pub db: Arc<RunDatabase>,
    // Held for the lifetime of the app; dropping it releases the OS lock.
    _instance_lock: InstanceLock,
}

impl AppState {
    fn new(data_dir: std::path::PathBuf) -> Result<Self, String> {
        // Acquire the process guard before opening (and recovering) the run
        // database. A second instance must never mark the first one's live run
        // as interrupted.
        let instance_lock = InstanceLock::acquire(&data_dir.join("instance.lock.sqlite3"))?;
        let db = Arc::new(RunDatabase::open(&data_dir.join("runs.sqlite3"))?);
        let recovered = db.mark_interrupted_at_startup()?;
        if recovered > 0 {
            eprintln!("marked {recovered} unfinished run(s) as interrupted after restart");
        }
        let registry = Arc::new(NodeRegistry::builtin());
        let interactions = Arc::new(PendingInteractions::new());
        let broker: Arc<dyn InteractionBroker> = interactions.clone();
        let policy: Arc<dyn CapabilityPolicy> = Arc::new(policy::DeclaredCapabilityPolicy);
        let credentials: Arc<dyn CredentialResolver> =
            Arc::new(lingxi_runtime::credentials::BuiltinCredentials);
        let skills_root = lingxi_runtime::SkillLibrary::from_environment()
            .map(|library| library.root().to_path_buf())
            .or_else(|| {
                let path = data_dir.join("skills");
                path.is_dir().then_some(path)
            });
        let engine = Arc::new(Engine::with_services(
            registry.clone(),
            policy,
            broker,
            ServiceConfig {
                credentials: credentials.clone(),
                skills_root: skills_root.clone(),
            },
        ));
        Ok(Self {
            registry,
            engine,
            interactions,
            credentials,
            skills_root,
            runs: Arc::new(Mutex::new(HashMap::new())),
            store: store::WorkflowStore::new(data_dir.join("workflows")),
            templates: templates::TemplateStore::new(data_dir.join("templates")),
            db,
            _instance_lock: instance_lock,
        })
    }
}

pub fn run() {
    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default();

    // The automation bridge is compiled only for E2E builds. Production
    // binaries must never expose the WebDriver command surface.
    #[cfg(feature = "e2e")]
    {
        builder = builder
            .plugin(tauri_plugin_wdio::init())
            .plugin(tauri_plugin_wdio_webdriver::init());
    }

    let result = builder
        .setup(|app| {
            let data_dir = match std::env::var_os("LINGXI_DATA_DIR") {
                Some(path) if !path.is_empty() => std::path::PathBuf::from(path),
                _ => match app.path().app_data_dir() {
                    Ok(path) => path,
                    Err(error) => {
                        eprintln!(
                            "LingXiAgent cannot start: cannot resolve app data directory: {error}"
                        );
                        std::process::exit(1);
                    }
                },
            };
            let state = match AppState::new(data_dir) {
                Ok(state) => state,
                Err(error) => {
                    // Tauri turns a setup error into a panic/abort. A second
                    // instance must exit quietly instead of producing a crash
                    // report while the first instance keeps running.
                    eprintln!("LingXiAgent cannot start: {error}");
                    std::process::exit(1);
                }
            };
            app.manage(state);
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
            commands::template_list,
            commands::template_load,
            commands::template_save,
            commands::template_delete,
            commands::run_list,
            commands::run_detail,
            commands::run_events,
            commands::active_run,
            commands::credential_status,
            commands::credential_set,
            commands::credential_delete,
            commands::provider_models,
            commands::skill_list,
            commands::agent_template,
        ])
        .run(tauri::generate_context!());
    if let Err(error) = result {
        eprintln!("LingXiAgent cannot start: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lingxi_spec::Workflow;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_data_dir(tag: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "lingxi-app-state-{tag}-{}-{nanos}",
            std::process::id()
        ))
    }

    #[test]
    fn a_second_instance_cannot_interrupt_the_first_instances_run() {
        let dir = temp_data_dir("single-instance");
        let first = AppState::new(dir.clone()).expect("first instance should start");
        let workflow = Workflow::new("held by first instance");
        first
            .db
            .create_run("run-held", &workflow, 100)
            .expect("running record");

        let error = match AppState::new(dir.clone()) {
            Ok(_) => panic!("second instance must be refused"),
            Err(error) => error,
        };
        assert!(error.contains("already running"), "{error}");

        let held = first.db.run_detail("run-held").unwrap().unwrap();
        assert_eq!(
            held.run.status, "running",
            "the second instance must not run startup recovery"
        );

        drop(first);
        let second = AppState::new(dir.clone()).expect("lock is released with the first instance");
        let recovered = second.db.run_detail("run-held").unwrap().unwrap();
        assert_eq!(recovered.run.status, "interrupted");
        drop(second);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
