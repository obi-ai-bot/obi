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
    assert_eq!(answer.body["mode"], "bypass");
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

/// A fix that commits nothing failed: `Nothing committed: ` and the agent's first line. Dismiss lets
/// it go; a job that needs nothing can't be dismissed.
#[test]
fn nothing_committed_fails_and_dismiss_lets_it_go() {
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
    assert_eq!(job["status"], "failed");
    assert_eq!(job["summary"], "Nothing committed: Nothing to do.");
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
    assert_eq!(
        request(&obid, "POST", "/v1/jobs/nowhere/dismiss", None).status,
        404
    );

    let quiet = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around"}),
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

/// A check that keeps failing gets the agent another round with its output, then stops at a limit.
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
    assert_eq!(job["status"], "failed");
    assert_eq!(job["round"], 2);
    assert_eq!(job["rounds"], 2);
    assert_eq!(
        job["limit"],
        "`echo the check failed; false` still fails after 2 round(s)"
    );
    assert!(
        job["summary"]
            .as_str()
            .unwrap()
            .starts_with("Stopped at a limit: ")
    );
    let log = std::fs::read_to_string(obid.home.join("logs").join(&id).join("check.log")).unwrap();
    assert!(log.contains("the check failed"), "{log}");
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
        let id = post_job(&obid, json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": format!("ASK: {ask}")})).body["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let job = wait(&obid, &id);
        assert_eq!(job["status"], "done", "{job}");
        assert_eq!(job["summary"], expect, "{ask}");
    }
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
            json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}),
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
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}),
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
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around"}),
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
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": task}),
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

// Ports PermissionTests.aQuestionSendsEveryKey, exercising the binary and both summary/plan paths.
#[test]
fn a_question_sends_every_key_and_resumes_the_same_round() {
    let folder = Folder::new("question-keys");
    let remote = fixture(&folder.0);
    let config = config(&folder.0, &remote);
    let obid = start(&folder.0, &config);
    let summary = "Choose *.swift?\n**QUESTION:** Which *.swift?\nOPTIONS: Keep (Recommended) — Keep the API. | Change — Change the API.";
    let id = post_job(&obid, json!({"repo":"obi-e2e/fixture-app", "kind":"investigate", "task":format!("SAY_JSON: {}", json!(summary)), "check":"touch checked; exit 42"})).body["id"].as_str().unwrap().to_owned();
    let job = until(&obid, &id, |j| j["question"].is_object());
    assert_eq!(job["status"], "running");
    assert_eq!(job["step"], "Waiting for your answer");
    assert_eq!(request(&obid, "GET", "/v1/status", None).body["running"], 0);
    assert!(
        !obid
            .home
            .join("worktrees")
            .join(&id)
            .join("checked")
            .exists()
    );
    // A waiting question releases its slot; another actual job can finish.
    request(
        &obid,
        "PUT",
        "/v1/settings/jobs",
        Some(r#"{"maxRunning":1}"#),
    );
    let other = post_job(
        &obid,
        json!({"repo":"obi-e2e/fixture-app", "kind":"investigate", "task":"ECHO"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(wait(&obid, &other)["status"], "done");
    assert_eq!(
        job["question"],
        json!({"text":"Which *.swift?", "options":["Keep","Change"], "details":["Keep the API.","Change the API."],"recommended":0,"plan":null})
    );
    let inbox = request(&obid, "GET", "/v1/inbox", None).body;
    let item = inbox
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["job"] == id)
        .unwrap();
    assert_eq!(item["kind"], "question");
    let round = job["round"].clone();
    let answer = request(
        &obid,
        "POST",
        &format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap()),
        Some(r#"{"answer":"ECHO"}"#),
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    let ended = wait(&obid, &id);
    assert!(ended["question"].is_null());
    assert_eq!(ended["round"], round);
    assert!(
        ended["summaries"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()
            .as_str()
            .unwrap()
            .contains("heard: ECHO"),
        "{ended}"
    );
    assert_eq!(ended["status"], "failed"); // check runs only after the answer
    assert_eq!(ended["notes"], json!(["ECHO"]));
    assert_eq!(
        request(
            &obid,
            "POST",
            &format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap()),
            Some(r#"{"answer":"again"}"#)
        )
        .status,
        409
    );
}

#[test]
fn a_question_keeps_waiting_after_restart_and_stop_drops_it() {
    let folder = Folder::new("question-restart");
    let remote = fixture(&folder.0);
    let config = config(&folder.0, &remote);
    let mut obid = start(&folder.0, &config);
    let id = post_job(&obid, json!({"repo":"obi-e2e/fixture-app", "kind":"investigate", "task":format!("SAY_JSON: {}", json!("QUESTION: Which?\nOPTIONS: A | B"))})).body["id"].as_str().unwrap().to_owned();
    let job = until(&obid, &id, |j| j["question"].is_object());
    assert_eq!(job["question"]["details"], Value::Null);
    assert_eq!(job["question"]["recommended"], Value::Null);
    assert_eq!(job["question"]["plan"], Value::Null);
    obid.child.kill().unwrap();
    obid.child.wait().unwrap();
    drop(obid);
    let mut obid = start(&folder.0, &config);
    std::thread::sleep(Duration::from_millis(250));
    let kept = request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(kept["status"], "running");
    assert_eq!(kept["step"], "Waiting for your answer");
    assert_eq!(kept["question"], job["question"]);
    let inbox = request(&obid, "GET", "/v1/inbox", None).body;
    assert_eq!(
        inbox
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["job"] == id && i["state"] == "open")
            .count(),
        1
    );
    assert_eq!(
        request(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(r#"{"text":"ECHO"}"#)
        )
        .status,
        200
    );
    let ended = wait(&obid, &id);
    assert_eq!(ended["round"], job["round"]);
    assert!(ended["summary"].as_str().unwrap().contains("heard: ECHO"));
    // Simulate the crash window after the job answer was persisted but its card wasn't settled.
    let old = inbox
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["job"] == id)
        .unwrap();
    let path = obid
        .home
        .join("inbox")
        .join(format!("{}.json", old["id"].as_str().unwrap()));
    let mut raw: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    raw["done"] = Value::Null;
    std::fs::write(&path, raw.to_string()).unwrap();
    obid.child.kill().unwrap();
    obid.child.wait().unwrap();
    drop(obid);
    let obid = start(&folder.0, &config);
    let repaired = request(&obid, "GET", "/v1/inbox", None).body;
    assert!(
        !repaired
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["job"] == id && i["state"] == "open")
    );
    let id = post_job(&obid, json!({"repo":"obi-e2e/fixture-app", "kind":"investigate", "task":format!("SAY_JSON: {}", json!("QUESTION: Stop?"))})).body["id"].as_str().unwrap().to_owned();
    until(&obid, &id, |j| j["question"].is_object());
    let stopped = request(&obid, "POST", &format!("/v1/jobs/{id}/stop"), Some("{}")).body;
    assert_eq!(stopped["status"], "stopped");
    assert!(stopped["question"].is_null());
    let inbox = request(&obid, "GET", "/v1/inbox", None).body;
    assert!(
        !inbox
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["job"] == id && i["state"] == "open")
    );
}

#[test]
fn a_plan_waits_for_the_owner_and_mode_changes_only_on_approval() {
    let folder = Folder::new("question-plan");
    let remote = fixture(&folder.0);
    let config = config(&folder.0, &remote);
    let obid = start(&folder.0, &config);
    for task in [
        format!("SAY_JSON: {}", json!("1. Read\n2. Test")),
        r#"ASK: {"tool":"ExitPlanMode","input":{"plan":"1. Read\n2. Test"}}"#.into(),
    ] {
        let id = post_job(
            &obid,
            json!({"repo":"obi-e2e/fixture-app","kind":"investigate","task":task,"mode":"plan"}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let job = until(&obid, &id, |j| j["question"]["plan"].is_string());
        // The agent's own plan, not a summary written after obid let ExitPlanMode through.
        assert_eq!(job["question"]["plan"], "1. Read\n2. Test", "{job}");
        assert_eq!(job["mode"], "plan");
        assert!(job["permission"].is_null());
        assert_eq!(job["question"]["text"], "Approve the plan?");
        assert_eq!(job["question"]["recommended"], 0);
        assert_eq!(job["question"]["details"], Value::Null);
        assert_eq!(
            job["question"]["options"],
            json!(["Approve: Accept edits", "Approve: Bypass", "Change it"])
        );
        assert_eq!(
            request(
                &obid,
                "POST",
                &format!("/v1/jobs/{id}/messages"),
                Some(r#"{"text":"Approve: Bypass"}"#)
            )
            .status,
            200
        );
        // Ended, or waiting on a plan again: a job that missed the approval asks once more.
        let ended = until(&obid, &id, |j| {
            !matches!(j["status"].as_str(), Some("queued" | "running"))
                || j["notes"].is_array() && j["question"].is_object()
        });
        assert_eq!(ended["mode"], "bypass", "{ended}");
        assert!(ended["question"].is_null());
        assert_eq!(ended["round"], job["round"]);
    }
}

#[test]
fn a_native_plan_question_starts_the_job_already_queued_behind_it() {
    let folder = Folder::new("question-plan-slot");
    let remote = fixture(&folder.0);
    let obid = start(&folder.0, &config(&folder.0, &remote));
    assert_eq!(
        request(
            &obid,
            "PUT",
            "/v1/settings/jobs",
            Some(r#"{"maxRunning":1}"#)
        )
        .status,
        200
    );
    let plan=post_job(&obid,json!({"repo":"obi-e2e/fixture-app","kind":"investigate","mode":"plan","task":r#"WAIT_TO_ASK ASK: {"tool":"ExitPlanMode","input":{"plan":"Read first."}}"#})).body["id"].as_str().unwrap().to_owned();
    until(&obid, &plan, |j| j["status"] == "running");
    let next = post_job(
        &obid,
        json!({"repo":"obi-e2e/fixture-app","kind":"investigate","task":"SLEEP"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    until(&obid, &next, |j| j["waiting"]["kind"] == "cap");
    let release = obid.home.join("worktrees").join(&plan).join(".obi");
    std::fs::create_dir_all(&release).unwrap();
    std::fs::write(release.join("release-ask"), "").unwrap();
    until(&obid, &plan, |j| j["question"].is_object());
    until(&obid, &next, |j| j["status"] == "running"); // No create/answer/settings call wakes scheduling.
    beat(&obid, &next);
    let round = request(&obid, "GET", &format!("/v1/jobs/{plan}"), None).body["round"].clone();
    let accepted = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{plan}/messages"),
        Some(r#"{"text":"Approve: Bypass"}"#),
    );
    assert_eq!(accepted.status, 200, "{}", accepted.text);
    assert_eq!(accepted.body["status"], "queued");
    assert!(accepted.body["question"].is_null());
    until(&obid, &plan, |j| j["waiting"]["kind"] == "cap");
    assert_eq!(request(&obid, "GET", "/v1/status", None).body["running"], 1);
    request(&obid, "POST", &format!("/v1/jobs/{next}/stop"), None);
    let resumed = until(&obid, &plan, |j| j["status"] == "done");
    assert_eq!(resumed["mode"], "bypass");
    assert_eq!(resumed["round"], round);
    assert_eq!(resumed["notes"], json!(["Approve: Bypass"]));
}
