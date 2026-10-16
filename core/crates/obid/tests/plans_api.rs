//! The plan and conversation endpoints for #442.
mod support;

use std::path::{Path, PathBuf};

use serde_json::json;
use support::*;

fn planner() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-planner")
}

#[test]
fn plan_uses_recent_turns_and_conversation_paginates() {
    let folder = Folder::new("plans-api");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &planner());
    config["home"] = json!(folder.0.join("home"));
    let obid = start(&folder.0, &config, None);
    let events = follow_events(&obid);
    let answer = call(
        &obid,
        "POST",
        "/v1/plans",
        Some(&json!({
            "said": "and the vault one?",
            "turns": [
                {"who":"user", "text":"how is the inbox job going?"},
                {"who":"oby", "text":"Inbox is at its check."}
            ]
        })),
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    let conversation = answer.body["conversation"].clone();
    assert!(conversation.is_string(), "{}", answer.text);
    assert_eq!(
        answer.body,
        json!({"kind":"reply","text":"Fine.","jobs":[],"drafts":[],"conversation":conversation})
    );
    let prompt = std::fs::read_to_string(folder.0.join("env-home/plan-input")).unwrap();
    assert!(prompt.contains("User: how is the inbox job going?"));
    assert!(prompt.contains("Oby: Inbox is at its check."));
    assert!(prompt.contains("The user says now:\nand the vault one?"));
    let heard = events_named(&events, "turn", 10, |got| got.len() == 2);
    assert_eq!(heard[0]["who"], "user");
    assert_eq!(heard[0]["text"], "and the vault one?");
    assert_eq!(heard[1]["who"], "oby");
    assert_eq!(heard[1]["text"], "Fine.");
    assert!(
        heard
            .iter()
            .all(|event| event["jobs"].is_array() && event["at"].is_string())
    );

    let page = call(&obid, "GET", "/v1/conversation?limit=1", None);
    assert_eq!(page.status, 200, "{}", page.text);
    assert_eq!(page.body.as_array().unwrap().len(), 1);
    assert_eq!(page.body[0]["who"], "oby");
    let before = page.body[0]["id"].as_str().unwrap();
    let prior = call(
        &obid,
        "GET",
        &format!("/v1/conversation?before={before}&limit=1"),
        None,
    );
    assert_eq!(prior.status, 200, "{}", prior.text);
    assert_eq!(prior.body[0]["who"], "user");

    for turns in [
        json!([{"who":"robot", "text":"hello"}]),
        json!([{"who":"user", "text":" "}]),
        json!(std::iter::repeat_n(json!({"who":"user", "text":"x"}), 51).collect::<Vec<_>>()),
    ] {
        let refused = call(
            &obid,
            "POST",
            "/v1/plans",
            Some(&json!({"said":"hi", "turns": turns})),
        );
        assert_eq!(refused.status, 422, "{}", refused.text);
    }
    let malformed = call(
        &obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said":"hi", "turns":"no"})),
    );
    assert_eq!(malformed.status, 400, "{}", malformed.text);

    let oversized = call(&obid, "GET", "/v1/conversation?limit=9999", None);
    assert_eq!(oversized.status, 200);
    assert_eq!(oversized.body.as_array().unwrap().len(), 2);
    assert_eq!(
        call(&obid, "GET", "/v1/conversation?limit=0", None).status,
        422
    );
    assert_eq!(
        call(&obid, "GET", "/v1/conversation?before=nope", None).status,
        404
    );
}

#[test]
fn plans_map_replies_questions_none_and_dispatched_jobs() {
    let folder = Folder::new("plan-kinds");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    let obid = start(&folder.0, &config, Some(planner().parent().unwrap()));
    let post = |said: &str| call(&obid, "POST", "/v1/plans", Some(&json!({"said": said})));

    let reply = post("a normal reply");
    assert_eq!(reply.status, 200, "{}", reply.text);
    let conversation = reply.body["conversation"].clone();
    assert!(conversation.is_string(), "{}", reply.text);
    assert_eq!(
        reply.body,
        json!({"kind":"reply","text":"Fine.","jobs":[],"drafts":[],"conversation":conversation})
    );
    let question = post("question-case");
    assert_eq!(question.status, 200, "{}", question.text);
    assert_eq!(question.body["kind"], "question");
    assert_eq!(question.body["said"], "question-case");
    assert_eq!(question.body["question"]["text"], "Which repository?");
    assert_eq!(question.body["jobs"], json!([]));
    let none = post("none-case");
    assert_eq!(
        none.body,
        json!({"kind":"none","jobs":[],"drafts":[],"conversation":conversation})
    );

    let dispatch = post("fix oby #176 and #198");
    assert_eq!(dispatch.status, 200, "{}", dispatch.text);
    assert_eq!(dispatch.body["kind"], "reply", "{}", dispatch.text);
    let jobs = dispatch.body["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 2);
    assert_eq!(
        jobs[0]["files"],
        json!([
            "Engine/Accounts.swift",
            "Engine/Review.swift",
            "RunnerTests/"
        ])
    );
    assert_eq!(
        jobs[1]["files"],
        json!(["Engine/Review.swift", "Engine/CheckRuns.swift"])
    );
    assert_eq!(dispatch.body["drafts"], json!([]));
}

#[test]
fn plans_refuse_attachments_outside_the_apps_folder() {
    let folder = Folder::new("plan-attachments");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    let obid = start(&folder.0, &config, None);
    let answer = call(
        &obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said":"Look at this", "attachments":["/etc/hosts"]})),
    );
    assert_eq!(answer.status, 422, "{}", answer.text);
    assert!(
        answer
            .text
            .contains("isn't one of the files the Oby app attached")
    );
}

#[test]
fn conversation_turns_are_kept_between_runner_restarts() {
    let folder = Folder::new("conversation-kept");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    let obid = start(&folder.0, &config, None);
    let answer = call(&obid, "POST", "/v1/plans", Some(&json!({"said":"hello"})));
    assert_eq!(answer.status, 200, "{}", answer.text);
    let home = obid.home.clone();
    drop(obid);
    let restarted = start(&folder.0, &config, None);
    let turns = call(&restarted, "GET", "/v1/conversation", None);
    assert_eq!(turns.status, 200, "{}", turns.text);
    assert_eq!(turns.body.as_array().unwrap().len(), 2);
    assert_eq!(turns.body[0]["text"], "hello");
    assert_eq!(turns.body[1]["text"], "Fine.");
    let conversation = answer.body["conversation"].as_str().unwrap();
    assert!(
        home.join(format!("conversations/{conversation}.json"))
            .is_file()
    );
}

// ---------------------------------------------------------------------------------------------
// The brain (#546): the plan, its checks, retries and fallbacks.

/// The fake planner's own folder: its account's (`configDir`), where it keeps its queue of
/// plans and what each call got.
fn brain(obid: &Obid) -> PathBuf {
    obid.home.join("accounts/stub")
}

/// What the fake planner answers next, one line per call.
fn queue(obid: &Obid, lines: &[String]) {
    std::fs::create_dir_all(brain(obid)).unwrap();
    std::fs::write(brain(obid).join("plans"), lines.join("\n") + "\n").unwrap();
}

/// Each call the brain got, in order: its folder of `args`, `input`, `pwd` and `work.md`.
fn calls(obid: &Obid) -> Vec<PathBuf> {
    let mut calls: Vec<(u32, PathBuf)> = std::fs::read_dir(brain(obid).join("calls"))
        .map(|dir| {
            dir.flatten()
                .filter_map(|e| Some((e.file_name().to_str()?.parse().ok()?, e.path())))
                .collect()
        })
        .unwrap_or_default();
    calls.sort();
    calls.into_iter().map(|(_, path)| path).collect()
}

fn read(path: PathBuf) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

/// The brain's turns, as obid keeps them.
fn records(obid: &Obid) -> Vec<serde_json::Value> {
    read(obid.home.join("brain-turns.jsonl"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn reply(text: &str) -> String {
    json!({"action": "reply_only", "reply": text, "dispatches": [], "question": null, "jobs": []})
        .to_string()
}

fn started(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    start(&folder.0, &config, Some(planner().parent().unwrap()))
}

fn said(obid: &Obid, words: &str) -> serde_json::Value {
    let answer = call(obid, "POST", "/v1/plans", Some(&json!({"said": words})));
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

/// BrainRetryTests.emptyExit15RecoversBeforeRulesPlan: one transient failure recovers on the
/// one retry.
#[test]
fn an_empty_exit_15_recovers_before_rules_plan() {
    let folder = Folder::new("brain-exit-15");
    let obid = started(&folder);
    queue(&obid, &["EXIT 15".into(), reply("Ready")]);
    assert_eq!(said(&obid, "hello")["text"], "Ready");
    assert_eq!(calls(&obid).len(), 2);
    let record = records(&obid).pop().unwrap();
    assert_eq!(record["by"], "claude");
    assert_eq!(record["refused"], json!([]));
}

/// BrainRetryTests.exhaustedRetriesKeepExitAndStderrInFallbackEvidence
#[test]
fn exhausted_retries_keep_exit_and_stderr_in_fallback_evidence() {
    let folder = Folder::new("brain-exhausted");
    let obid = started(&folder);
    queue(
        &obid,
        &["EXIT 15 failure 1".into(), "EXIT 15 failure 2".into()],
    );
    // Rules stand in: "hello" names no repository, so they ask.
    let answer = said(&obid, "hello");
    assert_eq!(answer["kind"], "question", "{answer}");
    assert_eq!(answer["question"]["text"], "Which repository?");
    assert_eq!(calls(&obid).len(), 2);
    let record = records(&obid).pop().unwrap();
    assert_eq!(record["by"], "rules");
    let refused = record["refused"].as_array().unwrap();
    assert_eq!(refused.len(), 1, "{refused:?}");
    for attempt in 1..=2 {
        let evidence = format!("attempt {attempt}: exit code 15, stderr: failure {attempt}");
        assert!(
            refused[0].as_str().unwrap().contains(&evidence),
            "{refused:?}"
        );
    }
}

/// BrainRetryTests.retriesAreLimitedToTransientEmptyFailures: an empty answer is tried again
/// once; an answer that says something else isn't.
#[test]
fn retries_are_limited_to_transient_empty_failures() {
    let folder = Folder::new("brain-retries");
    let obid = started(&folder);
    queue(&obid, &["EXIT 0".into(), "EXIT 0".into()]);
    assert_eq!(said(&obid, "hello")["kind"], "question");
    assert_eq!(calls(&obid).len(), 2);
    let refused = records(&obid).pop().unwrap()["refused"].to_string();
    assert!(
        refused.contains("attempt 2: empty, stderr: <empty>"),
        "{refused}"
    );

    queue(
        &obid,
        &["FAIL 1 Please sign in".into(), reply("Never asked.")],
    );
    assert_eq!(said(&obid, "hello")["kind"], "question");
    assert_eq!(calls(&obid).len(), 3);
    let refused = records(&obid).pop().unwrap()["refused"].to_string();
    assert!(
        refused.contains("attempt 1: exit code 1, stderr: <empty>"),
        "{refused}"
    );
    assert!(!refused.contains("attempt 2"), "{refused}");
}

/// #546's acceptance: a plan naming an unknown job is refused, retried with the reason, and the
/// second plan is used.
#[test]
fn a_plan_naming_an_unknown_job_is_refused_and_retried_with_the_reason() {
    let folder = Folder::new("brain-refused");
    let obid = started(&folder);
    let stop = json!({"action": "stop_agent", "reply": "", "dispatches": [], "question": null,
                      "jobs": ["zz"], "all": false});
    queue(
        &obid,
        &[stop.to_string(), reply("Nothing of that name runs.")],
    );
    assert_eq!(
        said(&obid, "stop the zz job")["text"],
        "Nothing of that name runs."
    );
    let calls = calls(&obid);
    assert_eq!(calls.len(), 2);
    assert!(!read(calls[0].join("input")).contains("Your last plan was refused"));
    assert!(
        read(calls[1].join("input"))
            .trim_end()
            .ends_with("Your last plan was refused: zz isn't a job Oby can stop. Make a new one."),
        "{}",
        read(calls[1].join("input"))
    );
    let record = records(&obid).pop().unwrap();
    assert_eq!(record["by"], "claude");
    assert!(
        record["refused"][0]
            .as_str()
            .unwrap()
            .starts_with("claude plan refused (zz isn't a job Oby can stop): {"),
        "{record}"
    );
}

/// BrainSteadyTests, through the process: quick questions think with Haiku, long requests with
/// Sonnet, and with nothing to read the brain has no tool at all.
#[test]
fn the_brain_thinks_with_haiku_and_long_requests_with_sonnet() {
    let folder = Folder::new("brain-models");
    let obid = started(&folder);
    said(&obid, "how is it going?");
    said(&obid, &"x".repeat(700));
    let calls = calls(&obid);
    let first = read(calls[0].join("args"));
    assert!(first.contains("--model\nclaude-haiku-5-5\n"), "{first}");
    assert!(
        first.contains("--tools\n\n--strict-mcp-config\n"),
        "{first}"
    );
    assert!(!first.contains("--max-turns"), "{first}");
    assert!(read(calls[1].join("args")).contains("--model\nclaude-sonnet-5-5\n"));
}

/// Codex plans when Claude can't, with the same schema and checks.
#[test]
fn codex_plans_when_claude_cannot() {
    let folder = Folder::new("brain-codex");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &planner());
    let agents = planner().parent().unwrap().to_path_buf();
    config["agents"]["codex"] = json!({"bin": agents.join("fake-codex"), "accounts": []});
    let obid = start(&folder.0, &config, Some(&agents));
    queue(&obid, &["EXIT 15".into(), "EXIT 15".into()]);
    assert_eq!(said(&obid, "how is it going?")["text"], "From Codex.");
    let record = records(&obid).pop().unwrap();
    assert_eq!(record["by"], "codex");
    assert!(
        record["refused"][0]
            .as_str()
            .unwrap()
            .starts_with("claude failed: claude returned no plan after retry")
    );
}

// ---------------------------------------------------------------------------------------------
// The briefing (#546, step 2): what the brain is told before the user's words.

/// A job whose agent works until it's stopped, titled `title`, running.
fn running(obid: &Obid, title: &str) -> serde_json::Value {
    let answer = call(
        obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate",
                             "task": "SLEEP", "title": title}}),
        ),
    );
    assert!(
        answer.status == 200 || answer.status == 201,
        "{}",
        answer.text
    );
    let id = answer.body["id"].as_str().unwrap().to_owned();
    within(30, "the job runs", || {
        let job = call(obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["status"] == "running" && !job["step"].as_str().unwrap_or("").is_empty())
            .then_some(job)
    })
}

fn host(obid: &Obid) -> String {
    call(obid, "GET", "/v1/status", None).body["runner"]["host"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn stop_plan(ids: &[&str]) -> String {
    json!({"action": "stop_agent", "reply": "", "dispatches": [], "question": null,
           "jobs": ids, "all": ids.is_empty()})
    .to_string()
}

/// ConversationTests.theBrainReadsTheConversationAndMayStopOneJob, and #546's acceptance: "how
/// are the jobs going?" with a running job is told about it, and "cancel it" right after stops it.
#[test]
fn the_brain_reads_the_conversation_and_may_stop_one_job() {
    let folder = Folder::new("brain-briefing");
    let obid = started(&folder);
    let job = running(&obid, "Vault secrets");
    let id = job["id"].as_str().unwrap();
    let step = job["step"].as_str().unwrap();
    queue(
        &obid,
        &[
            reply("Vault secrets is running its tests."),
            stop_plan(&[id]),
        ],
    );
    let first = said(&obid, "how are the jobs going?");
    assert_eq!(first["text"], "Vault secrets is running its tests.");
    let calls = calls(&obid);
    let input = read(calls[0].join("input"));
    assert!(input.starts_with("# What Oby knows right now"), "{input}");
    assert!(input.contains("## The conversation so far\n\n(Nothing yet.)"));
    assert!(input.contains(&format!(
        "{id} · Vault secrets · obi-e2e/fixture-app · Claude Code · Stub · running on {}",
        host(&obid)
    )));
    assert!(
        input
            .trim_end()
            .ends_with("The user says now:\nhow are the jobs going?")
    );
    // The agent's step is in the quoted file the brain may read, never in the prompt; with it,
    // the brain has Read and nothing else, and room to read and answer (#535).
    assert!(!input.contains(step), "{input}");
    let quoted = read(calls[0].join("work.md"));
    assert!(
        quoted.contains(&format!("## Job {id} (Vault secrets)\nStep now: {step}")),
        "{quoted}"
    );
    let args = read(calls[0].join("args"));
    assert!(
        args.contains("--tools\nRead\n--allowedTools\nRead\n--max-turns\n6\n"),
        "{args}"
    );
    assert!(args.contains("quoted in the file work.md"));
    // It thought in a folder of its own, gone since.
    let pwd = PathBuf::from(read(calls[0].join("pwd")).trim());
    assert!(
        pwd.starts_with(obid.home.join("plans")),
        "{}",
        pwd.display()
    );
    assert!(!pwd.exists());

    let second = said(&obid, "cancel it");
    assert_eq!(second["text"], "Stopped Vault secrets.");
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "stopped");
    let again = read(calls_after(&obid, 1).join("input"));
    assert!(
        again.contains("User: how are the jobs going?\nOby: Vault secrets is running its tests.\n"),
        "{again}"
    );
}

/// The `n`th call (from 0), however many there are now.
fn calls_after(obid: &Obid, n: usize) -> PathBuf {
    calls(obid)[n].clone()
}

/// ConversationTests.theReplyNeverContradictsTheHeaderAboutRunningJobs: with an agent working,
/// Oby never says nothing is running; it says what the header counts.
#[test]
fn the_reply_never_contradicts_the_header_about_running_jobs() {
    let folder = Folder::new("brain-header");
    let obid = started(&folder);
    let job = running(&obid, "Vault secrets");
    let id = job["id"].as_str().unwrap();
    let host = host(&obid);
    queue(
        &obid,
        &[
            reply("No jobs are running right now."),
            reply("No jobs failed; Vault secrets is still running."),
            reply("No jobs are running right now."),
        ],
    );
    let line = format!("1 agent is working: Vault secrets on {host}.");
    assert_eq!(said(&obid, "anything running?")["text"], line.as_str());
    let input = read(calls(&obid)[0].join("input"));
    assert!(input.contains(&format!("Working now: {line}")), "{input}");
    assert!(read(calls(&obid)[0].join("args")).contains("never say that nothing is running"));
    // Other replies pass as they are, and so does this one once nothing runs.
    assert_eq!(
        said(&obid, "did anything fail?")["text"],
        "No jobs failed; Vault secrets is still running."
    );
    assert_eq!(
        call(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None).status,
        200
    );
    assert_eq!(
        said(&obid, "anything running?")["text"],
        "No jobs are running right now."
    );
    assert!(
        read(calls(&obid)[2].join("input")).contains("Working now: No agent is working right now.")
    );
}

/// #505: a conversation of 60 turns sends the brain turns 11 to 60 only.
#[test]
fn a_conversation_of_60_turns_sends_the_last_50() {
    let folder = Folder::new("brain-505");
    let obid = started(&folder);
    let conversation = said(&obid, "turn 1")["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    for n in (3..60).step_by(2) {
        let answer = call(
            &obid,
            "POST",
            "/v1/plans",
            Some(&json!({"said": format!("turn {n}"), "conversation": conversation})),
        );
        assert_eq!(answer.status, 200, "{}", answer.text);
    }
    let page = call(
        &obid,
        "GET",
        &format!("/v1/conversation?id={conversation}&limit=500"),
        None,
    );
    assert_eq!(page.body.as_array().unwrap().len(), 60);
    said(&obid, "and now?");
    let input = read(calls(&obid).last().unwrap().join("input"));
    let told: Vec<&str> = input
        .lines()
        .filter(|l| l.starts_with("User: ") || l.starts_with("Oby: "))
        .collect();
    assert_eq!(told.len(), 50, "{input}");
    assert_eq!(told[0], "User: turn 11");
    assert_eq!(told[49], "Oby: Fine.");
}

/// The brain that may read its quoted file is boxed like a job: obid's own files (its token
/// here) are hidden from it. Without a file to read it has no tool at all, and isn't boxed, so
/// the same peek reads the token: the box is what hides it.
#[test]
fn a_brain_that_may_read_is_boxed() {
    let folder = Folder::new("brain-boxed");
    let obid = started(&folder);
    let token = obid.home.join("api-token");
    let peek = format!("PEEK {}", token.display());
    queue(&obid, std::slice::from_ref(&peek));
    assert_eq!(said(&obid, "anything to read?")["text"], "read");
    running(&obid, "Vault secrets");
    queue(&obid, &[peek]);
    assert_eq!(said(&obid, "anything to read?")["text"], "hidden");
    assert!(read(calls(&obid)[1].join("args")).contains("--allowedTools\nRead\n"));
}
