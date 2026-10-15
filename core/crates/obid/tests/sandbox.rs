//! The job sandbox, on this machine (bubblewrap on Linux, Seatbelt on macOS): an agent and the
//! repository's check write only to the job's worktree, the worktree's own git directory and the
//! job's temporary folder; read nothing of obid's home but the worktree and the clone's git common
//! directory, nor the person's home; and the check reaches no network at all (docs/runner-api.md,
//! "The job sandbox"; docs/ARCHITECTURE.md, section 6, "Rust core", done-when).
//!
//! Each case runs a shell inside the sandbox that tries every write and read below and prints one
//! line per try; the test then checks each line, and the disk.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use obid::sandbox::{Sandbox, Spec};

/// A folder of the test's own, removed when it ends.
struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("obid-sandbox-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Folder(path.canonicalize().unwrap())
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = Command::new("chmod")
            .args(["-R", "u+w"])
            .arg(&self.0)
            .status();
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "Test")
        .env("GIT_AUTHOR_EMAIL", "test@obid.invalid")
        .env("GIT_COMMITTER_NAME", "Test")
        .env("GIT_COMMITTER_EMAIL", "test@obid.invalid")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// obid's home as a job sees it: a clone with two worktrees (this job's and another's), another
/// clone, the database, the key, the API token; and the person's home with a secret.
struct World {
    _folder: Folder,
    home: PathBuf,
    person: PathBuf,
    outside: PathBuf,
    worktree: PathBuf,
    admin: PathBuf,
    common: PathBuf,
    temp: PathBuf,
    account: PathBuf,
}

fn world(name: &str) -> World {
    let folder = Folder::new(name);
    let root = folder.0.clone();
    let home = root.join("home");
    let person = root.join("person");
    let outside = root.join("outside");
    for dir in [&home, &person, &outside] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(person.join("secret.txt"), "the person's secret").unwrap();
    std::fs::write(home.join("api-token"), "a".repeat(64)).unwrap();
    std::fs::create_dir_all(home.join("keys")).unwrap();
    std::fs::write(home.join("keys/obi.key"), "the obi key").unwrap();
    std::fs::create_dir_all(home.join("jobs")).unwrap();
    std::fs::write(home.join("jobs/other.json"), "{}").unwrap();

    // The remote, then obid's clone of it (as obid makes them: no checkout), and another clone.
    let remote = root.join("remote");
    std::fs::create_dir_all(&remote).unwrap();
    git(&remote, &["init", "-q"]);
    std::fs::write(remote.join("README.md"), "fixture\n").unwrap();
    git(&remote, &["add", "-A"]);
    git(&remote, &["commit", "-q", "-m", "init"]);
    let clone = home.join("clones/o/app");
    std::fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        &root,
        &[
            "clone",
            "-q",
            "--no-checkout",
            remote.to_str().unwrap(),
            clone.to_str().unwrap(),
        ],
    );
    let other_clone = home.join("clones/o/other");
    git(
        &root,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            other_clone.to_str().unwrap(),
        ],
    );
    let worktree = home.join("worktrees/j1");
    let other = home.join("worktrees/j2");
    std::fs::create_dir_all(home.join("worktrees")).unwrap();
    git(
        &clone,
        &[
            "worktree",
            "add",
            "-q",
            "--detach",
            worktree.to_str().unwrap(),
            "HEAD",
        ],
    );
    git(
        &clone,
        &[
            "worktree",
            "add",
            "-q",
            "--detach",
            other.to_str().unwrap(),
            "HEAD",
        ],
    );
    std::fs::write(other.join("theirs.txt"), "another job's work").unwrap();
    let temp = home.join("tmp/j1");
    let account = home.join("accounts/stub");
    std::fs::create_dir_all(&temp).unwrap();
    std::fs::create_dir_all(&account).unwrap();
    let admin = PathBuf::from(git(
        &worktree,
        &["rev-parse", "--path-format=absolute", "--git-dir"],
    ));
    let common = PathBuf::from(git(
        &worktree,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    ));
    World {
        _folder: folder,
        home,
        person,
        outside,
        worktree,
        admin,
        common,
        temp,
        account,
    }
}

fn spec(world: &World, network: bool, commits: bool, account: bool) -> Spec {
    Spec {
        worktree: world.worktree.clone(),
        git_admin: Some(world.admin.clone()),
        git_common: Some(world.common.clone()),
        commits,
        temp: world.temp.clone(),
        accounts: if account {
            vec![world.account.clone()]
        } else {
            Vec::new()
        },
        read_only: Vec::new(),
        hidden: vec![world.home.clone(), world.person.clone()],
        network,
    }
}

/// The probe: each try prints `<what> <label> ok|no`.
fn probe_script(world: &World, port: u16) -> String {
    let h = world.home.display();
    let writes_denied = [
        ("home", format!("{h}/probe")),
        ("worktrees-folder", format!("{h}/worktrees/probe")),
        ("other-worktree", format!("{h}/worktrees/j2/probe")),
        (
            "clone-objects",
            format!("{}/objects/probe", world.common.display()),
        ),
        (
            "clone-refs",
            format!("{}/refs/heads/probe", world.common.display()),
        ),
        (
            "clone-remote-refs",
            format!("{}/refs/remotes/origin/probe", world.common.display()),
        ),
        ("clone-config", format!("{}/config", world.common.display())),
        (
            "clone-hooks",
            format!("{}/hooks/post-checkout", world.common.display()),
        ),
        (
            "worktree-pointer",
            format!("{}/.git", world.worktree.display()),
        ),
        ("jobs", format!("{h}/jobs/probe.json")),
        ("keys", format!("{h}/keys/probe")),
        ("api-token", format!("{h}/api-token")),
        ("person", format!("{}/probe", world.person.display())),
        ("outside", format!("{}/probe", world.outside.display())),
        ("tmp", "/tmp/obid-sandbox-probe".to_owned()),
    ];
    let writes_allowed = [
        ("worktree", format!("{}/probe", world.worktree.display())),
        ("admin", format!("{}/probe", world.admin.display())),
        ("temp", format!("{}/probe", world.temp.display())),
        ("tmpdir", "$TMPDIR/probe2".to_owned()),
    ];
    let reads_denied = [
        ("api-token", format!("{h}/api-token")),
        ("key", format!("{h}/keys/obi.key")),
        ("jobs", format!("{h}/jobs/other.json")),
        ("other-worktree", format!("{h}/worktrees/j2/theirs.txt")),
        ("other-clone", format!("{h}/clones/o/other/.git/config")),
        ("person", format!("{}/secret.txt", world.person.display())),
    ];
    let reads_allowed = [
        (
            "worktree",
            format!("{}/README.md", world.worktree.display()),
        ),
        ("common", format!("{}/config", world.common.display())),
        ("common-head", format!("{}/HEAD", world.common.display())),
    ];
    let mut script = String::from("cd \"$1\" || exit 9\n");
    for (label, path) in writes_denied.iter().chain(writes_allowed.iter()) {
        script.push_str(&format!("if ( : >> \"{path}\" ) 2>/dev/null; then echo \"write {label} ok\"; else echo \"write {label} no\"; fi\n"));
    }
    for (label, path) in reads_denied.iter().chain(reads_allowed.iter()) {
        script.push_str(&format!("if cat \"{path}\" >/dev/null 2>&1; then echo \"read {label} ok\"; else echo \"read {label} no\"; fi\n"));
    }
    // What a listing shows (macOS refuses it; bubblewrap shows an empty stand-in with only the
    // folders the job's own paths need): never another job's, nor the database, keys or token.
    script.push_str(&format!(
        "echo \"list-worktrees [$(ls -A \"{h}/worktrees\" 2>/dev/null | tr '\\n' ',')]\"\n"
    ));
    script.push_str(&format!(
        "echo \"list-home [$(ls -A \"{h}\" 2>/dev/null | tr '\\n' ',')]\"\n"
    ));
    script.push_str(&format!(
        "echo \"list-clones [$(ls -A \"{h}/clones/o\" 2>/dev/null | tr '\\n' ',')]\"\n"
    ));
    // git works in the worktree, but can't commit unless the job commits.
    script.push_str("if git rev-parse HEAD >/dev/null 2>&1; then echo \"git head ok\"; else echo \"git head no\"; fi\n");
    script.push_str("if git -c user.name=t -c user.email=t@t commit -q --allow-empty -m probe >/dev/null 2>&1; then echo \"git commit ok\"; else echo \"git commit no\"; fi\n");
    // The network: a connection to a listener on 127.0.0.1 the test holds.
    script.push_str(&format!(
        "if git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=2 ls-remote http://127.0.0.1:{port}/x >/dev/null 2>&1; then echo \"net loopback tried\"; else echo \"net loopback tried\"; fi\n"
    ));
    script.push_str("echo \"env-home $HOME\"\necho \"env-tmpdir $TMPDIR\"\n");
    // A Unix socket in the person's home: a login agent, a Docker socket.
    // And one outside both homes, where a terminal multiplexer's server or a login agent listens
    // (`/tmp/tmux-<uid>/default`, `/tmp/com.apple.launchd.*/Listeners`).
    for (label, socket) in [
        ("unix-socket", world.person.join("agent.sock")),
        ("unix-socket-outside", world.outside.join("server.sock")),
    ] {
        script.push_str(&format!(
            "node -e \"require('net').connect('{}').on('connect', () => {{ console.log('{label} ok'); process.exit(0) }}).on('error', () => {{ console.log('{label} no'); process.exit(0) }})\" 2>/dev/null || echo '{label} node-failed'\n",
            socket.display()
        ));
    }
    script
}

struct Ran {
    lines: BTreeMap<String, String>,
    connected: bool,
    socket_reached: bool,
    raw: String,
}

fn run(world: &World, spec: &Spec) -> Ran {
    let sandbox = Sandbox::detect(Path::new(env!("CARGO_BIN_EXE_obid")))
        .unwrap_or_else(|why| panic!("this machine can't make the job sandbox: {why}"));
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    listener.set_nonblocking(true).unwrap();
    let connected = Arc::new(AtomicBool::new(false));
    let done = Arc::new(AtomicBool::new(false));
    let watcher = {
        let (connected, done) = (connected.clone(), done.clone());
        std::thread::spawn(move || {
            while !done.load(Ordering::Relaxed) {
                if let Ok((stream, _)) = listener.accept() {
                    connected.store(true, Ordering::Relaxed);
                    drop(stream);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        })
    };
    let socket = std::os::unix::net::UnixListener::bind(world.person.join("agent.sock")).unwrap();
    socket.set_nonblocking(true).unwrap();
    let server = std::os::unix::net::UnixListener::bind(world.outside.join("server.sock")).unwrap();
    server.set_nonblocking(true).unwrap();
    let script = probe_script(world, port);
    let argv: Vec<OsString> = vec![
        "/bin/sh".into(),
        "-c".into(),
        script.into(),
        "probe".into(),
        world.worktree.clone().into(),
    ];
    let argv = sandbox.wrap(spec, &argv);
    if let Some(own) = spec.own_objects() {
        std::fs::create_dir_all(own).unwrap();
    }
    let env = obid::process::sandbox_env(&obid::process::tools_path(), &spec.temp, &spec.git_env());
    let output = Command::new(&argv[0])
        .args(&argv[1..])
        .env_clear()
        .envs(env)
        .current_dir(&world.worktree)
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    watcher.join().unwrap();
    let socket_reached = socket.accept().is_ok() || server.accept().is_ok();
    let raw = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let mut lines = BTreeMap::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let mut parts = line.rsplitn(2, ' ');
        if let (Some(result), Some(what)) = (parts.next(), parts.next()) {
            lines.insert(what.to_owned(), result.to_owned());
        }
    }
    Ran {
        lines,
        connected: connected.load(Ordering::Relaxed),
        socket_reached,
        raw,
    }
}

fn expect(ran: &Ran, what: &str, result: &str) {
    assert_eq!(
        ran.lines.get(what).map(String::as_str),
        Some(result),
        "{what}\n{}",
        ran.raw
    );
}

fn the_same_fences(ran: &Ran, world: &World, commits: bool) {
    for label in [
        "home",
        "worktrees-folder",
        "other-worktree",
        "clone-objects",
        "clone-refs",
        "clone-remote-refs",
        "clone-config",
        "clone-hooks",
        "worktree-pointer",
        "jobs",
        "keys",
        "api-token",
        "person",
        "outside",
        "tmp",
    ] {
        expect(ran, &format!("write {label}"), "no");
    }
    for label in ["worktree", "admin", "temp", "tmpdir"] {
        expect(ran, &format!("write {label}"), "ok");
    }
    for label in [
        "api-token",
        "key",
        "jobs",
        "other-worktree",
        "other-clone",
        "person",
    ] {
        expect(ran, &format!("read {label}"), "no");
    }
    for label in ["worktree", "common", "common-head"] {
        expect(ran, &format!("read {label}"), "ok");
    }
    for (listing, never) in [
        ("list-worktrees", &["j2"][..]),
        ("list-home", &["api-token", "keys", "jobs"][..]),
        ("list-clones", &["other"][..]),
    ] {
        let shown = ran
            .lines
            .get(listing)
            .unwrap_or_else(|| panic!("no {listing}\n{}", ran.raw));
        for name in never {
            assert!(
                !shown.split([',', '[', ']']).any(|n| n == *name),
                "{listing} shows {name}: {shown}\n{}",
                ran.raw
            );
        }
    }
    expect(ran, "git head", "ok");
    expect(ran, "unix-socket", "no");
    expect(ran, "unix-socket-outside", "no");
    assert!(
        !ran.socket_reached,
        "a socket in the person's home or outside was reached\n{}",
        ran.raw
    );
    expect(ran, "git commit", if commits { "ok" } else { "no" });
    expect(ran, "env-home", &world.temp.display().to_string());
    expect(ran, "env-tmpdir", &world.temp.display().to_string());
    // And on disk: nothing appeared where it was refused, the files that were there are unchanged.
    // Not even a job that commits writes the clone's objects or refs.
    assert!(!world.common.join("objects/probe").exists());
    assert!(!world.common.join("refs/heads/probe").exists());
    assert!(!world.common.join("refs/remotes/origin/probe").exists());
    for path in [
        world.home.join("probe"),
        world.home.join("worktrees/probe"),
        world.home.join("worktrees/j2/probe"),
        world.home.join("jobs/probe.json"),
        world.home.join("keys/probe"),
        world.person.join("probe"),
        world.outside.join("probe"),
    ] {
        assert!(!path.exists(), "{} was written", path.display());
    }
    assert_eq!(
        std::fs::read_to_string(world.home.join("api-token")).unwrap(),
        "a".repeat(64)
    );
    assert!(!world.common.join("hooks/post-checkout").exists());
    assert!(
        world.worktree.join("probe").exists()
            && world.admin.join("probe").exists()
            && world.temp.join("probe").exists()
    );
}

/// The repository's check: no writes outside its folders, no reads of obid's home, no network.
#[test]
fn the_check_is_fenced_in_and_has_no_network() {
    let world = world("check");
    let ran = run(&world, &spec(&world, false, false, false));
    the_same_fences(&ran, &world, false);
    assert!(!ran.connected, "the check reached 127.0.0.1\n{}", ran.raw);
}

/// An agent: the same fences, plus its account folder; the network any agent has (its model's
/// API), so the test's listener is reached, which shows the probe would have seen it.
#[test]
fn an_agent_is_fenced_in_but_keeps_the_network() {
    let world = world("agent");
    let ran = run(&world, &spec(&world, true, false, true));
    the_same_fences(&ran, &world, false);
    assert!(
        ran.connected,
        "the agent's probe never reached the listener\n{}",
        ran.raw
    );
}

/// A job that commits does so in its own git directory only: its HEAD (detached there) and its new
/// objects (its own object folder, the clone's read as alternates). The clone's objects and refs
/// stay as they were: no job touches another's branch or `refs/remotes/origin/*`; obid takes the
/// commits into the clone itself, outside the sandbox (tests/jobs_api.rs).
#[test]
fn a_committing_job_commits_without_writing_the_clone() {
    let world = world("commits");
    let refs = git(&world.common, &["for-each-ref"]);
    let objects = git(&world.common, &["count-objects", "-v"]);
    let before = git(&world.worktree, &["rev-parse", "HEAD"]);
    let spec = spec(&world, false, true, false);
    let ran = run(&world, &spec);
    the_same_fences(&ran, &world, true);
    assert_eq!(git(&world.common, &["for-each-ref"]), refs);
    assert_eq!(git(&world.common, &["count-objects", "-v"]), objects);
    let own = spec.own_objects().unwrap();
    let after = std::fs::read_to_string(world.admin.join("HEAD")).unwrap();
    let after = after.trim();
    assert_ne!(after, before, "the commit moved the job's own HEAD");
    let (dir, file) = after.split_at(2);
    assert!(
        own.join(dir).join(file).is_file(),
        "its commit is in the job's own objects"
    );
    assert!(!world.common.join("objects").join(dir).join(file).exists());
}

/// What the terminal-reaching probe printed, and what the shell holding that terminal read after it.
fn through_a_terminal(world: &World, spec: &Spec, probe: &str) -> String {
    let sandbox = Sandbox::detect(Path::new(env!("CARGO_BIN_EXE_obid")))
        .unwrap_or_else(|why| panic!("this machine can't make the job sandbox: {why}"));
    let argv: Vec<OsString> = vec!["/bin/sh".into(), "-c".into(), probe.into()];
    let argv = sandbox.wrap(spec, &argv);
    let root = world.outside.clone();
    let mut list: Vec<u8> = Vec::new();
    for arg in &argv {
        list.extend_from_slice(arg.as_encoded_bytes());
        list.push(0);
    }
    std::fs::write(root.join("argv"), list).unwrap();
    // The shell that holds the terminal starts the job's process as obid does (its stdin null),
    // then reads one line from the terminal: anything the job pushed into it.
    std::fs::write(
        root.join("holder.sh"),
        "xargs -0 sh -c '\"$@\" </dev/null' sh < \"$1\"\nIFS= read -r -t 3 line\necho \"outside-read:[$line]\"\n",
    )
    .unwrap();
    let holder = format!(
        "/bin/bash {} {}",
        root.join("holder.sh").display(),
        root.join("argv").display()
    );
    let mut command = Command::new("script");
    if cfg!(target_os = "macos") {
        command.args(["-q", "/dev/null", "/bin/sh", "-c", &holder]);
    } else {
        command.args(["-qec", &holder, "/dev/null"]);
    }
    let env = obid::process::sandbox_env(&obid::process::tools_path(), &spec.temp, &[]);
    let mut child = command
        .env_clear()
        .envs(env)
        .current_dir(&world.worktree)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    // The terminal's own input stays open (no end of file) until the holder is done.
    let _input = child.stdin.take();
    let output = child.wait_with_output().unwrap();
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// A job's process has no controlling terminal: when obid was started from a terminal, nothing the
/// agent or the check runs can open it, or push keystrokes into the shell that holds it (TIOCSTI),
/// which would run them outside the sandbox.
#[test]
fn a_job_cannot_reach_the_terminal_obid_was_started_from() {
    let world = world("tty");
    for network in [false, true] {
        let spec = spec(&world, network, false, !network);
        let probe = "if ( : < /dev/tty ) 2>/dev/null; then echo 'tty open'; else echo 'tty none'; fi\n\
            python3 -c 'import fcntl, termios\nf = open(\"/dev/tty\", \"rb\")\nfor c in b\"echo INJECTED-BY-JOB\\n\": fcntl.ioctl(f, termios.TIOCSTI, bytes([c]))\nprint(\"tiocsti done\")' 2>/dev/null || echo 'tiocsti refused'\n";
        let ran = through_a_terminal(&world, &spec, probe);
        assert!(
            ran.contains("outside-read:"),
            "the terminal's shell never read\n{ran}"
        );
        assert!(
            ran.contains("tty none"),
            "the job opened the terminal\n{ran}"
        );
        assert!(
            !ran.contains("tiocsti done") && !ran.contains("INJECTED-BY-JOB]"),
            "the job pushed keystrokes into the terminal\n{ran}"
        );
    }
}

/// On macOS, nothing the job runs has LaunchServices open an app (one it wrote in its worktree,
/// which would run outside the sandbox), nor sends Apple events (Finder writing for it), for the
/// check or for an agent.
#[cfg(target_os = "macos")]
#[test]
fn a_job_cannot_have_another_process_run_or_write_for_it() {
    let world = world("open");
    let sandbox = Sandbox::detect(Path::new(env!("CARGO_BIN_EXE_obid"))).unwrap();
    for network in [false, true] {
        let spec = spec(&world, network, false, !network);
        let marker = world.outside.join("via-open-app");
        let folder = world.outside.join("via-finder");
        let probe = format!(
            "mkdir -p Probe.app/Contents/MacOS || exit 9\n\
             printf '%s' '<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Probe</string><key>CFBundleIdentifier</key><string>invalid.obid.sandbox-probe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > Probe.app/Contents/Info.plist\n\
             printf '#!/bin/sh\\ntouch \"%s\"\\n' '{marker}' > Probe.app/Contents/MacOS/Probe\n\
             chmod +x Probe.app/Contents/MacOS/Probe\n\
             if /usr/bin/open -g -j ./Probe.app 2>/dev/null; then echo 'open ok'; else echo 'open no'; fi\n\
             if /usr/bin/osascript -e 'tell application \"Finder\" to make new folder at (POSIX file \"{outside}\" as alias) with properties {{name:\"via-finder\"}}' >/dev/null 2>&1; then echo 'appleevent ok'; else echo 'appleevent no'; fi\n\
             rm -rf Probe.app\n",
            marker = marker.display(),
            outside = world.outside.display(),
        );
        let argv: Vec<OsString> = vec!["/bin/sh".into(), "-c".into(), probe.into()];
        let argv = sandbox.wrap(&spec, &argv);
        let env = obid::process::sandbox_env(&obid::process::tools_path(), &spec.temp, &[]);
        let output = Command::new(&argv[0])
            .args(&argv[1..])
            .env_clear()
            .envs(env)
            .current_dir(&world.worktree)
            .output()
            .unwrap();
        let printed = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        // An app that was opened runs a moment later.
        std::thread::sleep(Duration::from_secs(3));
        assert!(
            printed.contains("open no"),
            "LaunchServices opened the app\n{printed}"
        );
        assert!(
            printed.contains("appleevent no"),
            "an Apple event went out\n{printed}"
        );
        assert!(
            !marker.exists(),
            "the app the job wrote ran outside the sandbox\n{printed}"
        );
        assert!(!folder.exists(), "Finder wrote for the job\n{printed}");
    }
}

/// A preference domain or keychain of the test's own, outside the sandbox: removed when the test
/// ends, however it ends.
#[cfg(target_os = "macos")]
struct Throwaway {
    domains: Vec<String>,
    keychain: Option<PathBuf>,
}

#[cfg(target_os = "macos")]
impl Drop for Throwaway {
    fn drop(&mut self) {
        // cfprefsd leaves an empty file behind a deleted domain.
        let folder = std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Preferences"));
        for domain in &self.domains {
            let _ = Command::new("/usr/bin/defaults")
                .args(["delete", domain])
                .output();
            if let Some(folder) = &folder {
                let _ = std::fs::remove_file(folder.join(format!("{domain}.plist")));
            }
        }
        if let Some(keychain) = &self.keychain {
            let _ = Command::new("/usr/bin/security")
                .arg("delete-keychain")
                .arg(keychain)
                .output();
        }
    }
}

/// The services a sandboxed process could ask, on macOS, to read or write for it what its file
/// rules keep it from: preferences (cfprefsd), the pasteboard, the data protection keychain (secd),
/// SecurityAgent.
#[cfg(target_os = "macos")]
const MACH_DENIED: [&str; 6] = [
    "com.apple.cfprefsd.daemon",
    "com.apple.cfprefsd.agent",
    "com.apple.pasteboard.1",
    "com.apple.securityd.xpc",
    "com.apple.securityd.general",
    "com.apple.security.agent",
];

/// And those it keeps: the file-based keychains' securityd, through which Node reads the system's
/// root certificates (a client reads a keychain's file itself, so the file rules hold those
/// keychains back), and trustd, which checks a server's certificate (an agent's HTTPS).
#[cfg(target_os = "macos")]
const MACH_KEPT: [&str; 2] = ["com.apple.SecurityServer", "com.apple.trustd.agent"];

/// On macOS, a job reads and writes no preferences through cfprefsd (which reads and writes the
/// person's for whoever asks, whatever the asker's file rules), reads or writes no pasteboard, and
/// reads no keychain of the person's: not a file-based one in their home (the login keychain),
/// unlocked, whose item `security` itself may read; and secd, the data protection keychain's,
/// doesn't answer. For the check and for an agent (docs/runner-api.md, "The job sandbox").
#[cfg(target_os = "macos")]
#[test]
fn a_job_reaches_no_preferences_pasteboard_or_keychain() {
    let world = world("prefs");
    let sandbox = Sandbox::detect(Path::new(env!("CARGO_BIN_EXE_obid"))).unwrap();
    let nonce = format!(
        "{}{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    );
    let read_domain = format!("obi.test.{nonce}.read");
    let write_domain = format!("obi.test.{nonce}.write");
    let own_domain = format!("obi.test.{nonce}.own");
    let secret = format!("the-person-{nonce}");
    // In the person's home, as their login keychain is.
    let keychain = world.person.join("probe.keychain-db");
    let _cleanup = Throwaway {
        domains: vec![
            read_domain.clone(),
            write_domain.clone(),
            own_domain.clone(),
        ],
        keychain: Some(keychain.clone()),
    };
    let ran = |args: &[&str]| {
        Command::new(args[0])
            .args(&args[1..])
            .output()
            .unwrap_or_else(|e| panic!("{args:?}: {e}"))
    };
    // What the person has: a preference, and a keychain with an item in it.
    assert!(
        ran(&[
            "/usr/bin/defaults",
            "write",
            &read_domain,
            "secret",
            "-string",
            &secret
        ])
        .status
        .success()
    );
    let keychain_arg = keychain.to_str().unwrap();
    assert!(
        ran(&[
            "/usr/bin/security",
            "create-keychain",
            "-p",
            "obid-test",
            keychain_arg
        ])
        .status
        .success()
    );
    assert!(
        ran(&[
            "/usr/bin/security",
            "add-generic-password",
            "-s",
            &read_domain,
            "-a",
            "obid-test",
            "-w",
            &secret,
            keychain_arg,
        ])
        .status
        .success()
    );
    // Outside the sandbox, all of it answers: the probe below would see it.
    let outside = ran(&[
        "/usr/bin/security",
        "find-generic-password",
        "-s",
        &read_domain,
        "-w",
        keychain_arg,
    ]);
    assert_eq!(String::from_utf8_lossy(&outside.stdout).trim(), secret);
    // It is unlocked, and the item lets `security` read it, so nothing asks.
    let readable = keychain.clone();
    let mach = "import ctypes, sys\n\
         lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')\n\
         port = ctypes.c_uint.in_dll(lib, 'bootstrap_port')\n\
         for name in sys.argv[1:]:\n\
         \x20   found = ctypes.c_uint(0)\n\
         \x20   kr = lib.bootstrap_look_up(port, name.encode(), ctypes.byref(found))\n\
         \x20   print('mach ' + name + (' ok' if kr == 0 else ' no'))\n";
    let services: Vec<&str> = MACH_DENIED
        .iter()
        .chain(MACH_KEPT.iter())
        .copied()
        .collect();
    let probe = format!(
        "python3 -c \"$MACH\" {services} || echo 'mach python-failed'\n\
         prefs() {{\n\
         \x20 if [ \"$(/usr/bin/defaults read {read_domain} secret 2>/dev/null)\" = '{secret}' ]; then echo \"prefs-read-$1 ok\"; else echo \"prefs-read-$1 no\"; fi\n\
         \x20 /usr/bin/defaults write {write_domain} planted-$1 -string by-the-job >/dev/null 2>&1\n\
         \x20 if /usr/bin/defaults write {own_domain} mine-$1 -string yes >/dev/null 2>&1 && [ \"$(/usr/bin/defaults read {own_domain} mine-$1 2>/dev/null)\" = yes ]; then echo \"prefs-own-$1 ok\"; else echo \"prefs-own-$1 no\"; fi\n\
         }}\n\
         prefs plain\n\
         export CFFIXED_USER_HOME=\"$HOME\"\n\
         prefs fixed\n\
         unset CFFIXED_USER_HOME\n\
         if [ \"$(/usr/bin/security find-generic-password -s {read_domain} -w '{readable}' 2>/dev/null)\" = '{secret}' ]; then echo 'keychain-item ok'; else echo 'keychain-item no'; fi\n\
         if /usr/bin/security show-keychain-info '{readable}' >/dev/null 2>&1; then echo 'keychain-info ok'; else echo 'keychain-info no'; fi\n\
         if [ -n \"$(/usr/bin/pbpaste 2>&1 >/dev/null)\" ] || ! /usr/bin/pbpaste >/dev/null 2>&1; then echo 'pbpaste refused'; else echo 'pbpaste answered'; fi\n",
        services = services.join(" "),
        readable = readable.display(),
    );
    // The person's real home is hidden too, as obid hides it for every job: their preferences
    // and their login keychain are files there.
    let homes = obid::jobs::person_homes();
    assert!(!homes.is_empty());
    for network in [false, true] {
        let mut spec = spec(&world, network, false, !network);
        spec.hidden.extend(homes.iter().cloned());
        let argv: Vec<OsString> = vec!["/bin/sh".into(), "-c".into(), probe.clone().into()];
        let argv = sandbox.wrap(&spec, &argv);
        let mut env = obid::process::sandbox_env(&obid::process::tools_path(), &spec.temp, &[]);
        env.push(("MACH".into(), mach.into()));
        let output = Command::new(&argv[0])
            .args(&argv[1..])
            .env_clear()
            .envs(env)
            .current_dir(&world.worktree)
            .output()
            .unwrap();
        let printed = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let has = |line: &str| printed.lines().any(|l| l == line);
        // Plainly, and with `CFFIXED_USER_HOME` set to its own `HOME` (which the job can set
        // itself): cfprefsd then reads and writes the person's preferences for it, though their
        // files are hidden from it.
        for how in ["plain", "fixed"] {
            assert!(
                has(&format!("prefs-read-{how} no")),
                "the job read the person's preference ({how})\n{printed}"
            );
            // cfprefsd would keep even the job's own preferences in the person's home, whatever
            // its `HOME` or `CFFIXED_USER_HOME`: a job has none.
            assert!(
                has(&format!("prefs-own-{how} no")),
                "the job kept a preference ({how})\n{printed}"
            );
        }
        assert!(
            has("keychain-item no"),
            "the job read a keychain item\n{printed}"
        );
        assert!(
            has("keychain-info no"),
            "securityd answered the job\n{printed}"
        );
        assert!(has("pbpaste refused"), "the pasteboard answered\n{printed}");
        // Nothing the job wrote reached the person's preferences.
        let after = ran(&["/usr/bin/defaults", "read", &write_domain]);
        assert!(
            !after.status.success(),
            "the job wrote the person's preferences: {}\n{printed}",
            String::from_utf8_lossy(&after.stdout)
        );
        let own = ran(&["/usr/bin/defaults", "read", &own_domain]);
        assert!(
            !own.status.success(),
            "the job's own preference reached the person's\n{printed}"
        );
        // And the services themselves: none answers the job, but those it keeps.
        for service in MACH_DENIED {
            assert!(has(&format!("mach {service} no")), "{service}\n{printed}");
        }
        for service in MACH_KEPT {
            assert!(has(&format!("mach {service} ok")), "{service}\n{printed}");
        }
    }
}
