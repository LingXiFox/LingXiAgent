//! Cross-process instance guard.
//!
//! SQLite already provides OS-level file locking on every supported desktop
//! platform. The first process holds an exclusive transaction on a dedicated
//! lock database for its entire lifetime; a second process fails to acquire it
//! before it can touch the run database or run startup recovery.

use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::Connection;

pub struct InstanceLock {
    connection: Mutex<Connection>,
}

impl InstanceLock {
    pub fn acquire(path: &Path) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create instance lock directory: {error}"))?;
        }
        let connection = Connection::open(path)
            .map_err(|error| format!("cannot open instance lock {}: {error}", path.display()))?;
        connection
            .busy_timeout(Duration::from_millis(250))
            .map_err(|error| format!("cannot configure instance lock timeout: {error}"))?;
        connection
            .execute_batch("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE;")
            .map_err(|error| {
                if lock_conflict(&error) {
                    "another LingXiAgent instance is already running".to_string()
                } else {
                    format!("cannot acquire instance lock {}: {error}", path.display())
                }
            })?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }
}

impl Drop for InstanceLock {
    fn drop(&mut self) {
        if let Ok(connection) = self.connection.lock() {
            let _ = connection.execute_batch("ROLLBACK;");
        }
    }
}

fn lock_conflict(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(code, _)
            if matches!(
                code.code,
                rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
            )
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_lock_path(tag: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!(
                "lingxi-instance-lock-{tag}-{}-{nanos}",
                std::process::id()
            ))
            .join("instance.lock.sqlite3")
    }

    #[test]
    fn a_second_owner_is_refused_until_the_first_releases() {
        let path = temp_lock_path("unit");
        let first = InstanceLock::acquire(&path).unwrap();
        let error = match InstanceLock::acquire(&path) {
            Ok(_) => panic!("second lock should fail"),
            Err(error) => error,
        };
        assert!(error.contains("already running"), "{error}");
        drop(first);
        let second = InstanceLock::acquire(&path).unwrap();
        drop(second);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
