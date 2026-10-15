//! The plug-in sandbox (docs/ARCHITECTURE.md 5.3, step 3), seen from inside: the test plug-in
//! tries reads, listings and writes and reports what each gave, and the test checks what
//! happened on the machine.

mod common;

use std::collections::BTreeSet;
use std::path::Path;

use common::{Home, id, options, sandbox_made};
use obi_plugin_api::PluginState;
use obi_plugin_host::PluginHost;
use serde_json::{Value, json};

fn path(p: &Path) -> String {
    p.to_str().unwrap().to_owned()
}

/// What the probe said about `key`: `Some(what it got)` when it worked, `None` when it didn't.
fn probed(probe: &Value, key: &str) -> Option<String> {
    let result = probe
        .get(key)
        .unwrap_or_else(|| panic!("{key} was not probed: {probe:#}"));
    (result["ok"] == json!(true)).then(|| result["got"].as_str().unwrap_or("").to_owned())
}

#[tokio::test]
async fn a_plugin_reads_and_writes_only_what_the_spec_lets_it() {
    let home = Home::new("probe");
    let own = home.install("context-test", "probe");
    let other = home.install("context-test", "other");
    let h = &home.path;
    std::fs::write(
        h.join("api-token"),
        "obid-api-token-0123456789abcdef0123456789",
    )
    .unwrap();
    std::fs::create_dir_all(h.join("keys")).unwrap();
    std::fs::write(h.join("keys/obi.key"), "private key").unwrap();
    std::fs::create_dir_all(h.join("worktrees/job1")).unwrap();
    std::fs::write(h.join("worktrees/job1/main.rs"), "fn main() {}").unwrap();
    std::fs::create_dir_all(home.data_dir("other")).unwrap();
    std::fs::write(home.data_dir("other").join("notes"), "other's data").unwrap();
    let data = home.data_dir("probe");
    let outside = std::env::temp_dir().join(format!("obi-plugin-escape-{}", std::process::id()));
    let _ = std::fs::remove_file(&outside);
    let real_home = std::env::var("HOME").ok().filter(|h| h != "/");

    let mut list = vec![path(h), path(&data)];
    list.extend(real_home.clone());
    let config = json!({"probe": {
        "read": [
            path(&own.join("obi-plugin.json")),
            path(&other.join("obi-plugin.json")),
            path(&h.join("api-token")),
            path(&h.join("keys/obi.key")),
            path(&h.join("worktrees/job1/main.rs")),
            path(&home.data_dir("other").join("notes")),
            "/etc/hosts",
        ],
        "list": list,
        "write": [
            path(&data.join("written")),
            path(&data.join("tmp/written")),
            path(&own.join("written")),
            path(&h.join("written")),
            path(&h.join("api-token")),
            path(&home.data_dir("other").join("written")),
            path(&outside),
        ],
    }});

    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let ready = host
        .set_enabled(&id("probe"), true, Some(config))
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    let probe = home.record("probe", "probe.json").unwrap();
    let read = |p: &Path| probed(&probe, &format!("read {}", path(p)));

    // Its own folder (read-only) and its data folder, and the system's files.
    assert!(read(&own.join("obi-plugin.json")).unwrap().starts_with('{'));
    assert!(probed(&probe, "read /etc/hosts").is_some(), "{probe:#}");
    assert_eq!(
        probed(&probe, &format!("list {}", path(&data))).map(|_| ()),
        Some(())
    );
    assert!(data.join("written").is_file());
    assert!(data.join("tmp/written").is_file());

    // Nothing else of obid's home.
    for secret in [
        other.join("obi-plugin.json"),
        h.join("api-token"),
        h.join("keys/obi.key"),
        h.join("worktrees/job1/main.rs"),
        home.data_dir("other").join("notes"),
    ] {
        assert_eq!(
            read(&secret),
            None,
            "{} was readable: {probe:#}",
            secret.display()
        );
    }
    // A listing of home shows none of what it holds.
    if let Some(listing) = probed(&probe, &format!("list {}", path(h))) {
        // On Linux the empty folder over home holds the two folders bound back in.
        for name in ["api-token", "keys", "worktrees", "plugins.json"] {
            assert!(
                !listing.split(',').any(|n| n == name),
                "home listed {listing}"
            );
        }
        let names: BTreeSet<&str> = listing.split(',').filter(|n| !n.is_empty()).collect();
        assert!(
            names.is_subset(&BTreeSet::from(["plugins", "plugin-data"])),
            "{listing}"
        );
    }
    // Nor the person's real HOME.
    if let Some(real_home) = &real_home {
        let outside_view = std::fs::read_dir(real_home).map(|d| d.count()).unwrap_or(0);
        if let Some(listing) = probed(&probe, &format!("list {real_home}")) {
            assert!(
                listing.is_empty() || outside_view == 0,
                "the real HOME was listed: {listing}"
            );
        }
    }

    // No write reached anything outside its data folder.
    assert!(!own.join("written").exists());
    assert!(!h.join("written").exists());
    assert!(!home.data_dir("other").join("written").exists());
    assert!(!outside.exists());
    assert_eq!(
        std::fs::read_to_string(h.join("api-token")).unwrap(),
        "obid-api-token-0123456789abcdef0123456789"
    );
    for refused in [own.join("written"), outside.clone()] {
        assert_eq!(
            probed(&probe, &format!("write {}", path(&refused))),
            None,
            "{probe:#}"
        );
    }
    host.shutdown().await;
}

#[tokio::test]
async fn its_environment_is_path_home_lang_and_tmpdir_only() {
    let home = Home::new("env");
    home.install("events-test", "events-test");
    let host = PluginHost::start_with(&home.path, options()).await.unwrap();
    let ready = host
        .set_enabled(&id("events-test"), true, None)
        .await
        .unwrap();
    if !sandbox_made(&ready) {
        return;
    }
    let seen = home.record("events-test", "env.json").unwrap();
    let env = seen["env"].as_object().unwrap();
    let names: BTreeSet<&str> = env.keys().map(String::as_str).collect();
    assert_eq!(
        names,
        BTreeSet::from(["HOME", "LANG", "PATH", "TMPDIR"]),
        "{seen:#}"
    );
    let data = home.data_dir("events-test");
    assert_eq!(env["HOME"], json!(path(&data)));
    assert_eq!(env["TMPDIR"], json!(path(&data.join("tmp"))));
    assert_eq!(seen["cwd"], json!(path(&data)));
    assert!(!env["PATH"].as_str().unwrap().is_empty());
    assert!(!env["LANG"].as_str().unwrap().is_empty());
    host.shutdown().await;
}

/// "Everything it starts" (docs/ARCHITECTURE.md 5.3) covers what a plug-in could ask a service
/// outside its sandbox to start for it, which would run unconfined: on macOS an app opened
/// through LaunchServices (`open`) or a job given to launchd, on Linux a unit started through
/// the user's systemd. None of them may run, a local service's Unix socket outside its data
/// folder (Docker's, an SSH agent's, D-Bus's) can't be reached, and no process outside its
/// sandbox can be signalled.
#[tokio::test]
async fn nothing_it_starts_runs_outside_its_sandbox() {
    let home = Home::new("escape");
    home.install("context-test", "escape");
    let h = &home.path;
    std::fs::write(h.join("api-token"), "obid-api-token-escape-test").unwrap();
    let data = home.data_dir("escape");
    std::fs::create_dir_all(&data).unwrap();
    let pid = std::process::id();
    let escaped = std::env::temp_dir().join(format!("obi-plugin-escaped-{pid}"));
    let _ = std::fs::remove_file(&escaped);
    let escape_script = format!(
        "echo escaped > '{}'; cat '{}' >> '{}'",
        path(&escaped),
        path(&h.join("api-token")),
        path(&escaped)
    );

    // A local service the plug-in mustn't reach, listening outside its data folder: on macOS
    // anywhere, on Linux in /tmp, where X11 and SSH agents keep theirs (/run, where D-Bus,
    // systemd and Docker keep theirs, is hidden the same way and checked below).
    let socket_dir = if cfg!(target_os = "linux") {
        std::path::PathBuf::from("/tmp")
    } else {
        std::env::temp_dir()
    };
    let socket = socket_dir.join(format!("obi-plugin-service-{pid}.sock"));
    let _ = std::fs::remove_file(&socket);
    let service = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    service.set_nonblocking(true).unwrap();

    let mut run: Vec<Vec<String>> = vec![vec!["/bin/kill".into(), "-0".into(), pid.to_string()]];
    let launchd_label = format!("obi.plugin-host.test.escape.{pid}");
    if cfg!(target_os = "macos") {
        // An app in its data folder, which LaunchServices would start outside the sandbox.
        let app = data.join("Escape.app");
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::write(
            app.join("Contents/Info.plist"),
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>escape</string>
<key>CFBundleIdentifier</key><string>com.obi.plugin-host.test.escape</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
"#,
        )
        .unwrap();
        let executable = app.join("Contents/MacOS/escape");
        std::fs::write(&executable, format!("#!/bin/sh\n{escape_script}\n")).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
        run.push(vec![
            "/usr/bin/open".into(),
            "-g".into(),
            "-n".into(),
            path(&app),
        ]);
        run.push(vec![
            "/bin/launchctl".into(),
            "submit".into(),
            "-l".into(),
            launchd_label.clone(),
            "--".into(),
            "/bin/sh".into(),
            "-c".into(),
            escape_script.clone(),
        ]);
    } else {
        for systemd_run in ["/usr/bin/systemd-run", "/bin/systemd-run"] {
            if Path::new(systemd_run).is_file() {
                run.push(vec![
                    systemd_run.into(),
                    "--user".into(),
                    "--collect".into(),
                    "--quiet".into(),
                    "/bin/sh".into(),
                    "-c".into(),
                    escape_script.clone(),
                ]);
                break;
            }
        }
    }
    let listed = ["/run", "/tmp"];
    let config = json!({"probe": {
        "connect": [path(&socket)],
        "run": run,
        "list": listed,
        "read": ["/etc/resolv.conf"],
    }});

    let options = obi_plugin_host::Options {
        initialize_timeout: std::time::Duration::from_secs(30),
        ..options()
    };
    let host = PluginHost::start_with(&home.path, options).await.unwrap();
    let ready = host
        .set_enabled(&id("escape"), true, Some(config))
        .await
        .unwrap();
    let cleanup = || {
        if cfg!(target_os = "macos") {
            let _ = std::process::Command::new("/bin/launchctl")
                .args(["remove", &launchd_label])
                .stderr(std::process::Stdio::null())
                .status();
        }
        let _ = std::fs::remove_file(&socket);
    };
    if !sandbox_made(&ready) {
        cleanup();
        return;
    }
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    let probe = home.record("escape", "probe.json").unwrap();
    // What it asked others to start would have run by now.
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let accepted = service.accept().is_ok();
    let escape = std::fs::read_to_string(&escaped).ok();
    let _ = std::fs::remove_file(&escaped);
    cleanup();
    host.shutdown().await;

    assert_eq!(
        escape, None,
        "something it started ran outside its sandbox: {probe:#}"
    );
    assert!(
        !accepted,
        "it reached a Unix socket outside its data folder: {probe:#}"
    );
    assert_eq!(
        probed(&probe, &format!("connect {}", path(&socket))),
        None,
        "{probe:#}"
    );
    assert_eq!(
        probed(&probe, &format!("run /bin/kill -0 {pid}")),
        None,
        "it could signal a process outside its sandbox: {probe:#}"
    );
    // Name lookups still work: the resolver's configuration is there to read, even when it
    // lives under /run.
    if std::fs::read_to_string("/etc/resolv.conf").is_ok() {
        assert!(
            probed(&probe, "read /etc/resolv.conf").is_some(),
            "{probe:#}"
        );
    }
    if cfg!(target_os = "linux") {
        // /run and /tmp are empty folders of its own: no D-Bus, user systemd, X11 or Docker
        // socket, nothing another program left in /tmp.
        let run_listing = probed(&probe, "list /run").unwrap_or_default();
        for name in ["user", "dbus", "docker.sock", "docker", "containerd"] {
            assert!(
                !run_listing.split(',').any(|n| n == name),
                "/run showed {run_listing}"
            );
        }
        let tmp_listing = probed(&probe, "list /tmp").unwrap_or_default();
        let socket_name = socket.file_name().unwrap().to_str().unwrap();
        assert!(
            !tmp_listing
                .split(',')
                .any(|n| n == socket_name || n == ".X11-unix"),
            "/tmp showed {tmp_listing}"
        );
    }
}

/// The machine's temporary folders (`/tmp`, `/var/tmp`, and on macOS `/private/var/folders`,
/// where `obid`'s own `TMPDIR` and so its jobs' temporary folders are) can't be read, and tools
/// that check every folder of the path they work in, like `git`, still work in the data folder.
#[tokio::test]
async fn the_temporary_folders_stay_hidden_and_tools_work_in_its_data_folder() {
    let home = Home::new("temp");
    home.install("context-test", "temp");
    let pid = std::process::id();
    let name = format!("obi-plugin-temp-secret-{pid}");
    let mut secrets = Vec::new();
    let mut folders = vec![
        std::path::PathBuf::from("/tmp"),
        std::path::PathBuf::from("/var/tmp"),
        std::env::temp_dir(),
    ];
    folders.dedup();
    for folder in &folders {
        let secret = folder.join(&name);
        if std::fs::write(&secret, "a job's temporary file").is_ok() {
            secrets.push(secret);
        }
    }
    assert!(!secrets.is_empty(), "no temporary folder to write to");
    // Apple's git (`/usr/bin/git`, through `xcrun`) is the one that checks every folder of
    // the path it works in; another git where there's none.
    let git = ["/usr/bin/git", "git"].into_iter().find(|git| {
        std::process::Command::new(git)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    });
    let git_script = "\"$0\" init -q repo && cd repo && echo hi > f && \"$0\" add f \\
        && \"$0\" -c user.email=t@example.invalid -c user.name=t commit -q -m m \\
        && \"$0\" status --porcelain && echo git-ok";
    let mut run: Vec<Vec<String>> = Vec::new();
    if let Some(git) = git {
        run.push(vec![
            "/bin/sh".into(),
            "-c".into(),
            git_script.into(),
            git.into(),
        ]);
    }
    let config = json!({"probe": {
        "read": secrets.iter().map(|s| path(s)).collect::<Vec<_>>(),
        "list": folders.iter().map(|f| path(f)).collect::<Vec<_>>(),
        "run": run,
    }});

    // The probe runs while the plug-in initializes, git among it.
    let options = obi_plugin_host::Options {
        initialize_timeout: std::time::Duration::from_secs(30),
        ..options()
    };
    let host = PluginHost::start_with(&home.path, options).await.unwrap();
    let ready = host
        .set_enabled(&id("temp"), true, Some(config))
        .await
        .unwrap();
    let cleanup = || {
        for secret in &secrets {
            let _ = std::fs::remove_file(secret);
        }
    };
    if !sandbox_made(&ready) {
        cleanup();
        return;
    }
    host.shutdown().await;
    cleanup();
    assert_eq!(ready.state, PluginState::Ready, "{ready:?}");
    let probe = home.record("temp", "probe.json").unwrap();
    for secret in &secrets {
        assert_eq!(
            probed(&probe, &format!("read {}", path(secret))),
            None,
            "{} was readable: {probe:#}",
            secret.display()
        );
    }
    for folder in &folders {
        if let Some(listing) = probed(&probe, &format!("list {}", path(folder))) {
            assert!(
                !listing.split(',').any(|n| n == name),
                "{} showed {listing}",
                folder.display()
            );
        }
    }
    if let Some(git) = git {
        let got = probed(&probe, &format!("run /bin/sh -c {git_script} {git}"));
        assert!(
            got.as_deref().is_some_and(|got| got.contains("git-ok")),
            "git didn't work in the data folder: {probe:#}"
        );
    } else {
        eprintln!("NOTE: no git on this machine, so only the temporary folders are checked");
    }
}
