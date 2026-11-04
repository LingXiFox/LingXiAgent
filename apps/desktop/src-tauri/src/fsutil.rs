//! File replacement shared by the workflow and template stores.
//!
//! Unix `rename` atomically replaces an existing destination. Windows
//! `MoveFileEx` without `MOVEFILE_REPLACE_EXISTING` refuses to overwrite, so
//! retry after removing the old file. That fallback has a tiny gap between
//! removal and rename, but it is the only option without an extra Win32 crate.

use std::fs;
use std::io;
use std::path::Path;

pub(crate) fn replace_file(temp: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        match fs::rename(temp, destination) {
            Ok(()) => Ok(()),
            Err(error)
                if destination.exists()
                    && matches!(
                        error.kind(),
                        io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
                    ) =>
            {
                fs::remove_file(destination)?;
                fs::rename(temp, destination)
            }
            Err(error) => Err(error),
        }
    }
    #[cfg(not(windows))]
    {
        fs::rename(temp, destination)
    }
}
