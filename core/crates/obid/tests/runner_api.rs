//! More of RunnerTests' API-level tests, ported to the real obid binary asked over HTTP: the job as
//! the API sends it, Clear done, jobs beyond the latest 50, the slot a job waits for, and what a
//! dispatch body sets. The Swift test each one ports is named on it; tests/PORTING.md lists every
//! RunnerTests test, ported or not, and why.

mod support;

use std::path::{Path, PathBuf};

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
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around",
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
        assert_eq!(extra, ["obi", "worktree"], "{body}");
        assert_eq!(keys.len(), 67);
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
        assert_eq!(body["mode"], "bypass");
        assert_eq!(body["outgoing"], json!([]));
        assert_eq!(body["moves"], json!([]));
        assert_eq!(body["connectionUses"], json!([]));
        assert!(body["pipeline"].is_object());
        assert_eq!(body["rounds"], 1);
        assert_eq!(body["round"], 1);
        assert_eq!(body["kind"], "investigate");
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
/// `POST /v1/plans`): a dispatched job keeps the mode it was given, takes the default (bypass,
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
    assert_eq!(defaulted["mode"], "bypass");
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
