//! The Lead (#589): "work on the roadmap" reads the board with obid's own gh, leaves out what
//! obid says it must, and starts the rest, claiming each issue.
mod support;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

const REPO: &str = "obi-e2e/fixture-app";

fn planner() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-planner")
}

fn started(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    start(&folder.0, &config, Some(planner().parent().unwrap()))
}

/// One issue on the board: its number, column, labels, assignees.
struct Row<'a>(u64, &'a str, &'a [&'a str], &'a [&'a str]);

/// The board the fake gh serves (tests/agents/gh), and the open pull requests on it.
fn board(obid: &Obid, rows: &[Row], prs: Value) -> PathBuf {
    let dir = obid.folder.join("env-home/board");
    std::fs::create_dir_all(&dir).unwrap();
    let items: Vec<Value> = rows
        .iter()
        .map(|Row(n, column, ..)| {
            json!({"content": {"type": "Issue", "number": n, "repository": REPO}, "status": column})
        })
        .collect();
    let issues: Vec<Value> = rows
        .iter()
        .map(|Row(n, _, labels, assignees)| {
            json!({"number": n, "title": format!("Issue {n}"), "url": format!("https://github.com/{REPO}/issues/{n}"),
                   "labels": labels.iter().map(|l| json!({"name": l})).collect::<Vec<_>>(),
                   "assignees": assignees.iter().map(|a| json!({"login": a})).collect::<Vec<_>>(),
                   "milestone": null})
        })
        .collect();
    std::fs::write(dir.join("user"), "wellington\n").unwrap();
    std::fs::write(
        dir.join("projects.json"),
        json!({"projects": [{"title": "Oby - roadmap", "number": 7}]}).to_string(),
    )
    .unwrap();
    std::fs::write(dir.join("items.json"), json!({"items": items}).to_string()).unwrap();
    std::fs::write(dir.join("issues.json"), Value::from(issues).to_string()).unwrap();
    std::fs::write(dir.join("prs.json"), prs.to_string()).unwrap();
    dir
}

fn brief(issue: u64) -> Value {
    json!({"repo": REPO, "issue": issue, "kind": "build", "title": format!("Work on {issue}"),
           "goal": "SLEEP until ended", "files": [format!("src/{issue}/")], "check": "node --test",
           "out_of_scope": "Everything else."})
}

fn start_jobs(issues: &[u64]) -> String {
    json!({"action": "start_jobs", "reply": "Starting.", "question": null,
           "jobs": issues.iter().map(|n| brief(*n)).collect::<Vec<_>>()})
    .to_string()
}

/// What the fake planner answers next, one line per call.
fn queue(obid: &Obid, lines: &[String]) {
    let dir = obid.home.join("accounts/stub");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("plans"), lines.join("\n") + "\n").unwrap();
}

/// Each call the planner got, in order.
fn calls(obid: &Obid) -> Vec<PathBuf> {
    let mut calls: Vec<(u32, PathBuf)> = std::fs::read_dir(obid.home.join("accounts/stub/calls"))
        .map(|dir| {
            dir.flatten()
                .filter_map(|e| Some((e.file_name().to_str()?.parse().ok()?, e.path())))
                .collect()
        })
        .unwrap_or_default();
    calls.sort();
    calls.into_iter().map(|(_, path)| path).collect()
}

fn lead_turns(obid: &Obid) -> Vec<Value> {
    std::fs::read_to_string(obid.home.join("lead-turns.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Each `gh issue edit` obid ran: `<issue> <repo> <label added> <last line of the body>`.
fn edits(dir: &Path) -> Vec<String> {
    std::fs::read_to_string(dir.join("edits"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

fn said(obid: &Obid, words: &str) -> Value {
    let answer = call(obid, "POST", "/v1/plans", Some(&json!({"said": words})));
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn jobs(obid: &Obid) -> Vec<Value> {
    let answer = call(obid, "GET", "/v1/jobs", None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body["jobs"]
        .as_array()
        .or(answer.body.as_array())
        .cloned()
        .unwrap_or_default()
}

/// Three workable issues and one blocked: three jobs start, each issue is claimed, and the
/// blocked one is named with its reason. Said again, nothing new starts and no model is asked.
/// (LeadTests.theLeadStartsJobsRightAwayClaimsEachIssueAndIsLogged,
/// theSameRequestTwiceStartsNothingNew.)
#[test]
fn the_roadmap_starts_its_workable_issues_once_and_claims_each() {
    let folder = Folder::new("lead-roadmap");
    let obid = started(&folder);
    let dir = board(
        &obid,
        &[
            Row(1, "Todo", &[], &[]),
            Row(2, "Todo", &[], &["wellington"]),
            Row(3, "Todo", &[], &[]),
            Row(4, "Todo", &["status:blocked"], &[]),
        ],
        json!([]),
    );
    queue(&obid, &[start_jobs(&[1, 2, 3])]);
    let events = follow_events(&obid);

    let answer = said(&obid, "work on the roadmap");
    // It says it's thinking first, like every turn (#592), and that it's done.
    let thoughts = events_named(&events, "thinking", 10, |got| got.len() == 2);
    let states: Vec<(&str, &str)> = thoughts
        .iter()
        .map(|t| (t["text"].as_str().unwrap(), t["state"].as_str().unwrap()))
        .collect();
    assert_eq!(
        states,
        [
            ("Reading the roadmap", "running"),
            ("Reading the roadmap", "done")
        ]
    );
    assert_eq!(answer["kind"], "reply", "{answer}");
    let text = answer["text"].as_str().unwrap();
    assert!(
        text.starts_with("Started 3 jobs: Work on 1 (#1), Work on 2 (#2), Work on 3 (#3)."),
        "{text}"
    );
    assert!(text.contains("Skipped #4 (blocked)."), "{text}");
    let started: Vec<&Value> = answer["jobs"].as_array().unwrap().iter().collect();
    assert_eq!(started.len(), 3);
    for (job, issue) in started.iter().zip([1, 2, 3]) {
        assert_eq!(job["issue"], issue);
        assert_eq!(job["files"], json!([format!("src/{issue}/")]));
        assert_eq!(job["check"], "node --test");
        assert_eq!(job["rounds"], 4);
    }
    // Each issue is claimed as issue sync does: the label and the hidden line, no comment.
    let claims = edits(&dir);
    assert_eq!(claims.len(), 3, "{claims:?}");
    for (claim, job) in claims.iter().zip(&started) {
        let id = job["id"].as_str().unwrap();
        let issue = job["issue"].as_u64().unwrap();
        assert_eq!(
            claim,
            &format!("{issue} {REPO} status:in-progress <!-- oby-claim: job {id} -->")
        );
    }
    // The Lead thinks with Sonnet and reads with Read alone, boxed, the board and the verdicts
    // inside the turn's fence.
    let args = std::fs::read_to_string(calls(&obid)[0].join("args")).unwrap();
    assert!(args.contains("--model\nclaude-sonnet-5-5\n"), "{args}");
    assert!(
        args.contains("--tools\nRead\n--allowedTools\nRead(./work.md)\n"),
        "{args}"
    );
    let work = std::fs::read_to_string(calls(&obid)[0].join("work.md")).unwrap();
    assert!(work.contains("<<<quoted-"), "{work}");
    assert!(
        work.contains(&format!(
            "| 4 | {REPO}#4 | Issue 4 | Todo | status:blocked |"
        )),
        "{work}"
    );
    assert!(work.contains("| skipped: blocked |"), "{work}");
    let turns = lead_turns(&obid);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0]["kind"], "lead");
    assert_eq!(turns[0]["started"].as_array().unwrap().len(), 3);
    assert_eq!(turns[0]["claimed"].as_array().unwrap().len(), 3);
    assert_eq!(turns[0]["skipped"][0]["reason"], "blocked");

    let again = said(&obid, "work on the roadmap");
    let text = again["text"].as_str().unwrap();
    assert!(
        text.starts_with("Nothing to start on the roadmap."),
        "{text}"
    );
    assert!(text.contains("#1 (job "), "{text}");
    assert_eq!(again["jobs"], json!([]));
    assert_eq!(jobs(&obid).len(), 3);
    assert_eq!(
        calls(&obid).len(),
        1,
        "no model is asked when nothing is workable"
    );
    assert_eq!(edits(&dir).len(), 3);
}

/// An issue with an open pull request, `oby:skip` or another assignee is never started, even when
/// the Lead names it: obid refuses the plan with why, and the Lead's next one starts the rest.
#[test]
fn skipped_issues_are_never_started() {
    let folder = Folder::new("lead-skips");
    let obid = started(&folder);
    let dir = board(
        &obid,
        &[
            Row(1, "Todo", &[], &[]),
            Row(2, "Todo", &["oby:skip"], &[]),
            Row(3, "Todo", &[], &["someone"]),
            Row(4, "Todo", &[], &[]),
        ],
        json!([{"number": 9, "title": "feat: one", "closingIssuesReferences": [{"number": 1}]}]),
    );
    queue(&obid, &[start_jobs(&[1, 2, 3, 4]), start_jobs(&[4])]);

    let answer = said(&obid, "pick up the next issues");
    let started = answer["jobs"].as_array().unwrap();
    assert_eq!(started.len(), 1, "{answer}");
    assert_eq!(started[0]["issue"], 4);
    let text = answer["text"].as_str().unwrap();
    assert!(
        text.contains("#1 (PR #9 is open), #2 (oby:skip), #3 (assigned to someone)"),
        "{text}"
    );
    let refused = lead_turns(&obid)[0]["refused"][0]
        .as_str()
        .unwrap()
        .to_owned();
    for why in [
        "#1 is refused: PR #9 is open",
        "#2 is refused: oby:skip",
        "#3 is refused: assigned to someone",
    ] {
        assert!(refused.contains(why), "{refused}");
    }
    // The second call heard why the first plan was refused.
    let input = std::fs::read_to_string(calls(&obid)[1].join("input")).unwrap();
    assert!(input.contains("Your last plan was refused:"), "{input}");
    assert_eq!(edits(&dir).len(), 1);
}

/// A board that can't be read is said in one line and recorded, and no model is asked.
#[test]
fn a_board_that_cant_be_read_is_said_and_recorded() {
    let folder = Folder::new("lead-unreadable");
    let obid = started(&folder);
    let dir = board(&obid, &[Row(1, "Todo", &[], &[])], json!([]));
    std::fs::write(dir.join("unreadable"), "").unwrap();

    let answer = said(&obid, "work on the roadmap");
    let text = answer["text"].as_str().unwrap();
    assert!(
        text.starts_with("Oby couldn't read the roadmap: no project called"),
        "{text}"
    );
    assert_eq!(text.lines().count(), 1);
    assert_eq!(answer["jobs"], json!([]));
    let turns = lead_turns(&obid);
    assert_eq!(turns.len(), 1);
    assert!(
        turns[0]["refused"][0]
            .as_str()
            .unwrap()
            .starts_with("the board couldn't be read: "),
        "{}",
        turns[0]
    );
    assert!(calls(&obid).is_empty());
}

/// Two turns at once (the Mac and the iPhone) plan the same issues: one job starts on each.
/// (LeadTests.twoTurnsAtOnceStartOneJobOnAnIssue.)
#[test]
fn two_turns_at_once_start_one_job_on_an_issue() {
    let folder = Folder::new("lead-twice-at-once");
    let obid = started(&folder);
    board(
        &obid,
        &[Row(1, "Todo", &[], &[]), Row(2, "Todo", &[], &[])],
        json!([]),
    );
    let plan = format!("SLEEP 1 {}", start_jobs(&[1, 2]));
    queue(&obid, &[plan.clone(), plan]);
    let answers: Vec<Value> = std::thread::scope(|scope| {
        let turns: Vec<_> = (0..2)
            .map(|_| {
                scope.spawn(|| {
                    let body = json!({"said": "work on the roadmap", "new": true});
                    call(&obid, "POST", "/v1/plans", Some(&body)).body
                })
            })
            .collect();
        turns.into_iter().map(|t| t.join().unwrap()).collect()
    });
    assert_eq!(calls(&obid).len(), 2, "both turns planned");
    assert_eq!(jobs(&obid).len(), 2, "{answers:?}");
    let texts: Vec<&str> = answers
        .iter()
        .map(|a| a["text"].as_str().unwrap())
        .collect();
    assert!(
        texts
            .iter()
            .any(|t| t.contains("#1, #2 already have a job.")),
        "{texts:?}"
    );
}
