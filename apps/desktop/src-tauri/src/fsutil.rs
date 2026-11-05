//! File replacement shared by the workflow and template stores.
//!
//! Unix `rename` atomically replaces an existing destination. Windows
//! `ReplaceFileW` performs the equivalent safe commit while keeping a backup
//! handle open, so a failed replacement leaves the original file intact.
//! A missing destination is created with a plain rename.

use std::fs;
use std::io;
use std::path::Path;

pub(crate) fn replace_file(temp: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        if !destination.exists() {
            return fs::rename(temp, destination);
        }
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::ReplaceFileW;
        let wide = |path: &Path| -> Vec<u16> {
            path.as_os_str()
                .encode_wide()
                .chain(std::iter::once(0))
                .collect()
        };
        let replaced = wide(destination);
        let replacement = wide(temp);
        // No backup file, no exclude list, no reserved argument. The function
        // fails instead of deleting the destination when the replacement is
        // unreadable, which is the property the previous remove-then-rename
        // fallback did not have.
        let result = unsafe {
            ReplaceFileW(
                replaced.as_ptr(),
                replacement.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        if result == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
    #[cfg(not(windows))]
    {
        fs::rename(temp, destination)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static SCRATCH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn scratch_dir() -> std::path::PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or_default();
        // Parallel tests can sample the same nanosecond; the sequence keeps
        // each test's directory independent. Both files must also live in the
        // same directory, because that is what makes the rename atomic.
        let sequence = SCRATCH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "lingxi-fsutil-{}-{unique}-{sequence}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).expect("create scratch dir");
        dir
    }

    #[test]
    fn replaces_an_existing_file_and_cleans_the_temp() {
        let dir = scratch_dir();
        let destination = dir.join("workflow.json");
        let temp = dir.join("workflow.json.tmp");
        fs::write(&destination, b"old").expect("write old");
        fs::write(&temp, b"new").expect("write new");

        replace_file(&temp, &destination).expect("replace");

        assert_eq!(fs::read(&destination).expect("read"), b"new");
        assert!(!temp.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failed_replacement_leaves_the_original_intact() {
        let dir = scratch_dir();
        let destination = dir.join("workflow.json");
        let missing_temp = dir.join("missing.tmp");
        fs::write(&destination, b"original").expect("write original");

        let error = replace_file(&missing_temp, &destination).expect_err("must fail");

        assert!(matches!(
            error.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied | io::ErrorKind::Other
        ));
        assert_eq!(fs::read(&destination).expect("read"), b"original");
        let _ = fs::remove_dir_all(&dir);
    }
}
