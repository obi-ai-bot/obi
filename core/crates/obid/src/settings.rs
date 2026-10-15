//! What Settings changes and obid keeps across restarts, in `home/settings.json` (0600): how many
//! jobs run at once (docs/runner-api.md, "GET /v1/settings/jobs and PUT /v1/settings/jobs").

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// How many jobs may run at once: 1 to 20.
pub const MAX_RUNNING_RANGE: std::ops::RangeInclusive<u32> = 1..=20;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// How many jobs run at once (`status.maxRunning`).
    #[serde(default = "default_max_running")]
    pub max_running: u32,
}

fn default_max_running() -> u32 {
    crate::api::MAX_RUNNING
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            max_running: default_max_running(),
        }
    }
}

/// Where the settings are kept.
pub fn path(home: &Path) -> PathBuf {
    home.join("settings.json")
}

/// The settings kept in `home`, or the defaults when there are none. A file that doesn't read, or
/// holds a value out of range, gives the defaults for what it can't say, and is logged.
pub fn load(home: &Path) -> Settings {
    let file = path(home);
    let mut settings = match std::fs::read(&file) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Settings::default(),
        Err(e) => {
            tracing::warn!("can't read {}: {e}", file.display());
            Settings::default()
        }
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
            tracing::warn!("{} doesn't read: {e}", file.display());
            Settings::default()
        }),
    };
    if !MAX_RUNNING_RANGE.contains(&settings.max_running) {
        tracing::warn!(
            "{} says maxRunning {}, which isn't 1 to 20",
            file.display(),
            settings.max_running
        );
        settings.max_running = default_max_running();
    }
    settings
}

/// Keeps `settings` in `home`.
pub fn save(home: &Path, settings: &Settings) -> std::io::Result<()> {
    let text = serde_json::to_vec_pretty(settings).map_err(std::io::Error::other)?;
    crate::store::write_private(&path(home), &text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kept_and_read_back_with_defaults_for_what_isnt_there() {
        let home = std::env::temp_dir().join(format!("obid-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        assert_eq!(load(&home).max_running, 6);
        save(&home, &Settings { max_running: 3 }).unwrap();
        assert_eq!(load(&home).max_running, 3);
        std::fs::write(path(&home), r#"{"maxRunning": 99}"#).unwrap();
        assert_eq!(load(&home).max_running, 6);
        std::fs::write(path(&home), "{").unwrap();
        assert_eq!(load(&home).max_running, 6);
        std::fs::write(path(&home), "{}").unwrap();
        assert_eq!(load(&home).max_running, 6);
        let _ = std::fs::remove_dir_all(&home);
    }
}
