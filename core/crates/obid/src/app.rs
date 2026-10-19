//! obid as Oby.app runs it (the owner's decision of 2026-10-18: open the app, and Oby's engine is
//! running, with no terminal and no install.sh). The app registers `Contents/Helpers/obid` as a
//! login item that starts `obid serve` with no `--config`; then, on macOS, obid uses the same file
//! install.sh writes, `~/Library/Application Support/Oby/obid/config.json`, writes it the first
//! time from what it finds on the Mac, and logs to `~/Library/Logs/obid.log` as install.sh's
//! service does. Its plug-ins and web app come from the app's own `Contents/Resources/obid`.

use std::path::{Path, PathBuf};

/// `~/Library/Application Support/Oby/obid/config.json` under the person's home, where install.sh
/// keeps it too.
pub fn config_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Oby/obid/config.json")
}

/// The obid home the Mac app reads its token from (`LocalRunner.home`, docs/runner-api.md, "The Mac
/// app on the same Mac").
pub fn obid_home(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Oby/Runner")
}

/// `~/Library/Logs/obid.log`, as install.sh's launch agent writes it.
pub fn log_path(home: &Path) -> PathBuf {
    home.join("Library/Logs/obid.log")
}

/// `Contents/Resources/obid` of the app obid runs from (`Contents/Helpers/obid`), where the app
/// carries obid's plug-ins and web app; none for an obid anywhere else.
pub fn resources() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    resources_of(&exe)
}

fn resources_of(exe: &Path) -> Option<PathBuf> {
    let contents = exe.parent()?.parent()?;
    (contents.file_name()? == "Contents")
        .then(|| contents.join("Resources/obid"))
        .filter(|dir| dir.is_dir())
}

/// What obid writes the first time, as install.sh does: listening where the Mac app looks for it,
/// in the home the app reads the token from, the person's login as owner, Claude Code with its
/// default login, Codex too when it's on the login shell's PATH, the gateway on for pairing, and
/// telemetry off. `bundledPlugins` and `web` are left out: obid takes them from the app.
pub fn default_config(home: &Path, owner: &str, codex: bool) -> serde_json::Value {
    let mut agents = serde_json::json!({
        "claude": {"bin": "claude", "accounts": [{"id": "default", "name": "Default", "configDir": null}]}
    });
    if codex {
        agents["codex"] = serde_json::json!(
            {"bin": "codex", "accounts": [{"id": "codex", "name": "Codex", "configDir": null}]}
        );
    }
    serde_json::json!({
        "listen": "127.0.0.1:7777",
        "home": obid_home(home),
        "owner": owner,
        "agents": agents,
        "gateway": "127.0.0.1:8810",
        "telemetry": false
    })
}

/// The configuration at `path`, written from [`default_config`] when there's none (0600, in a folder
/// only its owner opens); one that's there is never rewritten.
pub fn ensure_config(path: &Path, home: &Path) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    if std::fs::symlink_metadata(path).is_ok() {
        return Ok(());
    }
    let folder = path.parent().ok_or("the configuration has no folder")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(folder)
        .map_err(|e| format!("can't make {}: {e}", folder.display()))?;
    let owner = nix::unistd::User::from_uid(nix::unistd::getuid())
        .ok()
        .flatten()
        .map(|user| user.name)
        .ok_or("can't find the person's login name")?;
    let codex = crate::process::resolve_bin("codex").is_some();
    let text = serde_json::to_string_pretty(&default_config(home, &owner, codex))
        .map_err(|e| e.to_string())?;
    let new = folder.join(".config.json.new");
    let _ = std::fs::remove_file(&new);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&new)
        .map_err(|e| format!("can't write {}: {e}", new.display()))?;
    file.write_all(format!("{text}\n").as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("can't write {}: {e}", new.display()))?;
    // Never over one that appeared meanwhile.
    std::fs::hard_link(&new, path).map_err(|e| format!("can't write {}: {e}", path.display()))?;
    let _ = std::fs::remove_file(&new);
    Ok(())
}

/// Sends what obid says on stderr to `~/Library/Logs/obid.log` (appended, 0600 when new).
pub fn log_to_file(home: &Path) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let path = log_path(home);
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)
            .map_err(|e| format!("can't make {}: {e}", folder.display()))?;
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| format!("can't open {}: {e}", path.display()))?;
    nix::unistd::dup2_stderr(&file).map_err(|e| format!("can't log to {}: {e}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("obid-app-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    /// The first start writes what install.sh would, and the configuration it writes is one obid
    /// accepts; a configuration that's there is kept as it is.
    #[test]
    fn the_first_start_writes_a_configuration_obid_takes() {
        let home = folder("config");
        let path = config_path(&home);
        ensure_config(&path, &home).unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let config = crate::config::Config::load(&path).unwrap();
        assert_eq!(config.home, obid_home(&home));
        assert_eq!(config.listen.to_string(), "127.0.0.1:7777");
        assert_eq!(
            config.gateway.map(|g| g.to_string()).as_deref(),
            Some("127.0.0.1:8810")
        );
        assert!(!config.telemetry);
        std::fs::write(&path, "{\"edited\": true}").unwrap();
        ensure_config(&path, &home).unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{\"edited\": true}"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn codex_is_listed_only_when_its_there() {
        let home = Path::new("/Users/someone");
        assert!(
            default_config(home, "someone", false)["agents"]
                .get("codex")
                .is_none()
        );
        assert_eq!(
            default_config(home, "someone", true)["agents"]["codex"]["bin"],
            "codex"
        );
    }

    #[test]
    fn the_apps_resources_are_found_only_inside_an_app() {
        let root = folder("resources");
        let contents = root.join("Oby.app/Contents");
        std::fs::create_dir_all(contents.join("Helpers")).unwrap();
        assert_eq!(resources_of(&contents.join("Helpers/obid")), None);
        std::fs::create_dir_all(contents.join("Resources/obid")).unwrap();
        assert_eq!(
            resources_of(&contents.join("Helpers/obid")),
            Some(contents.join("Resources/obid"))
        );
        assert_eq!(resources_of(&root.join("bin/obid")), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
