//! The jobs as the apps see them: the real obid binary, asked over HTTP (docs/runner-api.md,
//! "POST /v1/jobs" to "POST /v1/jobs/{id}/dismiss", "POST /v1/stop-all", "GET /v1/events").
//! Ported from RunnerTests' API-level tests (RunnerTests.swift: `dispatchTakesOnlyWholeJobs`,
//! `waitAnswersWithTheJobOnceItEnded`; StopTests; DismissTests), with a stand-in agent
//! (tests/agents/fake-claude) run by obid's Claude Code adapter in the job sandbox.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const OBID: &str = env!("CARGO_BIN_EXE_obid");
const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// A folder of the test's own, removed when it ends.
struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("obid-jobs-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Folder(path.canonicalize().unwrap())
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        // OBID_TEST_KEEP=1 keeps it, for reading the jobs' logs.
        if std::env::var_os("OBID_TEST_KEEP").is_some() {
            eprintln!("kept {}", self.0.display());
            return;
        }
        let _ = Command::new("chmod")
            .args(["-R", "u+w"])
            .arg(&self.0)
            .status();
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn obi() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .unwrap()
}

/// The e2e fixture's bare remote, built by the harness's own code.
fn fixture(root: &Path) -> PathBuf {
    let module = obi().join("e2e/lib/fixture.mjs");
    let script = format!(
        "import {{ buildFixture }} from {:?}; console.log(JSON.stringify(buildFixture(process.argv[1])));",
        module.to_str().unwrap()
    );
    let output = Command::new("node")
        .args(["--input-type=module", "-e", &script, root.to_str().unwrap()])
        .output()
        .expect("node runs");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let built: Value = serde_json::from_slice(&output.stdout).unwrap();
    PathBuf::from(built["remote"].as_str().unwrap())
}

struct Obid {
    child: Child,
    port: u16,
    home: PathBuf,
    folder: PathBuf,
    stderr: PathBuf,
}

impl Drop for Obid {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn config(folder: &Path, remote: &Path) -> Value {
    json!({
        "listen": "127.0.0.1:0",
        "home": folder.join("home"),
        "owner": "wellington",
        "agents": {"claude": {"bin": Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude"),
                              "accounts": [{"id": "stub", "name": "Stub", "configDir": folder.join("home/accounts/stub")}]}},
        "repos": [{"repo": "obi-e2e/fixture-app", "remote": format!("file://{}", remote.display()), "defaultBranch": "main"}],
        "allowFileRemotes": true,
        "telemetry": false
    })
}

/// Puts `token` in obid's `home/api-token` (0600, in a 0700 `home`), where obid takes its token
/// from: never from its environment (docs/runner-api.md, "obid only: configuration").
fn put_token(config: &Value, token: &str) {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let home = Path::new(config["home"].as_str().expect("home"));
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(home)
        .unwrap();
    let path = home.join("api-token");
    let _ = std::fs::remove_file(&path);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    std::io::Write::write_all(&mut file, format!("{token}\n").as_bytes()).unwrap();
}

fn start(folder: &Path, config: &Value) -> Obid {
    start_with(folder, config, None)
}

/// [`start`] with `path_first` first on obid's `PATH`.
fn start_with(folder: &Path, config: &Value, path_first: Option<&Path>) -> Obid {
    let mut search = std::env::var_os("PATH").unwrap_or_default();
    if let Some(first) = path_first {
        let mut dirs = vec![first.to_path_buf()];
        dirs.extend(std::env::split_paths(&search));
        search = std::env::join_paths(dirs).unwrap();
    }
    let path = folder.join("config.json");
    put_token(config, TOKEN);
    std::fs::write(&path, config.to_string()).unwrap();
    std::fs::create_dir_all(folder.join("env-home")).unwrap();
    std::fs::create_dir_all(folder.join("tmp")).unwrap();
    let stderr = folder.join("obid.stderr");
    let mut child = Command::new(OBID)
        .args(["serve", "--config"])
        .arg(&path)
        .env_clear()
        .env("PATH", search)
        .env("HOME", folder.join("env-home"))
        .env("TMPDIR", folder.join("tmp"))
        // Never the person's real Keychain (support::start): obid asks it at start when
        // claudeKeychain is left out.
        .env(
            "OBID_SECURITY_BIN",
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-security"),
        )
        // What obid must keep from its agents, whatever its own environment holds.
        .env("CLAUDECODE", "1")
        .env("ANTHROPIC_API_KEY", "sk-ant-not-a-key")
        .env("GH_TOKEN", "not-a-token")
        .stdout(Stdio::piped())
        .stderr(
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&stderr)
                .unwrap(),
        )
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let port = line
        .trim()
        .strip_prefix("obid listening on http://127.0.0.1:")
        .and_then(|p| p.parse().ok())
        .unwrap_or_else(|| {
            panic!(
                "obid didn't start: {line:?} {}",
                std::fs::read_to_string(&stderr).unwrap_or_default()
            )
        });
    Obid {
        child,
        port,
        home: folder.join("home"),
        folder: folder.to_path_buf(),
        stderr,
    }
}

struct Answer {
    status: u16,
    body: Value,
    text: String,
}

fn request(obid: &Obid, method: &str, target: &str, body: Option<&str>) -> Answer {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(150)))
        .unwrap();
    let mut text = format!(
        "{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\nConnection: close\r\n"
    );
    if let Some(body) = body {
        text.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    text.push_str("\r\n");
    text.push_str(body.unwrap_or(""));
    stream.write_all(text.as_bytes()).unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let raw = String::from_utf8(raw).unwrap();
    let (head, rest) = raw.split_once("\r\n\r\n").unwrap();
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    let text = if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        unchunk(rest)
    } else {
        rest.to_owned()
    };
    let body = serde_json::from_str(text.trim()).unwrap_or(Value::Null);
    Answer { status, body, text }
}

fn unchunk(mut body: &str) -> String {
    let mut out = String::new();
    loop {
        let (size, rest) = body.split_once("\r\n").unwrap();
        let size = usize::from_str_radix(size.trim(), 16).unwrap();
        if size == 0 {
            return out;
        }
        out.push_str(&rest[..size]);
        body = &rest[size + 2..];
    }
}

fn post_job(obid: &Obid, job: Value) -> Answer {
    request(
        obid,
        "POST",
        "/v1/jobs",
        Some(&json!({"job": job}).to_string()),
    )
}

fn wait(obid: &Obid, id: &str) -> Value {
    let answer = request(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

/// Polls `GET /v1/jobs/{id}` until `ready` holds, for at most 30 seconds.
fn until(obid: &Obid, id: &str, ready: impl Fn(&Value) -> bool) -> Value {
    let give_up_at = Instant::now() + Duration::from_secs(30);
    loop {
        let job = request(obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        if ready(&job) {
            return job;
        }
        assert!(
            Instant::now() < give_up_at,
            "the job never got there: {job}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The stand-in agent's heartbeat (`.obi/beat` in its worktree, a count it writes every 50 ms),
/// once it beats: a process in a sandbox has a pid of its own namespace, so this is how the test
/// sees it run.
fn beat(obid: &Obid, id: &str) -> u64 {
    let path = obid.home.join("worktrees").join(id).join(".obi/beat");
    let give_up_at = Instant::now() + Duration::from_secs(30);
    loop {
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(count) = text.trim().parse()
        {
            return count;
        }
        assert!(Instant::now() < give_up_at, "the agent never started");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Whether the agent of job `id`, which has beaten already, has stopped: its count (even one it
/// was killed while writing) stays the same.
fn stopped_beating(obid: &Obid, id: &str) -> bool {
    let path = obid.home.join("worktrees").join(id).join(".obi/beat");
    let first = std::fs::read_to_string(&path).ok();
    std::thread::sleep(Duration::from_millis(400));
    std::fs::read_to_string(&path).ok() == first
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// `POST /v1/jobs` takes a whole job (#269): repo, kind and task make one; a plan's draft is
/// gone; what isn't JSON is a bad request; what obid can't run is refused with why.
#[test]
fn dispatch_takes_only_whole_jobs() {
    let folder = Folder::new("dispatch");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let draft = r#"{"job": {"id": "9f08fd10", "branch": "oby/review-33", "account": "default"}}"#;
    assert_eq!(request(&obid, "POST", "/v1/jobs", Some(draft)).status, 410);
    assert_eq!(
        request(
            &obid,
            "POST",
            "/v1/jobs",
            Some(r#"{"job": {"branch": "oby/review-33"}}"#)
        )
        .status,
        422
    );
    assert_eq!(request(&obid, "POST", "/v1/jobs", Some("{")).status, 400);
    let whole = json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Fix it"});
    for (change, why) in [
        (
            json!({"repo": "someone/else"}),
            "isn't a repository obid knows",
        ),
        (json!({"kind": "dance"}), "kind is one of"),
        (json!({"task": ""}), "task is 1 to 2,000 characters"),
        (
            json!({"task": "x".repeat(2001)}),
            "task is 1 to 2,000 characters",
        ),
        (json!({"agent": "codex"}), "names no agents.codex"),
        (json!({"account": "nobody"}), "There's no account nobody"),
        (json!({"branch": "--upload-pack=sh"}), "isn't a branch name"),
        (json!({"branch": "oby/review 33"}), "isn't a branch name"),
        (json!({"rounds": 11}), "rounds is 1 to 10"),
        (json!({"check": "a\nb"}), "check is one line"),
        (json!({"mode": "yolo"}), "mode is ask"),
        (
            json!({"files": ["../etc/passwd"]}),
            "isn't a path inside the repository",
        ),
        (json!({"title": "x".repeat(61)}), "title is one line"),
        (
            json!({"startWhen": [{"pr": 205, "is": "merged"}]}),
            "start condition",
        ),
        (json!({"pr": "33"}), "pr is a positive whole number"),
    ] {
        let mut job = whole.clone();
        for (key, value) in change.as_object().unwrap() {
            job[key] = value.clone();
        }
        let answer = post_job(&obid, job);
        assert_eq!(answer.status, 422, "{change}: {}", answer.text);
        assert!(
            answer.body["error"].as_str().unwrap().contains(why),
            "{change}: {}",
            answer.text
        );
    }
    assert_eq!(request(&obid, "GET", "/v1/jobs/9f08fd10", None).status, 404);
    assert_eq!(
        request(&obid, "GET", "/v1/jobs/nobody/wait", None).status,
        404
    );
    assert_eq!(
        request(&obid, "POST", "/v1/jobs/nobody/stop", None).status,
        404
    );
    assert_eq!(request(&obid, "GET", "/v1/jobs", None).body, json!([]));
}

/// A stand-in `gh` in `folder/bin` that keeps its arguments (`folder/gh-calls`) and environment
/// (`folder/gh-env`), and opens pull request 7.
fn fake_gh(folder: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = folder.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{calls}'\nenv >> '{env}'\ncase \"$1 $2\" in\n  \"pr list\") exit 0 ;;\n  \"pr create\") echo https://github.com/obi-e2e/fixture-app/pull/7 ;;\n  *) exit 1 ;;\nesac\n",
        calls = folder.join("gh-calls").display(),
        env = folder.join("gh-env").display()
    );
    std::fs::write(bin.join("gh"), script).unwrap();
    std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

/// A build job: its own branch from the base, the agent commits in the sandbox, the check passes,
/// the job ends done with its commit counted, and publishes it: its branch pushed to the remote and
/// its pull request opened with the owner's `gh` (a stand-in here), which gets no token from
/// obid's environment. The base on the remote never moves: obid never merges. (A job whose scan
/// finds a possible secret, or can't run, publishes nothing: tests/publish_api.rs.)
#[test]
fn a_build_job_commits_and_ends_done() {
    let folder = Folder::new("build");
    let remote = fixture(&folder.0.join("fixture"));
    let main = git(&remote, &["rev-parse", "refs/heads/main"]);
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let answer = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt", "check": "test -f hello.txt", "title": "Hello file"}),
    );
    assert_eq!(answer.status, 201, "{}", answer.text);
    let id = answer.body["id"].as_str().unwrap().to_owned();
    assert_eq!(answer.body["status"], "queued");
    assert_eq!(answer.body["branch"], format!("oby/build-{id}"));
    assert_eq!(answer.body["base"], "main");
    assert_eq!(answer.body["title"], "Hello file");
    assert_eq!(answer.body["mode"], "sandbox");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["commits"], 1);
    assert_eq!(job["summary"], "Added hello.txt.");
    assert_eq!(job["session"], "00000000-0000-4000-8000-000000000001");
    assert_eq!(job["publishError"], Value::Null, "{job}");
    assert_eq!(
        job["published"],
        "https://github.com/obi-e2e/fixture-app/pull/7"
    );
    assert_eq!(job["pushed"], 1);
    assert_eq!(
        job["startCommit"],
        "aeab70f3025191d31993e778dba0eacc96c3b913"
    );
    let worktree = PathBuf::from(job["worktree"].as_str().unwrap());
    assert_eq!(worktree, obid.home.join("worktrees").join(&id));
    assert_eq!(
        git(&worktree, &["log", "-1", "--format=%s"]),
        "Add hello.txt"
    );
    // The agent committed on a detached HEAD (the sandbox never writes the clone's refs); obid
    // took the commit into its clone and moved the job's branch there.
    assert_eq!(
        git(&worktree, &["rev-parse", "--abbrev-ref", "HEAD"]),
        "HEAD"
    );
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    assert_eq!(
        git(
            &clone,
            &["rev-parse", &format!("refs/heads/oby/build-{id}")]
        ),
        git(&worktree, &["rev-parse", "HEAD"])
    );
    assert_eq!(
        git(
            &clone,
            &["log", "-1", "--format=%s", &format!("oby/build-{id}")]
        ),
        "Add hello.txt"
    );
    // Its own objects aside, the clone has every object of the branch.
    git(&clone, &["fsck", "--connectivity-only", "--no-dangling"]);
    // Published: the branch on the remote is the job's commit, its pull request opened into the
    // base, both listed in `outgoing`; the base is where it was.
    let head = git(&worktree, &["rev-parse", "HEAD"]);
    assert_eq!(
        git(
            &remote,
            &["rev-parse", &format!("refs/heads/oby/build-{id}")]
        ),
        head
    );
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), main);
    let actions: Vec<(&str, &str)> = job["outgoing"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| (o["action"].as_str().unwrap(), o["id"].as_str().unwrap()))
        .collect();
    assert_eq!(
        actions,
        [
            ("push", head.as_str()),
            (
                "pullRequest",
                "https://github.com/obi-e2e/fixture-app/pull/7"
            )
        ]
    );
    let calls = std::fs::read_to_string(folder.0.join("gh-calls")).unwrap();
    assert!(
        calls.contains(&format!(
            "pr create -R obi-e2e/fixture-app --base main --head oby/build-{id} --title=feat: added hello.txt --body-file "
        )),
        "{calls}"
    );
    // obid's environment holds GH_TOKEN (start_with): gh never gets it.
    let gh_env = std::fs::read_to_string(folder.0.join("gh-env")).unwrap();
    assert!(
        !gh_env.contains("GH_TOKEN")
            && !gh_env.contains("ANTHROPIC_API_KEY")
            && !gh_env.contains("CLAUDECODE"),
        "{gh_env}"
    );
    let stages: Vec<(String, String)> = job["pipeline"]["stages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (
                s["id"].as_str().unwrap().to_owned(),
                s["state"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert_eq!(
        stages[..3],
        [
            ("prepare".into(), "done".into()),
            ("work".into(), "done".into()),
            ("check".into(), "done".into())
        ]
    );
    assert_eq!(stages[3], ("publish".into(), "done".into()));
    // The list, newest first, and the job by id, the same.
    let list = request(&obid, "GET", "/v1/jobs?limit=5", None).body;
    assert_eq!(list[0]["id"], id.as_str());
    assert_eq!(
        request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body,
        job
    );
}

/// A fix that commits nothing is done, as Claude Code is when its model stops: the agent's summary
/// says why, and `reason` that nothing was published. It needs nothing, so it can't be dismissed.
#[test]
fn nothing_committed_is_done_and_needs_nothing() {
    let folder = Folder::new("nothing");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Look around"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["summary"], "Nothing to do.");
    assert_eq!(
        job["reason"],
        "Nothing committed, so nothing was published."
    );
    assert_eq!(job["commits"], 0);
    assert_eq!(
        request(&obid, "POST", &format!("/v1/jobs/{id}/dismiss"), None).status,
        409
    );
    assert_eq!(
        request(&obid, "POST", "/v1/jobs/nowhere/dismiss", None).status,
        404
    );

    let quiet = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "Look around"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(wait(&obid, &quiet)["status"], "done");
    let refused = request(&obid, "POST", &format!("/v1/jobs/{quiet}/dismiss"), None);
    assert_eq!(refused.status, 409);
    assert!(
        refused.body["error"]
            .as_str()
            .unwrap()
            .contains("doesn't need you")
    );
}

/// A check that keeps failing gets the agent another round with its output, then stops at a limit:
/// it needs you, with One more round, its branch kept. Dismiss lets it go.
#[test]
fn a_check_that_keeps_failing_stops_at_a_limit() {
    let folder = Folder::new("limit");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt", "check": "echo the check failed; false", "rounds": 2}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["round"], 2);
    assert_eq!(job["rounds"], 2);
    assert_eq!(
        job["limit"],
        "`echo the check failed; false` still fails after 2 round(s)"
    );
    assert_eq!(
        job["reason"],
        "Stopped at a limit: `echo the check failed; false` still fails after 2 round(s). The branch is kept and nothing was pushed."
    );
    assert_eq!(job["nextStep"], "One more round");
    // The agent's own summary stays.
    assert!(
        !job["summary"]
            .as_str()
            .unwrap()
            .starts_with("Stopped at a limit: "),
        "{job}"
    );
    let log = std::fs::read_to_string(obid.home.join("logs").join(&id).join("check.log")).unwrap();
    assert!(log.contains("the check failed"), "{log}");
    let dismissed = request(&obid, "POST", &format!("/v1/jobs/{id}/dismiss"), None);
    assert_eq!(dismissed.status, 200);
    assert!(dismissed.body["dismissed"].as_str().unwrap().ends_with('Z'));
    let publish = dismissed.body["pipeline"]["stages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == "publish")
        .cloned()
        .unwrap();
    assert_eq!(publish["detail"], "Dismissed");
}

/// A check that fails the way the owner asked for (a test meant to fail): the fix round quotes the
/// task, the agent says the failure is intended, and the job ends with that round instead of
/// another one that would undo it.
#[test]
fn a_failure_the_task_asked_for_ends_the_rounds() {
    let folder = Folder::new("intended");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt, a test that fails ON PURPOSE", "check": "echo the check failed; false", "rounds": 3}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    // No other round, and nothing goes out: a check that fails isn't a pass, whatever the agent
    // says (AGENTS.md: only checks that pass publish).
    // It needs you, with no button: nothing publishes a check that fails, by hand neither.
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["nextStep"], Value::Null, "{job}");
    assert_eq!(job["round"], 2);
    assert_eq!(job["limit"], Value::Null);
    assert_eq!(job["pushed"], Value::Null, "{job}");
    assert_eq!(job["published"], Value::Null, "{job}");
    let reason = job["reason"].as_str().unwrap();
    assert!(reason.contains("nothing was pushed"), "{job}");
    assert!(!reason.contains("by hand"), "{job}");
    // The agent's own words stay with the round.
    let rounds = job["summaries"].as_array().unwrap();
    assert!(
        rounds
            .last()
            .unwrap()
            .as_str()
            .unwrap()
            .starts_with("FAILS AS ASKED"),
        "{job}"
    );
}

/// obid answers the agent's permission prompts: publishing and leaving the worktree are refused,
/// the rest of a bypass job's work is allowed; and none of obid's own secrets reach the agent.
#[test]
fn permission_prompts_are_answered_by_the_rules() {
    let folder = Folder::new("ask");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    for (ask, expect) in [
        (
            json!({"tool": "Bash", "input": {"command": "git push origin HEAD"}}),
            "answer: deny",
        ),
        (
            json!({"tool": "Read", "input": {"file_path": "/etc/passwd"}}),
            "answer: deny",
        ),
        (
            json!({"tool": "Bash", "input": {"command": "sleep 1", "run_in_background": true}}),
            "answer: deny",
        ),
        (
            json!({"tool": "mcp__github__create_pull_request", "input": {}}),
            "answer: deny",
        ),
        (
            json!({"tool": "Bash", "input": {"command": "node --test"}}),
            "answer: allow",
        ),
        (
            json!({"tool": "Read", "input": {"file_path": "src/greet.js"}}),
            "answer: allow",
        ),
    ] {
        let id = post_job(&obid, json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": format!("ASK: {ask}")})).body["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let job = wait(&obid, &id);
        assert_eq!(job["status"], "done", "{job}");
        assert_eq!(job["summary"], expect, "{ask}");
    }
}

/// What a job's agent asks, one after another, as a job's task (the stand-in's `ASKS:`).
fn asks(list: &[Value]) -> Value {
    json!({"repo": "obi-e2e/fixture-app", "kind": "research",
           "task": format!("ASKS: {}", Value::Array(list.to_vec()))})
}

/// The job once it has ended or waits for the owner, so a job that shouldn't ask fails fast
/// rather than wait for an answer no one gives.
fn settled(obid: &Obid, id: &str) -> Value {
    let job = until(obid, id, |j| {
        j["permission"].is_object() || !matches!(j["status"].as_str(), Some("queued" | "running"))
    });
    assert_eq!(job["permission"], Value::Null, "it asked the owner: {job}");
    wait(obid, id)
}

fn inbox(obid: &Obid) -> Value {
    request(obid, "GET", "/v1/inbox", None).body
}

/// A job in the default mode asks the owner nothing about what stays inside its sandbox (edits in
/// its worktree, commands, tests, reads): obid answers by its rules, and the job lists what it
/// answered, the refused ones too. Nothing reaches the inbox (#586).
#[test]
fn work_inside_the_sandbox_is_answered_without_the_owner() {
    let folder = Folder::new("sandbox-inside");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    assert_eq!(
        request(&obid, "GET", "/v1/settings/permissions", None).body,
        json!({"mode": "sandbox"})
    );
    let id = post_job(
        &obid,
        asks(&[
            json!({"tool": "Edit", "input": {"file_path": "src/greet.js"}}),
            json!({"tool": "Bash", "input": {"command": "cargo test --workspace"}}),
            json!({"tool": "Bash", "input": {"command": "node --test && git status"}}),
            // A commit's message only says "curl" and "~/.ssh": it isn't a download or a key.
            json!({"tool": "Bash", "input": {"command": "git commit -m \"$(cat <<'EOF'\nfix: don't curl; ~/.ssh stays\nEOF\n)\""}}),
            json!({"tool": "Bash", "input": {"command": "git commit -am \"keep .env.local and ~/.ssh out of logs\""}}),
            json!({"tool": "Read", "input": {"file_path": "src/greet.js"}}),
            json!({"tool": "Grep", "input": {"pattern": "curl", "path": "src"}}),
            json!({"tool": "Bash", "input": {"command": "git push origin HEAD"}}),
            json!({"tool": "Read", "input": {"file_path": "/etc/passwd"}}),
        ]),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = settled(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["mode"], "sandbox");
    assert_eq!(
        job["summary"]
            .as_str()
            .unwrap()
            .split(", ")
            .take(7)
            .collect::<Vec<_>>(),
        [
            "answers: allow",
            "allow",
            "allow",
            "allow",
            "allow",
            "allow",
            "allow"
        ]
    );
    assert!(
        job["summary"]
            .as_str()
            .unwrap()
            .contains("deny: obid publishes"),
        "{job}"
    );
    assert_eq!(job["permission"], Value::Null);
    assert_eq!(inbox(&obid), json!([]));
    let answered = job["answered"].as_array().unwrap();
    assert_eq!(job["answeredCount"], 9, "{job}");
    let seen: Vec<(&str, &str)> = answered
        .iter()
        .map(|a| {
            (
                a["title"].as_str().unwrap(),
                a["decision"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        seen,
        [
            ("Edit greet.js", "allowed"),
            ("Run cargo test", "allowed"),
            ("Run node --test && git status", "allowed"),
            // A command with no rule is titled in full (#634).
            (
                "Run git commit -m \"$(cat <<'EOF'\nfix: don't curl; ~/.ssh stays\nEOF\n)\"",
                "allowed",
            ),
            ("Run git commit", "allowed"),
            ("Use Read", "allowed"),
            ("Use Grep", "allowed"),
            ("Run git push", "refused"),
            ("Use Read", "refused"),
        ]
    );
    assert_eq!(answered[1]["detail"], "cargo test --workspace");
    assert!(
        answered[7]["reason"]
            .as_str()
            .unwrap()
            .contains("publishes"),
        "{job}"
    );
    assert!(answered[0]["at"].as_str().unwrap().ends_with('Z'));
    // The record is on the job after it ended, and across a read.
    let again = request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(again["answered"], job["answered"]);
}

/// What leaves the sandbox or sticks still asks the owner, with why: the network beyond the
/// model's API, secrets, a read outside the worktree. The owner's answer reaches the agent, and a
/// secret's card offers no "always" (#586).
#[test]
fn what_leaves_the_sandbox_still_asks() {
    let folder = Folder::new("sandbox-outside");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    // The account's own folder (its `configDir`), as obid gives it to the agent.
    let login = folder.0.join("home/accounts/stub/settings.json");
    for (ask, why, always) in [
        (
            json!({"tool": "Bash", "input": {"command": format!("cat {}", login.display())}}),
            "It touches secrets or the vault.",
            false,
        ),
        (
            json!({"tool": "Bash", "input": {"command": "cat /Users/Shared/notes.txt"}}),
            "It reads outside the job's worktree.",
            true,
        ),
        (
            json!({"tool": "Bash", "input": {"command": "npm install left-pad"}}),
            "It reaches the network beyond the model's API.",
            true,
        ),
        (
            json!({"tool": "WebFetch", "input": {"url": "https://example.com/a"}}),
            "It reaches the network beyond the model's API.",
            true,
        ),
        (
            json!({"tool": "Bash", "input": {"command": "cat ~/.ssh/id_rsa"}}),
            "It touches secrets or the vault.",
            false,
        ),
        (
            json!({"tool": "Glob", "input": {"pattern": "/etc/*"}}),
            "It reads outside the job's worktree.",
            true,
        ),
    ] {
        let id = post_job(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "research",
                   "task": format!("ASK: {ask}")}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let waiting = until(&obid, &id, |j| j["permission"].is_object());
        assert_eq!(waiting["permission"]["why"], why, "{ask}");
        assert_eq!(
            waiting["permission"]["always"].is_string(),
            always,
            "{waiting}"
        );
        assert_eq!(waiting["answeredCount"], 0, "{waiting}");
        let items = inbox(&obid);
        let items = items.as_array().unwrap();
        assert_eq!(items.len(), 1, "{items:?}");
        assert_eq!(items[0]["kind"], "permission");
        let answer = request(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/permission"),
            Some(&json!({"id": waiting["permission"]["id"], "decision": "deny"}).to_string()),
        );
        assert_eq!(answer.status, 200, "{}", answer.text);
        let job = wait(&obid, &id);
        assert!(
            job["summary"].as_str().unwrap().starts_with("answer: deny"),
            "{job}"
        );
        // The owner's own answer isn't one obid made.
        assert_eq!(job["answeredCount"], 0, "{job}");
    }
}

/// Only the owner makes what sticks: an "always" on a network card saves their rule, and the next
/// job's install goes through without asking; a secret's card can't be saved ("always" is
/// refused), so the next job asks again (#586).
#[test]
fn only_the_owner_saves_a_rule_and_never_for_secrets() {
    let folder = Folder::new("sandbox-rules");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let job = |command: &str| {
        let task = format!(
            "ASK: {}",
            json!({"tool": "Bash", "input": {"command": command}})
        );
        post_job(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": task}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let answer = |id: &str, permission: &Value, decision: &str| {
        request(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/permission"),
            Some(&json!({"id": permission["id"], "decision": decision}).to_string()),
        )
    };
    assert_eq!(
        request(&obid, "GET", "/v1/permissions/rules", None).body,
        json!([])
    );
    // The network: the owner's "always" saves a rule, and it covers the next job.
    let id = job("npm install left-pad");
    let waiting = until(&obid, &id, |j| j["permission"].is_object());
    assert_eq!(
        waiting["permission"]["rule"], "Bash(npm install:*)",
        "{waiting}"
    );
    let saved = answer(&id, &waiting["permission"], "always");
    assert_eq!(saved.status, 200, "{}", saved.text);
    assert_eq!(wait(&obid, &id)["summary"], "answer: allow");
    let rules = request(&obid, "GET", "/v1/permissions/rules", None).body;
    assert_eq!(rules.as_array().unwrap().len(), 1, "{rules}");
    assert_eq!(rules[0]["rule"], "Bash(npm install:*)");
    let id = job("npm install left-pad");
    let covered = settled(&obid, &id);
    assert_eq!(covered["summary"], "answer: allow", "{covered}");
    assert_eq!(covered["answered"][0]["decision"], "allowed");
    assert_eq!(inbox(&obid), json!([]));
    // A secret: no rule to save, so it is allowed once and asked again.
    let id = job("cat ~/.ssh/id_rsa");
    let waiting = until(&obid, &id, |j| j["permission"].is_object());
    assert_eq!(waiting["permission"]["rule"], Value::Null, "{waiting}");
    let refused = answer(&id, &waiting["permission"], "always");
    assert_eq!(refused.status, 422, "{}", refused.text);
    assert!(refused.text.contains("no rule to save"), "{}", refused.text);
    assert_eq!(answer(&id, &waiting["permission"], "allow").status, 200);
    assert_eq!(wait(&obid, &id)["summary"], "answer: allow");
    let id = job("cat ~/.ssh/id_rsa");
    let again = until(&obid, &id, |j| j["permission"].is_object());
    assert_eq!(
        again["permission"]["why"], "It touches secrets or the vault.",
        "{again}"
    );
    assert_eq!(
        request(&obid, "GET", "/v1/permissions/rules", None)
            .body
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

/// Upgrading doesn't change a mode the owner chose: an install whose `permissions.json` saved
/// `bypass` keeps it, and its jobs don't ask about an install. Only an unset mode (no file, or a
/// file with rules and no mode) becomes `sandbox` (#586).
#[test]
fn an_install_that_chose_bypass_keeps_it() {
    for (kept, mode) in [
        (Some(json!({"mode": "bypass", "rules": []})), "bypass"),
        (Some(json!({"rules": []})), "sandbox"),
        (None, "sandbox"),
    ] {
        let folder = Folder::new("sandbox-upgrade");
        let remote = fixture(&folder.0.join("fixture"));
        let home = folder.0.join("home");
        std::fs::create_dir_all(&home).unwrap();
        if let Some(kept) = &kept {
            std::fs::write(home.join("permissions.json"), kept.to_string()).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(
                    home.join("permissions.json"),
                    std::fs::Permissions::from_mode(0o600),
                )
                .unwrap();
            }
        }
        let obid = start(&folder.0, &config(&folder.0, &remote));
        assert_eq!(
            request(&obid, "GET", "/v1/settings/permissions", None).body,
            json!({"mode": mode}),
            "{kept:?}"
        );
        let task = format!(
            "ASK: {}",
            json!({"tool": "Bash", "input": {"command": "npm install left-pad"}})
        );
        let id = post_job(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": task}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned();
        if mode == "bypass" {
            let job = settled(&obid, &id);
            assert_eq!(job["mode"], "bypass");
            assert_eq!(job["summary"], "answer: allow", "{job}");
        } else {
            let job = until(&obid, &id, |j| j["permission"].is_object());
            assert_eq!(job["mode"], "sandbox");
        }
    }
}

/// Re-review of #586, S2: a secret waits for the owner's own answer. Changing the job's mode, to
/// any mode, Bypass too, doesn't settle its card, and the agent hears nothing until the owner
/// answers it.
#[test]
fn a_mode_change_never_settles_a_secret() {
    let folder = Folder::new("sandbox-secret-mode");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let task = format!(
        "ASK: {}",
        json!({"tool": "Read", "input": {"file_path": ".env"}})
    );
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": task}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let waiting = until(&obid, &id, |j| j["permission"].is_object());
    assert_eq!(
        waiting["permission"]["why"],
        "It touches secrets or the vault."
    );
    for mode in ["ask", "plan", "acceptEdits", "bypass", "sandbox"] {
        let changed = request(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/mode"),
            Some(&json!({"mode": mode}).to_string()),
        );
        assert_eq!(changed.status, 200, "{}", changed.text);
        std::thread::sleep(Duration::from_millis(300));
        let job = request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        assert_eq!(job["mode"], mode);
        assert_eq!(
            job["permission"]["id"], waiting["permission"]["id"],
            "{mode}: {job}"
        );
        assert_eq!(job["status"], "running", "{mode}");
        assert_eq!(job["summary"], "", "{mode}: the agent heard an answer");
    }
    let allowed = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/permission"),
        Some(&json!({"id": waiting["permission"]["id"], "decision": "allow"}).to_string()),
    );
    assert_eq!(allowed.status, 200, "{}", allowed.text);
    assert_eq!(wait(&obid, &id)["summary"], "answer: allow");
}

/// Settings › Permissions: the default is Sandbox, and the owner can go back to asking for
/// commands (Accept edits): then a test run waits for them (#586).
#[test]
fn the_owner_can_go_back_to_asking_for_commands() {
    let folder = Folder::new("sandbox-back");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let put = |mode: &str| {
        request(
            &obid,
            "PUT",
            "/v1/settings/permissions",
            Some(&json!({"mode": mode}).to_string()),
        )
    };
    assert_eq!(put("acceptEdits").body, json!({"mode": "acceptEdits"}));
    assert_eq!(put("nonsense").status, 422);
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research",
               "task": "ASK: {\"tool\": \"Bash\", \"input\": {\"command\": \"node --test\"}}"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let waiting = until(&obid, &id, |j| j["permission"].is_object());
    assert_eq!(waiting["mode"], "acceptEdits");
    assert_eq!(waiting["permission"]["title"], "Run node --test");
    assert!(waiting["permission"].get("why").is_none(), "{waiting}");
    let allowed = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/permission"),
        Some(&json!({"id": waiting["permission"]["id"], "decision": "allow"}).to_string()),
    );
    assert_eq!(allowed.status, 200, "{}", allowed.text);
    assert_eq!(wait(&obid, &id)["summary"], "answer: allow");
    // Back to Sandbox, and the same command goes through, recorded.
    assert_eq!(put("sandbox").body, json!({"mode": "sandbox"}));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research",
               "task": "ASK: {\"tool\": \"Bash\", \"input\": {\"command\": \"node --test\"}}"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = settled(&obid, &id);
    assert_eq!(job["summary"], "answer: allow");
    assert_eq!(job["answered"][0]["title"], "Run node --test");
    // The setting reads back.
    assert_eq!(
        request(&obid, "GET", "/v1/settings/permissions", None).body,
        json!({"mode": "sandbox"})
    );
}

/// Stop ends a running job's agent within 2 seconds, with everything it started; stop-all stops
/// every queued and running job and says which; a job that ended comes back as it is.
#[test]
fn stop_and_stop_all_end_the_agents() {
    let folder = Folder::new("stop");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let new = |obid: &Obid| {
        post_job(
            obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "SLEEP"}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let id = new(&obid);
    beat(&obid, &id);
    assert!(!stopped_beating(&obid, &id), "the agent isn't running");
    let running = until(&obid, &id, |j| j["status"] == "running");
    assert_eq!(running["session"], "00000000-0000-4000-8000-000000000001");
    let status = request(&obid, "GET", "/v1/status", None).body;
    assert_eq!(status["running"], 1);
    assert_eq!(status["accounts"][0]["id"], "stub");
    assert_eq!(status["accounts"][0]["running"], 1);
    let started = Instant::now();
    let stopped = request(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None);
    assert_eq!(stopped.status, 200);
    assert_eq!(stopped.body["status"], "stopped");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(stopped_beating(&obid, &id), "the agent outlived its stop");
    assert_eq!(wait(&obid, &id)["status"], "stopped");
    assert_eq!(
        request(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None).body["status"],
        "stopped"
    );

    let (a, b) = (new(&obid), new(&obid));
    beat(&obid, &a);
    beat(&obid, &b);
    let all = request(&obid, "POST", "/v1/stop-all", None);
    assert_eq!(all.status, 200);
    assert_eq!(all.body["stopped"], 2);
    assert!(
        all.body["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|j| j["status"] == "stopped")
    );
    assert!(
        stopped_beating(&obid, &a) && stopped_beating(&obid, &b),
        "an agent outlived stop-all"
    );
    assert_eq!(
        request(&obid, "POST", "/v1/stop-all", None).body,
        json!({"stopped": 0, "jobs": []})
    );
}

/// SIGTERM: obid ends its agents, exits 0 within 10 seconds, and leaves its jobs as a restart
/// would: the next start carries them on.
#[test]
fn a_restart_carries_the_jobs_on() {
    let folder = Folder::new("restart");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote);
    let mut obid = start(&folder.0, &config);
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "SLEEP"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let beat_file = obid.home.join("worktrees").join(&id).join(".obi/beat");
    beat(&obid, &id);
    nix::sys::signal::kill(
        nix::unistd::Pid::from_raw(obid.child.id() as i32),
        nix::sys::signal::Signal::SIGTERM,
    )
    .unwrap();
    let started = Instant::now();
    let status = loop {
        if let Some(status) = obid.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "obid didn't exit within 10 seconds"
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(
        status.success(),
        "{status}: {}",
        std::fs::read_to_string(&obid.stderr).unwrap_or_default()
    );
    assert!(stopped_beating(&obid, &id), "the agent outlived obid");
    let kept: Value = serde_json::from_slice(
        &std::fs::read(obid.home.join("jobs").join(format!("{id}.json"))).unwrap(),
    )
    .unwrap();
    assert_eq!(kept["status"], "running");

    std::fs::remove_file(&beat_file).unwrap();
    let folder_path = obid.folder.clone();
    drop(obid);
    let obid = start(&folder_path, &config);
    let job = until(&obid, &id, |j| j["status"] == "running");
    assert_eq!(job["id"], id.as_str());
    // It carries on: its agent beats again.
    beat(&obid, &id);
    assert_eq!(
        request(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None).body["status"],
        "stopped"
    );
    assert!(stopped_beating(&obid, &id));
}

/// `GET /v1/events`: a `job` event for every change, as it happens.
#[test]
fn events_follow_every_change() {
    let folder = Folder::new("events");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let mut stream = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    stream
        .write_all(format!("GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\n\r\n").as_bytes())
        .unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.starts_with("HTTP/1.1 200"), "{line}");
    // The stream is followed before anything changes.
    std::thread::sleep(Duration::from_millis(200));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "Look around"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut seen_done = false;
    let (mut seen_ready, mut seen_running) = (false, false);
    let give_up_at = Instant::now() + Duration::from_secs(30);
    let mut event = String::new();
    while !seen_done && Instant::now() < give_up_at {
        line.clear();
        if reader.read_line(&mut line).unwrap() == 0 {
            break;
        }
        let text = line.trim();
        if let Some(name) = text.strip_prefix("event: ") {
            event = name.to_owned();
        } else if let Some(data) = text.strip_prefix("data: ") {
            assert_eq!(event, "job");
            let job: Value = serde_json::from_str(data).unwrap();
            assert_eq!(job["id"], id.as_str());
            // While its worktree gets ready it is queued, as the Swift runner has it; running
            // once its agent starts.
            if job["step"] == "Getting fixture-app ready" {
                assert_eq!(job["status"], "queued", "{job}");
                seen_ready = true;
            }
            if job["status"] == "running" {
                seen_running = true;
            }
            seen_done = job["status"] == "done";
        }
    }
    assert!(seen_done, "no event said the job was done");
    assert!(seen_ready && seen_running, "the job got ready, then ran");
}

/// An account with no `configDir` uses the tool's own login (runner-api.md, "obid only:
/// configuration"), but never the person's real folders: the job gets a copy of the login only,
/// in a folder of its own. What the agent writes there (a hook in its settings, its
/// `.claude.json`) stays there; the person's real `~/.claude` and `~/.claude.json` can't be
/// written, so nothing a job plants runs later outside the sandbox. The copied credentials are
/// gone once the job's run ends.
#[test]
fn the_default_login_is_a_copy_the_person_keeps_unchanged() {
    let folder = Folder::new("login");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote);
    config["agents"]["claude"]["accounts"][0]["configDir"] = Value::Null;
    let person = folder.0.join("env-home");
    std::fs::create_dir_all(person.join(".claude")).unwrap();
    let files = [
        (
            ".claude/.credentials.json",
            "{\"token\":\"test-login-copy\"}",
        ),
        (".claude/settings.json", "{}"),
        (".claude.json", "{\"numStartups\":1}"),
    ];
    for (name, text) in files {
        std::fs::write(person.join(name), text).unwrap();
    }
    let obid = start(&folder.0, &config);
    let task = format!("LOGIN: {}", person.display());
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": task}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(
        job["summary"],
        "login: creds={\"token\":\"test-login-copy\"} settings=ok state=ok real=no real-state=no"
    );
    // The person's own login is as it was.
    for (name, text) in files {
        assert_eq!(
            std::fs::read_to_string(person.join(name)).unwrap(),
            text,
            "{name}"
        );
    }
    // The hook landed in the job's own copy, and the copied credentials are gone.
    let login = obid.home.join("logins").join(&id);
    assert!(
        std::fs::read_to_string(login.join(".claude/settings.json"))
            .unwrap()
            .contains("planted")
    );
    assert!(!login.join(".claude/.credentials.json").exists());
    assert!(login.join(".claude.json").exists());
}

/// #655: a job never gets its account's own folder, only a folder of its own with a copy of the
/// login (no refresh token: a refresh inside a box would rotate the account's login away, #651)
/// and the account's trimmed `.claude.json`. Nothing it writes reaches the account's folder, which
/// unboxed processes (the tool's own sign-in, the keeper's refresh) read, nor can it read it, even
/// where the account's folder is outside obid's home and the person's; the copied credentials are
/// gone once its run ends.
#[test]
fn a_job_never_writes_its_accounts_folder() {
    let folder = Folder::new("account-folder");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote);
    let account = folder.0.join("elsewhere/stub");
    config["agents"]["claude"]["accounts"][0]["configDir"] = json!(account);
    std::fs::create_dir_all(&account).unwrap();
    let files = [
        (
            ".credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh","expiresAt":4102444800000}}"#,
        ),
        (
            ".claude.json",
            r#"{"oauthAccount":{"emailAddress":"owner@example.com"},"mcpServers":{"x":{"command":"x"}}}"#,
        ),
    ];
    for (name, text) in files {
        std::fs::write(account.join(name), text).unwrap();
    }
    let obid = start(&folder.0, &config);
    let task = format!("PLANT: {}", account.display());
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": task}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(
        job["summary"],
        "plant: dir=own refresh=none settings=ok state=ok real=no real-state=no read=no"
    );
    // The account's folder is as it was: nothing planted, nothing added.
    for (name, text) in files {
        assert_eq!(
            std::fs::read_to_string(account.join(name)).unwrap(),
            text,
            "{name}"
        );
    }
    assert!(!account.join("settings.json").exists());
    // The job's own folder got the hook and a trimmed .claude.json; its credentials are gone.
    let login = obid.home.join("logins").join(&id);
    assert!(
        std::fs::read_to_string(login.join("settings.json"))
            .unwrap()
            .contains("planted")
    );
    let state = std::fs::read_to_string(login.join(".claude.json")).unwrap();
    assert!(
        state.contains("owner@example.com") && !state.contains("mcpServers"),
        "{state}"
    );
    assert!(!login.join(".credentials.json").exists());
}

/// #626: routing skips an account whose login file isn't there (a login only in the macOS
/// Keychain can't reach the job's sandbox): another account of the tool, else another tool.
#[test]
fn routing_skips_an_account_that_isnt_signed_in() {
    let folder = Folder::new("signed-out");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote);
    let accounts = folder.0.join("home/accounts");
    config["agents"]["claude"]["accounts"] = json!([
        {"id": "keychain", "name": "Keychain", "configDir": accounts.join("keychain")},
        {"id": "file", "name": "File", "configDir": accounts.join("file")}
    ]);
    config["agents"]["codex"] = json!({
        "bin": Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-codex"),
        "accounts": [{"id": "codex", "name": "Codex", "configDir": accounts.join("codex")}]
    });
    for (account, file) in [("file", ".credentials.json"), ("codex", "auth.json")] {
        std::fs::create_dir_all(accounts.join(account)).unwrap();
        std::fs::write(accounts.join(account).join(file), "{}").unwrap();
    }
    let obid = start(&folder.0, &config);
    let job = |agent: Value| {
        let answer = post_job(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "Say hello.",
                   "agent": agent}),
        );
        assert_eq!(answer.status, 201, "{}", answer.text);
        (answer.body["agent"].clone(), answer.body["account"].clone())
    };
    assert_eq!(job(json!("claude")), (json!("claude"), json!("file")));
    std::fs::remove_file(accounts.join("file/.credentials.json")).unwrap();
    assert_eq!(job(json!("auto")), (json!("codex"), json!("codex")));
}
