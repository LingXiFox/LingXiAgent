//! Durable run history. This module is deliberately confined to the desktop
//! shell: the runtime knows only about EventSink, never about SQLite.

use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use lingxi_runtime::{RunCause, RunEvent, RunStatus};
use lingxi_spec::Workflow;
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;

use crate::redact::{redact_event, redact_json, redact_text};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS runs (
    run_id          TEXT PRIMARY KEY,
    workflow_id     TEXT NOT NULL,
    workflow_name   TEXT NOT NULL,
    status          TEXT NOT NULL,
    cause           TEXT,
    detail          TEXT,
    started_at_ms   INTEGER NOT NULL,
    finished_at_ms  INTEGER,
    duration_ms     INTEGER,
    node_count      INTEGER NOT NULL,
    workflow_json   TEXT NOT NULL,
    last_seq        INTEGER NOT NULL DEFAULT -1
);
CREATE TABLE IF NOT EXISTS run_events (
    run_id      TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,
    at_ms       INTEGER NOT NULL,
    event_type  TEXT NOT NULL,
    payload     TEXT NOT NULL,
    PRIMARY KEY (run_id, seq)
);
CREATE INDEX IF NOT EXISTS run_events_run_seq ON run_events(run_id, seq);
"#;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecord {
    pub run_id: String,
    pub workflow_id: String,
    pub workflow_name: String,
    pub status: String,
    pub cause: Option<String>,
    pub detail: Option<String>,
    pub started_at_ms: u64,
    pub finished_at_ms: Option<u64>,
    pub duration_ms: Option<u64>,
    pub node_count: u64,
    pub last_seq: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunDetail {
    pub run: RunRecord,
    pub workflow: Workflow,
    pub events: Vec<RunEvent>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppendOutcome {
    Appended,
    Duplicate,
}

pub struct RunDatabase {
    connection: Mutex<Connection>,
}

impl RunDatabase {
    pub fn open(path: &Path) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create run database directory: {error}"))?;
        }
        let connection = Connection::open(path)
            .map_err(|error| format!("cannot open run database {}: {error}", path.display()))?;
        Self::from_connection(connection)
    }

    pub fn open_in_memory() -> Result<Self, String> {
        Self::from_connection(
            Connection::open_in_memory()
                .map_err(|error| format!("cannot open memory db: {error}"))?,
        )
    }

    fn from_connection(connection: Connection) -> Result<Self, String> {
        connection
            .execute_batch(
                "PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;",
            )
            .map_err(|error| format!("cannot configure run database: {error}"))?;
        connection
            .execute_batch(SCHEMA)
            .map_err(|error| format!("cannot initialize run database schema: {error}"))?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    pub fn create_run(
        &self,
        run_id: &str,
        workflow: &Workflow,
        started_at_ms: u64,
    ) -> Result<(), String> {
        let workflow_json = redacted_workflow_json(workflow)?;
        let workflow_name = redact_text(&workflow.name);
        let connection = self.lock()?;
        connection
            .execute(
                "INSERT INTO runs (run_id, workflow_id, workflow_name, status, started_at_ms, node_count, workflow_json, last_seq)
                 VALUES (?1, ?2, ?3, 'running', ?4, ?5, ?6, -1)",
                params![
                    run_id,
                    workflow.id,
                    workflow_name,
                    started_at_ms as i64,
                    workflow.nodes.len() as i64,
                    workflow_json
                ],
            )
            .map_err(|error| format!("cannot create run record: {error}"))?;
        Ok(())
    }

    pub fn append_event(&self, event: &RunEvent) -> Result<AppendOutcome, String> {
        let run_id = event.run_id();
        let seq = event.seq() as i64;
        let payload = redacted_event_json(event)?;
        let mut connection = self.lock()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("cannot begin event transaction: {error}"))?;
        let last_seq: i64 = transaction
            .query_row(
                "SELECT last_seq FROM runs WHERE run_id = ?1",
                params![run_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| format!("cannot read run sequence: {error}"))?
            .ok_or_else(|| format!("run {run_id} does not exist"))?;

        if seq <= last_seq {
            transaction
                .commit()
                .map_err(|error| format!("cannot close duplicate event transaction: {error}"))?;
            return Ok(AppendOutcome::Duplicate);
        }
        if seq != last_seq + 1 {
            return Err(format!(
                "event sequence gap for run {run_id}: expected {}, received {seq}",
                last_seq + 1
            ));
        }

        let at_ms = now_ms();
        transaction
            .execute(
                "INSERT INTO run_events (run_id, seq, at_ms, event_type, payload)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![run_id, seq, at_ms as i64, event_type(event), payload],
            )
            .map_err(|error| format!("cannot append run event {seq}: {error}"))?;
        transaction
            .execute(
                "UPDATE runs SET last_seq = ?1 WHERE run_id = ?2",
                params![seq, run_id],
            )
            .map_err(|error| format!("cannot advance run sequence: {error}"))?;

        if let RunEvent::RunFinished {
            status,
            cause,
            detail,
            duration_ms,
            ..
        } = event
        {
            transaction
                .execute(
                    "UPDATE runs SET status = ?1, cause = ?2, detail = ?3, finished_at_ms = ?4, duration_ms = ?5
                     WHERE run_id = ?6",
                    params![
                        status_str(*status),
                        cause.map(cause_str),
                        detail.as_deref().map(redact_text),
                        at_ms as i64,
                        *duration_ms as i64,
                        run_id
                    ],
                )
                .map_err(|error| format!("cannot persist terminal run state: {error}"))?;
        }

        transaction
            .commit()
            .map_err(|error| format!("cannot commit run event: {error}"))?;
        Ok(AppendOutcome::Appended)
    }

    /// Any run still marked running when the app starts did not finish
    /// normally. It is marked interrupted, never completed, and is not resumed.
    pub fn mark_interrupted_at_startup(&self) -> Result<usize, String> {
        let mut connection = self.lock()?;
        let run_ids = {
            let mut statement = connection
                .prepare("SELECT run_id FROM runs WHERE status = 'running' ORDER BY started_at_ms")
                .map_err(|error| format!("cannot query unfinished runs: {error}"))?;
            let rows = statement
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|error| format!("cannot read unfinished runs: {error}"))?;
            let mut ids = Vec::new();
            for row in rows {
                ids.push(row.map_err(|error| format!("cannot read unfinished run id: {error}"))?);
            }
            ids
        };
        let mut count = 0;
        for run_id in run_ids {
            if interrupt_run(
                &mut connection,
                &run_id,
                "app restarted before the run finished",
            )? {
                count += 1;
            }
        }
        Ok(count)
    }

    pub fn mark_interrupted(&self, run_id: &str, detail: &str) -> Result<bool, String> {
        let mut connection = self.lock()?;
        interrupt_run(&mut connection, run_id, detail)
    }

    pub fn list_runs(&self, limit: u32) -> Result<Vec<RunRecord>, String> {
        let connection = self.lock()?;
        let mut statement = connection
            .prepare(
                "SELECT run_id, workflow_id, workflow_name, status, cause, detail, started_at_ms,
                        finished_at_ms, duration_ms, node_count, last_seq
                 FROM runs ORDER BY started_at_ms DESC LIMIT ?1",
            )
            .map_err(|error| format!("cannot list runs: {error}"))?;
        let rows = statement
            .query_map(params![limit.max(1) as i64], row_to_record)
            .map_err(|error| format!("cannot read run list: {error}"))?;
        let mut runs = Vec::new();
        for row in rows {
            runs.push(row.map_err(|error| format!("cannot decode run record: {error}"))?);
        }
        Ok(runs)
    }

    pub fn run_detail(&self, run_id: &str) -> Result<Option<RunDetail>, String> {
        let connection = self.lock()?;
        detail_locked(&connection, run_id)
    }

    pub fn active_run(&self) -> Result<Option<RunDetail>, String> {
        let run_id = {
            let connection = self.lock()?;
            connection
                .query_row(
                    "SELECT run_id FROM runs WHERE status = 'running' ORDER BY started_at_ms DESC LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| format!("cannot query active run: {error}"))?
        };
        match run_id {
            Some(run_id) => self.run_detail(&run_id),
            None => Ok(None),
        }
    }

    pub fn latest_run(&self) -> Result<Option<RunDetail>, String> {
        let run_id = {
            let connection = self.lock()?;
            connection
                .query_row(
                    "SELECT run_id FROM runs ORDER BY started_at_ms DESC LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| format!("cannot query latest run: {error}"))?
        };
        match run_id {
            Some(run_id) => self.run_detail(&run_id),
            None => Ok(None),
        }
    }

    pub fn run_events(
        &self,
        run_id: &str,
        after_seq: Option<u64>,
    ) -> Result<Vec<RunEvent>, String> {
        let connection = self.lock()?;
        let after_seq = after_seq.map(|value| value as i64).unwrap_or(-1);
        events_locked(&connection, run_id, after_seq)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>, String> {
        self.connection
            .lock()
            .map_err(|_| "run database lock is poisoned".to_string())
    }
}

fn detail_locked(connection: &Connection, run_id: &str) -> Result<Option<RunDetail>, String> {
    let run = connection
        .query_row(
            "SELECT run_id, workflow_id, workflow_name, status, cause, detail, started_at_ms,
                    finished_at_ms, duration_ms, node_count, last_seq
             FROM runs WHERE run_id = ?1",
            params![run_id],
            row_to_record,
        )
        .optional()
        .map_err(|error| format!("cannot read run {run_id}: {error}"))?;
    let Some(run) = run else {
        return Ok(None);
    };
    let workflow_json: String = connection
        .query_row(
            "SELECT workflow_json FROM runs WHERE run_id = ?1",
            params![run_id],
            |row| row.get(0),
        )
        .map_err(|error| format!("cannot read run workflow: {error}"))?;
    let workflow: Workflow = serde_json::from_str(&workflow_json)
        .map_err(|error| format!("cannot decode run workflow: {error}"))?;
    let events = events_locked(connection, run_id, -1)?;
    Ok(Some(RunDetail {
        run,
        workflow,
        events,
    }))
}

fn events_locked(
    connection: &Connection,
    run_id: &str,
    after_seq: i64,
) -> Result<Vec<RunEvent>, String> {
    let mut statement = connection
        .prepare(
            "SELECT seq, payload FROM run_events WHERE run_id = ?1 AND seq > ?2 ORDER BY seq ASC",
        )
        .map_err(|error| format!("cannot read run events: {error}"))?;
    let rows = statement
        .query_map(params![run_id, after_seq], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|error| format!("cannot query run events: {error}"))?;
    let mut events = Vec::new();
    for row in rows {
        let (seq, payload) =
            row.map_err(|error| format!("cannot decode run event row: {error}"))?;
        let event: RunEvent = serde_json::from_str(&payload)
            .map_err(|error| format!("cannot decode run event {seq}: {error}"))?;
        events.push(event);
    }
    Ok(events)
}

fn interrupt_run(connection: &mut Connection, run_id: &str, detail: &str) -> Result<bool, String> {
    let detail = redact_text(detail);
    let state: Option<(i64, i64, String)> = connection
        .query_row(
            "SELECT last_seq, started_at_ms, status FROM runs WHERE run_id = ?1",
            params![run_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|error| format!("cannot read run {run_id} for interruption: {error}"))?;
    let Some((last_seq, started_at_ms, status)) = state else {
        return Ok(false);
    };
    if status != "running" {
        return Ok(false);
    }
    let now = now_ms();
    let duration_ms = now.saturating_sub(started_at_ms as u64);
    let seq = (last_seq + 1).max(0) as u64;
    let event = RunEvent::RunFinished {
        run_id: run_id.to_string(),
        seq,
        status: RunStatus::Interrupted,
        cause: Some(RunCause::Interrupted),
        detail: Some(detail.clone()),
        duration_ms,
    };
    let payload = redacted_event_json(&event)?;
    let transaction = connection
        .transaction()
        .map_err(|error| format!("cannot begin interruption transaction: {error}"))?;
    transaction
        .execute(
            "INSERT INTO run_events (run_id, seq, at_ms, event_type, payload) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![run_id, seq as i64, now as i64, event_type(&event), payload],
        )
        .map_err(|error| format!("cannot append interruption event: {error}"))?;
    transaction
        .execute(
            "UPDATE runs SET status = 'interrupted', cause = 'interrupted', detail = ?1,
                    finished_at_ms = ?2, duration_ms = ?3, last_seq = ?4 WHERE run_id = ?5",
            params![detail, now as i64, duration_ms as i64, seq as i64, run_id],
        )
        .map_err(|error| format!("cannot mark run interrupted: {error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("cannot commit interruption: {error}"))?;
    Ok(true)
}

fn row_to_record(row: &Row<'_>) -> rusqlite::Result<RunRecord> {
    let started_at_ms: i64 = row.get(6)?;
    let finished_at_ms: Option<i64> = row.get(7)?;
    let duration_ms: Option<i64> = row.get(8)?;
    let node_count: i64 = row.get(9)?;
    Ok(RunRecord {
        run_id: row.get(0)?,
        workflow_id: row.get(1)?,
        workflow_name: row.get(2)?,
        status: row.get(3)?,
        cause: row.get(4)?,
        detail: row
            .get::<_, Option<String>>(5)?
            .map(|text| redact_text(&text)),
        started_at_ms: started_at_ms.max(0) as u64,
        finished_at_ms: finished_at_ms.map(|value| value.max(0) as u64),
        duration_ms: duration_ms.map(|value| value.max(0) as u64),
        node_count: node_count.max(0) as u64,
        last_seq: row.get(10)?,
    })
}

fn status_str(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Completed => "completed",
        RunStatus::Failed => "failed",
        RunStatus::Cancelled => "cancelled",
        RunStatus::Interrupted => "interrupted",
    }
}

fn cause_str(cause: RunCause) -> &'static str {
    match cause {
        RunCause::ValidationFailed => "validation_failed",
        RunCause::NodeFailed => "node_failed",
        RunCause::Cancelled => "cancelled",
        RunCause::EngineError => "engine_error",
        RunCause::Interrupted => "interrupted",
    }
}

fn event_type(event: &RunEvent) -> &'static str {
    match event {
        RunEvent::RunStarted { .. } => "run.started",
        RunEvent::NodeStarted { .. } => "node.started",
        RunEvent::NodeFinished { .. } => "node.finished",
        RunEvent::NodeFailed { .. } => "node.failed",
        RunEvent::NodeSkipped { .. } => "node.skipped",
        RunEvent::NodeCancelled { .. } => "node.cancelled",
        RunEvent::Log { .. } => "log",
        RunEvent::InteractionRequested { .. } => "interaction.requested",
        RunEvent::InteractionResolved { .. } => "interaction.resolved",
        RunEvent::RunFinished { .. } => "run.finished",
    }
}

fn redacted_event_json(event: &RunEvent) -> Result<String, String> {
    // redact_event is the single event-redaction contract shared by the live
    // bridge and the SQLite payload. Keeping one implementation prevents the
    // two sinks from drifting (for example, top-level NodeFinished outputs).
    serde_json::to_string(&redact_event(event))
        .map_err(|error| format!("cannot encode redacted event: {error}"))
}

fn redacted_workflow_json(workflow: &Workflow) -> Result<String, String> {
    let mut value = serde_json::to_value(workflow)
        .map_err(|error| format!("cannot encode run workflow: {error}"))?;
    redact_json(&mut value);
    serde_json::to_string(&value)
        .map_err(|error| format!("cannot encode redacted workflow: {error}"))
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::redact::{redact_event, REDACTED};
    use lingxi_spec::{Position, WorkflowNode};
    use serde_json::{json, Value};

    fn workflow_with_secret() -> Workflow {
        let mut workflow = Workflow::new("token=workflow-secret");
        let mut node = WorkflowNode::new("n1", "core.text_input", Position::default());
        node.params
            .insert("apiKey".to_string(), Value::from("sk-should-not-persist"));
        workflow.nodes.push(node);
        workflow
    }

    #[test]
    fn terminal_state_and_events_are_persisted() {
        let db = RunDatabase::open_in_memory().unwrap();
        let workflow = Workflow::new("run test");
        db.create_run("run-1", &workflow, 100).unwrap();
        db.append_event(&RunEvent::RunStarted {
            run_id: "run-1".into(),
            seq: 0,
            workflow_id: workflow.id.clone(),
            workflow_name: workflow.name.clone(),
            node_count: 0,
        })
        .unwrap();
        db.append_event(&RunEvent::Log {
            run_id: "run-1".into(),
            seq: 1,
            at_ms: 110,
            level: lingxi_runtime::LogLevel::Info,
            node_id: None,
            message: "hello".into(),
        })
        .unwrap();
        db.append_event(&RunEvent::RunFinished {
            run_id: "run-1".into(),
            seq: 2,
            status: RunStatus::Completed,
            cause: None,
            detail: None,
            duration_ms: 12,
        })
        .unwrap();

        let detail = db.run_detail("run-1").unwrap().unwrap();
        assert_eq!(detail.run.status, "completed");
        assert_eq!(detail.run.duration_ms, Some(12));
        assert_eq!(detail.events.len(), 3);
        assert_eq!(detail.events[2].seq(), 2);
        assert_eq!(db.list_runs(10).unwrap().len(), 1);
    }

    #[test]
    fn gaps_are_rejected_and_duplicates_are_ignored() {
        let db = RunDatabase::open_in_memory().unwrap();
        db.create_run("run-1", &Workflow::new("gap test"), 100)
            .unwrap();
        let first = RunEvent::RunStarted {
            run_id: "run-1".into(),
            seq: 0,
            workflow_id: "w".into(),
            workflow_name: "w".into(),
            node_count: 0,
        };
        assert_eq!(db.append_event(&first).unwrap(), AppendOutcome::Appended);
        assert_eq!(db.append_event(&first).unwrap(), AppendOutcome::Duplicate);
        let gap = RunEvent::RunFinished {
            run_id: "run-1".into(),
            seq: 2,
            status: RunStatus::Completed,
            cause: None,
            detail: None,
            duration_ms: 1,
        };
        assert!(db.append_event(&gap).unwrap_err().contains("gap"));
        assert_eq!(db.run_events("run-1", None).unwrap().len(), 1);
        assert_eq!(db.run_events("run-1", Some(0)).unwrap().len(), 0);
    }

    #[test]
    fn write_failures_are_reported() {
        let db = RunDatabase::open_in_memory().unwrap();
        db.create_run("run-1", &Workflow::new("write failure"), 100)
            .unwrap();
        db.connection
            .lock()
            .unwrap()
            .execute_batch("PRAGMA query_only = ON;")
            .unwrap();

        let error = db
            .append_event(&RunEvent::RunStarted {
                run_id: "run-1".into(),
                seq: 0,
                workflow_id: "w".into(),
                workflow_name: "w".into(),
                node_count: 0,
            })
            .unwrap_err();
        assert!(
            error.contains("cannot append run event"),
            "unexpected error: {error}"
        );
        assert_eq!(db.run_events("run-1", None).unwrap().len(), 0);
    }

    #[test]
    fn startup_marks_running_runs_interrupted() {
        let db = RunDatabase::open_in_memory().unwrap();
        db.create_run("run-1", &Workflow::new("interrupt test"), 100)
            .unwrap();
        db.append_event(&RunEvent::RunStarted {
            run_id: "run-1".into(),
            seq: 0,
            workflow_id: "w".into(),
            workflow_name: "w".into(),
            node_count: 0,
        })
        .unwrap();

        assert_eq!(db.mark_interrupted_at_startup().unwrap(), 1);
        let detail = db.run_detail("run-1").unwrap().unwrap();
        assert_eq!(detail.run.status, "interrupted");
        assert_eq!(detail.run.cause.as_deref(), Some("interrupted"));
        assert!(detail.run.finished_at_ms.is_some());
        assert!(matches!(
            detail.events.last(),
            Some(RunEvent::RunFinished {
                status: RunStatus::Interrupted,
                ..
            })
        ));
        assert_eq!(db.mark_interrupted_at_startup().unwrap(), 0);
    }

    #[test]
    fn persisted_events_match_live_redaction_for_top_level_outputs() {
        let db = RunDatabase::open_in_memory().unwrap();
        db.create_run("run-1", &Workflow::new("redaction parity"), 100)
            .unwrap();
        let event = RunEvent::NodeFinished {
            run_id: "run-1".into(),
            seq: 0,
            node_id: "n1".into(),
            kind: "core.log".into(),
            label: "safe label".into(),
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
        let live = redact_event(&event);
        db.append_event(&event).unwrap();
        let stored = db.run_events("run-1", None).unwrap().pop().unwrap();
        assert_eq!(
            serde_json::to_value(&stored).unwrap(),
            serde_json::to_value(&live).unwrap(),
            "persisted and live events must carry identical redaction"
        );
        let RunEvent::NodeFinished { outputs, .. } = stored else {
            panic!("expected node finished");
        };
        assert_eq!(outputs["apiKey"], REDACTED);
        assert_eq!(outputs["payload"]["accessToken"], REDACTED);
        assert_eq!(outputs["payload"]["safe"], "keep");
    }

    #[test]
    fn terminal_detail_is_redacted_in_the_run_record() {
        let db = RunDatabase::open_in_memory().unwrap();
        db.create_run("run-1", &Workflow::new("detail redaction"), 100)
            .unwrap();
        db.append_event(&RunEvent::RunFinished {
            run_id: "run-1".into(),
            seq: 0,
            status: RunStatus::Failed,
            cause: Some(RunCause::NodeFailed),
            detail: Some("token=super-secret".into()),
            duration_ms: 2,
        })
        .unwrap();

        let raw: String = db
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT detail FROM runs WHERE run_id = 'run-1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(raw, "token=[REDACTED]");
        let detail = db.run_detail("run-1").unwrap().unwrap();
        assert_eq!(detail.run.detail.as_deref(), Some("token=[REDACTED]"));
    }

    #[test]
    fn secrets_are_redacted_before_sqlite() {
        let db = RunDatabase::open_in_memory().unwrap();
        db.create_run("run-1", &workflow_with_secret(), 100)
            .unwrap();
        db.append_event(&RunEvent::Log {
            run_id: "run-1".into(),
            seq: 0,
            at_ms: 110,
            level: lingxi_runtime::LogLevel::Info,
            node_id: None,
            message: "token=super-secret and sk-abcdefghijklmnop".into(),
        })
        .unwrap();

        let detail = db.run_detail("run-1").unwrap().unwrap();
        assert_eq!(
            detail.workflow.nodes[0].params.get("apiKey"),
            Some(&Value::from(REDACTED))
        );
        assert!(detail.run.workflow_name.contains(REDACTED));
        assert!(!detail.run.workflow_name.contains("workflow-secret"));
        let Some(RunEvent::Log { message, .. }) = detail.events.first() else {
            panic!("expected log event");
        };
        assert!(!message.contains("super-secret"));
        assert!(!message.contains("sk-abcdefghijklmnop"));
        assert!(message.contains(REDACTED));
    }
}
