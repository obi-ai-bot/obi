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
        "repos": [{"repo": "obi-e2e/fixture-app", "remote": format!("file://{}", remote.display()), "defaultBranch": "main", "pullRequests": true}],
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
/// (`folder/gh-env`), opens pull request 7, and answers `gh pr view` with `folder/pr-view.json`
/// when there's one.
fn fake_gh(folder: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = folder.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{calls}'\nenv >> '{env}'\ncase \"$1 $2\" in\n  \"pr list\") exit 0 ;;\n  \"pr create\") echo https://github.com/obi-e2e/fixture-app/pull/7 ;;\n  \"pr view\") exec cat '{view}' ;;\n  *) exit 1 ;;\nesac\n",
        calls = folder.join("gh-calls").display(),
        env = folder.join("gh-env").display(),
        view = folder.join("pr-view.json").display()
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
    // The list, newest first, and the job by id, the same, but for each round's diff stat, only
    // there (#736).
    let list = request(&obid, "GET", "/v1/jobs?limit=5", None).body;
    assert_eq!(list[0]["id"], id.as_str());
    let mut by_id = request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(by_id["diff"]["rounds"].as_array().map(Vec::len), Some(1));
    by_id["diff"].as_object_mut().unwrap().remove("rounds");
    assert_eq!(by_id, job);
}

/// A fresh obid, no repository in its configuration: gh lists the GitHub repositories its login
/// can push to (`GET /v1/repos`), a job starts in one, and that job adds it to the configuration
/// file, every other key kept. A repository neither listed nor GitHub's is still refused. (git's
/// own `insteadOf` sends the GitHub URL to the fixture's remote, as a test can't reach GitHub.)
#[test]
fn a_fresh_obid_works_in_the_github_repositories_gh_can_push_to() {
    use std::os::unix::fs::PermissionsExt;
    let folder = Folder::new("github-repos");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = folder.0.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(
        bin.join("gh"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{calls}'\ncase \"$1 $2\" in\n  \"auth status\") if [ -f '{out}' ]; then echo '{{\"hosts\":{{}}}}'; else echo '{{\"hosts\":{{\"github.com\":[{{\"state\":\"success\",\"active\":true,\"login\":\"octo-cat\"}}]}}}}'; fi ;;\n  \"api user/repos\"*) printf 'obi-e2e/fixture-app\\tmain\\nobi-e2e/other\\tdev\\n' ;;\n  *) exit 1 ;;\nesac\n",
            calls = folder.0.join("gh-calls").display(),
            out = folder.0.join("signed-out").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::create_dir_all(folder.0.join("env-home")).unwrap();
    std::fs::write(
        folder.0.join("env-home/.gitconfig"),
        format!(
            "[url \"file://{}\"]\n\tinsteadOf = https://github.com/obi-e2e/fixture-app.git\n",
            remote.display()
        ),
    )
    .unwrap();
    let mut config = config(&folder.0, &remote);
    config["repos"] = json!([]);
    let obid = start_with(&folder.0, &config, Some(&bin));

    let give_up_at = Instant::now() + Duration::from_secs(30);
    let listed = loop {
        let answer = request(&obid, "GET", "/v1/repos", None);
        assert_eq!(answer.status, 200, "{}", answer.text);
        if answer.body["repos"]
            .as_array()
            .is_some_and(|r| !r.is_empty())
        {
            break answer.body;
        }
        assert!(Instant::now() < give_up_at, "gh's repositories never came");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(
        listed,
        json!({"repos": [
            {"repo": "obi-e2e/fixture-app", "defaultBranch": "main", "listed": false},
            {"repo": "obi-e2e/other", "defaultBranch": "dev", "listed": false}
        ]})
    );
    let calls = std::fs::read_to_string(folder.0.join("gh-calls")).unwrap();
    assert!(calls.contains("--paginate"), "{calls}");
    assert!(calls.contains("permissions.push"), "{calls}");

    let unknown = post_job(
        &obid,
        json!({"repo": "obi-e2e/elsewhere", "kind": "fix", "task": "Look around"}),
    );
    assert_eq!(unknown.status, 422, "{}", unknown.text);
    assert!(
        unknown.text.contains("isn't a repository obid knows"),
        "{}",
        unknown.text
    );

    let answer = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Look around"}),
    );
    assert_eq!(answer.status, 201, "{}", answer.text);
    assert_eq!(answer.body["base"], "main");
    let id = answer.body["id"].as_str().unwrap().to_owned();
    let path = folder.0.join("config.json");
    let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        written["repos"],
        json!([{"repo": "obi-e2e/fixture-app", "remote": "https://github.com/obi-e2e/fixture-app.git", "defaultBranch": "main"}])
    );
    assert_eq!(written["owner"], "wellington");
    assert_eq!(written["agents"], config["agents"]);
    obid::config::Config::load(&path).expect("obid starts with what it wrote");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(
        request(&obid, "GET", "/v1/repos", None).body["repos"][0],
        json!({"repo": "obi-e2e/fixture-app", "defaultBranch": "main", "listed": true})
    );

    // gh signed out: GitHub's list goes with its account, the listed repository stays.
    std::fs::write(folder.0.join("signed-out"), "").unwrap();
    let github = request(&obid, "GET", "/v1/github", None);
    assert_eq!(github.body["signedIn"], false, "{}", github.text);
    assert_eq!(
        request(&obid, "GET", "/v1/repos", None).body,
        json!({"repos": [{"repo": "obi-e2e/fixture-app", "defaultBranch": "main", "listed": true}]})
    );
    let gone = post_job(
        &obid,
        json!({"repo": "obi-e2e/other", "kind": "fix", "task": "Look around"}),
    );
    assert_eq!(gone.status, 422, "{}", gone.text);
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

    // Rename (`PATCH /v1/jobs/{id}`, Sangam's Rename): trimmed, kept, said in its changes, and
    // sent to every app as one `job` event; a refused rename sends none.
    let mut events = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    events
        .write_all(format!("GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\n\r\n").as_bytes())
        .unwrap();
    let mut events = BufReader::new(events);
    let mut line = String::new();
    events.read_line(&mut line).unwrap();
    assert!(line.starts_with("HTTP/1.1 200"), "{line}");
    std::thread::sleep(Duration::from_millis(200));
    let path = format!("/v1/jobs/{quiet}");
    let renamed = request(
        &obid,
        "PATCH",
        &path,
        Some(r#"{"title": "  Look around the app  "}"#),
    );
    assert_eq!(renamed.status, 200, "{}", renamed.body);
    assert_eq!(renamed.body["title"], "Look around the app");
    assert_eq!(
        request(&obid, "GET", &path, None).body["title"],
        "Look around the app"
    );
    let changes = renamed.body["changes"].as_array().unwrap();
    assert_eq!(changes.last().unwrap()["what"], "Renamed by you");
    let long = format!(r#"{{"title": "{}"}}"#, "a".repeat(61));
    for bad in [
        r#"{"title": "  "}"#,
        r#"{"title": "two\nlines"}"#,
        long.as_str(),
    ] {
        assert_eq!(
            request(&obid, "PATCH", &path, Some(bad)).status,
            422,
            "{bad}"
        );
    }
    for bad in [r#"{"name": "x"}"#, r#"{"title": 3}"#, "not json"] {
        assert_eq!(
            request(&obid, "PATCH", &path, Some(bad)).status,
            400,
            "{bad}"
        );
    }
    events
        .get_ref()
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let (mut event, mut renamed_events) = (String::new(), 0);
    loop {
        line.clear();
        if !matches!(events.read_line(&mut line), Ok(n) if n > 0) {
            break;
        }
        let text = line.trim();
        if let Some(name) = text.strip_prefix("event: ") {
            event = name.to_owned();
        } else if let Some(data) = text.strip_prefix("data: ")
            && event == "job"
        {
            let job: Value = serde_json::from_str(data).unwrap();
            if job["id"] == quiet.as_str() {
                assert_eq!(job["title"], "Look around the app", "{job}");
                renamed_events += 1;
            }
        }
    }
    assert_eq!(renamed_events, 1);
    assert_eq!(
        request(
            &obid,
            "PATCH",
            "/v1/jobs/nowhere",
            Some(r#"{"title": "x"}"#)
        )
        .status,
        404
    );
}

/// A job that changes obid runs obid's own tests inside its job sandbox, and they start obid's
/// fake agent there. Seatbelt can't make a sandbox inside another, so the test's obid runs its agent
/// in the job's sandbox it inherits, and only in a job's ("The job sandbox"). Each case runs one of
/// these tests inside a sandbox, as a job runs `cargo test`.
#[cfg(target_os = "macos")]
mod inside_a_job {
    use super::*;
    use obid::sandbox::{self, Sandbox, Spec};
    use std::ffi::OsString;

    /// What the inner run is given: the outer obid's home (with a file in it), a folder outside
    /// everything the job may write, and the job's temporary folder.
    pub struct Job {
        _folder: Folder,
        pub home: PathBuf,
        pub outside: PathBuf,
        pub temp: PathBuf,
    }

    impl Job {
        pub fn new(name: &str) -> Job {
            let folder = Folder::new(name);
            let home = folder.0.join("obid-home");
            let outside = folder.0.join("outside");
            let temp = folder.0.join("job-tmp");
            for dir in [&home, &outside, &temp] {
                std::fs::create_dir_all(dir).unwrap();
            }
            std::fs::write(home.join("api-token"), "outer obid's\n").unwrap();
            Job {
                _folder: folder,
                home,
                outside,
                temp,
            }
        }

        /// A sandbox made as a job's agent's (`Jobs::spec`): this repository is the worktree,
        /// obid's home and, with `person`, the person's homes are hidden.
        pub fn spec(&self, person: bool) -> Spec {
            let mut hidden = vec![self.home.clone()];
            if person {
                hidden.extend(obid::jobs::person_homes());
            }
            let path = obid::process::tools_path();
            let mut read_only =
                sandbox::tool_roots(&path, &hidden, std::slice::from_ref(&self.home));
            // The test binaries, wherever cargo built them.
            let this = std::env::current_exe().unwrap();
            read_only.extend(
                [this.parent().unwrap(), Path::new(OBID).parent().unwrap()].map(Path::to_path_buf),
            );
            Spec {
                worktree: obi(),
                temp: self.temp.clone(),
                read_only,
                hidden,
                network: true,
                ..Spec::default()
            }
        }

        /// The command line that runs this binary's `test` (and only it, ignored or not)
        /// inside `spec`'s sandbox.
        pub fn wrapped(&self, spec: &Spec, test: &str) -> Vec<OsString> {
            Sandbox::detect(Path::new(OBID))
                .unwrap()
                .wrap(spec, &self.argv(test))
        }

        pub fn argv(&self, test: &str) -> Vec<OsString> {
            vec![
                std::env::current_exe().unwrap().into_os_string(),
                test.into(),
                "--exact".into(),
                "--include-ignored".into(),
                "--nocapture".into(),
            ]
        }

        /// Runs `argv` in this repository with a job's environment and `env`: what it printed,
        /// and whether its one test passed.
        pub fn run(&self, argv: &[OsString], env: &[(&str, OsString)]) -> (bool, String) {
            let path = obid::process::tools_path();
            let output = Command::new(&argv[0])
                .args(&argv[1..])
                .current_dir(obi())
                .env_clear()
                .envs(obid::process::sandbox_env(&path, &self.temp, env))
                .stdin(Stdio::null())
                .output()
                .unwrap();
            let said = format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            (said.contains("test result: ok. 1 passed"), said)
        }

        /// What the inner obids logged, the folders their tests kept (`OBID_TEST_KEEP`).
        pub fn inner_logs(&self) -> String {
            let mut logs = String::new();
            for entry in std::fs::read_dir(&self.temp).unwrap().flatten() {
                logs +=
                    &std::fs::read_to_string(entry.path().join("obid.stderr")).unwrap_or_default();
            }
            logs
        }
    }
}

/// A fake-agent job test runs inside a job's sandbox, and its obid says it kept its agent in the
/// sandbox it runs in.
#[cfg(target_os = "macos")]
#[test]
fn a_fake_agent_test_runs_inside_a_jobs_sandbox() {
    let job = inside_a_job::Job::new("inside-a-job");
    let argv = job.wrapped(
        &job.spec(true),
        "nothing_committed_is_done_and_needs_nothing",
    );
    let (passed, said) = job.run(&argv, &[("OBID_TEST_KEEP", "1".into())]);
    assert!(passed, "{said}");
    assert!(
        job.inner_logs()
            .contains("obid runs inside a job sandbox, which Seatbelt can't nest in"),
        "{said}"
    );
}

/// The fake agent of a test run inside a job's sandbox still reads nothing of the person's home
/// or the outer obid's, and writes only where the job may: its own worktree, here.
#[cfg(target_os = "macos")]
#[test]
fn a_fake_agent_inside_a_jobs_sandbox_stays_in_it() {
    let job = inside_a_job::Job::new("inside-a-job-fenced");
    let person = nix::unistd::User::from_uid(nix::unistd::getuid())
        .unwrap()
        .unwrap()
        .dir;
    let dirs = [
        person.clone(),
        job.home.clone(),
        job.outside.clone(),
        PathBuf::from("."),
    ];
    let reach = dirs
        .iter()
        .map(|d| d.display().to_string())
        .collect::<Vec<_>>()
        .join(" ");
    let argv = job.wrapped(&job.spec(true), "reach_from_inside_a_job");
    let (passed, said) = job.run(&argv, &[("OBID_REACH", reach.into())]);
    assert!(passed, "{said}");
    // The homes are hidden; a folder elsewhere is read, as by any job, never written.
    for (dir, reached) in [
        (&dirs[0], "read=no write=no"),
        (&dirs[1], "read=no write=no"),
        (&dirs[2], "read=ok write=no"),
    ] {
        let expected = format!("{} {reached}", dir.display());
        assert!(said.contains(&expected), "{expected}: {said}");
        assert!(!dir.join(".obid-reached").exists(), "{dir:?}");
    }
    assert!(said.contains(". read=ok write=ok"), "{said}");
}

/// Run by the test above, inside a job's sandbox: a job whose fake agent tries the folders
/// `OBID_REACH` names, and says what it reached.
#[cfg(target_os = "macos")]
#[test]
#[ignore = "run inside a job's sandbox by a_fake_agent_inside_a_jobs_sandbox_stays_in_it"]
fn reach_from_inside_a_job() {
    let reach = std::env::var("OBID_REACH").unwrap();
    let folder = Folder::new("reach");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": format!("REACH: {reach}")}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    println!("REACHED: {}", job["summary"]);
}

/// Inside any sandbox but a job's, obid makes none and runs nothing: one that doesn't hide the
/// person's home, and one that hides it but lacks the job profile's other fences (Unix sockets,
/// the pasteboard), as an App Sandbox or a sandboxed launcher would.
#[cfg(target_os = "macos")]
#[test]
fn inside_another_sandbox_a_fake_agent_test_runs_nothing() {
    let job = inside_a_job::Job::new("inside-another");
    let person = nix::unistd::User::from_uid(nix::unistd::getuid())
        .unwrap()
        .unwrap()
        .dir;
    let foreign = format!(
        "(version 1)(allow default)(deny file-read-data (literal {:?}))(deny file-read* (subpath {:?}))",
        person.display().to_string(),
        job.home.display().to_string(),
    );
    let test = "nothing_committed_is_done_and_needs_nothing";
    let mut sandbox_exec: Vec<std::ffi::OsString> =
        vec!["/usr/bin/sandbox-exec".into(), "-p".into(), foreign.into()];
    sandbox_exec.extend(job.argv(test));
    for argv in [job.wrapped(&job.spec(false), test), sandbox_exec] {
        let (passed, said) = job.run(&argv, &[]);
        assert!(!passed, "{said}");
        assert!(said.contains("sandbox-exec can't make a sandbox"), "{said}");
    }
}

/// #606: what the agent left uncommitted when its job ends without being done is one `wip:`
/// commit on the job's branch, published by nothing; a round the owner asks for afterwards takes
/// it back out, so it counts as none of the job's commits.
#[test]
fn uncommitted_work_is_kept_as_a_wip_commit() {
    let folder = Folder::new("wip");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "DRAFT: draft.txt"}),
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
    let branch = format!("oby/fix-{id}");
    let start = job["startCommit"].as_str().unwrap();
    assert_eq!(
        git(&clone, &["log", "-1", "--format=%s", &branch]),
        "wip: work left uncommitted when the job ended"
    );
    assert_eq!(git(&clone, &["rev-parse", &format!("{branch}~1")]), start);
    assert_eq!(
        git(&clone, &["show", &format!("{branch}:draft.txt")]),
        "draft"
    );
    let worktree = obid.home.join("worktrees").join(&id);
    assert_eq!(git(&worktree, &["status", "--porcelain"]), "");
    assert_eq!(job["published"], Value::Null);
    // Nothing tried to publish (the GitHub feed's own `api graphql` calls aside).
    assert!(
        !std::fs::read_to_string(folder.0.join("gh-calls"))
            .unwrap_or_default()
            .lines()
            .any(|call| call.starts_with("pr "))
    );

    // Tried again: the agent finds its work uncommitted, as it left it, and ends with nothing
    // committed of its own, so nothing is published, and the work is kept again.
    let more = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(
            &json!({"text": "Try again, picking up where you left off. Finish with a short summary as asked."})
                .to_string(),
        ),
    );
    assert_eq!(more.status, 200, "{}", more.text);
    let job = until(&obid, &id, |j| {
        j["round"] == 2 && j["status"] != "queued" && j["status"] != "running"
    });
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["commits"], 0, "{job}");
    assert_eq!(job["published"], Value::Null, "{job}");
    // Nothing tried to publish (the GitHub feed's own `api graphql` calls aside).
    assert!(
        !std::fs::read_to_string(folder.0.join("gh-calls"))
            .unwrap_or_default()
            .lines()
            .any(|call| call.starts_with("pr "))
    );
    // The job ends before its worker keeps the work.
    until(&obid, &id, |_| {
        git(&clone, &["log", "-1", "--format=%s", &branch])
            == "wip: work left uncommitted when the job ended"
    });
    assert_eq!(git(&clone, &["rev-parse", &format!("{branch}~1")]), start);

    // Stopped mid-round: the same.
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "DRAFT: notes.txt SLEEP"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    beat(&obid, &id);
    request(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None);
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "stopped");
    let branch = format!("oby/build-{id}");
    // Stop answers before its worker keeps the work.
    until(&obid, &id, |_| {
        git(&clone, &["log", "-1", "--format=%s", &branch])
            == "wip: work left uncommitted when the job ended"
    });
    assert_eq!(
        git(&clone, &["show", &format!("{branch}:notes.txt")]),
        "draft"
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
    // The job carries its latest check run; every run is on the job by id (#734).
    let checks = job["checks"].as_array().unwrap();
    assert_eq!(checks.len(), 1, "{job}");
    assert_eq!(checks[0]["round"], 2);
    let step = &checks[0]["steps"][0];
    assert_eq!(
        (&step["passed"], &step["running"]),
        (&json!(false), &json!(false))
    );
    assert!(
        step["started"].is_string() && step["seconds"].is_u64(),
        "{step}"
    );
    let detail = request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    let rounds: Vec<Value> = detail["checks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|run| run["round"].clone())
        .collect();
    assert_eq!(rounds, [json!(1), json!(2)]);
    // Nothing went out, so no scan ran (#735).
    assert_eq!(
        job["scan"],
        json!({"ran": false, "reason": "checks failed"})
    );
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

/// A usage limit stops the round: it needs you with Try again, and obid tries it again by itself
/// a minute after the reset Claude Code named, from the same session. A reset already a minute
/// gone by (a stale one) arms nothing, so nothing loops.
#[test]
fn a_usage_limit_is_tried_again_after_its_reset() {
    let folder = Folder::new("reset");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let post = |task: &str| {
        post_job(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": task}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    // Reset 55 seconds ago: obid tries again 5 seconds from now.
    let id = post("LIMITED: -55");
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["nextStep"], "Try again", "{job}");
    assert_eq!(
        job["reason"],
        "Claude AI usage limit reached. Oby tries again by itself after the reset."
    );
    assert!(job["resumesAt"].as_str().unwrap().ends_with('Z'), "{job}");
    let session = job["session"].clone();
    let again = until(&obid, &id, |j| {
        j["round"] == 2 && j["status"] != "queued" && j["status"] != "running"
    });
    assert_eq!(again["status"], "done", "{again}");
    assert_eq!(again["session"], session, "{again}");
    assert_eq!(again["resumesAt"], Value::Null, "{again}");
    assert_eq!(again["reason"], Value::Null, "{again}");

    let stale = post("LIMITED: -120");
    let job = wait(&obid, &stale);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["nextStep"], "Try again", "{job}");
    assert_eq!(job["resumesAt"], Value::Null, "{job}");
    assert_eq!(job["reason"], "Claude AI usage limit reached.");
}

/// A job stopped at a limit after committing keeps its commits and counts them (#757): words told
/// to it start a follow-up from its branch, whose worktree has them.
#[test]
fn a_job_stopped_at_a_limit_counts_its_commits_for_a_follow_up() {
    let folder = Folder::new("limit-commits");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt", "check": "false", "rounds": 1}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(
        job["limit"], "`false` still fails after 1 round(s)",
        "{job}"
    );
    assert_eq!(job["commits"], 1, "{job}");
    let branch = format!("oby/build-{id}");
    let head = git(&clone, &["rev-parse", &branch]);

    let told = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": "Go on with it."}).to_string()),
    );
    assert_eq!(told.status, 201, "{}", told.text);
    let next = told.body["id"].as_str().unwrap().to_owned();
    let follow = wait(&obid, &next);
    assert_eq!(follow["followUpOf"], id.as_str(), "{follow}");
    assert_eq!(follow["startCommit"], head.as_str(), "{follow}");
    let worktree = obid.home.join("worktrees").join(&next);
    assert!(worktree.join("a.txt").exists(), "{follow}");
}

/// A follow-up that commits nothing still publishes the first job's commits it started from: it
/// ends done with them counted, pushed and in a pull request (#770). A follow-up of that one starts
/// on its branch with them, and, adding nothing to a branch that's out, publishes nothing.
#[test]
fn a_follow_up_publishes_the_first_jobs_commits() {
    let folder = Folder::new("follow-publish");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt", "request": "Add a.txt", "title": "Add a.txt", "check": "test -e b.txt", "rounds": 1}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["commits"], 1, "{job}");
    let head = git(&clone, &["rev-parse", &format!("oby/build-{id}")]);
    let tell = |id: &str, text: &str| {
        let told = request(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(&json!({ "text": text }).to_string()),
        );
        assert_eq!(told.status, 201, "{}", told.text);
        told.body["id"].as_str().unwrap().to_owned()
    };

    // Its agent leaves b.txt for the check and commits nothing.
    let next = tell(&id, "DRAFT: b.txt");
    let follow = wait(&obid, &next);
    assert_eq!(follow["status"], "done", "{follow}");
    assert_eq!(follow["startCommit"], head.as_str(), "{follow}");
    assert_eq!(follow["commits"], 1, "{follow}");
    assert_eq!(follow["reason"], Value::Null, "{follow}");
    assert_eq!(
        follow["published"], "https://github.com/obi-e2e/fixture-app/pull/7",
        "{follow}"
    );
    assert_eq!(follow["pushed"], 1, "{follow}");
    assert_eq!(
        git(
            &remote,
            &["rev-parse", &format!("refs/heads/oby/build-{next}")]
        ),
        head
    );

    let last = tell(&next, "DRAFT: b.txt");
    let again = wait(&obid, &last);
    assert_eq!(again["branch"], format!("oby/build-{next}"), "{again}");
    assert!(
        obid.home
            .join("worktrees")
            .join(&last)
            .join("a.txt")
            .exists(),
        "{again}"
    );
    assert_eq!(again["status"], "done", "{again}");
    assert_eq!(again["commits"], 0, "{again}");
    assert_eq!(
        again["reason"], "Nothing committed, so nothing was published.",
        "{again}"
    );
}

/// A follow-up of a job whose pull request was closed without merging doesn't send those commits
/// again by itself when it adds none: it ends done, saying so, with Publish the owner's (#770).
#[test]
fn a_follow_up_doesnt_republish_a_closed_pull_requests_commits() {
    let folder = Folder::new("follow-closed");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    std::fs::write(
        folder.0.join("pr-view.json"),
        json!({"state": "CLOSED", "reviewDecision": null, "mergedAt": null, "baseRefName": "main"})
            .to_string(),
    )
    .unwrap();
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt", "request": "Add a.txt", "title": "Add a.txt", "check": "test -f a.txt"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = until(&obid, &id, |j| j["pullRequest"]["state"] == "CLOSED");
    assert_eq!(job["status"], "done", "{job}");
    let told = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": "Why was it closed?"}).to_string()),
    );
    assert_eq!(told.status, 201, "{}", told.text);
    let next = told.body["id"].as_str().unwrap().to_owned();
    let follow = wait(&obid, &next);
    assert_eq!(follow["status"], "done", "{follow}");
    assert_eq!(follow["branch"], format!("oby/build-{next}"), "{follow}");
    assert_eq!(follow["commits"], 1, "{follow}");
    assert_eq!(follow["published"], Value::Null, "{follow}");
    assert_eq!(follow["outgoing"], json!([]), "{follow}");
    let turned_down = "The pull request of Add a.txt was closed without merging, so Oby didn't publish its commits again: Publish opens a new pull request with them.";
    assert_eq!(follow["reason"], turned_down, "{follow}");

    // A follow-up of that follow-up carries the same turned-down commits: nor does it.
    let told = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{next}/messages"),
        Some(&json!({"text": "And now?"}).to_string()),
    );
    assert_eq!(told.status, 201, "{}", told.text);
    let last = told.body["id"].as_str().unwrap().to_owned();
    let again = wait(&obid, &last);
    assert_eq!(again["status"], "done", "{again}");
    assert_eq!(again["branch"], format!("oby/build-{last}"), "{again}");
    assert_eq!(again["commits"], 1, "{again}");
    assert_eq!(again["published"], Value::Null, "{again}");
    assert_eq!(again["outgoing"], json!([]), "{again}");
    assert_eq!(again["reason"], turned_down, "{again}");
}

/// A follow-up of a job that pushed with no pull request (a remote without them) doesn't push
/// those commits again to a branch of its own when it adds none: they're out (#770).
#[test]
fn a_follow_up_doesnt_repush_its_first_jobs_pushed_commits() {
    let folder = Folder::new("follow-pushed");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote);
    config["repos"][0]["pullRequests"] = json!(false);
    let obid = start(&folder.0, &config);
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt", "request": "Add a.txt", "title": "Add a.txt", "check": "test -f a.txt"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["pushed"], 1, "{job}");
    assert_eq!(job["published"], Value::Null, "{job}");
    let told = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": "Anything left?"}).to_string()),
    );
    assert_eq!(told.status, 201, "{}", told.text);
    let next = told.body["id"].as_str().unwrap().to_owned();
    let follow = wait(&obid, &next);
    assert_eq!(follow["status"], "done", "{follow}");
    assert_eq!(follow["branch"], format!("oby/build-{next}"), "{follow}");
    assert_eq!(follow["commits"], 0, "{follow}");
    assert_eq!(follow["outgoing"], json!([]), "{follow}");
    assert_eq!(
        follow["reason"], "Nothing committed, so nothing was published.",
        "{follow}"
    );
}

/// A job stopped at a limit, tried again: the round's final words are its summary and its last
/// round's; an agent that says nothing keeps the earlier round's, never "" (#764).
#[test]
fn try_again_after_a_limit_keeps_the_rounds_summary() {
    let folder = Folder::new("limit-again");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let tried = |file: &str, words: &str| {
        let id = post_job(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": format!("COMMIT: {file} AGAIN:{words}"), "check": "test -e .obi/tried", "rounds": 1}),
        )
        .body["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let job = wait(&obid, &id);
        // At its limit it needs you (#725), One more round its next step.
        assert_eq!(job["status"], "interrupted", "{job}");
        assert_eq!(job["nextStep"], "One more round", "{job}");
        assert!(job["limit"].is_string(), "{job}");
        let more = request(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(
                &json!({"text": "Try again, picking up where you left off. Finish with a short summary as asked."})
                    .to_string(),
            ),
        );
        assert_eq!(more.status, 200, "{}", more.text);
        // Round 2 starts, then ends however long publishing takes on a busy machine.
        until(&obid, &id, |j| j["round"] == 2);
        let job = wait(&obid, &id);
        assert_eq!(job["round"], 2, "{job}");
        assert_eq!(job["status"], "done", "{job}");
        job
    };

    let job = tried("a.txt", " Done.");
    assert_eq!(job["summary"], "Done.", "{job}");
    assert_eq!(job["summaries"], json!(["Added a.txt.", "Done."]), "{job}");

    let job = tried("b.txt", "");
    assert_eq!(job["summary"], "Added b.txt.", "{job}");
    assert_eq!(job["summaries"], json!(["Added b.txt."]), "{job}");
}

/// Each round's change against the start commit is kept as that round's (#736): paths and the
/// counts `git diff --numstat` gives, never what the files hold.
#[test]
fn each_round_keeps_its_diff_stat() {
    let folder = Folder::new("diff");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "EDIT: src/greet.js COMMIT: a.txt", "check": "false", "rounds": 2}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let start = job["startCommit"].as_str().unwrap();
    let numstat = git(
        &clone,
        &["diff", "--numstat", start, &format!("oby/build-{id}")],
    );
    let mut by_file: Vec<Value> = numstat
        .lines()
        .map(|line| {
            let parts: Vec<&str> = line.split('\t').collect();
            json!({"path": parts[2], "added": parts[0].parse::<u64>().unwrap(), "removed": parts[1].parse::<u64>().unwrap()})
        })
        .collect();
    by_file.sort_by_key(|f| f["path"].as_str().unwrap().to_owned());
    assert_eq!(by_file.len(), 2, "{numstat}");
    let diff = &job["diff"];
    assert_eq!(diff["files"], 2, "{job}");
    assert_eq!(diff["added"], 2, "{job}");
    assert_eq!(diff["removed"], 0, "{job}");
    let mut served = diff["byFile"].as_array().unwrap().clone();
    served.sort_by_key(|f| f["path"].as_str().unwrap().to_owned());
    assert_eq!(served, by_file);
    // Every round's only on the job itself, not on every event.
    assert!(diff.get("rounds").is_none(), "{job}");
    let detail = request(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(detail["diff"]["byFile"], diff["byFile"]);
    let rounds = detail["diff"]["rounds"].as_array().unwrap();
    assert_eq!(
        rounds
            .iter()
            .map(|r| r["round"].clone())
            .collect::<Vec<_>>(),
        [json!(1), json!(2)]
    );
    assert_eq!(rounds[0]["byFile"].as_array().unwrap().len(), 2);
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

/// The prompts the stand-in agent got in the job's worktree (`KEEP PROMPTS`), oldest first.
fn prompts(obid: &Obid, id: &str) -> Vec<String> {
    let log = obid
        .home
        .join("worktrees")
        .join(id)
        .join(".obi/prompts.log");
    std::fs::read_to_string(&log)
        .unwrap_or_default()
        .split("<<<end of prompt>>>\n")
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect()
}

/// #958: a fix, build or test with a check gets 3 rounds when nobody named a number, however it
/// started; a number given is kept, 1 included; a review, or a job with no check, keeps 1.
#[test]
fn a_fix_with_a_check_gets_three_rounds_unless_told() {
    let folder = Folder::new("rounds-default");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let rounds = |job: Value| {
        let answer = post_job(&obid, job);
        assert_eq!(answer.status, 201, "{}", answer.text);
        answer.body["rounds"].clone()
    };
    let job = |kind: &str, check: Option<&str>, rounds: Option<u32>| {
        let mut job = json!({"repo": "obi-e2e/fixture-app", "kind": kind, "task": "Nothing to do"});
        if let Some(check) = check {
            job["check"] = json!(check);
        }
        if let Some(rounds) = rounds {
            job["rounds"] = json!(rounds);
        }
        job
    };
    for kind in ["fix", "build", "test"] {
        assert_eq!(rounds(job(kind, Some("true"), None)), 3, "{kind}");
    }
    assert_eq!(rounds(job("fix", Some("true"), Some(1))), 1);
    assert_eq!(rounds(job("fix", Some("true"), Some(5))), 5);
    assert_eq!(rounds(job("fix", None, None)), 1);
    assert_eq!(rounds(job("review", Some("true"), None)), 1);
    assert_eq!(rounds(job("investigate", Some("true"), None)), 1);
}

/// A check that keeps failing, with no rounds named: the agent is told it has 3 rounds and that
/// the check runs offline, hears the check's output in rounds 2 and 3, and the job stops at its
/// limit after round 3, nothing pushed. One more round (Try again's words) picks the session up
/// with the check's output in front of them, as the orchestrator's retry does.
#[test]
fn a_failing_check_is_heard_every_round_and_on_one_more_round() {
    let folder = Folder::new("rounds-heard");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let check = "echo CHECK-SAID-7e1; false";
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "KEEP PROMPTS COMMIT: a.txt", "check": check}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(
        (&job["round"], &job["rounds"]),
        (&json!(3), &json!(3)),
        "{job}"
    );
    assert_eq!(job["nextStep"], "One more round", "{job}");
    assert_eq!(
        job["limit"],
        format!("`{check}` still fails after 3 round(s)")
    );
    assert_eq!(job["pushed"], Value::Null, "{job}");
    let said = prompts(&obid, &id);
    assert_eq!(said.len(), 3, "{said:?}");
    assert!(
        said[0].contains("You have 3 rounds: if the check fails, obid sends you its output."),
        "{}",
        said[0]
    );
    assert!(
        said[0].contains("with no network: fetch what it needs"),
        "{}",
        said[0]
    );
    for round in &said[1..] {
        assert!(
            round.starts_with(&format!("`{check}` failed after your last round.")),
            "{round}"
        );
        assert!(round.contains("CHECK-SAID-7e1"), "{round}");
    }

    let more = request(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(
            &json!({"text": "Try again, picking up where you left off. Finish with a short summary as asked."})
                .to_string(),
        ),
    );
    assert_eq!(more.status, 200, "{}", more.text);
    until(&obid, &id, |j| j["round"] == 4);
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert_eq!(job["rounds"], 4, "{job}");
    let said = prompts(&obid, &id);
    assert_eq!(said.len(), 4, "{said:?}");
    let resumed = &said[3];
    assert!(
        resumed.starts_with(&format!(
            "`{check}` failed after your last round. Its output, from the end:"
        )),
        "{resumed}"
    );
    assert!(resumed.contains("CHECK-SAID-7e1"), "{resumed}");
    assert!(
        resumed.trim_end().ends_with(
            "Try again, picking up where you left off. Finish with a short summary as asked."
        ),
        "{resumed}"
    );
}

/// A fix whose check fails once, with no rounds named, is fixed in its second round and
/// publishes: Needs you never hears of it.
#[test]
fn a_fix_that_fails_once_is_fixed_in_its_second_round() {
    let folder = Folder::new("rounds-second");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "COMMIT: a.txt", "check": "test -e .obi/ran || { mkdir -p .obi; touch .obi/ran; false; }"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["round"], 2, "{job}");
    assert_eq!(job["commits"], 1, "{job}");
    assert!(job["published"].is_string(), "{job}");
    assert_eq!(job["publishError"], Value::Null, "{job}");
}

/// Work the agent left uncommitted, none committed: obid tells it once to commit it, and what it
/// commits publishes. Its summary stays the work's.
#[test]
fn uncommitted_work_gets_one_commit_turn() {
    let folder = Folder::new("commit-turn");
    let remote = fixture(&folder.0.join("fixture"));
    let bin = fake_gh(&folder.0);
    let obid = start_with(&folder.0, &config(&folder.0, &remote), Some(&bin));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "DRAFT: draft.txt COMMIT WHEN TOLD"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["commits"], 1, "{job}");
    assert_eq!(job["reason"], Value::Null, "{job}");
    assert!(job["published"].is_string(), "{job}");
    assert_eq!(job["summary"], "Nothing to do.", "{job}");
    assert_eq!(
        job["summaries"],
        json!(["Nothing to do.", "Committed the draft."]),
        "{job}"
    );
    let branch = format!("oby/fix-{id}");
    assert_eq!(
        git(&remote, &["show", &format!("{branch}:draft.txt")]),
        "draft"
    );
}

/// The job's temporary HOME, with the package caches its agent filled, stays between its runs
/// for the offline check, and goes with its worktree; the MCP config's broker token never stays.
#[test]
fn a_jobs_home_stays_until_its_worktree_is_cleaned_up() {
    let folder = Folder::new("home-kept");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let id = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Nothing to do"}),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let job = wait(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    let home = obid.home.join("tmp").join(&id);
    assert!(home.is_dir(), "{home:?}");
    assert!(!home.join("obi-mcp.json").exists());
    // Clear done settles it, and its worktree goes, with its HOME.
    let cleared = request(&obid, "POST", "/v1/clear", None);
    assert_eq!(cleared.status, 200, "{}", cleared.text);
    until(&obid, &id, |_| {
        !obid.home.join("worktrees").join(&id).exists()
    });
    assert!(!home.exists(), "{home:?}");
}

/// obid answers the agent's permission prompts: publishing, leaving the worktree and a background
/// subagent are refused, the rest of a bypass job's work is allowed (a background command too); and none of obid's own secrets reach the agent.
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
            json!({"tool": "Agent", "input": {"description": "x", "run_in_background": true}}),
            "answer: deny",
        ),
        // Waited for: Claude Code wakes when it ends (crate::agent).
        (
            json!({"tool": "Bash", "input": {"command": "sleep 1", "run_in_background": true}}),
            "answer: allow",
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
            // A job's transcript comes as events of its own (`transcript`).
            if event == "transcript" {
                continue;
            }
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

/// Ports ReserveTests.theAPILiftsAndRestoresTheReserve: the usage Claude Code reports during a job
/// fills its Account, and the reserve it puts the account in is lifted and put back, across a
/// restart.
#[test]
fn the_api_lifts_and_restores_the_reserve() {
    let folder = Folder::new("reserve");
    let remote = fixture(&folder.0);
    let config = config(&folder.0, &remote);
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    let mut obid = start(&folder.0, &config);
    let status = |obid: &Obid| request(obid, "GET", "/v1/status", None).body["accounts"][0].clone();
    assert!(status(&obid)["sevenDay"].is_null());

    let reset = obi_protocol::time::now() + 2 * 86_400;
    let usage = json!({"status": "allowed_warning", "unifiedWindows": {
        "five_hour": {"utilization": 0.1, "resetsAt": reset - 86_400},
        "seven_day": {"utilization": 0.82, "resetsAt": reset}}});
    let job = |task: String| json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": task, "check": "true"});
    let first = post_job(&obid, job(format!("USAGE: {usage}")));
    assert_eq!(first.status, 201, "{}", first.text);
    wait(&obid, first.body["id"].as_str().unwrap());
    let stub = status(&obid);
    assert_eq!(stub["fiveHour"], 0.1);
    assert_eq!(stub["sevenDay"], 0.82);
    assert_eq!(
        stub["fiveHourResets"],
        obi_protocol::time::format(reset - 86_400)
    );
    assert_eq!(stub["sevenDayResets"], obi_protocol::time::format(reset));
    assert_eq!(stub["reserved"], true);
    assert!(stub["fullUntil"].is_null());

    // In its reserve, it takes only a job sent to it by name.
    let refused = post_job(&obid, job("Nothing to do".into()));
    assert_eq!(refused.status, 422, "{}", refused.text);
    assert!(
        refused
            .text
            .contains("Stub is in its weekly reserve (82% of its week used)"),
        "{}",
        refused.text
    );
    let mut named = job("Nothing to do".into());
    named["account"] = json!("stub");
    assert_eq!(post_job(&obid, named.clone()).status, 201);

    let lift =
        |obid: &Obid, body: &str| request(obid, "POST", "/v1/accounts/stub/reserve", Some(body));
    let lifted = lift(&obid, r#"{"lift": true}"#);
    assert_eq!(lifted.status, 200, "{}", lifted.text);
    assert_eq!(lifted.body["reserved"], false);
    assert_eq!(
        lifted.body["reserveLiftedUntil"],
        obi_protocol::time::format(reset)
    );
    assert_eq!(post_job(&obid, job("Nothing to do".into())).status, 201);

    // A restart keeps the usage and the lift.
    obid.child.kill().unwrap();
    obid.child.wait().unwrap();
    drop(obid);
    let obid = start(&folder.0, &config);
    assert_eq!(status(&obid)["sevenDay"], 0.82);
    assert_eq!(status(&obid)["reserved"], false);
    let restored = lift(&obid, r#"{"lift": false}"#);
    assert_eq!(restored.status, 200, "{}", restored.text);
    assert_eq!(restored.body["reserved"], true);
    assert!(restored.body["reserveLiftedUntil"].is_null());
    assert_eq!(post_job(&obid, job("Nothing to do".into())).status, 422);

    let nobody = request(
        &obid,
        "POST",
        "/v1/accounts/nobody/reserve",
        Some(r#"{"lift": true}"#),
    );
    assert_eq!(nobody.status, 404);
    for (body, status) in [
        ("false", 400),
        ("{", 400),
        ("{}", 422),
        (r#"{"lift": "true"}"#, 422),
        (r#"{"lift": true, "x": 1}"#, 422),
    ] {
        assert_eq!(lift(&obid, body).status, status, "{body}");
    }
}

/// A Claude Code job's turns sum into its `usage` as their result lines report them, and it
/// stays once the job ended (#731).
#[test]
fn a_jobs_turns_sum_into_its_usage() {
    let folder = Folder::new("job-usage");
    let remote = fixture(&folder.0);
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let plain = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Nothing to do", "check": "true"}),
    );
    let plain = wait(&obid, plain.body["id"].as_str().unwrap());
    // The stand-in's plain result reports a cost of 0 and no tokens.
    assert_eq!(plain["usage"], json!({"costUsd": 0.0, "priced": "plan"}));

    let job = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "TOKENS", "check": "false", "rounds": 2}),
    );
    assert_eq!(job.status, 201, "{}", job.text);
    let job = wait(&obid, job.body["id"].as_str().unwrap());
    assert_eq!(job["round"], 2, "{job}");
    // Two turns, each 110 in, 25 out, 1000 read from the cache, 50 written to it, $0.25.
    assert_eq!(
        job["usage"],
        json!({"input": 220, "output": 50, "cacheRead": 2000, "cacheWrite": 100, "costUsd": 0.5, "priced": "plan"}),
        "{job}"
    );
}

/// A job alone on its account gets the whole rise of each window between its account's reports,
/// as an estimate (#732).
#[test]
fn a_job_alone_gets_the_whole_rise_of_its_accounts_windows() {
    let folder = Folder::new("window-share");
    let remote = fixture(&folder.0);
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    let obid = start(&folder.0, &config(&folder.0, &remote));
    let at = obi_protocol::time::now() + 3_600;
    let report = |five: f64, week: f64| {
        json!({"status": "allowed", "unifiedWindows": {
        "five_hour": {"utilization": five, "resetsAt": at}, "seven_day": {"utilization": week, "resetsAt": at + 86_400}}})
    };
    let usages = json!([report(0.1, 0.3), report(0.3, 0.35)]);
    let job = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": format!("TOKENS USAGES: {usages}"), "check": "false", "rounds": 2}),
    );
    assert_eq!(job.status, 201, "{}", job.text);
    let job = wait(&obid, job.body["id"].as_str().unwrap());
    assert_eq!(job["round"], 2, "{job}");
    assert_eq!(
        job["windowShare"],
        json!({"fiveHour": 20.0, "sevenDay": 5.0, "estimate": true}),
        "{job}"
    );
    // A job whose account reported once has no share to show.
    let one = post_job(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": format!("USAGE: {}", report(0.4, 0.4)), "check": "true"}),
    );
    let one = wait(&obid, one.body["id"].as_str().unwrap());
    assert!(one.get("windowShare").is_none(), "{one}");
}
