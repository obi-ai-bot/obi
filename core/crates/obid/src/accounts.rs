//! Subscription usage and the owner's weekly reserve, kept privately across restarts.
use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Usage {
    pub five_hour: Option<f64>,
    pub seven_day: Option<f64>,
    pub five_hour_resets: Option<i64>,
    pub seven_day_resets: Option<i64>,
    pub full_until: Option<i64>,
    pub reserve_lifted_until: Option<i64>,
}
impl Usage {
    pub fn reserved(&self, now: i64) -> bool {
        self.seven_day.unwrap_or(0.0) >= 0.8
            && self.seven_day_resets.is_none_or(|at| at > now)
            && self.reserve_lifted_until.is_none_or(|at| at <= now)
    }
    pub fn eligible(&self, named: bool, now: i64) -> bool {
        let below = |used: Option<f64>, reset: Option<i64>| {
            used.unwrap_or(0.0) < 0.95 || reset.is_some_and(|at| at <= now)
        };
        self.full_until.is_none_or(|at| at <= now)
            && below(self.five_hour, self.five_hour_resets)
            && below(self.seven_day, self.seven_day_resets)
            && (named || !self.reserved(now))
    }
}
pub struct Accounts {
    file: PathBuf,
    state: Mutex<HashMap<String, Usage>>,
    blocked: bool,
}
impl Accounts {
    pub fn open(home: &Path) -> Self {
        let file = home.join("account-usage.json");
        let (state, blocked) = match std::fs::read(&file) {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(state) => (state, false),
                Err(_) => {
                    tracing::warn!("account usage does not read; accounts are held until repaired");
                    (HashMap::new(), true)
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (HashMap::new(), false),
            Err(_) => (HashMap::new(), true),
        };
        Self {
            file,
            state: Mutex::new(state),
            blocked,
        }
    }
    pub fn get(&self, id: &str) -> Usage {
        if self.blocked {
            return Usage {
                full_until: Some(253402300799),
                ..Usage::default()
            };
        }
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .cloned()
            .unwrap_or_default()
    }
    pub fn eligible(&self, id: &str, named: bool) -> bool {
        self.get(id).eligible(named, time::now())
    }
    fn change(
        &self,
        id: &str,
        require_saved: bool,
        update: impl FnOnce(&mut Usage),
    ) -> std::io::Result<Usage> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if self.blocked {
            return Err(std::io::Error::other(
                "saved usage is unreadable; repair account-usage.json before changing reserves",
            ));
        }
        let mut next = state.clone();
        let value = next.entry(id.to_owned()).or_default();
        update(value);
        let value = value.clone();
        let saved = crate::store::write_private(
            &self.file,
            &serde_json::to_vec_pretty(&next).map_err(std::io::Error::other)?,
        );
        // A failed disk write must not forget a fresh limit during this process. An owner's
        // reserve change, however, is acknowledged and applied only when it was saved.
        if saved.is_ok() || !require_saved {
            *state = next;
        }
        saved?;
        Ok(value)
    }
    pub fn record(&self, id: &str, usage: &Usage) -> std::io::Result<Usage> {
        self.change(id, false, |kept| {
            if let Some(used) = usage.five_hour {
                kept.five_hour = Some(used);
                if usage.five_hour_resets.is_some() {
                    kept.five_hour_resets = usage.five_hour_resets;
                }
            }
            if let Some(used) = usage.seven_day {
                kept.seven_day = Some(used);
                if usage.seven_day_resets.is_some() {
                    kept.seven_day_resets = usage.seven_day_resets;
                }
            }
            if usage.full_until.is_some() {
                kept.full_until = usage.full_until;
            }
        })
    }
    pub fn lift(&self, id: &str, lift: bool) -> std::io::Result<Usage> {
        let now = time::now();
        self.change(id, true, |usage| {
            usage.reserve_lifted_until = lift.then(|| {
                usage
                    .seven_day_resets
                    .filter(|at| *at > now)
                    .unwrap_or(now + 7 * 86400)
            })
        })
    }
}
fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.parse().ok())
        .filter(|v| v.is_finite())
}
fn epoch(value: &Value) -> Option<i64> {
    number(value)
        .filter(|v| *v >= 0.0 && *v < i64::MAX as f64)
        .map(|v| v as i64)
}
fn share(value: &Value, divisor: f64) -> Option<f64> {
    number(value).map(|n| (n / divisor).clamp(0.0, 1.0))
}
/// Claude Code's unified subscription windows; reset times are epoch seconds.
pub fn claude(message: &Value) -> Usage {
    let info = &message["rate_limit_info"];
    let windows = &info["unifiedWindows"];
    let mut usage = Usage {
        five_hour: share(&windows["five_hour"]["utilization"], 1.0),
        seven_day: share(&windows["seven_day"]["utilization"], 1.0),
        five_hour_resets: epoch(&windows["five_hour"]["resetsAt"]),
        seven_day_resets: epoch(&windows["seven_day"]["resetsAt"]),
        ..Usage::default()
    };
    let mut full = Vec::new();
    if usage.five_hour.is_some_and(|n| n >= 1.0) {
        full.push(usage.five_hour_resets);
    }
    if usage.seven_day.is_some_and(|n| n >= 1.0) {
        full.push(usage.seven_day_resets);
    }
    if !full.is_empty() || info["status"] == "rejected" {
        usage.full_until = Some(
            full.into_iter()
                .flatten()
                .min()
                .or_else(|| epoch(&info["resetsAt"]))
                .unwrap_or(time::now() + 3600),
        );
    }
    usage
}
/// Codex subscription limits; ignore model-specific limits and identify windows by duration.
pub fn codex(limits: &Value) -> Option<Usage> {
    if limits
        .get("limitId")
        .and_then(Value::as_str)
        .is_some_and(|id| id != "codex")
    {
        return None;
    }
    let mut usage = Usage::default();
    for key in ["primary", "secondary"] {
        let w = &limits[key];
        match w["windowDurationMins"].as_u64() {
            Some(300) => {
                usage.five_hour = share(&w["usedPercent"], 100.0);
                usage.five_hour_resets = epoch(&w["resetsAt"]);
            }
            Some(10080) => {
                usage.seven_day = share(&w["usedPercent"], 100.0);
                usage.seven_day_resets = epoch(&w["resetsAt"]);
            }
            _ => {}
        }
    }
    (usage.five_hour.is_some() || usage.seven_day.is_some()).then_some(usage)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn disk_failure_keeps_fresh_limits_but_does_not_apply_an_unsaved_lift() {
        let home = std::env::temp_dir().join(format!("obid-disk-usage-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let accounts = Accounts::open(&home);
        std::fs::create_dir(home.join("account-usage.json")).unwrap();
        assert!(
            accounts
                .record(
                    "a",
                    &Usage {
                        seven_day: Some(0.82),
                        ..Usage::default()
                    }
                )
                .is_err()
        );
        assert!(accounts.get("a").reserved(time::now()));
        assert!(accounts.lift("a", true).is_err());
        assert!(accounts.get("a").reserved(time::now()));
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn corrupt_usage_cannot_be_bypassed_by_lifting_a_reserve() {
        let home = std::env::temp_dir().join(format!("obid-bad-usage-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join("account-usage.json"), "{").unwrap();
        let accounts = Accounts::open(&home);
        assert!(!accounts.eligible("a", true));
        assert!(accounts.lift("a", true).is_err());
        assert!(accounts.lift("a", false).is_err());
        assert!(!accounts.eligible("a", true));
        assert_eq!(
            std::fs::read_to_string(home.join("account-usage.json")).unwrap(),
            "{"
        );
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn windows_and_partial_updates() {
        let limits = json!({"primary": {"windowDurationMins": 10080, "usedPercent": 82, "resetsAt": "2000000000"}, "secondary": {"windowDurationMins": 300, "usedPercent": 20, "resetsAt": 1900000000}});
        let usage = codex(&limits).unwrap();
        assert_eq!(usage.seven_day, Some(0.82));
        assert_eq!(usage.five_hour, Some(0.2));
        assert_eq!(usage.seven_day_resets, Some(2000000000));
        assert!(codex(&json!({"limitId": "model", "primary": limits["primary"]})).is_none());
        assert!(
            codex(&json!({"primary": {"windowDurationMins": 300, "usedPercent": "NaN"}})).is_none()
        );
        let home = std::env::temp_dir().join(format!("obid-usage-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let accounts = Accounts::open(&home);
        accounts.record("a", &usage).unwrap();
        accounts
            .record(
                "a",
                &Usage {
                    five_hour: Some(0.4),
                    ..Usage::default()
                },
            )
            .unwrap();
        let kept = Accounts::open(&home).get("a");
        assert_eq!(kept.seven_day, Some(0.82));
        assert_eq!(kept.five_hour_resets, Some(1900000000));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(home.join("account-usage.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn reserves_expire_and_near_full_limits_always_hold() {
        let mut usage = Usage {
            seven_day: Some(0.82),
            seven_day_resets: Some(200),
            ..Usage::default()
        };
        assert!(usage.reserved(100));
        assert!(!usage.eligible(false, 100));
        assert!(usage.eligible(true, 100));
        usage.reserve_lifted_until = Some(200);
        assert!(usage.eligible(false, 100));
        usage.five_hour = Some(0.95);
        assert!(!usage.eligible(true, 100));
        usage.five_hour_resets = Some(99);
        assert!(usage.eligible(false, 100));
        usage.seven_day = Some(0.95);
        assert!(!usage.eligible(true, 100));
        assert!(usage.eligible(false, 201));
        usage.full_until = Some(300);
        assert!(!usage.eligible(true, 201));
        let full = claude(
            &json!({"rate_limit_info": {"unifiedWindows": {"five_hour": {"utilization": 1, "resetsAt": 400}}}}),
        );
        assert_eq!(full.full_until, Some(400));
    }
}
