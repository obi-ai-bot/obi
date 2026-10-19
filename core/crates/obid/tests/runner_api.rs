//! More of RunnerTests' API-level tests, ported to the real obid binary asked over HTTP: the job as
//! the API sends it, Clear done, jobs beyond the latest 50, the slot a job waits for, and what a
//! dispatch body sets. The Swift test each one ports is named on it; tests/PORTING.md lists every
//! RunnerTests test, ported or not, and why.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

/// tests/agents/fake-claude: the stand-in agent (`COMMIT: <file>`, `SLEEP`, `FAIL`, `ASK: …`).
fn fake_claude() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude")
}

/// obid with the fixture repository and the stand-in agent.
fn obid(folder: &Folder) -> (Obid, Value) {
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &fake_claude());
    (start(&folder.0, &config, None), config)
}

fn dispatch(obid: &Obid, job: Value) -> Value {
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({"job": job})));
    assert_eq!(answer.status, 201, "{}", answer.text);
    answer.body
}

fn job(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn ended(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn is_iso_second(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 20
        && bytes.iter().enumerate().all(|(i, b)| match i {
            4 | 7 => *b == b'-',
            10 => *b == b'T',
            13 | 16 => *b == b':',
            19 => *b == b'Z',
            _ => b.is_ascii_digit(),
        })
}

fn events(obid: &Obid) -> BufReader<TcpStream> {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stream.write_all(format!("GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\n\r\n").as_bytes()).unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        reader.read_line(&mut line).unwrap();
        if line == "\r\n" {
            break;
        }
    }
    reader
}

fn next_check_event(reader: &mut BufReader<TcpStream>) -> Value {
    let mut is_check = false;
    let mut line = String::new();
    loop {
        line.clear();
        reader.read_line(&mut line).unwrap();
        if line.starts_with("event: ") {
            is_check = line.trim_end() == "event: check";
        } else if is_check && let Some(data) = line.strip_prefix("data: ") {
            return serde_json::from_str(data.trim()).unwrap();
        }
    }
}

/// Every key the Swift runner's job has (Runner/API.swift, `JobJSON`): the stored ones, the ones
/// it sends as null when unset (`Nullable`) and the derived ones (`Derived`). 65 in all.
const SWIFT_JOB_KEYS: [&str; 65] = [
    "id",
    "request",
    "agent",
    "account",
    "repo",
    "branch",
    "kind",
    "task",
    "status",
    "step",
    "summary",
    "created",
    // Nullable
    "base",
    "pr",
    "session",
    "started",
    "finished",
    "commits",
    "published",
    "pushed",
    "publishError",
    "summaries",
    "issue",
    "fromPR",
    "rounds",
    "round",
    "check",
    "model",
    "effort",
    "complexity",
    "notes",
    "pullRequest",
    "pullRequestError",
    "dismissed",
    "reviewing",
    "review",
    "reviewError",
    "reviewOf",
    "files",
    "lead",
    "claim",
    "outgoing",
    "question",
    "limit",
    "startCommit",
    "firstSwiftBuildSeconds",
    "macCheck",
    "mergeError",
    "appleCheck",
    "appleRan",
    "tetrix",
    "moves",
    "xcodeCloud",
    "xcodeCloudError",
    "startWhen",
    "waiting",
    "mode",
    "permission",
    "connectionUses",
    // Derived
    "pipeline",
    "title",
    "mergeNeedsYou",
    "reviewNeedsYou",
    "cloudNeedsYou",
    "report",
];

/// RunnerTests.jobsHaveISODatesAndEveryKey and TitleTests.theJobKeepsItsTitleAndTheAPISendsIt:
/// every key the apps read is there, null when unset rather than left out, plus the two only obid
/// sends (`obi`, `worktree`: runner-api.md, "obid only: Obi-to-Obi review jobs"); dates are ISO
/// 8601 to the second; the title given is the one sent. A job from before modes runs as bypass.
#[test]
fn jobs_have_iso_dates_and_every_key() {
    let folder = Folder::new("every-key");
    let (obid, _) = obid(&folder);
    let sent = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "Look around",
               "title": "Job progress screen"}),
    );
    let id = sent["id"].as_str().unwrap().to_owned();
    for body in [sent, job(&obid, &id), ended(&obid, &id)] {
        let keys = body.as_object().unwrap();
        for key in SWIFT_JOB_KEYS {
            assert!(keys.contains_key(key), "{key} is missing: {body}");
        }
        let mut extra: Vec<&str> = keys
            .keys()
            .map(String::as_str)
            .filter(|k| !SWIFT_JOB_KEYS.contains(k))
            .collect();
        extra.sort_unstable();
        assert_eq!(
            extra,
            [
                "answered",
                "answeredCount",
                "artifactProblems",
                "artifacts",
                "conversation",
                "followUpOf",
                "nextStep",
                "obi",
                "reason",
                "worktree"
            ],
            "{body}"
        );
        assert_eq!(keys.len(), 75);
        // What obid never sets is there, as null.
        for key in [
            "published",
            "pushed",
            "fromPR",
            "complexity",
            "pullRequest",
            "pullRequestError",
            "reviewing",
            "review",
            "reviewError",
            "reviewOf",
            "lead",
            "claim",
            "question",
            "firstSwiftBuildSeconds",
            "macCheck",
            "mergeError",
            "appleCheck",
            "appleRan",
            "tetrix",
            "xcodeCloud",
            "xcodeCloudError",
            "startWhen",
            "permission",
            "pr",
            "issue",
            "obi",
        ] {
            assert!(body[key].is_null(), "{key} isn't null: {body}");
        }
        assert!(is_iso_second(body["created"].as_str().unwrap()), "{body}");
        assert_eq!(body["title"], "Job progress screen");
        assert_eq!(body["report"], false);
        assert_eq!(body["cloudNeedsYou"], false);
        assert_eq!(body["mergeNeedsYou"], false);
        assert_eq!(body["reviewNeedsYou"], false);
        assert_eq!(body["mode"], "sandbox");
        assert_eq!(body["outgoing"], json!([]));
        assert_eq!(body["moves"], json!([]));
        assert_eq!(body["connectionUses"], json!([]));
        assert!(body["pipeline"].is_object());
        assert_eq!(body["rounds"], 1);
        assert_eq!(body["round"], 1);
        assert_eq!(body["kind"], "research");
    }
    let done = ended(&obid, &id);
    assert_eq!(done["status"], "done");
    assert!(is_iso_second(done["started"].as_str().unwrap()), "{done}");
    assert!(is_iso_second(done["finished"].as_str().unwrap()), "{done}");
    // WaitingTests.theAPISendsWhatItWaitsFor, its second half: nothing to wait for is null.
    assert!(done["waiting"].is_null());
}

/// ReviewJobTests.theRunnerSaysAReviewMadeNoCommits: a review's worktree holds the pull request's
/// commits, not its own, so the API says it made none.
#[test]
fn the_runner_says_a_review_made_no_commits() {
    let folder = Folder::new("review-commits");
    let remote = fixture(&folder.0.join("fixture"));
    // Pull request #90: a commit on top of main, as GitHub keeps it under refs/pull/90/head.
    let clone = folder.0.join("author");
    git(
        &folder.0,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            clone.to_str().unwrap(),
        ],
    );
    std::fs::write(clone.join("NOTES.md"), "The pull request's own work.\n").unwrap();
    git(&clone, &["add", "NOTES.md"]);
    git(
        &clone,
        &[
            "-c",
            "user.name=Author",
            "-c",
            "user.email=author@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "Add notes",
        ],
    );
    git(&clone, &["push", "-q", "origin", "HEAD:refs/pull/90/head"]);
    let obid = start(&folder.0, &config(&folder.0, &remote, &fake_claude()), None);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "review", "task": "Look around", "pr": 90}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let done = ended(&obid, &id);
    assert_eq!(done["status"], "done", "{done}");
    assert_eq!(done["commits"], 0);
    assert_eq!(done["pr"], 90);
    assert_eq!(done["branch"], "oby/review-90");
}

/// RunnerTests.dispatchBodiesAreWholeJobs, through the API: what a whole job's body sets is the
/// job's (rounds, check, model, issue and the branch it names); an empty startWhen is none, and
/// files left out are null, not none.
#[test]
fn dispatch_bodies_are_whole_jobs() {
    let folder = Folder::new("whole");
    let (obid, _) = obid(&folder);
    let sent = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Fix #42", "issue": 42,
               "account": "stub", "rounds": 3, "check": "true", "model": "claude-fable-5-1",
               "startWhen": []}),
    );
    assert_eq!(sent["repo"], "obi-e2e/fixture-app");
    assert_eq!(sent["kind"], "fix");
    assert_eq!(sent["task"], "Fix #42");
    assert_eq!(sent["issue"], 42);
    assert!(sent["pr"].is_null());
    assert_eq!(sent["account"], "stub");
    assert_eq!(sent["rounds"], 3);
    assert_eq!(sent["check"], "true");
    assert_eq!(sent["model"], "claude-fable-5-1");
    assert!(sent["startWhen"].is_null());
    assert!(sent["files"].is_null());
    assert_eq!(sent["branch"], "oby/fix-42");
    let id = sent["id"].as_str().unwrap().to_owned();
    call(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None);
    // A check left out is the repository's own.
    let own = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around"}),
    );
    assert_eq!(own["check"], "node --test");
}

/// ClearTests.statusSaysNullUntilTheFirstClearThenTheTime and everyAppFollowingEventsHearsAClear:
/// `clearedAt` is null until the first clear; `POST /v1/clear` answers the time, on obid's clock,
/// to the second; every app following events hears the same body; status says it from then on.
/// ClearTests.theClearSurvivesARestartAndNeverGoesBack, the part the API shows: a restart keeps
/// it, and a later clear moves it on (src/clear.rs's own test sets the clock for the rest).
#[test]
fn clear_done_is_kept_said_and_heard() {
    let folder = Folder::new("clear");
    let (mut obid, config) = obid(&folder);
    let status = call(&obid, "GET", "/v1/status", None).body;
    assert!(status.as_object().unwrap().contains_key("clearedAt"));
    assert!(status["clearedAt"].is_null());
    let events = follow_events(&obid);
    let before = obi_protocol::time::now();
    let answer = call(&obid, "POST", "/v1/clear", None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    let time = answer.body["clearedAt"].as_str().unwrap().to_owned();
    assert_eq!(answer.body, json!({"clearedAt": time}));
    assert!(is_iso_second(&time), "{time}");
    let cleared = obi_protocol::time::parse(&time).unwrap();
    assert!(cleared >= before && cleared <= obi_protocol::time::now());
    let heard = events_named(&events, "clear", 10, |got| !got.is_empty());
    assert_eq!(heard, [json!({"clearedAt": time})]);
    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["clearedAt"],
        time.as_str()
    );

    assert!(obid.stop().success());
    let folder_path = obid.folder.clone();
    drop(obid);
    let obid = start(&folder_path, &config, None);
    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["clearedAt"],
        time.as_str()
    );
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let later = call(&obid, "POST", "/v1/clear", None).body["clearedAt"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(obi_protocol::time::parse(&later).unwrap() > cleared);
    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["clearedAt"],
        later.as_str()
    );
}

/// OldJobsTests.theAPIFindsAndDismissesJob60: of 60 jobs kept from before, the list has the
/// newest 50, and any of them is found by id, the 59th that needs nothing as much as the failed
/// 60th; dismissing that one is kept across the next restart.
#[test]
fn the_api_finds_and_dismisses_job_60() {
    let folder = Folder::new("job-60");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &fake_claude());
    let home = folder.0.join("home");
    std::fs::create_dir_all(&home).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    // Saved before obid starts, as a runner that ran them would have: job #1 the newest.
    let store = obid::store::Store::open(&home).unwrap();
    let now = obi_protocol::time::now() - 3600;
    for number in 1..=60 {
        let id = if number == 60 {
            "failed".to_owned()
        } else {
            format!("job-{number}")
        };
        let mut old = obid::job::Job::new(
            id.clone(),
            "obi-e2e/fixture-app".into(),
            "fix".into(),
            format!("Fix #{number}"),
            "claude".into(),
            "stub".into(),
        );
        old.branch = format!("oby/fix-{number}");
        old.base = Some("main".into());
        old.created = now - number * 60;
        old.started = Some(old.created + 1);
        old.finished = Some(old.created + 30);
        old.round = Some(1);
        if number == 60 {
            old.status = obid::job::Status::Failed;
            old.summary = "Couldn't finish: the check failed.".into();
        } else {
            old.status = obid::job::Status::Done;
            old.commits = Some(0);
            old.summary = "Nothing to do.".into();
        }
        store.save(&old).unwrap();
    }
    let obid = start(&folder.0, &config, None);
    let listed: Vec<String> = call(&obid, "GET", "/v1/jobs?limit=50", None)
        .body
        .as_array()
        .unwrap()
        .iter()
        .map(|j| j["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        listed,
        (1..=50).map(|n| format!("job-{n}")).collect::<Vec<_>>()
    );
    assert_eq!(job(&obid, "job-59")["id"], "job-59");
    assert_eq!(job(&obid, "failed")["status"], "failed");
    let dismissed = call(&obid, "POST", "/v1/jobs/failed/dismiss", None);
    assert_eq!(dismissed.status, 200, "{}", dismissed.text);
    assert!(dismissed.body["dismissed"].as_str().unwrap().ends_with('Z'));
    assert_eq!(call(&obid, "GET", "/v1/jobs/nowhere", None).status, 404);
    drop(obid);
    let obid = start(&folder.0, &config, None);
    assert!(
        job(&obid, "failed")["dismissed"]
            .as_str()
            .unwrap()
            .ends_with('Z')
    );
}

/// WaitingTests.theAPISendsWhatItWaitsFor, and ParallelTests.aSeventhJobWaitsWhileSixRunAndStartsWhenOneEnds
/// as the API shows it (with PipelineTests.oldJobsDecodeAndAPISendsDerivedStages on the running ones): six jobs run at once (`maxRunning`); the seventh is queued with
/// `waiting` `{"kind": "cap", "text": "a slot opens"}` and no job named, and starts once one of
/// the six ends, its `waiting` then null.
#[test]
fn a_seventh_job_waits_for_a_slot_and_says_so() {
    let folder = Folder::new("slot");
    let (obid, _) = obid(&folder);
    assert_eq!(call(&obid, "GET", "/v1/status", None).body["maxRunning"], 6);
    let sleeper = || {
        dispatch(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}),
        )["id"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let six: Vec<String> = (0..6).map(|_| sleeper()).collect();
    for id in &six {
        // Running, its agent at work: past getting the worktree ready.
        let running = within(60, "six jobs run", || {
            let body = job(&obid, id);
            (body["status"] == "running" && body["step"] != "Getting fixture-app ready")
                .then_some(body)
        });
        // PipelineTests.oldJobsDecodeAndAPISendsDerivedStages: the API sends the stages it
        // derives; a running job is at its second, Work, of six (prepare, work, the
        // repository's check, publish, review, merged), with no pull request.
        let pipeline = &running["pipeline"];
        assert_eq!(pipeline["number"], 2, "{running}");
        assert_eq!(pipeline["total"], 6, "{running}");
        assert_eq!(pipeline["stages"].as_array().unwrap().len(), 6);
        assert_eq!(pipeline["stages"][1]["id"], "work");
        assert!(running["pullRequest"].is_null());
        assert!(running["waiting"].is_null());
    }
    let seventh = sleeper();
    let waiting = within(30, "the seventh says what it waits for", || {
        let body = job(&obid, &seventh);
        (!body["waiting"].is_null()).then_some(body)
    });
    assert_eq!(waiting["status"], "queued");
    assert_eq!(
        waiting["waiting"],
        json!({"kind": "cap", "text": "a slot opens"})
    );
    assert_eq!(call(&obid, "GET", "/v1/status", None).body["running"], 6);
    let stopped = call(&obid, "POST", &format!("/v1/jobs/{}/stop", six[0]), None);
    assert_eq!(stopped.body["status"], "stopped");
    let running = within(60, "the seventh starts", || {
        let body = job(&obid, &seventh);
        (body["status"] == "running").then_some(body)
    });
    assert!(running["waiting"].is_null(), "{running}");
    let all = call(&obid, "POST", "/v1/stop-all", None);
    assert_eq!(all.body["stopped"], 6);
}

/// ClaimTests.aClientMayClaimFilesAtDispatch, its dispatch half (the other, a plan's files from
/// its issues, needs `POST /v1/plans`, which obid doesn't serve): a client's `files` are checked,
/// every one, and kept cleaned, each once; a path outside the repository refuses the job.
#[test]
fn a_client_may_claim_files_at_dispatch() {
    let folder = Folder::new("claim");
    let (obid, _) = obid(&folder);
    let post = |files: Value| {
        call(
            &obid,
            "POST",
            "/v1/jobs",
            Some(
                &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Fix #176",
                                 "issue": 176, "files": files}}),
            ),
        )
    };
    for bad in [
        json!(["/etc/passwd"]),
        json!(["src/", "~/.ssh/id_ed25519"]),
        json!(["a/../../b"]),
    ] {
        let refused = post(bad.clone());
        assert_eq!(refused.status, 422, "{bad}: {}", refused.text);
        assert!(
            refused.body["error"]
                .as_str()
                .unwrap()
                .contains("isn't a path inside the repository"),
            "{bad}: {}",
            refused.text
        );
    }
    let started = post(json!(["./src/greet.js", "docs/", "src//greet.js", "  "]));
    assert_eq!(started.status, 201, "{}", started.text);
    assert_eq!(started.body["files"], json!(["src/greet.js", "docs/"]));
    let none = post(json!([]));
    assert_eq!(none.body["files"], json!([]));
    let many: Vec<String> = (0..31).map(|n| format!("src/{n}.js")).collect();
    let refused = post(json!(many));
    assert_eq!(refused.status, 422);
    assert!(
        refused.body["error"]
            .as_str()
            .unwrap()
            .contains("at most 30 paths")
    );
    call(&obid, "POST", "/v1/stop-all", None);
}

/// NoDispatchCardTests.startedJobsKeepTheirMode, its API half (the brain's half needs
/// `POST /v1/plans`): a dispatched job keeps the mode it was given, takes the default (sandbox,
/// Settings › Permissions) without one, and a mode that isn't one is refused.
#[test]
fn dispatched_jobs_keep_their_mode() {
    let folder = Folder::new("mode");
    let (obid, _) = obid(&folder);
    let given = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Fix #12", "issue": 12,
               "mode": "acceptEdits"}),
    );
    assert_eq!(given["mode"], "acceptEdits");
    let defaulted = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Fix #12", "issue": 12}),
    );
    assert_eq!(
        defaulted["mode"],
        call(&obid, "GET", "/v1/status", None).body["permissions"]["mode"]
    );
    assert_eq!(defaulted["mode"], "sandbox");
    let refused = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Fix #12",
                             "mode": "sometimes"}}),
        ),
    );
    assert_eq!(refused.status, 422);
    call(&obid, "POST", "/v1/stop-all", None);
}

/// A device's publishing key, X9.63 base64, from a fixed private scalar (no key in the source).
fn device_key(scalar: u8) -> String {
    use base64::Engine as _;
    use p256::elliptic_curve::sec1::ToEncodedPoint;
    let secret = p256::SecretKey::from_slice(&[scalar; 32]).unwrap();
    base64::engine::general_purpose::STANDARD
        .encode(secret.public_key().to_encoded_point(false).as_bytes())
}

fn register(obid: &Obid, key: &str) -> Answer {
    call(
        obid,
        "POST",
        "/v1/devices",
        Some(&json!({"name": "Test iPhone", "publicKey": key})),
    )
}

/// Ports RunnerTests.newPhonesNeedPairing: a new key registers only while pairing is open (the
/// owner touched `home/pairing` in the last 10 minutes), which it uses up; a known key gets its id
/// back at once.
#[test]
fn new_phones_need_pairing() {
    let folder = Folder::new("pairing");
    let (obid, _) = obid(&folder);
    let mine = device_key(1);
    let other = device_key(2);
    let closed = register(&obid, &mine);
    assert_eq!(closed.status, 403, "{}", closed.text);
    let pairing = obid.home.join("pairing");
    assert!(
        closed.body["error"]
            .as_str()
            .unwrap()
            .contains(&format!("touch {}", pairing.display()))
    );
    // Opened 601 seconds ago: closed again.
    let file = std::fs::File::create(&pairing).unwrap();
    file.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(601))
        .unwrap();
    drop(file);
    assert_eq!(register(&obid, &mine).status, 403);
    std::fs::File::create(&pairing)
        .unwrap()
        .set_modified(std::time::SystemTime::now())
        .unwrap();
    let registered = register(&obid, &mine);
    assert_eq!(registered.status, 200, "{}", registered.text);
    let id = registered.body["id"].as_str().unwrap().to_owned();
    assert!(!pairing.exists(), "the device used pairing up");
    assert_eq!(register(&obid, &other).status, 403);
    assert_eq!(register(&obid, &mine).body, json!({"id": id}));
}

/// Ports RunnerTests.malformedKeysDontRegister: what isn't a P-256 public key (X9.63, base64) is
/// refused with 422, pairing open or not.
#[test]
fn malformed_keys_dont_register() {
    use base64::Engine as _;
    let folder = Folder::new("badkeys");
    let (obid, _) = obid(&folder);
    std::fs::write(obid.home.join("pairing"), "").unwrap();
    let raw = base64::engine::general_purpose::STANDARD
        .decode(device_key(1))
        .unwrap();
    for key in [
        "BJ3x".to_owned(),
        "not base64!".to_owned(),
        base64::engine::general_purpose::STANDARD.encode([4u8; 65]),
        // The key's raw representation (X and Y without the 04 prefix).
        base64::engine::general_purpose::STANDARD.encode(&raw[1..]),
    ] {
        let answer = register(&obid, &key);
        assert_eq!(answer.status, 422, "{key}: {}", answer.text);
    }
    assert!(
        obid.home.join("pairing").exists(),
        "nothing used pairing up"
    );
    assert_eq!(
        call(&obid, "POST", "/v1/devices", Some(&json!({"name": "x"}))).status,
        422
    );
}

/// `GET /v1/checks/next`: obid queues no Mac check (it publishes nothing yet, and its agents ask
/// for no Apple check), so a Mac that runs checks hears that none waits.
#[test]
fn a_mac_asking_for_a_check_hears_none_waits() {
    let folder = Folder::new("nextcheck");
    let (obid, _) = obid(&folder);
    let answer = call(
        &obid,
        "GET",
        "/v1/checks/next?mac=Studio&kinds=merge,apple",
        None,
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    assert_eq!(answer.body, json!({"check": null}));
}

/// AppleCheckTests.ObyCheckAppleWaitsForTheMacAndPrintsTheCompilersErrorsAndFailingTests:
/// an agent's job token queues a check of its committed worktree; the Mac takes it and its result
/// and diagnostic log are returned to that same job.
#[test]
fn oby_check_apple_waits_for_the_mac_and_prints_compilers_errors_and_failing_tests() {
    let folder = Folder::new("applecheck");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &fake_claude());
    let obid = start(&folder.0, &config, None);
    let created = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(&json!({"job":{"repo":"obi-e2e/fixture-app","kind":"investigate","task":"SLEEP"}})),
    );
    assert_eq!(created.status, 201, "{}", created.text);
    let job_id = created.body["id"].as_str().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let running = loop {
        let state = call(&obid, "GET", &format!("/v1/jobs/{job_id}"), None);
        if state.body["status"] == "running" {
            break state.body;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "job didn't start: {}",
            state.text
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    let token_path = obid.home.join("jobs").join(format!("{job_id}.json"));
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let kept = loop {
        let kept: Value = serde_json::from_slice(&std::fs::read(&token_path).unwrap()).unwrap();
        if kept["appleToken"].is_string() {
            break kept;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "agent did not receive a check token: job={kept}, log={}",
            obid.log()
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    let token = kept["appleToken"]
        .as_str()
        .expect("job-scoped Apple-check token");
    let env_path = std::path::Path::new(running["worktree"].as_str().unwrap())
        .join(".obi/apple-check-env.json");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let agent_env = loop {
        if let Ok(bytes) = std::fs::read(&env_path)
            && let Ok(value) = serde_json::from_slice::<Value>(&bytes)
        {
            break value;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "agent didn't receive the Apple-check environment"
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(
        agent_env["url"]
            .as_str()
            .unwrap()
            .starts_with("http://127.0.0.1:")
    );
    assert_eq!(agent_env["token"], token);
    let asked = call_with_token(&obid, token, "POST", "/v1/agent/apple-check", None);
    assert_eq!(asked.status, 200, "{}", asked.text);
    assert_eq!(asked.body["check"]["kind"], "apple");
    for key in [
        "started",
        "finished",
        "mac",
        "steps",
        "failures",
        "checkRun",
        "comment",
        "postError",
    ] {
        assert!(
            asked.body["check"].get(key).is_some(),
            "missing MacCheckJSON key {key}"
        );
    }
    assert!(asked.body["check"].get("problem").is_none());
    assert!(asked.body.get("appleToken").is_none());
    assert!(
        asked.body["line"]
            .as_str()
            .unwrap()
            .contains("queued, waiting for a Mac")
    );
    assert!(asked.body["report"].is_null());
    let no_mac = call(&obid, "GET", "/v1/checks/next?mac=Studio", None);
    assert_eq!(
        no_mac.body,
        json!({"check": null}),
        "default kinds only takes merge checks"
    );
    let taken = call(
        &obid,
        "GET",
        "/v1/checks/next?mac=Studio&kinds=merge,apple",
        None,
    );
    assert_eq!(taken.status, 200, "{}", taken.text);
    assert_eq!(taken.body["check"]["state"], "running");
    assert_eq!(taken.body["check"]["mac"], "Studio");
    let id = taken.body["check"]["id"].as_str().unwrap();
    let bundle = call(&obid, "GET", &format!("/v1/checks/{id}/bundle"), None);
    assert_eq!(bundle.status, 200, "{}", bundle.text);
    let failed = json!({
        "passed": false,
        "steps": [
            {"name":"Mac app and MacTests","passed":false,"seconds":61},
            {"name":"iPhone app with Watch, and iOSTests","passed":true,"seconds":17}
        ],
        "failures":["MacTests.JobViewTests/showsActions()"],
        "log":"Mac/JobView.swift:12:5: error: cannot find 'OSLog' in scope"
    });
    let ended = call(
        &obid,
        "POST",
        &format!("/v1/checks/{id}/result"),
        Some(&failed),
    );
    assert_eq!(ended.status, 200, "{}", ended.text);
    assert_eq!(ended.body["check"]["state"], "failed");
    let answer = call_with_token(&obid, token, "GET", "/v1/agent/apple-check", None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    assert_eq!(
        answer.body["check"]["failures"][0],
        "MacTests.JobViewTests/showsActions()"
    );
    assert!(
        answer.body["report"]
            .as_str()
            .unwrap()
            .contains("cannot find 'OSLog' in scope")
    );
    assert!(
        answer.body["report"]
            .as_str()
            .unwrap()
            .contains("MacTests.JobViewTests/showsActions()")
    );
    assert_eq!(running["status"], "running");
    assert_eq!(
        call_with_token(&obid, "wrong", "GET", "/v1/agent/apple-check", None).status,
        401
    );
}

/// CheckTests.theAPIHandsOutChecksTakesTheirResultsAndTellsEveryApp: check state is on the job,
/// each transition emits a check event, and duplicate/malformed results are refused.
#[test]
fn the_api_hands_out_checks_takes_their_results_and_tells_every_app() {
    let folder = Folder::new("checkresult");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &fake_claude());
    let mut job = obid::job::Job::new(
        "author".into(),
        "obi-e2e/fixture-app".into(),
        "fix".into(),
        "Fix it".into(),
        "claude".into(),
        "stub".into(),
    );
    job.status = obid::job::Status::Done;
    job.branch = "oby/fix-author".into();
    job.base = Some("dev".into());
    job.pr = Some(80);
    job.mac_check = Some(json!({
        "id":"ab12cd34","job":"author","repo":"obi-e2e/fixture-app","pr":80,
        "branch":"oby/fix-author","base":"dev","head":"0123456789012345678901234567890123456789",
        "round":1,"state":"queued","created":obi_protocol::time::format(obi_protocol::time::now()),
        "started":null,"finished":null,"mac":null,"steps":null,"failures":null,
        "checkRun":null,"comment":null,"postError":null,"problem":null,"handedOff":null,
        "tries":null,"transient":null,"kind":"merge","finalCheck":null,"agentAsked":null
    }));
    let jobs = std::path::Path::new(config["home"].as_str().unwrap()).join("jobs");
    std::fs::create_dir_all(&jobs).unwrap();
    std::fs::write(
        jobs.join("author.json"),
        serde_json::to_vec_pretty(&job).unwrap(),
    )
    .unwrap();
    let obid = start(&folder.0, &config, None);
    let mut feed = events(&obid);
    let queued = call(&obid, "GET", "/v1/checks/next?mac=Studio", None);
    assert_eq!(queued.status, 200, "{}", queued.text);
    assert_eq!(queued.body["check"]["id"], "ab12cd34");
    assert_eq!(queued.body["check"]["kind"], "merge");
    assert_eq!(queued.body["check"]["state"], "running");
    let id = queued.body["check"]["id"].as_str().unwrap();
    assert_eq!(next_check_event(&mut feed)["state"], "running");
    assert_eq!(
        call(
            &obid,
            "POST",
            &format!("/v1/checks/{id}/result"),
            Some(&json!({}))
        )
        .status,
        400
    );
    let report = json!({"passed":false,"steps":[
        {"name":"Mac app and MacTests","passed":false,"seconds":61}
    ],"failures":["PublishTests/blocksASecret()"],"log":"error: x"});
    let ended = call(
        &obid,
        "POST",
        &format!("/v1/checks/{id}/result"),
        Some(&report),
    );
    assert_eq!(ended.status, 200, "{}", ended.text);
    assert_eq!(ended.body["check"]["state"], "failed");
    assert_eq!(next_check_event(&mut feed)["state"], "failed");
    assert_eq!(
        call(
            &obid,
            "POST",
            &format!("/v1/checks/{id}/result"),
            Some(&report)
        )
        .status,
        409
    );
    let current = call(&obid, "GET", "/v1/jobs/author", None);
    assert_eq!(
        current.body["macCheck"]["state"], "failed",
        "{}",
        current.text
    );
    assert_eq!(current.body.get("appleToken"), None);
}

/// ParallelTests.theCapIsInStatusAndSettings: `status.maxRunning` starts at 6; Settings changes it
/// with `PUT /v1/settings/jobs`, 1 to 20 (0 and 21 are refused), `GET` says it, status follows,
/// and obid keeps it across a restart.
#[test]
fn the_cap_is_in_status_and_settings() {
    let folder = Folder::new("cap");
    let (mut obid, config) = obid(&folder);
    let status = call(&obid, "GET", "/v1/status", None).body;
    assert_eq!(status["maxRunning"], 6);
    assert_eq!(status["running"], 0);
    for refused in [0, 21] {
        let answer = call(
            &obid,
            "PUT",
            "/v1/settings/jobs",
            Some(&json!({"maxRunning": refused})),
        );
        assert_eq!(answer.status, 422, "{refused}: {}", answer.text);
    }
    assert_eq!(
        call(
            &obid,
            "PUT",
            "/v1/settings/jobs",
            Some(&json!({"maxRunning": "3"}))
        )
        .status,
        422
    );
    let set = call(
        &obid,
        "PUT",
        "/v1/settings/jobs",
        Some(&json!({"maxRunning": 3})),
    );
    assert_eq!(set.status, 200, "{}", set.text);
    assert_eq!(set.body, json!({"maxRunning": 3}));
    assert_eq!(
        call(&obid, "GET", "/v1/settings/jobs", None).body,
        json!({"maxRunning": 3})
    );
    assert_eq!(call(&obid, "GET", "/v1/status", None).body["maxRunning"], 3);
    assert!(obid.stop().success());
    drop(obid);
    let obid = start(&folder.0, &config, None);
    assert_eq!(
        call(&obid, "GET", "/v1/settings/jobs", None).body,
        json!({"maxRunning": 3})
    );
    assert_eq!(call(&obid, "GET", "/v1/status", None).body["maxRunning"], 3);
}

/// With the cap lowered to one, a second job waits for the slot, and raising the cap starts it at
/// once (runner-api.md, "GET /v1/settings/jobs and PUT /v1/settings/jobs").
#[test]
fn raising_the_cap_starts_a_waiting_job_at_once() {
    let folder = Folder::new("raise");
    let (obid, _) = obid(&folder);
    let set = |max: u64| {
        let answer = call(
            &obid,
            "PUT",
            "/v1/settings/jobs",
            Some(&json!({"maxRunning": max})),
        );
        assert_eq!(answer.status, 200, "{}", answer.text);
    };
    set(1);
    let sleeper = || {
        dispatch(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}),
        )["id"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let first = sleeper();
    within(60, "the first runs", || {
        (job(&obid, &first)["status"] == "running").then_some(())
    });
    let second = sleeper();
    let waiting = within(30, "the second waits for the slot", || {
        let body = job(&obid, &second);
        (!body["waiting"].is_null()).then_some(body)
    });
    assert_eq!(
        waiting["waiting"],
        json!({"kind": "cap", "text": "a slot opens"})
    );
    set(2);
    within(60, "the second starts", || {
        (job(&obid, &second)["status"] == "running").then_some(())
    });
    assert_eq!(call(&obid, "POST", "/v1/stop-all", None).body["stopped"], 2);
}

/// RunnerTests.messagesReachOnlyJobsThatCanTakeThem, with the owner's decision of 2026-10-18
/// (Sangam's design leads): `POST /v1/jobs/{id}/messages` answers 404 for an unknown job, 400 for
/// a body without `text` and 422 for words that aren't 1 to 2,000 characters. Words for a job that
/// ended start a follow-up (`201`, the new job): the same kind, agent, account, repository, base
/// and conversation, on a branch and worktree of its own, `followUpOf` the first job, the words
/// its request; the first job stays as it ended, even one that never started. Only the exact
/// Try-again words pick a job's session up again in its own worktree for one more round (and one
/// more on a loop's limit), as Try again does, and a job that never started has none to pick up.
#[test]
fn messages_reach_only_jobs_that_can_take_them() {
    let folder = Folder::new("talk");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &fake_claude());
    config["repos"]
        .as_array_mut()
        .unwrap()
        .push(json!({"repo": "obi-e2e/gone", "remote": format!("file://{}", folder.0.join("nowhere.git").display()), "defaultBranch": "main"}));
    let obid = start(&folder.0, &config, None);
    let post = |id: &str, body: Value| {
        call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(&body),
        )
    };

    assert_eq!(post("nowhere", json!({"text": "hi"})).status, 404);
    // Never started: its repository couldn't be got ready, so it has no session.
    let never = dispatch(
        &obid,
        json!({"repo": "obi-e2e/gone", "kind": "investigate", "task": "Look around"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(ended(&obid, &never)["status"], "failed");
    let refused = post(&never, json!({"text": TRY_AGAIN}));
    assert_eq!(refused.status, 422, "{}", refused.text);
    assert!(
        refused.body["error"]
            .as_str()
            .unwrap()
            .contains("never started"),
        "{}",
        refused.text
    );
    let after_never = post(&never, json!({"text": "hi"}));
    assert_eq!(after_never.status, 201, "{}", after_never.text);
    assert_eq!(after_never.body["followUpOf"], never.as_str());
    assert_eq!(job(&obid, &never)["status"], "failed");

    // A loop of up to two rounds that ends done after its first (its check passes), then the
    // owner's words.
    let finished = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around", "rounds": 2, "branch": "oby/review-33"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let done = ended(&obid, &finished);
    assert_eq!(done["status"], "done", "{done}");
    assert_eq!(
        (done["round"].clone(), done["rounds"].clone()),
        (json!(1), json!(2))
    );
    assert_eq!(post(&finished, json!({"words": "hi"})).status, 400);
    assert_eq!(post(&finished, json!({"text": " \n "})).status, 422);
    assert_eq!(
        post(&finished, json!({"text": "x".repeat(2001)})).status,
        422
    );
    let words = "rename notes.txt to hello.txt";
    let followed = post(&finished, json!({"text": words}));
    assert_eq!(followed.status, 201, "{}", followed.text);
    let next = &followed.body;
    assert_ne!(next["id"], finished.as_str());
    assert_eq!(next["followUpOf"], finished.as_str());
    assert_eq!(next["request"], words);
    for key in ["kind", "agent", "account", "repo", "base", "conversation"] {
        assert_eq!(next[key], done[key], "{key}");
    }
    assert_ne!(next["branch"], "oby/review-33");
    let next_id = next["id"].as_str().unwrap().to_owned();
    let next_done = ended(&obid, &next_id);
    assert_eq!(next_done["status"], "done", "{next_done}");
    assert_ne!(next_done["worktree"], done["worktree"]);
    let first = job(&obid, &finished);
    assert_eq!(first["status"], "done");
    assert_eq!(first["round"], 1);
    assert!(first["notes"].is_null(), "{first}");

    // Try again picks the session up again, in the same worktree and branch.
    let session = done["session"].as_str().unwrap().to_owned();
    let resumed = post(&finished, json!({"text": TRY_AGAIN}));
    assert_eq!(resumed.status, 200, "{}", resumed.text);
    let again = &resumed.body;
    assert_eq!(again["id"], finished.as_str());
    assert_eq!(again["branch"], "oby/review-33");
    assert_eq!(again["notes"], json!([TRY_AGAIN]));
    assert_eq!(again["round"], 2);
    assert_eq!(again["rounds"], 3);
    assert_eq!(again["step"], format!("You: {TRY_AGAIN}"));
    assert!(again["finished"].is_null());
    let after = ended(&obid, &finished);
    assert_eq!(after["status"], "done", "{after}");
    assert_eq!(after["session"], session.as_str());
    assert_eq!(after["worktree"], done["worktree"]);
    assert_eq!(after["notes"], json!([TRY_AGAIN]));
}

/// A follow-up of a job whose commits aren't merged (here not published: this obid has no `gh`)
/// starts from that job's branch head, on a branch of its own: its agent sees that work, and only
/// its own commits count as its. A job takes one follow-up at a time: while one works, more words
/// for the first job are refused, pointing at it.
#[test]
fn a_follow_up_starts_from_the_first_jobs_unmerged_work() {
    let folder = Folder::new("follow-up-work");
    let (obid, _) = obid(&folder);
    let post = |id: &str, text: &str| {
        call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(&json!({"text": text})),
        )
    };
    let first = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: one.txt"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let done = ended(&obid, &first);
    assert_eq!(done["commits"], 1, "{done}");
    assert!(done["published"].is_null(), "{done}");
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let head = git_out(
        &clone,
        &["rev-parse", &format!("refs/heads/oby/build-{first}")],
    );

    let followed = post(&first, "COMMIT: two.txt");
    assert_eq!(followed.status, 201, "{}", followed.text);
    let next = followed.body["id"].as_str().unwrap().to_owned();
    assert_eq!(followed.body["branch"], format!("oby/build-{next}"));
    let after = ended(&obid, &next);
    assert_eq!(after["startCommit"], head.as_str(), "{after}");
    assert_eq!(after["commits"], 1, "{after}");
    let worktree = std::path::Path::new(after["worktree"].as_str().unwrap());
    assert!(worktree.join("one.txt").is_file() && worktree.join("two.txt").is_file());

    // One follow-up at a time.
    let looked = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    ended(&obid, &looked);
    let pausing = post(&looked, "PAUSE: 3000");
    assert_eq!(pausing.status, 201, "{}", pausing.text);
    let busy = post(&looked, "and one more");
    assert_eq!(busy.status, 422, "{}", busy.text);
    assert!(
        busy.body["error"]
            .as_str()
            .unwrap()
            .contains("is following it up already"),
        "{}",
        busy.text
    );
}

fn git_out(dir: &std::path::Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}");
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// What a job hears when the owner tries it again (`Inbox.tryAgainMessage`).
const TRY_AGAIN: &str =
    "Try again, picking up where you left off. Finish with a short summary as asked.";

/// The owner's words reach a job whose agent is at work as its next turn, before the check, in
/// the same round, and that turn's reply joins the round's summaries but leaves the job's summary
/// to the work; a job that must commit and whose round the owner asked for (Try again) may end
/// done with nothing committed: their words decide (runner-api.md, "POST /v1/jobs/{id}/messages").
#[test]
fn a_running_job_hears_the_words_next_and_the_owners_round_may_commit_nothing() {
    let folder = Folder::new("hear");
    let (obid, _) = obid(&folder);
    let post = |id: &str, text: &str| {
        call(
            &obid,
            "POST",
            &format!("/v1/jobs/{id}/messages"),
            Some(&json!({"text": text})),
        )
    };
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "PAUSE: 3000"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    within(60, "its agent is at work", || {
        let body = job(&obid, &id);
        (body["status"] == "running" && body["step"] == "Starting Claude Code").then_some(())
    });
    let heard = post(&id, "ECHO and add a test");
    assert_eq!(heard.status, 200, "{}", heard.text);
    assert_eq!(heard.body["status"], "running");
    assert_eq!(heard.body["step"], "You: ECHO and add a test");
    let done = ended(&obid, &id);
    assert_eq!(done["status"], "done", "{done}");
    assert_eq!(done["round"], 1);
    assert_eq!(
        done["summaries"],
        json!([
            "Paused.",
            "heard: ECHO and add a test resume=00000000-0000-4000-8000-000000000001"
        ])
    );
    // The turn only the words started keeps the work's summary (#699).
    assert_eq!(done["summary"], "Paused.");

    // A fix that commits nothing is done, saying so; the owner's round after it may end done
    // without a commit too.
    let fix = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "Look around"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let nothing = ended(&obid, &fix);
    assert_eq!(nothing["status"], "done");
    assert_eq!(nothing["summary"], "Nothing to do.");
    assert_eq!(
        nothing["reason"],
        "Nothing committed, so nothing was published."
    );
    assert_eq!(post(&fix, TRY_AGAIN).status, 200);
    let left = ended(&obid, &fix);
    assert_eq!(left["status"], "done", "{left}");
    assert_eq!(left["commits"], 0);
    assert_eq!(left["round"], 2);
    assert_eq!(left["rounds"], 1);
}

/// DismissTests.theAPIDismissesAndSaysWhenItCant, its last line: publishing a dismissed job by hand
/// is off, `409`, saying so (and `404` for an unknown job).
#[test]
fn publish_by_hand_is_off_a_dismissed_job() {
    let folder = Folder::new("publish");
    let (obid, _) = obid(&folder);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "FAIL"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(ended(&obid, &id)["status"], "interrupted");
    assert_eq!(
        call(&obid, "POST", &format!("/v1/jobs/{id}/dismiss"), None).status,
        200
    );
    let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/publish"), None);
    assert_eq!(answer.status, 409, "{}", answer.text);
    assert!(answer.body["error"].as_str().unwrap().contains("dismissed"));
    assert_eq!(
        call(&obid, "GET", "/v1/jobs/nowhere/publish", None).status,
        404
    );
}

/// A job's agent that asks for each of `calls` in turn (tests/agents/fake-claude, `ASKS:`).
fn asking(obid: &Obid, mode: &str, calls: Value) -> String {
    dispatch(
        obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "mode": mode,
               "task": format!("ASKS: {calls}")}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn bash(command: &str) -> Value {
    json!({"tool": "Bash", "input": {"command": command}})
}

/// The job once its agent waits for the owner's OK on a permission titled `title`.
fn waiting_for(obid: &Obid, id: &str, title: &str) -> Value {
    within(60, &format!("{id} waits for its OK on {title}"), || {
        let body = job(obid, id);
        (body["permission"]["title"] == title).then_some(body)
    })
}

/// The open inbox items of job `id`.
fn open_items(obid: &Obid, id: &str) -> Vec<Value> {
    call(obid, "GET", "/v1/inbox", None)
        .body
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["job"] == id)
        .cloned()
        .collect()
}

/// PermissionTests.theAPIAnswersPermissionsAndModes, with the inbox's side of
/// aPermissionWaitsInTheInboxAndAlwaysSavesARuleTheNextPromptUses and
/// denyReachesTheAgentWithTheWords: in `ask` a command waits for the owner, on the job (its card,
/// with the rule "always" saves) and in the inbox; `POST /v1/jobs/{id}/permission` answers it
/// (422 for another decision, 409 for a permission that isn't the one waiting, 404 for an unknown
/// job); always saves the rule, which answers the next prompt it covers by itself; words in the
/// inbox are a no that reaches the agent; the job's mode changes; Settings › Permissions' default
/// changes what new jobs get; rules are listed and forgotten.
#[test]
fn the_api_answers_permissions_and_modes() {
    let folder = Folder::new("permissions");
    let (obid, _) = obid(&folder);
    let id = asking(
        &obid,
        "ask",
        json!([
            bash("swift test"),
            bash("swift test --filter X"),
            bash("make lint")
        ]),
    );
    let waiting = waiting_for(&obid, &id, "Run swift test");
    assert_eq!(waiting["mode"], "ask");
    assert_eq!(waiting["status"], "running");
    assert_eq!(waiting["step"], "Waiting for your OK");
    let card = &waiting["permission"];
    assert_eq!(card["rule"], "Bash(swift test:*)");
    assert_eq!(
        card["always"],
        "Yes, and don't ask again for swift test in obi-e2e/fixture-app"
    );
    assert_eq!(card["detail"], "swift test");
    assert_eq!(card["tool"], "Bash");
    let permission = card["id"].as_str().unwrap().to_owned();
    assert!(
        permission.starts_with('p') && permission.len() == 7,
        "{card}"
    );
    let items = open_items(&obid, &id);
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0]["kind"], "permission");
    assert_eq!(items[0]["id"], format!("{id}-permission-{permission}"));
    assert_eq!(items[0]["text"], "Run swift test");
    assert_eq!(
        items[0]["options"],
        json!(["Allow", "Always allow", "Deny"])
    );

    let answer = |job: &str, body: Value| {
        call(
            &obid,
            "POST",
            &format!("/v1/jobs/{job}/permission"),
            Some(&body),
        )
    };
    assert_eq!(
        answer(&id, json!({"id": permission, "decision": "maybe"})).status,
        422
    );
    assert_eq!(
        answer(&id, json!({"id": "p000000", "decision": "allow"})).status,
        409
    );
    assert_eq!(
        answer("nope", json!({"id": "p1", "decision": "allow"})).status,
        404
    );
    assert_eq!(
        answer(
            &id,
            json!({"id": permission, "decision": "deny", "message": "x".repeat(2001)})
        )
        .status,
        422
    );
    let always = answer(&id, json!({"id": permission, "decision": "always"}));
    assert_eq!(always.status, 200, "{}", always.text);
    // The rule saved answers `swift test --filter X` by itself; `make lint` asks.
    let next = waiting_for(&obid, &id, "Run make lint");
    assert_eq!(next["permission"]["rule"], "Bash(make lint:*)");
    let rules = call(&obid, "GET", "/v1/permissions/rules", None).body;
    let rule = rules[0].as_object().unwrap();
    assert_eq!(rules.as_array().unwrap().len(), 1, "{rules}");
    let mut keys: Vec<&str> = rule.keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(keys, ["created", "decision", "id", "repo", "rule"]);
    assert_eq!(rule["rule"], "Bash(swift test:*)");
    assert_eq!(rule["repo"], "obi-e2e/fixture-app");
    assert_eq!(rule["decision"], "allow");
    let done = call(&obid, "GET", "/v1/inbox?state=done", None).body;
    let first = done
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == format!("{id}-permission-{permission}"))
        .cloned()
        .unwrap_or_else(|| panic!("{done}"));
    assert_eq!(first["answer"], "Always allow");

    // Words of the owner's own, in the inbox, are a no that reaches the agent.
    let items = open_items(&obid, &id);
    assert_eq!(items.len(), 1, "{items:?}");
    let said = call(
        &obid,
        "POST",
        &format!("/v1/inbox/{}/answer", items[0]["id"].as_str().unwrap()),
        Some(&json!({"answer": "No, run only the tests"})),
    );
    assert_eq!(said.status, 200, "{}", said.text);
    assert_eq!(said.body["answer"], "No, run only the tests");
    assert_eq!(said.body["state"], "done");
    let ended = ended(&obid, &id);
    assert_eq!(ended["status"], "done", "{ended}");
    assert_eq!(
        ended["summary"],
        "answers: allow, allow, deny: No, run only the tests"
    );
    assert_eq!(ended["notes"], json!(["No, run only the tests"]));
    assert!(ended["permission"].is_null());

    let mode = |body: Value| call(&obid, "POST", &format!("/v1/jobs/{id}/mode"), Some(&body));
    assert_eq!(mode(json!({"mode": "sometimes"})).status, 422);
    let changed = mode(json!({"mode": "acceptEdits"}));
    assert_eq!(changed.status, 200, "{}", changed.text);
    assert_eq!(changed.body["mode"], "acceptEdits");
    assert_eq!(
        call(
            &obid,
            "POST",
            "/v1/jobs/nope/mode",
            Some(&json!({"mode": "ask"}))
        )
        .status,
        404
    );

    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["permissions"]["mode"],
        "sandbox"
    );
    assert_eq!(
        call(
            &obid,
            "PUT",
            "/v1/settings/permissions",
            Some(&json!({"mode": "never"}))
        )
        .status,
        422
    );
    let set = call(
        &obid,
        "PUT",
        "/v1/settings/permissions",
        Some(&json!({"mode": "ask"})),
    );
    assert_eq!(set.body, json!({"mode": "ask"}));
    assert_eq!(
        call(&obid, "GET", "/v1/settings/permissions", None).body,
        json!({"mode": "ask"})
    );
    assert_eq!(
        call(&obid, "GET", "/v1/status", None).body["permissions"]["mode"],
        "ask"
    );
    let defaulted = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "research", "task": "Look around"}),
    );
    assert_eq!(defaulted["mode"], "ask");
    ended_ok(&obid, defaulted["id"].as_str().unwrap());

    let rule_id = rule["id"].as_str().unwrap();
    let forgot = call(
        &obid,
        "DELETE",
        &format!("/v1/permissions/rules/{rule_id}"),
        None,
    );
    assert_eq!(forgot.status, 200, "{}", forgot.text);
    assert_eq!(forgot.body, json!([]));
    assert_eq!(
        call(&obid, "DELETE", "/v1/permissions/rules/nope", None).status,
        404
    );
}

fn ended_ok(obid: &Obid, id: &str) {
    let job = ended(obid, id);
    assert_eq!(job["status"], "done", "{job}");
}

/// A waiting permission the job's new mode allows is answered at once (`POST /v1/jobs/{id}/mode`);
/// words told to the job while one waits are a no with those words (`POST /v1/jobs/{id}/messages`);
/// stopping a waiting job drops its permission and settles its inbox item; in `acceptEdits` a
/// file edit in the worktree goes through and a command asks; in `plan` an edit is refused.
#[test]
fn modes_answer_what_they_allow_and_stopping_drops_the_permission() {
    let folder = Folder::new("modes");
    let (obid, _) = obid(&folder);

    let moved = asking(&obid, "ask", json!([bash("swift test")]));
    waiting_for(&obid, &moved, "Run swift test");
    let bypass = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{moved}/mode"),
        Some(&json!({"mode": "bypass"})),
    );
    assert_eq!(bypass.status, 200, "{}", bypass.text);
    assert_eq!(ended(&obid, &moved)["summary"], "answers: allow");

    let told = asking(&obid, "ask", json!([bash("make")]));
    waiting_for(&obid, &told, "Run make");
    let words = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{told}/messages"),
        Some(&json!({"text": "use swift build instead"})),
    );
    assert_eq!(words.status, 200, "{}", words.text);
    assert_eq!(
        ended(&obid, &told)["summary"],
        "answers: deny: use swift build instead"
    );

    let edits = asking(
        &obid,
        "acceptEdits",
        json!([{"tool": "Edit", "input": {"file_path": "src/a.js"}}, bash("rm -rf build")]),
    );
    waiting_for(&obid, &edits, "Run rm");
    let stopped = call(&obid, "POST", &format!("/v1/jobs/{edits}/stop"), None);
    assert_eq!(stopped.body["status"], "stopped");
    assert!(stopped.body["permission"].is_null(), "{}", stopped.text);
    assert!(open_items(&obid, &edits).is_empty());

    let planning = asking(
        &obid,
        "plan",
        json!([{"tool": "Edit", "input": {"file_path": "src/a.js"}}, {"tool": "Read", "input": {"file_path": "src/a.js"}}]),
    );
    let planned = ended(&obid, &planning);
    let summary = planned["summary"].as_str().unwrap();
    assert!(
        summary.starts_with("answers: deny: Plan mode: read only") && summary.ends_with(", allow"),
        "{planned}"
    );
}
