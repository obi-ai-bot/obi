//! Publishing the owner's work, on the real obid binary asked over HTTP (docs/runner-api.md, "Job",
//! "Job pipeline and pull request following", `GET` and `POST /v1/jobs/{id}/publish`; #451): a job
//! that ends done with commits publishes by itself (the gate, the push, the pull request); a
//! possible secret, or a scanner that can't run, sends nothing; one bounded round rewrites a
//! history that holds a secret; someone else's push is never overwritten; publishing by hand needs
//! a registered device's fresh signature of obid's own sentence; and the published pull request
//! is followed. obid never merges: the remote's base never moves.
//!
//! The remote is the e2e fixture's bare repository (a `file://` remote), and GitHub is a stand-in
//! `gh` first on obid's `PATH` that keeps what it was asked.

mod support;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

/// The stand-in agent of these tests (`COMMIT:`, `LEAK:`, and the fix the publish gate asks for).
fn agent() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/publishing-claude")
}

/// The pull request the stand-in `gh` opens.
const PULL: &str = "https://github.com/obi-e2e/fixture-app/pull/7";

/// A stand-in `gh` in `folder/bin`, keeping its state in `folder/gh`: every call's arguments
/// (`calls`), its environment (`env`), the title and description it was given, the open pull
/// requests `pr list` answers (`open`: `__HEAD__` stands for the commit obid's clone has the
/// branch at, which is what obid pushed), whether `pr list` fails (`list-fails`, or once for the
/// branch's own lookup, as GitHub's 502: `list-fails-once`), and what `pr view` answers (`view.json`).
fn fake_gh(folder: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = folder.join("bin");
    let state = folder.join("gh");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&state).unwrap();
    let script = format!(
        r#"#!/bin/sh
dir='{state}'
printf '%s\n' "$*" >> "$dir/calls"
env >> "$dir/env"
prev=
case "$1 $2" in
  "pr list")
    [ -f "$dir/list-fails" ] && {{ echo 'GraphQL: Could not resolve to a Repository' >&2; exit 1; }}
    case "$*" in *--head*)
      [ -f "$dir/list-fails-once" ] && {{ rm "$dir/list-fails-once"; echo 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' >&2; exit 1; }} ;;
    esac
    [ -f "$dir/open" ] || exit 0
    for a in "$@"; do [ "$prev" = --head ] && branch="$a"; prev="$a"; done
    oid=$(git -C '{clone}' rev-parse "refs/heads/$branch")
    sed "s/__HEAD__/$oid/" "$dir/open"
    exit 0 ;;
  "pr create")
    for a in "$@"; do
      [ "$prev" = --body-file ] && cp "$a" "$dir/body"
      case "$a" in --title=*) printf '%s' "${{a#--title=}}" > "$dir/title" ;; esac
      prev="$a"
    done
    echo '[{{"url":"{PULL}","isCrossRepository":false,"headRefOid":"__HEAD__","baseRefName":"main"}}]' > "$dir/open"
    echo 'Creating pull request…'
    echo '{PULL}'
    exit 0 ;;
  "pr edit")
    for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$dir/body"; prev="$a"; done
    exit 0 ;;
  "pr view") [ -f "$dir/view.json" ] && cat "$dir/view.json" && exit 0; exit 1 ;;
  *) echo "gh: not in this test" >&2; exit 1 ;;
esac
"#,
        state = state.display(),
        clone = folder.join("home/clones/obi-e2e/fixture-app").display()
    );
    std::fs::write(bin.join("gh"), script).unwrap();
    std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

/// What the stand-in `gh` keeps under `name`, or nothing.
fn kept(folder: &Path, name: &str) -> String {
    std::fs::read_to_string(folder.join("gh").join(name)).unwrap_or_default()
}

/// obid with the fixture repository, the stand-in agent, and `path_first` first on its `PATH`.
fn obid_with(folder: &Folder, path_first: &Path) -> (Obid, PathBuf, Value) {
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &agent());
    (start(&folder.0, &config, Some(path_first)), remote, config)
}

/// [`obid_with`], its quiet window (`stallAfter`) cut to `seconds`, which caps the waits before
/// each try again of a publish GitHub or the remote didn't take.
fn obid_retrying_within(folder: &Folder, path_first: &Path, seconds: u64) -> (Obid, PathBuf) {
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["stallAfter"] = json!(seconds);
    (start(&folder.0, &config, Some(path_first)), remote)
}

fn dispatch(obid: &Obid, job: Value) -> String {
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({"job": job})));
    assert_eq!(answer.status, 201, "{}", answer.text);
    answer.body["id"].as_str().unwrap().to_owned()
}

fn ended(obid: &Obid, id: &str) -> Value {
    let answer = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn git(dir: &Path, args: &[&str]) -> String {
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
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// The commit `branch` is at on the remote, or none.
fn remote_branch(remote: &Path, branch: &str) -> Option<String> {
    let listed = git(
        remote,
        &[
            "for-each-ref",
            "--format=%(objectname)",
            &format!("refs/heads/{branch}"),
        ],
    );
    (!listed.is_empty()).then_some(listed)
}

fn stage(job: &Value, id: &str) -> Value {
    job["pipeline"]["stages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == id)
        .cloned()
        .unwrap_or(Value::Null)
}

/// The made-up key id the stand-in agent leaks, put together here so this file holds none.
fn leaked_key() -> String {
    ["AK", "IA", "QWERTYUIOPASDFGH"].concat()
}

/// A job that ends done with a commit publishes by itself: the scan, one push of its branch to the
/// remote, its pull request opened into the base with a scanned title and description, every
/// outgoing action listed, and the pull request followed. Telling it more, its new commit goes to
/// the same branch and pull request. Nothing is merged, and the base on the remote never moves.
#[test]
fn a_done_job_publishes_by_itself_and_follows_its_pull_request() {
    let folder = Folder::new("publish-itself");
    let bin = fake_gh(&folder.0);
    std::fs::write(
        folder.0.join("gh/view.json"),
        r#"{"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","mergedAt":null,"baseRefName":"main","headRefOid":""}"#,
    )
    .unwrap();
    let (obid, remote, _) = obid_with(&folder, &bin);
    let main = remote_branch(&remote, "main").unwrap();
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt",
               "check": "test -f hello.txt", "title": "Hello file"}),
    );
    let job = ended(&obid, &id);
    let branch = format!("oby/build-{id}");
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["publishError"], Value::Null, "{job}");
    assert_eq!(job["published"], PULL);
    assert_eq!(job["commits"], 1);
    assert_eq!(job["pushed"], 1);
    assert_eq!(job["summary"], "Added hello.txt.");
    // The scan ran on what went out, and was clean (#735).
    let scan = &job["scan"];
    assert_eq!(scan["ran"], true, "{job}");
    assert_eq!(scan["clean"], true, "{job}");
    assert_eq!(scan["commits"], 1, "{job}");
    assert_eq!(scan["files"], 1, "{job}");
    assert!(scan["seconds"].is_u64(), "{job}");
    assert!(
        scan.get("findings").is_none() && scan.get("reason").is_none(),
        "{job}"
    );
    // The branch on the remote is the job's commit; the base is where it was.
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let head = git(&clone, &["rev-parse", &format!("refs/heads/{branch}")]);
    assert_eq!(
        remote_branch(&remote, &branch).as_deref(),
        Some(head.as_str())
    );
    assert_eq!(
        remote_branch(&remote, "main").as_deref(),
        Some(main.as_str())
    );
    // What went out, ids only, oldest first.
    let outgoing = job["outgoing"].as_array().unwrap();
    assert_eq!(outgoing.len(), 2, "{job}");
    assert_eq!(outgoing[0]["action"], "push");
    assert_eq!(outgoing[0]["id"], head.as_str());
    assert_eq!(outgoing[0]["branch"], branch.as_str());
    assert_eq!(outgoing[0]["repo"], "obi-e2e/fixture-app");
    assert_eq!(outgoing[1]["action"], "pullRequest");
    assert_eq!(outgoing[1]["id"], PULL);
    assert!(outgoing[1].get("branch").is_none());
    // The pull request: into the base, from the job's branch, ready for review, never merged.
    let calls = kept(&folder.0, "calls");
    assert!(
        calls.contains(&format!("pr create -R obi-e2e/fixture-app --base main --head {branch} --title=feat: added hello.txt")),
        "{calls}"
    );
    assert!(
        !calls.contains("--draft") && !calls.contains("pr merge"),
        "{calls}"
    );
    let body = kept(&folder.0, "body");
    assert!(
        body.starts_with("The agent's summary:\n\n> Added hello.txt.\n\n"),
        "{body}"
    );
    assert!(
        body.contains("- Check: ` test -f hello.txt ` passed.\n- Secret scan: clean."),
        "{body}"
    );
    assert!(body.contains("never merges"), "{body}");
    // gh got no secret of obid's: not the API token, in its arguments or its environment.
    assert!(!calls.contains(TOKEN) && !kept(&folder.0, "env").contains(TOKEN));
    // Published: the Publish stage is done, and the Review stage waits for a person.
    assert_eq!(stage(&job, "publish")["state"], "done");
    assert_eq!(
        job["reviewError"],
        "obid doesn't run Oby's review yet: a person reviews the pull request on GitHub."
    );
    assert_eq!(stage(&job, "merged")["state"], "upcoming");
    assert_eq!(stage(&job, "merged")["title"], "Merged into main");
    // Followed: obid reads the pull request right after it opened it.
    let followed = within(30, "obid reads the pull request", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        job["pullRequest"].is_object().then_some(job)
    });
    assert_eq!(followed["pullRequest"]["state"], "OPEN");
    assert_eq!(followed["pullRequest"]["reviewDecision"], "REVIEW_REQUIRED");
    assert_eq!(followed["pullRequest"]["base"], "main");
    assert_eq!(followed["pullRequestError"], Value::Null);
    assert!(calls_now(&folder.0).contains("pr view 7 --repo obi-e2e/fixture-app --json state,reviewDecision,mergedAt,baseRefName,headRefOid"));
    assert_eq!(
        stage(&followed, "review")["detail"],
        "Pull request open · waiting for your review on GitHub"
    );
    // Everything is published: nothing to publish by hand.
    let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/publish"), None);
    assert_eq!(answer.status, 409, "{}", answer.text);
    assert_eq!(
        answer.body["error"],
        "It's already published, with every commit."
    );

    // Tried again, its new commit goes to the same branch and pull request.
    again_commits(&obid, &id, "second.txt");
    let told = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": TRY_AGAIN})),
    );
    assert_eq!(told.status, 200, "{}", told.text);
    let again = ended(&obid, &id);
    assert_eq!(again["status"], "done", "{again}\n{}", obid.log());
    assert_eq!(again["commits"], 2);
    assert_eq!(again["pushed"], 2);
    assert_eq!(again["published"], PULL);
    let second = git(&clone, &["rev-parse", &format!("refs/heads/{branch}")]);
    assert_eq!(
        remote_branch(&remote, &branch).as_deref(),
        Some(second.as_str())
    );
    let actions: Vec<&str> = again["outgoing"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["action"].as_str().unwrap())
        .collect();
    assert_eq!(actions, ["push", "pullRequest", "push", "pullRequestEdit"]);
    assert_eq!(calls_now(&folder.0).matches("pr create").count(), 1);
    assert!(kept(&folder.0, "body").contains("Round 2, the agent's summary:"));
    assert_eq!(
        remote_branch(&remote, "main").as_deref(),
        Some(main.as_str())
    );
}

/// A follow-up of a job whose pull request is still open goes on its branch: it starts at the
/// branch head and publishes onto it, updating that pull request rather than opening a second.
/// Its own commits are all it counts. Meanwhile the first job takes no Try again: its follow-up
/// carries its branch on.
#[test]
fn a_follow_up_of_published_work_updates_its_pull_request() {
    let folder = Folder::new("publish-follow-up");
    let bin = fake_gh(&folder.0);
    std::fs::write(
        folder.0.join("gh/view.json"),
        r#"{"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","mergedAt":null,"baseRefName":"main","headRefOid":""}"#,
    )
    .unwrap();
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt",
               "check": "test -f hello.txt", "title": "Hello file"}),
    );
    let first = ended(&obid, &id);
    assert_eq!(first["published"], PULL, "{first}");
    let branch = format!("oby/build-{id}");
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let head = git(&clone, &["rev-parse", &format!("refs/heads/{branch}")]);

    let told = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": "COMMIT: second.txt"})),
    );
    assert_eq!(told.status, 201, "{}", told.text);
    let next = told.body["id"].as_str().unwrap().to_owned();
    assert_eq!(told.body["branch"], branch.as_str());
    // The first job takes no Try again while its follow-up has its branch.
    let again = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": TRY_AGAIN})),
    );
    assert_eq!(again.status, 422, "{}", again.text);
    let follow = ended(&obid, &next);
    assert_eq!(follow["status"], "done", "{follow}\n{}", obid.log());
    assert_eq!(follow["startCommit"], head.as_str());
    assert_eq!(follow["commits"], 1);
    assert_eq!(follow["published"], PULL);
    let actions: Vec<&str> = follow["outgoing"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["action"].as_str().unwrap())
        .collect();
    assert_eq!(actions, ["push", "pullRequestEdit"]);
    assert_eq!(kept(&folder.0, "calls").matches("pr create").count(), 1);
    let pushed = git(&clone, &["rev-parse", &format!("refs/heads/{branch}")]);
    assert_eq!(
        remote_branch(&remote, &branch).as_deref(),
        Some(pushed.as_str())
    );
    assert_eq!(
        git(&clone, &["rev-parse", &format!("{pushed}~1")]),
        head,
        "on top of the first job's commit"
    );
    let again = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": TRY_AGAIN})),
    );
    assert_eq!(again.status, 422, "{}", again.text);
    assert!(
        again.body["error"].as_str().unwrap().contains("follow-up"),
        "{}",
        again.text
    );
}

/// What a job hears when the owner tries it again (`Inbox.tryAgainMessage`): its session again,
/// where words for a job that ended would start a follow-up.
const TRY_AGAIN: &str =
    "Try again, picking up where you left off. Finish with a short summary as asked.";

/// The stand-in agent commits `file` in job `id`'s next Try again.
fn again_commits(obid: &Obid, id: &str, file: &str) {
    let job = call(obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    let worktree = Path::new(job["worktree"].as_str().unwrap()).join(".obi");
    std::fs::create_dir_all(&worktree).unwrap();
    std::fs::write(worktree.join("again"), format!("COMMIT: {file}")).unwrap();
}

fn calls_now(folder: &Path) -> String {
    kept(folder, "calls")
}

/// A possible secret in a commit that the fix round leaves there: nothing goes out (no push, no
/// pull request), the job fails naming the file, the line and the rule, and never the secret.
#[test]
fn a_possible_secret_sends_nothing() {
    let folder = Folder::new("publish-secret");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "LEAK: keys.txt STUBBORN"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}");
    // It had its one fix round, and a second block of the same is the end.
    assert_eq!(job["round"], 2, "{job}");
    let summary = job["reason"].as_str().unwrap();
    assert!(
        summary.starts_with("Not published: possible secret in keys.txt:1 (AWS access key"),
        "{summary}"
    );
    assert!(!summary.contains(&leaked_key()), "{summary}");
    // It needs you, nothing lost: one more try at rewriting it, and the agent's own summary.
    assert_eq!(job["nextStep"], "Try again", "{job}");
    assert!(
        !job["summary"]
            .as_str()
            .unwrap()
            .starts_with("Not published:"),
        "{job}"
    );
    assert!(!obid.log().contains(&leaked_key()));
    // The scan's record names the file, line and rule, never the token (#735).
    let scan = &job["scan"];
    assert_eq!(
        (&scan["ran"], &scan["clean"]),
        (&json!(true), &json!(false)),
        "{job}"
    );
    let finding = &scan["findings"][0];
    assert_eq!(
        (&finding["file"], &finding["line"]),
        (&json!("keys.txt"), &json!(1)),
        "{job}"
    );
    assert!(finding["rule"].as_str().unwrap().contains("AWS"), "{job}");
    assert!(!job.to_string().contains(&leaked_key()), "{job}");
    let kept = std::fs::read_to_string(obid.home.join(format!("jobs/{id}.json"))).unwrap();
    assert!(!kept.contains(&leaked_key()));
    assert_eq!(job["published"], Value::Null);
    assert_eq!(job["outgoing"], json!([]));
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    assert!(!calls_now(&folder.0).contains("pr create"));
}

/// A job with one round still gets one to rewrite what the scan found (seen live 2026-10-18: a
/// chat job's test token failed it outright, and Claude Code would just fix and commit again).
#[test]
fn a_one_round_job_still_gets_its_fix_round() {
    let folder = Folder::new("publish-fix-one");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "LEAK: keys.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["round"], 2);
    assert_eq!(job["published"], PULL);
    let pushed = remote_branch(&remote, &format!("oby/build-{id}")).unwrap();
    let history = git(&remote, &["log", "-p", &format!("main..{pushed}")]);
    assert!(!history.contains(&leaked_key()), "{history}");
}

/// With a round left, the agent gets one to rewrite the commit that holds the secret (a fixup,
/// autosquashed onto the base); obid scans the rewritten history again and publishes it, and no
/// commit on the remote holds the secret.
#[test]
fn a_fix_round_rewrites_the_history_before_anything_goes_out() {
    let folder = Folder::new("publish-fix");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "LEAK: keys.txt", "rounds": 2}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["round"], 2);
    assert_eq!(job["summary"], "Took the key out of keys.txt.");
    assert_eq!(job["published"], PULL);
    let branch = format!("oby/build-{id}");
    let pushed = remote_branch(&remote, &branch).unwrap();
    let history = git(&remote, &["log", "-p", &format!("main..{pushed}")]);
    assert!(history.contains("keys.txt"), "{history}");
    assert!(!history.contains(&leaked_key()), "{history}");
}

/// When the scanner can't run (a gitleaks that is installed and broken), nothing goes out: the job
/// stays done with `publishError` saying so, and Publish by hand is offered.
#[test]
fn a_scanner_that_cant_run_sends_nothing() {
    let folder = Folder::new("publish-broken");
    let bin = fake_gh(&folder.0);
    let broken = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/bin-broken-gitleaks");
    std::fs::copy(broken.join("gitleaks"), bin.join("gitleaks")).unwrap();
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    let error = job["publishError"].as_str().unwrap();
    assert!(
        error.starts_with("Not published: the secret scan couldn't run (gitleaks couldn't run"),
        "{error}"
    );
    assert_eq!(job["published"], Value::Null);
    assert_eq!(job["outgoing"], json!([]));
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    assert_eq!(stage(&job, "publish")["state"], "failed");
    assert_eq!(stage(&job, "publish")["reason"], error);
    // It didn't run, and the record says why (#735).
    assert_eq!(job["scan"], json!({"ran": false, "reason": error}));
    let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/publish"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
}

/// A device's key from a fixed private scalar (no key in the source), and its public key as the
/// apps register it (X9.63, base64).
fn device(scalar: u8) -> (p256::ecdsa::SigningKey, String) {
    use base64::Engine as _;
    use p256::elliptic_curve::sec1::ToEncodedPoint;
    let secret = p256::SecretKey::from_slice(&[scalar; 32]).unwrap();
    let public = base64::engine::general_purpose::STANDARD
        .encode(secret.public_key().to_encoded_point(false).as_bytes());
    (p256::ecdsa::SigningKey::from(secret), public)
}

/// What a device sends to publish `job` by `action`, signed at `at` (seconds since the epoch).
fn approval(
    key: &p256::ecdsa::SigningKey,
    device: &str,
    job: &str,
    action: &str,
    at: i64,
) -> Value {
    use base64::Engine as _;
    use p256::ecdsa::signature::Signer as _;
    let signed_at = obi_protocol::time::format(at);
    let signature: p256::ecdsa::Signature =
        key.sign(format!("oby-publish\n{job}\n{action}\n{signed_at}").as_bytes());
    json!({"device": device, "action": action, "signedAt": signed_at,
           "signature": base64::engine::general_purpose::STANDARD.encode(signature.to_der())})
}

/// Publishing by hand, for a job whose own publish failed: `GET` says obid's one sentence; `POST`
/// goes through only with a registered device's fresh signature of exactly that sentence, runs the
/// same gate (a scanner that can't run still sends nothing), and answers the pull request.
#[test]
fn publishing_by_hand_needs_a_devices_fresh_signature() {
    let folder = Folder::new("publish-by-hand");
    let bin = fake_gh(&folder.0);
    let broken = folder.0.join("broken");
    std::fs::create_dir_all(&broken).unwrap();
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/bin-broken-gitleaks/gitleaks"),
        broken.join("gitleaks"),
    )
    .unwrap();
    std::fs::copy(bin.join("gh"), broken.join("gh")).unwrap();
    let (mut obid, remote, config) = obid_with(&folder, &broken);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "COMMIT: hello.txt"}),
    );
    let job = ended(&obid, &id);
    assert!(job["publishError"].as_str().is_some(), "{job}");
    let branch = format!("oby/fix-{id}");
    let sentence =
        format!("Push {branch} to obi-e2e/fixture-app and open a pull request into main.");
    let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/publish"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    assert_eq!(answer.body, json!({"action": sentence, "base": "main"}));

    std::fs::write(obid.home.join("pairing"), "").unwrap();
    let (key, public) = device(5);
    let (stranger, _) = device(6);
    let registered = call(
        &obid,
        "POST",
        "/v1/devices",
        Some(&json!({"name": "Test iPhone", "publicKey": public})),
    );
    assert_eq!(registered.status, 200, "{}", registered.text);
    let device_id = registered.body["id"].as_str().unwrap().to_owned();
    let now = obi_protocol::time::now();
    let publish = |body: &Value| call(&obid, "POST", &format!("/v1/jobs/{id}/publish"), Some(body));
    for (body, why) in [
        (
            approval(&key, "nobody", &id, &sentence, now),
            "isn't registered",
        ),
        (
            approval(&stranger, &device_id, &id, &sentence, now),
            "signature",
        ),
        (
            approval(&key, &device_id, &id, "Push it anywhere.", now),
            "something else",
        ),
        (
            approval(&key, &device_id, &id, &sentence, now - 600),
            "two minutes",
        ),
    ] {
        let refused = publish(&body);
        assert_eq!(refused.status, 403, "{why}: {}", refused.text);
        assert!(
            refused.body["error"].as_str().unwrap().contains(why),
            "{}",
            refused.text
        );
    }
    assert_eq!(publish(&json!({"device": device_id})).status, 422);
    // The scanner still can't run: nothing goes out, by hand either.
    let blocked = publish(&approval(&key, &device_id, &id, &sentence, now));
    assert_eq!(blocked.status, 409, "{}", blocked.text);
    assert!(
        blocked.body["error"]
            .as_str()
            .unwrap()
            .contains("couldn't run"),
        "{}",
        blocked.text
    );
    assert_eq!(remote_branch(&remote, &branch), None);

    // With a scanner that runs, the same job publishes by hand.
    obid.stop();
    let obid = start(&folder.0, &config, Some(&bin));
    // A new approval: the one above was used up, though nothing went out.
    let now = now + 2;
    let good = approval(&key, &device_id, &id, &sentence, now);
    let published = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/publish"),
        Some(&good),
    );
    assert_eq!(published.status, 200, "{}\n{}", published.text, obid.log());
    assert_eq!(published.body, json!({"url": PULL}));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["published"], PULL);
    assert_eq!(job["publishError"], Value::Null);
    assert_eq!(job["pushed"], 1);
    assert!(remote_branch(&remote, &branch).is_some());
    // The same approval again: there's nothing left to publish.
    let again = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/publish"),
        Some(&good),
    );
    assert_eq!(again.status, 409, "{}", again.text);
}

/// Someone else pushed to the job's branch: obid never overwrites it. The job stays done with
/// `publishError` saying so, and the remote branch keeps their commit.
#[test]
fn someone_elses_push_is_never_overwritten() {
    let folder = Folder::new("publish-lease");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    assert_eq!(ended(&obid, &id)["published"], PULL);
    let branch = format!("oby/build-{id}");
    // Someone pushes a commit of their own over the branch.
    let theirs = folder.0.join("theirs");
    git(
        &folder.0,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            theirs.to_str().unwrap(),
        ],
    );
    git(&theirs, &["checkout", "-q", "main"]);
    std::fs::write(theirs.join("theirs.txt"), "theirs\n").unwrap();
    git(&theirs, &["add", "theirs.txt"]);
    git(
        &theirs,
        &[
            "-c",
            "user.name=Someone",
            "-c",
            "user.email=someone@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "Theirs",
        ],
    );
    git(
        &theirs,
        &[
            "push",
            "-q",
            "-f",
            "origin",
            &format!("HEAD:refs/heads/{branch}"),
        ],
    );
    let their_commit = remote_branch(&remote, &branch).unwrap();
    again_commits(&obid, &id, "second.txt");
    let told = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{id}/messages"),
        Some(&json!({"text": TRY_AGAIN})),
    );
    assert_eq!(told.status, 200, "{}", told.text);
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}");
    let error = job["publishError"].as_str().unwrap();
    assert!(
        error.starts_with(&format!(
            "Not published: {branch} on GitHub is at {}",
            &their_commit[..12]
        )),
        "{error}"
    );
    assert_eq!(remote_branch(&remote, &branch), Some(their_commit));
}

/// The push went out and then GitHub's pull request lookup failed (#627), in a way a later try
/// wouldn't change: the job counts its pushed commits, and `publishError` is the pull request's
/// own failure, not "not published". Publishing by hand is still offered, for the pull request.
#[test]
fn a_pull_request_that_fails_after_the_push_still_counts_the_push() {
    let folder = Folder::new("publish-no-pull");
    let bin = fake_gh(&folder.0);
    std::fs::write(folder.0.join("gh/list-fails"), "").unwrap();
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    let job = ended(&obid, &id);
    let branch = format!("oby/build-{id}");
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["published"], Value::Null, "{job}");
    assert_eq!(job["commits"], 1);
    assert_eq!(job["pushed"], 1, "{job}");
    assert_eq!(
        job["publishError"],
        "Pushed, but couldn't look for the open pull request: GraphQL: Could not resolve to a Repository"
    );
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let head = git(&clone, &["rev-parse", &format!("refs/heads/{branch}")]);
    assert_eq!(remote_branch(&remote, &branch), Some(head.clone()));
    assert_eq!(job["outgoing"][0]["action"], "push");
    assert_eq!(job["outgoing"][0]["id"], head.as_str());
    assert_eq!(stage(&job, "publish")["state"], "failed");
    // Not tried again: GitHub doesn't know the repository.
    let lookups = calls_now(&folder.0)
        .lines()
        .filter(|call| call.starts_with("pr list") && call.contains("--head"))
        .count();
    assert_eq!(lookups, 1, "{}", calls_now(&folder.0));
    let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/publish"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
}

/// GitHub answers 502 once: obid publishes again after a wait (`Publishing again in …`), and the
/// job ends published, with nothing for the owner to do.
#[test]
fn a_publish_github_turned_down_is_tried_again() {
    let folder = Folder::new("publish-retry");
    let bin = fake_gh(&folder.0);
    std::fs::write(folder.0.join("gh/list-fails-once"), "").unwrap();
    // Room for a loaded machine: the window caps the stand-in agent's quiet time too.
    let (obid, _) = obid_retrying_within(&folder, &bin, 10);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["published"], PULL, "{job}");
    assert_eq!(job["publishError"], Value::Null, "{job}");
    let log = obid.log();
    assert!(
        log.contains(&format!(
            "job {id}: Publishing again in 10 seconds (1 of 3): Pushed, but "
        )) && log.contains("HTTP 502: Bad Gateway"),
        "{log}"
    );
}

/// A try whose pull request failed pushed (#627): that push stays counted whatever comes after
/// it, a stop while obid waits to try again, or a later try that fails before it pushes.
#[test]
fn a_push_that_went_out_stays_counted_across_tries() {
    let folder = Folder::new("publish-kept-push");
    let bin = fake_gh(&folder.0);
    let (obid, remote) = obid_retrying_within(&folder, &bin, 10);
    let waiting = |id: &str| {
        within(60, "obid to wait before publishing again", || {
            let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
            job["step"]
                .as_str()?
                .starts_with("Publishing again")
                .then_some(job)
        })
    };

    // Stopped while it waits.
    std::fs::write(folder.0.join("gh/list-fails-once"), "").unwrap();
    let stopped = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: a.txt"}),
    );
    assert_eq!(waiting(&stopped)["pushed"], 1);
    let stop = call(&obid, "POST", &format!("/v1/jobs/{stopped}/stop"), None);
    assert_eq!(stop.status, 200, "{}", stop.text);
    let job = ended(&obid, &stopped);
    assert_eq!(job["status"], "stopped", "{job}");
    assert_eq!(job["pushed"], 1, "{job}");
    assert_eq!(job["published"], Value::Null, "{job}");

    // The next try can't fetch the base: the push it made before still counts.
    std::fs::write(folder.0.join("gh/list-fails-once"), "").unwrap();
    let cut = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: b.txt"}),
    );
    waiting(&cut);
    let gone = folder.0.join("gone");
    std::fs::rename(&remote, &gone).unwrap();
    let job = ended(&obid, &cut);
    std::fs::rename(&gone, &remote).unwrap();
    assert_eq!(job["status"], "done", "{job}");
    assert_eq!(job["pushed"], 1, "{job}");
    let error = job["publishError"].as_str().unwrap();
    assert!(
        error.starts_with("Not published: couldn't fetch main: "),
        "{error}"
    );
}

/// A remote that isn't GitHub (here the fixture's `file://` one, with no `pullRequests` in the
/// configuration) gets the push and nothing else (#627): no `gh` pull request call, the job's
/// commits counted as pushed, and nothing left to publish by hand.
#[test]
fn a_remote_that_isnt_github_gets_the_push_and_no_pull_request() {
    let folder = Folder::new("publish-file-remote");
    let bin = fake_gh(&folder.0);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["repos"][0]
        .as_object_mut()
        .unwrap()
        .remove("pullRequests");
    let obid = start(&folder.0, &config, Some(&bin));
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    let job = ended(&obid, &id);
    let branch = format!("oby/build-{id}");
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["publishError"], Value::Null, "{job}");
    assert_eq!(job["published"], Value::Null);
    assert_eq!(job["pushed"], 1, "{job}");
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    let head = git(&clone, &["rev-parse", &format!("refs/heads/{branch}")]);
    assert_eq!(remote_branch(&remote, &branch), Some(head));
    // No pull request is looked for or opened (the GitHub feed's own `api graphql` calls aside).
    assert!(
        !calls_now(&folder.0)
            .lines()
            .any(|call| call.starts_with("pr ")),
        "{}",
        calls_now(&folder.0)
    );
    assert_eq!(stage(&job, "publish")["state"], "done");
    assert_eq!(
        stage(&job, "publish")["detail"],
        "Secret scan clean · pushed · no pull request for this remote"
    );
    let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/publish"), None);
    assert_eq!(answer.status, 409, "{}", answer.text);
    assert_eq!(
        answer.body["error"],
        "Nothing to publish: the remote is already at its head."
    );
}

/// Stopped while it publishes: nothing more goes out. A gitleaks that takes its time holds the
/// scan open; the job is stopped then, and no push or pull request follows.
#[test]
fn a_job_stopped_while_it_publishes_sends_nothing_more() {
    use std::os::unix::fs::PermissionsExt;
    let folder = Folder::new("publish-stop");
    let bin = fake_gh(&folder.0);
    std::fs::write(bin.join("gitleaks"), SLOW_GITLEAKS).unwrap();
    std::fs::set_permissions(bin.join("gitleaks"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    let publishing = within(60, "the job publishes", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["step"] == "Publishing").then_some(job)
    });
    assert_eq!(publishing["status"], "running");
    assert_eq!(publishing["publishStep"], "scan");
    assert_eq!(stage(&publishing, "publish")["state"], "current");
    assert_eq!(stage(&publishing, "publish")["detail"], "Secret scan");
    let stopped = call(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None);
    assert_eq!(stopped.status, 200, "{}", stopped.text);
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "stopped", "{job}");
    // Long enough for a publish that didn't stop to have pushed and opened its pull request.
    std::thread::sleep(std::time::Duration::from_secs(8));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "stopped", "{job}");
    assert_eq!(job["outgoing"], json!([]));
    assert_eq!(job["published"], Value::Null);
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    assert!(!calls_now(&folder.0).contains("pr create"));
}

/// What leaves in a commit besides its files and message is scanned too: a token as the author's
/// name is a possible secret, and a commit carrying a header obid doesn't publish (here one holding
/// a token) is refused. Nothing goes out either way.
#[test]
fn a_commits_author_and_headers_are_scanned_too() {
    let folder = Folder::new("publish-headers");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let author = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "AUTHOR: a.txt", "rounds": 2}),
    );
    let job = ended(&obid, &author);
    assert_eq!(job["status"], "interrupted", "{job}\n{}", obid.log());
    let summary = job["reason"].as_str().unwrap();
    assert!(
        summary.starts_with("Not published: possible secret in commit author:1 (GitHub token"),
        "{summary}"
    );
    // Who made a commit isn't the agent's to rewrite with a fixup: no fix round, and no next
    // step but a person's.
    assert_eq!(job["round"], 1);
    assert_eq!(job["nextStep"], Value::Null, "{job}");
    assert_eq!(remote_branch(&remote, &format!("oby/build-{author}")), None);
    let header = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "HEADER: b.txt"}),
    );
    let job = ended(&obid, &header);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    let error = job["publishError"].as_str().unwrap();
    assert!(
        error.contains("carries headers other than its tree, parents, author and committer"),
        "{error}"
    );
    assert_eq!(remote_branch(&remote, &format!("oby/build-{header}")), None);
    assert_eq!(job["outgoing"], json!([]));
    assert!(!calls_now(&folder.0).contains("pr create"));
}

/// An open pull request from a fork's branch of the same name isn't obid's: obid opens its own
/// rather than edit (and vouch for) someone else's.
#[test]
fn a_forks_pull_request_of_the_same_branch_is_never_taken_for_obids() {
    let folder = Folder::new("publish-fork");
    let bin = fake_gh(&folder.0);
    std::fs::write(
        folder.0.join("gh/open"),
        r#"[{"url":"https://github.com/obi-e2e/fixture-app/pull/9","isCrossRepository":true,"headRefOid":"__HEAD__","baseRefName":"main"}]"#,
    )
    .unwrap();
    let (obid, _, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: hello.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["published"], PULL, "{job}");
    let calls = calls_now(&folder.0);
    assert!(calls.contains("pr create"), "{calls}");
    assert!(!calls.contains("pr edit"), "{calls}");
}

/// The base can't be fetched when it publishes: nothing goes out, and `publishError` says so
/// without git's command line or the remote's address.
#[test]
fn a_base_that_cant_be_fetched_sends_nothing() {
    let folder = Folder::new("publish-nofetch");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "SLOW: hello.txt"}),
    );
    within(60, "the agent starts", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["status"] == "running").then_some(())
    });
    let gone = folder.0.join("gone");
    std::fs::rename(&remote, &gone).unwrap();
    let job = ended(&obid, &id);
    std::fs::rename(&gone, &remote).unwrap();
    assert_eq!(job["status"], "done", "{job}");
    let error = job["publishError"].as_str().unwrap();
    assert!(
        error.starts_with("Not published: couldn't fetch main: "),
        "{error}"
    );
    assert!(!error.contains(remote.to_str().unwrap()), "{error}");
    assert!(
        !error.contains("credential.helper") && !error.contains("--no-tags"),
        "{error}"
    );
    assert_eq!(job["outgoing"], json!([]));
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
}

/// Jobs on one repository that end together all publish (#628): one keeping its commits in the
/// clone never breaks another's fetch of the base, and every branch reaches the remote.
#[test]
fn jobs_ending_together_on_one_clone_all_publish() {
    let folder = Folder::new("publish-together");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let ids: Vec<String> = (0..4)
        .map(|n| {
            dispatch(
                &obid,
                json!({"repo": "obi-e2e/fixture-app", "kind": "build",
                       "task": format!("SLOW: together-{n}.txt")}),
            )
        })
        .collect();
    for id in &ids {
        let job = ended(&obid, id);
        assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
        assert_eq!(job["publishError"], Value::Null, "{job}\n{}", obid.log());
        assert_eq!(job["published"], PULL, "{job}");
        let clone = obid.home.join("clones/obi-e2e/fixture-app");
        let head = git(
            &clone,
            &["rev-parse", &format!("refs/heads/oby/build-{id}")],
        );
        assert_eq!(
            remote_branch(&remote, &format!("oby/build-{id}")).as_deref(),
            Some(head.as_str())
        );
    }
}

/// The made-up GitHub token the stand-in agent uses (`AUTHOR:`, `HEADER:`, `FOLDER`), put together
/// here so this file holds none.
fn made_up_token() -> String {
    ["gh", "p_", "Zq8LmN2pR4sT6uV8wX0yA1bC3dE5fG7hJ9kM"].concat()
}

/// A token in a folder's name is found, however git writes the name in a diff's header (here one
/// holding " b/", which the header can't be split back into), and it is never repeated: not in
/// the job, its summary, the API, or obid's log.
#[test]
fn a_token_in_a_folders_name_is_found_and_never_repeated() {
    let folder = Folder::new("publish-folder");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "FOLDER"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}\n{}", obid.log());
    let summary = job["reason"].as_str().unwrap();
    assert!(
        summary.starts_with("Not published: possible secret in a file whose name obid won't show"),
        "{summary}"
    );
    assert!(summary.contains("GitHub token in a name"), "{summary}");
    // What the owner can do: where to look.
    assert!(
        summary.contains("it is among the names of the files and folders the branch adds"),
        "{summary}"
    );
    assert_eq!(job["publishStep"], Value::Null);
    let token = made_up_token();
    let api = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).text;
    assert!(!api.contains(&token), "{api}");
    assert!(!obid.log().contains(&token), "{}", obid.log());
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
}

/// The owner's own git configuration can't narrow the scan: with `log.showRoot = false` in the
/// global configuration of obid's `HOME`, a root commit merged in from an unrelated history still
/// has its files read.
#[test]
fn the_owners_git_configuration_cant_hide_a_root_commit() {
    let folder = Folder::new("publish-showroot");
    let bin = fake_gh(&folder.0);
    std::fs::create_dir_all(folder.0.join("env-home")).unwrap();
    std::fs::write(
        folder.0.join("env-home/.gitconfig"),
        "[log]\n\tshowRoot = false\n",
    )
    .unwrap();
    let (obid, remote, _) = obid_with(&folder, &bin);
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "ORPHAN STUBBORN"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "interrupted", "{job}\n{}", obid.log());
    let summary = job["reason"].as_str().unwrap();
    assert!(
        summary.starts_with("Not published: possible secret in root.txt:1 (AWS access key"),
        "{summary}"
    );
    assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
}

/// Publishing by hand publishes the run that was approved: the sentence names the branch, not its
/// commits, so when obid described an earlier run in the two minutes before the device signed, the
/// approval could be of either and is refused, after a restart too. While a hand publish runs, the
/// job can't be dismissed.
#[test]
fn a_hand_publish_is_for_the_run_that_was_approved() {
    use std::os::unix::fs::PermissionsExt;
    let folder = Folder::new("publish-run");
    let bin = fake_gh(&folder.0);
    let broken = folder.0.join("broken");
    std::fs::create_dir_all(&broken).unwrap();
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/bin-broken-gitleaks/gitleaks"),
        broken.join("gitleaks"),
    )
    .unwrap();
    std::fs::copy(bin.join("gh"), broken.join("gh")).unwrap();
    let (mut obid, remote, config) = obid_with(&folder, &broken);
    // Two jobs whose own publish failed (the scanner can't run).
    let ran = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "COMMIT: hello.txt"}),
    );
    let held = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "fix", "task": "COMMIT: other.txt"}),
    );
    assert!(ended(&obid, &ran)["publishError"].is_string());
    assert!(ended(&obid, &held)["publishError"].is_string());
    std::fs::write(obid.home.join("pairing"), "").unwrap();
    let (key, public) = device(9);
    let device_id = call(
        &obid,
        "POST",
        "/v1/devices",
        Some(&json!({"name": "Test iPhone", "publicKey": public})),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let sentence_of = |obid: &Obid, id: &str| {
        call(obid, "GET", &format!("/v1/jobs/{id}/publish"), None).body["action"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    // obid describes the first job's run; then it runs again, and its own publish fails again:
    // the same sentence, other commits. Another device asks again, and this one signs.
    let sentence = sentence_of(&obid, &ran);
    again_commits(&obid, &ran, "second.txt");
    let told = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{ran}/messages"),
        Some(&json!({"text": TRY_AGAIN})),
    );
    assert_eq!(told.status, 200, "{}", told.text);
    assert_eq!(ended(&obid, &ran)["commits"], 2);
    assert_eq!(sentence_of(&obid, &ran), sentence);
    let refused = |obid: &Obid, at: i64| {
        let answer = call(
            obid,
            "POST",
            &format!("/v1/jobs/{ran}/publish"),
            Some(&approval(&key, &device_id, &ran, &sentence, at)),
        );
        assert_eq!(answer.status, 409, "{}", answer.text);
        assert_eq!(
            answer.body["error"],
            "The job ran again since obid said what publishing it would do. Approve it again in two minutes."
        );
    };
    refused(&obid, obi_protocol::time::now());
    // What obid said is kept with the job: a restart doesn't forget it.
    obid.stop();
    std::fs::write(bin.join("gitleaks"), SLOW_GITLEAKS).unwrap();
    std::fs::set_permissions(bin.join("gitleaks"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let obid = start(&folder.0, &config, Some(&bin));
    refused(&obid, obi_protocol::time::now() + 1);
    assert_eq!(remote_branch(&remote, &format!("oby/fix-{ran}")), None);

    // A gitleaks that takes its time holds the other job's hand publish open: no dismissing it
    // meanwhile.
    let sentence = sentence_of(&obid, &held);
    let good = approval(
        &key,
        &device_id,
        &held,
        &sentence,
        obi_protocol::time::now() + 1,
    );
    std::thread::scope(|scope| {
        let publishing = scope.spawn(|| {
            call(
                &obid,
                "POST",
                &format!("/v1/jobs/{held}/publish"),
                Some(&good),
            )
        });
        within(30, "the hand publish is under way", || {
            let job = call(&obid, "GET", &format!("/v1/jobs/{held}"), None).body;
            (job["publishStep"] == "scan").then_some(())
        });
        let dismissed = call(&obid, "POST", &format!("/v1/jobs/{held}/dismiss"), None);
        assert_eq!(dismissed.status, 409, "{}", dismissed.text);
        assert!(
            dismissed.body["error"]
                .as_str()
                .unwrap()
                .contains("publishing")
        );
        let published = publishing.join().unwrap();
        assert_eq!(published.status, 200, "{}", published.text);
    });
    let job = call(&obid, "GET", &format!("/v1/jobs/{held}"), None).body;
    assert_eq!(job["dismissed"], Value::Null);
    assert_eq!(job["pushed"], 1);
}

/// Only the names a job adds are its own: a base that already holds `.env.development` and a
/// fixture `id_rsa` in a folder still publishes a job that adds a file next to them, and a job
/// that adds a `.env` there is still stopped.
#[test]
fn names_already_on_the_base_are_the_bases() {
    let folder = Folder::new("publish-base-names");
    let bin = fake_gh(&folder.0);
    let remote = fixture(&folder.0.join("fixture"));
    // The base gets the files a person committed there before.
    let theirs = folder.0.join("theirs");
    git(
        &folder.0,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            theirs.to_str().unwrap(),
        ],
    );
    git(&theirs, &["checkout", "-q", "main"]);
    std::fs::create_dir_all(theirs.join("cfg/.env.d")).unwrap();
    std::fs::write(theirs.join("cfg/.env.development"), "MODE=dev\n").unwrap();
    std::fs::write(theirs.join("cfg/id_rsa"), "not a key, a fixture\n").unwrap();
    std::fs::write(theirs.join("cfg/.env.d/a.txt"), "a\n").unwrap();
    git(&theirs, &["add", "-A"]);
    git(
        &theirs,
        &[
            "-c",
            "user.name=Someone",
            "-c",
            "user.email=someone@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "Fixtures",
        ],
    );
    git(&theirs, &["push", "-q", "origin", "main"]);
    let config = config(&folder.0, &remote, &agent());
    let obid = start(&folder.0, &config, Some(&bin));
    let id = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: cfg/b.txt"}),
    );
    let job = ended(&obid, &id);
    assert_eq!(job["status"], "done", "{job}\n{}", obid.log());
    assert_eq!(job["publishError"], Value::Null, "{job}");
    assert_eq!(job["published"], PULL);
    let env = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: cfg/.env"}),
    );
    let job = ended(&obid, &env);
    assert_eq!(job["status"], "interrupted", "{job}");
    assert!(
        job["reason"]
            .as_str()
            .unwrap()
            .starts_with("Not published: possible secret in .env (.env file)"),
        "{job}"
    );
    assert_eq!(remote_branch(&remote, &format!("oby/build-{env}")), None);
}

/// A stand-in gitleaks that takes its time, then reads its input to the end and finds only the
/// canary obid puts last (crate::scan, `run_gitleaks`).
const SLOW_GITLEAKS: &str = "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --report-path=*) r=\"${a#--report-path=}\";; esac; done\n\
sleep 2\nn=$(awk 'END {print NR}' \"$2\")\necho \"[{\\\"StartLine\\\": $n, \\\"RuleID\\\": \\\"github-pat\\\"}]\" > \"$r\"\nexit 99\n";

/// A gitleaks that reports a finding in the names without saying which (a line it wasn't given)
/// still stops the publish: nothing is dropped as clean. One with no report it could read is a
/// gitleaks that didn't read its input, a scan that couldn't run (crate::scan's tests).
#[test]
fn a_name_finding_gitleaks_cant_place_still_counts() {
    use std::os::unix::fs::PermissionsExt;
    let folder = Folder::new("publish-unplaced");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    // It reads to the end (its report has obid's canary, the last line) and, in the names only
    // (a line that reads exactly the file's name), finds something it can't place: line 999.
    let file = "trigger-two";
    {
        std::fs::write(
            bin.join("gitleaks"),
            format!(
                "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --report-path=*) r=\"${{a#--report-path=}}\";; esac; done\n\
                 n=$(awk 'END {{print NR}}' \"$2\")\n\
                 if grep -qx '{file}' \"$2\"; then extra='{{\"StartLine\": 999, \"RuleID\": \"github-pat\"}}, '; else extra=''; fi\n\
                 echo \"[$extra{{\\\"StartLine\\\": $n, \\\"RuleID\\\": \\\"github-pat\\\"}}]\" > \"$r\"\nexit 99\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(bin.join("gitleaks"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        let id = dispatch(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": format!("EMPTY: {file}")}),
        );
        let job = ended(&obid, &id);
        assert_eq!(job["status"], "interrupted", "{file}: {job}");
        let summary = job["reason"].as_str().unwrap();
        assert!(summary.contains("(gitleaks"), "{file}: {summary}");
        assert!(summary.contains("in a name)"), "{file}: {summary}");
        assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    }
}

/// The clone's own settings can't hide a name: with `log.diffMerges = off` a `.env.local` added
/// in a merge commit itself (in neither parent) is still found, and with
/// `diff.ignoreSubmodules = all` a submodule named with a token is too.
#[test]
fn the_clones_settings_cant_hide_a_merge_or_a_submodule() {
    let folder = Folder::new("publish-clone-settings");
    let bin = fake_gh(&folder.0);
    let (obid, remote, _) = obid_with(&folder, &bin);
    // A first job makes the clone; then its settings are changed.
    let warm = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "COMMIT: warm.txt"}),
    );
    assert_eq!(ended(&obid, &warm)["published"], PULL);
    let clone = obid.home.join("clones/obi-e2e/fixture-app");
    git(&clone, &["config", "log.diffMerges", "off"]);
    git(&clone, &["config", "diff.ignoreSubmodules", "all"]);
    let evil = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "EVIL: .env.local"}),
    );
    let job = ended(&obid, &evil);
    assert_eq!(job["status"], "interrupted", "{job}\n{}", obid.log());
    assert!(
        job["reason"]
            .as_str()
            .unwrap()
            .starts_with("Not published: possible secret in .env.local (.env file)"),
        "{job}"
    );
    assert_eq!(remote_branch(&remote, &format!("oby/build-{evil}")), None);
    let link = dispatch(
        &obid,
        json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": "GITLINK"}),
    );
    let job = ended(&obid, &link);
    assert_eq!(job["status"], "interrupted", "{job}\n{}", obid.log());
    let summary = job["reason"].as_str().unwrap();
    assert!(summary.contains("GitHub token in a name"), "{summary}");
    assert!(!summary.contains(&made_up_token()), "{summary}");
    assert_eq!(remote_branch(&remote, &format!("oby/build-{link}")), None);
}

/// A name that holds secrets by itself is found however it arrives: a `.env` moved into a new
/// folder, and an `id_ed25519` brought in through a merged side branch.
#[test]
fn a_moved_env_and_a_key_from_a_side_branch_are_found() {
    let folder = Folder::new("publish-moves");
    let bin = fake_gh(&folder.0);
    let remote = fixture(&folder.0.join("fixture"));
    let theirs = folder.0.join("theirs");
    git(
        &folder.0,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            theirs.to_str().unwrap(),
        ],
    );
    git(&theirs, &["checkout", "-q", "main"]);
    std::fs::write(theirs.join(".env"), "MODE=dev\n").unwrap();
    git(&theirs, &["add", "-A"]);
    git(
        &theirs,
        &[
            "-c",
            "user.name=Someone",
            "-c",
            "user.email=someone@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "An env",
        ],
    );
    git(&theirs, &["push", "-q", "origin", "main"]);
    let obid = start(&folder.0, &config(&folder.0, &remote, &agent()), Some(&bin));
    for (task, place) in [
        ("MOVE: .env newdir/.env", ".env (.env file)"),
        ("SIDE: id_ed25519", "id_ed25519 (private key file)"),
    ] {
        let id = dispatch(
            &obid,
            json!({"repo": "obi-e2e/fixture-app", "kind": "build", "task": task}),
        );
        let job = ended(&obid, &id);
        assert_eq!(
            job["status"],
            "interrupted",
            "{task}: {job}\n{}",
            obid.log()
        );
        assert!(
            job["reason"]
                .as_str()
                .unwrap()
                .starts_with(&format!("Not published: possible secret in {place}")),
            "{task}: {job}"
        );
        assert_eq!(remote_branch(&remote, &format!("oby/build-{id}")), None);
    }
}
