//! What Settings changes and obid keeps across restarts, in `home/settings.json` (0600): how many
//! jobs run at once (docs/runner-api.md, "GET /v1/settings/jobs and PUT /v1/settings/jobs"), and
//! the owner's check-in (docs/runner-api.md, "obid only: check-ins (#1116)").

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// How many jobs may run at once: 1 to 20.
pub const MAX_RUNNING_RANGE: std::ops::RangeInclusive<u32> = 1..=20;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// How many jobs run at once (`status.maxRunning`).
    #[serde(default = "default_max_running")]
    pub max_running: u32,
    /// The owner's check-in, when they turned it on in a conversation (crate::brain::recap).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_in: Option<CheckIn>,
    /// The due time of the last summary a check-in posted, kept while they're off: never two on
    /// one day, even off and on again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_in_sent: Option<i64>,
}

/// When Oby checks in by itself, and where (#1116): set, changed and turned off only by the
/// owner's words in a conversation (`oby_check_in`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckIn {
    /// Daily, weekdays or weekly at a time: never hourly.
    pub schedule: crate::routines::Schedule,
    pub zone: String,
    /// The conversation it posts in: the one the owner asked in.
    pub conversation: String,
    /// What its next time counts from: when it was set, or the latest time it was due.
    pub from: i64,
}

impl CheckIn {
    /// Its time zone; one obid doesn't know reads as UTC.
    pub fn zone(&self) -> jiff::tz::TimeZone {
        jiff::tz::TimeZone::get(&self.zone).unwrap_or(jiff::tz::TimeZone::UTC)
    }
}

fn default_max_running() -> u32 {
    crate::api::MAX_RUNNING
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            max_running: default_max_running(),
            check_in: None,
            check_in_sent: None,
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

/// The settings in `home` changed by `change` and kept, one change at a time, so two never undo
/// each other: what `change` answers.
pub fn update<T>(home: &Path, change: impl FnOnce(&mut Settings) -> T) -> std::io::Result<T> {
    static ONE: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
    let mut settings = load(home);
    let answer = change(&mut settings);
    save(home, &settings)?;
    Ok(answer)
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
        save(
            &home,
            &Settings {
                max_running: 3,
                ..Settings::default()
            },
        )
        .unwrap();
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
