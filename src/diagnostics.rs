//! Opt-in error diagnostics, written only when CHAUMARCHY_LOG names a file.
//!
//! Every user-facing error in this wallet is a fixed string, which leaves no
//! way to tell a structural mint incompatibility from a transient network
//! failure. This records the operation that failed and the underlying library's
//! message, and nothing else: no password, recovery phrase, token, or request
//! body ever reaches it.
//!
//! Treat the file as sensitive anyway. A mint or database error can quote
//! protocol detail, so it is created 0600 and appended without rotation.
use std::fmt::Display;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn note(context: &str, error: &dyn Display) {
    let Some(path) = std::env::var_os("CHAUMARCHY_LOG") else {
        return;
    };
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.as_secs())
        .unwrap_or_default();
    // Bounded so a large mint response cannot fill the disk through the log.
    let message: String = format!("{seconds} {context}: {error}")
        .chars()
        .take(400)
        .collect();
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
    {
        let _ = writeln!(file, "{message}");
    }
}

/// Record why a step failed and report whether it succeeded, for the paths that
/// deliberately continue past a failure.
pub fn logged<T, E: Display>(context: &str, result: std::result::Result<T, E>) -> bool {
    match result {
        Ok(_) => true,
        Err(error) => {
            note(context, &error);
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn records_causes_only_when_a_destination_is_configured() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("diagnostics.log");
        std::env::remove_var("CHAUMARCHY_LOG");
        note("unconfigured", &"must not be written");
        assert!(!path.exists());

        std::env::set_var("CHAUMARCHY_LOG", &path);
        note("context", &"underlying failure");
        assert!(!logged("failing step", Err::<(), _>("cause")));
        assert!(logged("passing step", Ok::<_, &str>(())));
        note("bounded", &"x".repeat(5000));
        std::env::remove_var("CHAUMARCHY_LOG");

        let written = fs::read_to_string(&path).unwrap();
        assert!(written.contains("context: underlying failure"));
        assert!(written.contains("failing step: cause"));
        assert!(!written.contains("passing step"));
        assert!(!written.contains("unconfigured"));
        for line in written.lines() {
            assert!(line.chars().count() <= 400, "log lines stay bounded");
        }
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
