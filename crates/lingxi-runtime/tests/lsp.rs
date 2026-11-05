mod common;

use std::time::{SystemTime, UNIX_EPOCH};

use lingxi_runtime::lsp::{LspClient, LspConfig};
use lingxi_runtime::workspace::{Workspace, ABSENT_VERSION};

fn fixture() -> String {
    format!(
        "{}/../../fixtures/mock-lsp/server.py",
        env!("CARGO_MANIFEST_DIR")
    )
}

#[tokio::test]
async fn lsp_client_returns_real_diagnostics_and_symbols() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lingxi-lsp-{}-{unique}", std::process::id()));
    let workspace = Workspace::open(&root).expect("workspace");
    workspace
        .write(
            "src/demo.py",
            "# TODO: fix this\ndef mock_fn():\n    return 1\n",
            ABSENT_VERSION,
        )
        .expect("seed file");

    let config = LspConfig::new(
        common::python_bin(),
        vec![fixture()],
        workspace.root().to_path_buf(),
    );
    let mut client = LspClient::spawn(&config).await.expect("spawn lsp");
    client.initialize().await.expect("initialize");

    let diagnostics = client
        .diagnostics(&workspace, "src/demo.py")
        .await
        .expect("diagnostics");
    assert_eq!(diagnostics.len(), 1, "fixture emits exactly one diagnostic");
    assert_eq!(diagnostics[0].line, 0);
    assert_eq!(diagnostics[0].severity, Some(2));
    assert!(diagnostics[0].message.contains("TODO"));

    let symbols = client
        .symbols(&workspace, "src/demo.py")
        .await
        .expect("symbols");
    assert_eq!(symbols.len(), 1);
    assert_eq!(symbols[0].name, "mock_fn");
    assert_eq!(symbols[0].kind, 12);
    assert_eq!(symbols[0].line, 1);

    client.shutdown().await;
    let _ = std::fs::remove_dir_all(&root);
}
