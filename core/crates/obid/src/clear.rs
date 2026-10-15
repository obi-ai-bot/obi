//! Clear done (docs/runner-api.md, "POST /v1/clear"): when it was last pressed, on any app, kept in
//! `home/cleared.json` so it survives a restart. The clock never goes back: a clear earlier than
//! the last one keeps the later time.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct Cleared {
    file: PathBuf,
    at: Mutex<Option<i64>>,
}

impl Cleared {
    /// The last clear kept in `home/cleared.json`, or none. A file that doesn't read as one is
    /// left as it is and counts as none; the next clear writes it afresh.
    pub fn open(home: &Path) -> Cleared {
        let file = home.join("cleared.json");
        let at = match std::fs::read(&file) {
            Ok(bytes) => serde_json::from_slice::<serde_json::Value>(&bytes)
                .ok()
                .and_then(|value| {
                    value
                        .get("clearedAt")
                        .and_then(serde_json::Value::as_str)
                        .and_then(obi_protocol::time::parse)
                })
                .or_else(|| {
                    tracing::warn!("{} isn't a clear: nothing is cleared", file.display());
                    None
                }),
            Err(_) => None,
        };
        Cleared {
            file,
            at: Mutex::new(at),
        }
    }

    /// When Clear done was last pressed, in seconds since 1970.
    pub fn at(&self) -> Option<i64> {
        *self.at.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Clears at `now`, or keeps the later time already there, and writes it down before it
    /// answers.
    pub fn clear(&self, now: i64) -> std::io::Result<i64> {
        let mut at = self.at.lock().unwrap_or_else(|e| e.into_inner());
        let time = at.map_or(now, |last| last.max(now));
        let body = serde_json::json!({"clearedAt": obi_protocol::time::format(time)});
        crate::store::write_private(&self.file, body.to_string().as_bytes())?;
        *at = Some(time);
        Ok(time)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("obid-clear-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    /// ClearTests.theClearSurvivesARestartAndNeverGoesBack, the part only a clock the test sets
    /// can show: an earlier clear (a clock put right) keeps the later time, and garbage in the
    /// file is no clear.
    #[test]
    fn the_clear_survives_a_restart_and_never_goes_back() {
        let home = folder("back");
        let now = 1_791_582_173;
        let first = Cleared::open(&home);
        assert_eq!(first.at(), None);
        assert_eq!(first.clear(now).unwrap(), now);
        assert_eq!(Cleared::open(&home).at(), Some(now));
        let kept = std::fs::read_to_string(home.join("cleared.json")).unwrap();
        assert!(
            kept.contains(r#""clearedAt":"2026-10-09T21:42:53Z""#),
            "{kept}"
        );
        assert_eq!(first.clear(now + 60).unwrap(), now + 60);
        assert_eq!(first.clear(now - 60).unwrap(), now + 60);
        assert_eq!(Cleared::open(&home).at(), Some(now + 60));
        std::fs::write(home.join("cleared.json"), "{").unwrap();
        let broken = Cleared::open(&home);
        assert_eq!(broken.at(), None);
        assert_eq!(broken.clear(now).unwrap(), now);
        assert_eq!(Cleared::open(&home).at(), Some(now));
        let _ = std::fs::remove_dir_all(&home);
    }
}
