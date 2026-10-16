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
            reply(""),
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

// ---------------------------------------------------------------------------------------------
// The loop (#546, step 3): several actions in one turn, their step events, Stop and cancel.

fn set_mode(id: &str, mode: &str) -> String {
    json!({"action": "set_mode", "reply": "", "dispatches": [], "question": null,
           "jobs": [id], "mode": mode})
    .to_string()
}

/// "1:set_mode:running", for comparing step events.
fn steps(events: &[serde_json::Value]) -> Vec<String> {
    events
        .iter()
        .map(|e| {
            format!(
                "{}:{}:{}",
                e["index"],
                e["action"].as_str().unwrap(),
                e["state"].as_str().unwrap()
            )
        })
        .collect()
}

/// ConversationStepsTests.aTwoStepTurnSendsEachRunningAndDoneEventInOrder, and #546's acceptance:
/// the events show each step running, then done, in order; the brain hears what it did.
#[test]
fn a_two_step_turn_sends_each_running_and_done_event_in_order() {
    let folder = Folder::new("brain-two-steps");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let events = follow_events(&obid);
    queue(
        &obid,
        &[
            set_mode(&id, "ask"),
            set_mode(&id, "acceptEdits"),
            reply("Done."),
        ],
    );
    let answer = said(&obid, "change the mode twice");
    assert_eq!(
        answer["text"],
        "Vault secrets is in Ask mode now. Vault secrets is in Accept edits mode now. Done."
    );
    let heard = events_named(&events, "step", 10, |got| got.len() == 4);
    assert_eq!(
        steps(&heard),
        [
            "1:set_mode:running",
            "1:set_mode:done",
            "2:set_mode:running",
            "2:set_mode:done"
        ]
    );
    let turn = turn_of(&obid, "change the mode twice");
    assert!(
        heard
            .iter()
            .all(|e| e["turn"] == turn.as_str() && e["text"] == "Changing permission mode")
    );
    assert!(heard.iter().all(|e| e["at"].is_string()));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["mode"], "acceptEdits");
    // Each later step tells the brain what was done, and thinks with Sonnet.
    let calls = calls(&obid);
    assert_eq!(calls.len(), 3);
    let second = read(calls[1].join("input"));
    assert!(second.contains("The user says now:\nchange the mode twice\n\n(Oby already did this for the request, step by step: Vault secrets is in Ask mode now.\n"), "{second}");
    assert!(read(calls[1].join("args")).contains("--model\nclaude-sonnet-5-5\n"));
}

/// The id of the user's turn that said `words`.
fn turn_of(obid: &Obid, words: &str) -> String {
    call(obid, "GET", "/v1/conversation?limit=500", None)
        .body
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["who"] == "user" && t["text"] == words)
        .map(|t| t["id"].as_str().unwrap().to_owned())
        .unwrap()
}

/// The same action twice in one turn is done once: the brain only repeated itself.
#[test]
fn a_repeated_action_ends_the_turn() {
    let folder = Folder::new("brain-repeat");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    queue(
        &obid,
        &[
            set_mode(&id, "ask"),
            set_mode(&id, "ask"),
            reply("Never heard."),
        ],
    );
    assert_eq!(
        said(&obid, "ask me before anything")["text"],
        "Vault secrets is in Ask mode now."
    );
    assert_eq!(calls(&obid).len(), 2);
}

/// ConversationStepsTests.stoppingAfterTheFirstStepDoesNotStartAnotherAction, and #546's
/// acceptance: a stop after step one starts nothing more, and the answer says what was done.
#[test]
fn stopping_after_the_first_step_does_not_start_another_action() {
    let folder = Folder::new("brain-stop-steps");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let events = follow_events(&obid);
    queue(
        &obid,
        &[
            set_mode(&id, "ask"),
            format!("SLEEP 2 {}", set_mode(&id, "acceptEdits")),
        ],
    );
    let answer = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "change the mode, then change it again"));
        let first = events_named(&events, "step", 10, |got| got.len() == 2);
        assert_eq!(steps(&first), ["1:set_mode:running", "1:set_mode:done"]);
        let stopped = call(&obid, "POST", "/v1/conversation/stop", None);
        assert_eq!(stopped.body, json!({"stopped": true}));
        asking.join().unwrap()
    });
    assert_eq!(answer["text"], "Vault secrets is in Ask mode now.");
    std::thread::sleep(std::time::Duration::from_millis(500));
    assert!(events.try_iter().all(|(name, _)| name != "step"));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["mode"], "ask");
    let turns = call(&obid, "GET", "/v1/conversation", None).body;
    assert_eq!(
        turns.as_array().unwrap().last().unwrap()["text"],
        "Vault secrets is in Ask mode now."
    );
}

/// BrainRetryTests.cancellationDoesNotRestartClaude: a turn stopped while Claude failed isn't
/// tried again.
#[test]
fn a_stop_does_not_restart_claude() {
    let folder = Folder::new("brain-stop-retry");
    let obid = started(&folder);
    queue(&obid, &["SLEEP 1 EXIT 15".into(), reply("Never.")]);
    let answer = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "hello"));
        within(5, "the brain is asked", || {
            (calls(&obid).len() == 1).then_some(())
        });
        call(&obid, "POST", "/v1/conversation/stop", None);
        asking.join().unwrap()
    });
    assert_eq!(answer["kind"], "none", "{answer}");
    std::thread::sleep(std::time::Duration::from_millis(500));
    assert_eq!(calls(&obid).len(), 1);
    let refused = records(&obid).pop().unwrap()["refused"].to_string();
    assert!(
        refused.contains("claude stopped: the turn ended"),
        "{refused}"
    );
}

/// ConversationTests.aCancelledTurnStopsNothing: cancelled while the brain thought, its plan (a
/// stop) does nothing when it comes, and the turn is kept with why.
#[test]
fn a_cancelled_turn_stops_nothing() {
    let folder = Folder::new("brain-cancelled");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    queue(&obid, &[format!("SLEEP 1 {}", stop_plan(&[&id]))]);
    let answer = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "cancel the vault job"));
        within(5, "the brain is asked", || {
            (calls(&obid).len() == 1).then_some(())
        });
        let cancelled = call(&obid, "POST", "/v1/plans/cancel", None);
        assert_eq!(cancelled.body, json!({"cancelled": true}));
        asking.join().unwrap()
    });
    assert_eq!(answer["kind"], "none", "{answer}");
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "running");
    assert_eq!(
        records(&obid).pop().unwrap()["refused"]
            .as_array()
            .unwrap()
            .last()
            .unwrap(),
        "the turn was cancelled before the plan came: nothing done"
    );
}

/// ConversationTests.aReplacedTurnStopsNothing: new words in the same conversation replace the
/// turn under way; its plan does nothing, and the new one answers.
#[test]
fn a_replaced_turn_stops_nothing() {
    let folder = Folder::new("brain-replaced");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    queue(
        &obid,
        &[
            format!("SLEEP 1 {}", stop_plan(&[&id])),
            reply("Still running."),
        ],
    );
    let (first, second) = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "cancel the vault job"));
        within(5, "the brain is asked", || {
            (calls(&obid).len() == 1).then_some(())
        });
        let second = said(&obid, "how is it going?");
        (asking.join().unwrap(), second)
    });
    assert_eq!(second["text"], "Still running.");
    assert_eq!(first["kind"], "none", "{first}");
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "running");
}

/// ConversationTests.neverMindAndStopEndTheTurnAndStopNoJob: a bare "never mind" or "stop" never
/// reaches the brain and stops no job; with a turn under way, it stops that turn.
#[test]
fn never_mind_and_stop_end_the_turn_and_stop_no_job() {
    let folder = Folder::new("brain-never-mind");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    for words in ["stop", "Cancel.", "never mind"] {
        let answer = said(&obid, words);
        assert_eq!(answer["kind"], "none", "{words}: {answer}");
    }
    assert!(calls(&obid).is_empty());
    assert_eq!(call(&obid, "GET", "/v1/conversation", None).body, json!([]));
    queue(&obid, &[format!("SLEEP 1 {}", stop_plan(&[&id]))]);
    let answer = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "stop the vault job"));
        within(5, "the brain is asked", || {
            (calls(&obid).len() == 1).then_some(())
        });
        assert_eq!(said(&obid, "never mind")["kind"], "none");
        asking.join().unwrap()
    });
    assert_eq!(answer["kind"], "none", "{answer}");
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "running");
    assert_eq!(calls(&obid).len(), 1);
}

/// StopTests.stopAgentStopsRunningAndQueuedJobs and oneJobIsOneJob: "stop everything" stops every
/// job, running or queued, and says how many.
#[test]
fn stop_everything_stops_running_and_queued_jobs() {
    let folder = Folder::new("brain-stop-all");
    let obid = started(&folder);
    let settings = call(
        &obid,
        "PUT",
        "/v1/settings/jobs",
        Some(&json!({"maxRunning": 1})),
    );
    assert_eq!(settings.status, 200, "{}", settings.text);
    let first = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let queued = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(&json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP", "title": "Watch home"}})),
    )
    .body["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{queued}"), None).body["status"],
        "queued"
    );
    // The brain plans the stop twice: the second is the same action, so the turn ends.
    queue(&obid, &[stop_plan(&[]), stop_plan(&[])]);
    assert_eq!(said(&obid, "stop everything")["text"], "Stopped 2 jobs.");
    for id in [&first, &queued] {
        assert_eq!(
            call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["status"],
            "stopped"
        );
    }
    // Nothing runs: the brain may still say stop everything, and hears so.
    queue(&obid, &[stop_plan(&[]), reply("")]);
    assert_eq!(
        said(&obid, "stop everything")["text"],
        "Nothing is running."
    );
    // One job is one job.
    running(&obid, "Watch home");
    queue(&obid, &[stop_plan(&[]), reply("")]);
    assert_eq!(said(&obid, "stop everything")["text"], "Stopped 1 job.");
}

/// #538: an action that couldn't happen ends the turn, and its step is `failed`: decided from
/// the action's outcome, never from how its words begin.
#[test]
fn a_failed_action_ends_the_turn_and_its_step_fails() {
    let folder = Folder::new("brain-failed-step");
    let obid = started(&folder);
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let events = follow_events(&obid);
    let move_it = json!({"action": "move_job", "reply": "", "dispatches": [], "question": null,
                         "jobs": [id], "move": {"agent": "claude", "account": "auto", "model": "claude-opus-5-5"}});
    queue(&obid, &[move_it.to_string(), reply("Never heard.")]);
    let answer = said(&obid, "use Opus for the vault job");
    let heard = events_named(&events, "step", 10, |got| got.len() == 2);
    assert_eq!(steps(&heard), ["1:move_job:running", "1:move_job:failed"]);
    assert_eq!(heard[0]["text"], "Moving Vault secrets to Claude Code");
    assert!(
        answer["text"].as_str().unwrap().contains("obid can't"),
        "{answer}"
    );
    assert_eq!(calls(&obid).len(), 1);
}

/// The turn's budget bounds the planning too (review on #551): a plan that comes after it is
/// kept as refused and does nothing, and the answer says the turn ran out of time.
#[test]
fn a_plan_that_comes_after_the_turn_budget_does_nothing() {
    let folder = Folder::new("brain-late-plan");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &planner());
    config["turnBudget"] = json!(2);
    let obid = start(&folder.0, &config, Some(planner().parent().unwrap()));
    let id = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    // Claude's attempt and its one retry are both slow: the stop comes after the budget.
    let late = format!("SLEEP 3 {}", stop_plan(&[&id]));
    queue(&obid, &[late.clone(), late]);
    let started = std::time::Instant::now();
    let answer = said(&obid, "stop the vault job");
    // The planner itself kept to the budget: it didn't wait for the slow brain.
    assert!(
        started.elapsed() < std::time::Duration::from_secs(3),
        "{:?}",
        started.elapsed()
    );
    assert_eq!(
        answer["text"], "That's as far as Oby got in one go: say “continue” for the rest.",
        "{answer}"
    );
    std::thread::sleep(std::time::Duration::from_millis(1500));
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["status"], "running");
    let refused = records(&obid).pop().unwrap()["refused"].to_string();
    assert!(
        refused.contains("the plan came after the turn's budget: nothing done"),
        "{refused}"
    );
}

// ---------------------------------------------------------------------------------------------
// What persists or widens trust waits for the owner's own Confirm (#546, the owner's decision of
// 2026-10-16): the brain never does it itself, however it was talked into it.

/// A job from `POST /v1/jobs` in `mode`, running `task`.
fn job_in(obid: &Obid, title: &str, task: &str, mode: &str) -> String {
    let answer = call(
        obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": task,
                             "title": title, "mode": mode}}),
        ),
    );
    assert!(
        answer.status == 200 || answer.status == 201,
        "{}",
        answer.text
    );
    answer.body["id"].as_str().unwrap().to_owned()
}

/// The open inbox items of `kind`.
fn items_of(obid: &Obid, kind: &str) -> Vec<serde_json::Value> {
    call(obid, "GET", "/v1/inbox", None)
        .body
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["kind"] == kind)
        .cloned()
        .collect()
}

/// The owner's own answer, with the API token.
fn owner_answers(obid: &Obid, item: &str, answer: &str) -> Answer {
    call(
        obid,
        "POST",
        &format!("/v1/inbox/{item}/answer"),
        Some(&json!({"answer": answer})),
    )
}

/// answer_permission with always saves no rule: a confirm item waits, and the owner's Confirm
/// saves the rule and answers the agent.
#[test]
fn always_allowing_waits_for_the_owners_confirm() {
    let folder = Folder::new("brain-confirm-always");
    let obid = started(&folder);
    let id = job_in(
        &obid,
        "Vault secrets",
        r#"ASKS: [{"tool": "Bash", "input": {"command": "make lint"}}]"#,
        "ask",
    );
    within(30, "a permission waits", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        job["permission"].is_object().then_some(())
    });
    let always = json!({"action": "answer_permission", "reply": "", "dispatches": [], "question": null,
                        "jobs": [id], "decision": "always", "message": null});
    queue(&obid, &[always.to_string(), reply("")]);
    let answer = said(&obid, "how is the vault job going?");
    assert!(
        answer["text"]
            .as_str()
            .unwrap()
            .contains("confirm it in your inbox"),
        "{answer}"
    );
    // Nothing changed: no rule, the agent still waits.
    assert_eq!(
        call(&obid, "GET", "/v1/permissions/rules", None).body,
        json!([])
    );
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert!(job["permission"].is_object(), "{job}");
    let confirms = items_of(&obid, "confirm");
    assert_eq!(confirms.len(), 1, "{confirms:?}");
    assert_eq!(confirms[0]["options"], json!(["Confirm", "Cancel"]));
    assert_eq!(
        confirms[0]["title"],
        "Always allow Bash(make lint:*) in obi-e2e/fixture-app"
    );
    let permission = job["permission"]["id"].as_str().unwrap();
    assert_eq!(
        confirms[0]["confirm"],
        json!({"action": "always_allow", "target": id, "payload": {"permission": permission}})
    );
    // The owner's own Confirm does it.
    let confirmed = owner_answers(&obid, confirms[0]["id"].as_str().unwrap(), "Confirm");
    assert_eq!(confirmed.status, 200, "{}", confirmed.text);
    let rules = call(&obid, "GET", "/v1/permissions/rules", None).body;
    assert_eq!(rules.as_array().unwrap().len(), 1, "{rules}");
    assert_eq!(rules[0]["rule"], "Bash(make lint:*)");
    assert!(
        items_of(&obid, "confirm").is_empty(),
        "closed once confirmed"
    );
    within(30, "the agent hears it", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["status"] == "done").then_some(())
    });
}

/// set_mode bypass leaves the mode as it is: a confirm item waits, and the owner's Confirm sets
/// it. Other modes are set at once.
#[test]
fn bypass_mode_waits_for_the_owners_confirm() {
    let folder = Folder::new("brain-confirm-bypass");
    let obid = started(&folder);
    let id = job_in(&obid, "Vault secrets", "SLEEP", "ask");
    within(30, "the job runs", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["status"] == "running").then_some(())
    });
    let mode = |mode: &str| {
        json!({"action": "set_mode", "reply": "", "dispatches": [], "question": null,
               "jobs": [id], "mode": mode})
        .to_string()
    };
    queue(&obid, &[mode("bypass"), reply("")]);
    let answer = said(&obid, "stop asking on the vault job");
    assert!(
        answer["text"]
            .as_str()
            .unwrap()
            .contains("confirm it in your inbox"),
        "{answer}"
    );
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(job["mode"], "ask");
    let confirms = items_of(&obid, "confirm");
    assert_eq!(confirms.len(), 1, "{confirms:?}");
    assert_eq!(
        confirms[0]["title"],
        "Stop asking on Vault secrets: Bypass mode"
    );
    assert_eq!(
        confirms[0]["confirm"],
        json!({"action": "set_mode_bypass", "target": id, "payload": null})
    );
    // Cancel does nothing; a second card's Confirm does it.
    assert_eq!(
        owner_answers(&obid, confirms[0]["id"].as_str().unwrap(), "Cancel").status,
        200
    );
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["mode"],
        "ask"
    );
    queue(&obid, &[mode("bypass"), reply("")]);
    said(&obid, "stop asking on the vault job");
    let confirm = items_of(&obid, "confirm").pop().unwrap();
    assert_eq!(
        owner_answers(&obid, confirm["id"].as_str().unwrap(), "Confirm").status,
        200
    );
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body["mode"],
        "bypass"
    );
    assert!(
        items_of(&obid, "confirm").is_empty(),
        "closed once confirmed"
    );
    // The other modes are done in the turn.
    queue(&obid, &[mode("plan"), reply("")]);
    assert_eq!(
        said(&obid, "plan first on the vault job")["text"],
        "Vault secrets is in Plan mode now."
    );
}

/// Stop and cancel reach the turn under way in one conversation, not the others (review on #551).
#[test]
fn stop_reaches_only_its_own_conversation() {
    let folder = Folder::new("brain-stop-scope");
    let obid = started(&folder);
    queue(
        &obid,
        &[
            format!("SLEEP 2 {}", reply("First.")),
            format!("SLEEP 2 {}", reply("Second.")),
        ],
    );
    let (first, second) = std::thread::scope(|scope| {
        let first = scope.spawn(|| {
            call(
                &obid,
                "POST",
                "/v1/plans",
                Some(&json!({"said": "one", "new": true})),
            )
            .body
        });
        within(5, "the first turn thinks", || {
            (calls(&obid).len() == 1).then_some(())
        });
        let second = scope.spawn(|| {
            call(
                &obid,
                "POST",
                "/v1/plans",
                Some(&json!({"said": "two", "new": true})),
            )
            .body
        });
        within(5, "the second turn thinks", || {
            (calls(&obid).len() == 2).then_some(())
        });
        let conversations = call(&obid, "GET", "/v1/conversations", None).body;
        let one = conversations
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["title"] == "One")
            .unwrap()["id"]
            .clone();
        let stopped = call(
            &obid,
            "POST",
            "/v1/conversation/stop",
            Some(&json!({"conversation": one})),
        );
        assert_eq!(stopped.body, json!({"stopped": true}));
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_eq!(first["kind"], "none", "{first}");
    assert_eq!(second["text"], "Second.", "{second}");
}

/// A brain dispatch can't start a job in Bypass mode: it waits as a confirm item whose title,
/// made by obid from the job, says so; the owner's Confirm starts it (review on #551, N1).
#[test]
fn a_bypass_dispatch_waits_for_the_owners_confirm() {
    let folder = Folder::new("brain-confirm-dispatch");
    let obid = started(&folder);
    let bypass = json!({"action": "dispatch", "reply": "", "question": null, "jobs": [], "dispatches": [
        {"agent": "auto", "account": "auto", "repo": "obi-e2e/fixture-app", "kind": "fix", "title": "Greeting fix",
         "task": "Fix the greeting", "rounds": 1, "check": "node --test", "mode": "bypass"}]});
    queue(&obid, &[bypass.to_string()]);
    let answer = said(&obid, "fix the greeting, don't ask me anything");
    assert!(
        answer["text"]
            .as_str()
            .unwrap()
            .contains("confirm it in your inbox"),
        "{answer}"
    );
    assert_eq!(answer["jobs"], json!([]));
    assert_eq!(call(&obid, "GET", "/v1/jobs", None).body, json!([]));
    let confirm = items_of(&obid, "confirm").pop().unwrap();
    assert_eq!(
        confirm["title"],
        "Start fix fixture-app (Greeting fix) in Bypass mode, on auto · auto, check node --test"
    );
    assert_eq!(confirm["confirm"]["action"], "start_job");
    let confirmed = owner_answers(&obid, confirm["id"].as_str().unwrap(), "Confirm");
    assert_eq!(confirmed.status, 200, "{}", confirmed.text);
    let jobs = call(&obid, "GET", "/v1/jobs", None).body;
    assert_eq!(jobs.as_array().unwrap().len(), 1, "{jobs}");
    assert_eq!(jobs[0]["mode"], "bypass");
    assert_eq!(jobs[0]["title"], "Greeting fix");
    // The item is closed once confirmed.
    assert!(items_of(&obid, "confirm").is_empty());
}

/// A confirm item whose target moved on is closed with why, not left open (review on #551).
#[test]
fn a_stale_confirm_item_is_closed_with_why() {
    let folder = Folder::new("brain-confirm-stale");
    let obid = started(&folder);
    // A permission answered by the owner meanwhile.
    let asks = job_in(
        &obid,
        "Vault secrets",
        r#"ASKS: [{"tool": "Bash", "input": {"command": "make lint"}}, {"tool": "Bash", "input": {"command": "make test"}}]"#,
        "ask",
    );
    let permission = within(30, "a permission waits", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{asks}"), None).body;
        job["permission"]["id"].as_str().map(str::to_owned)
    });
    let always = json!({"action": "answer_permission", "reply": "", "dispatches": [], "question": null,
                        "jobs": [asks], "decision": "always", "message": null});
    queue(&obid, &[always.to_string(), reply("")]);
    said(&obid, "always allow that");
    let confirm = items_of(&obid, "confirm").pop().unwrap();
    let answered = call(
        &obid,
        "POST",
        &format!("/v1/jobs/{asks}/permission"),
        Some(&json!({"id": permission, "decision": "allow"})),
    );
    assert_eq!(answered.status, 200, "{}", answered.text);
    let late = owner_answers(&obid, confirm["id"].as_str().unwrap(), "Confirm");
    assert_eq!(late.status, 409, "{}", late.text);
    assert!(
        items_of(&obid, "confirm").is_empty(),
        "the stale item stays open"
    );
    assert_eq!(
        call(&obid, "GET", "/v1/permissions/rules", None).body,
        json!([])
    );

    // Bypass for a job that stopped meanwhile.
    let sleeping = job_in(&obid, "Watch home", "SLEEP", "ask");
    within(30, "the job runs", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{sleeping}"), None).body;
        (job["status"] == "running").then_some(())
    });
    let bypass = json!({"action": "set_mode", "reply": "", "dispatches": [], "question": null,
                        "jobs": [sleeping], "mode": "bypass"});
    queue(&obid, &[bypass.to_string(), reply("")]);
    said(&obid, "stop asking on the watch job");
    let confirm = items_of(&obid, "confirm").pop().unwrap();
    assert_eq!(
        call(&obid, "POST", &format!("/v1/jobs/{sleeping}/stop"), None).status,
        200
    );
    let late = owner_answers(&obid, confirm["id"].as_str().unwrap(), "Confirm");
    assert_eq!(late.status, 409, "{}", late.text);
    assert_eq!(
        call(&obid, "GET", &format!("/v1/jobs/{sleeping}"), None).body["mode"],
        "ask"
    );
    assert!(items_of(&obid, "confirm").is_empty());
}

/// A bare "stop" said to start a new conversation stops no turn elsewhere (review on #551).
#[test]
fn a_bare_stop_in_a_new_conversation_stops_nothing_elsewhere() {
    let folder = Folder::new("brain-stop-new");
    let obid = started(&folder);
    queue(&obid, &[format!("SLEEP 2 {}", reply("Still here."))]);
    let answer = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "how is it going?"));
        within(5, "the turn thinks", || {
            (calls(&obid).len() == 1).then_some(())
        });
        let stop = call(
            &obid,
            "POST",
            "/v1/plans",
            Some(&json!({"said": "stop", "new": true})),
        );
        assert_eq!(stop.body["kind"], "none", "{}", stop.text);
        asking.join().unwrap()
    });
    assert_eq!(answer["text"], "Still here.", "{answer}");
}

/// Writes obid's vault file with `secret` (as `obid vault add` would): obid reads it from the file.
fn vault_holds(obid: &Obid, secret: &str) {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = obid.home.join("vault");
    if !dir.exists() {
        std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(dir.join("secrets.json"))
        .unwrap();
    std::io::Write::write_all(
        &mut file,
        json!({"secrets": {"staging-api-key": secret}})
            .to_string()
            .as_bytes(),
    )
    .unwrap();
}

/// No vault secret reaches the brain: not its prompt, its system prompt, its schema or the
/// quoted work.md. And a vault that can't be read runs no brain at all, and the turn says why
/// (#570's follow-up for the brain).
#[test]
fn no_vault_secret_reaches_the_brain_and_an_unreadable_vault_runs_none() {
    let folder = Folder::new("brain-vault");
    let obid = started(&folder);
    let secret = ["vault-", "brain/", "Q7m2+a=b?c&d"].concat();
    // A job's waiting permission holds it, asked before the vault knew it: quoted in work.md.
    let ask = json!({"tool": "Bash", "input": {"command": format!("curl -H 'X-Key: {secret}' https://example.com")}});
    let answer = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate",
                             "task": format!("ASK: {ask}"), "title": "Asker", "mode": "ask"}}),
        ),
    );
    assert_eq!(answer.status, 201, "{}", answer.text);
    let id = answer.body["id"].as_str().unwrap().to_owned();
    within(30, "the job asks", || {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (!job["permission"].is_null()).then_some(())
    });
    vault_holds(&obid, &secret);
    queue(&obid, &[reply("It's in the vault.")]);
    let words = format!("is {secret} still what the tests use?");
    assert_eq!(said(&obid, &words)["text"], "It's in the vault.");
    let call_dir = calls(&obid).pop().expect("the brain was asked");
    let quoted = std::fs::read_to_string(call_dir.join("work.md")).expect("work.md was written");
    assert!(quoted.contains("curl -H"), "{quoted}");
    for part in ["input", "args", "work.md"] {
        let text = std::fs::read_to_string(call_dir.join(part)).unwrap();
        assert!(!text.contains(&secret), "{part}: {text}");
        assert!(!text.contains("Q7m2"), "{part}: {text}");
    }
    // The vault breaks while a turn runs: its next step asks no brain, and the turn says why.
    let asked = calls(&obid).len();
    queue(
        &obid,
        &[
            format!("SLEEP 2 {}", set_mode(&id, "plan")),
            reply("I thought anyway."),
        ],
    );
    std::thread::scope(|scope| {
        let turn = scope.spawn(|| {
            call(
                &obid,
                "POST",
                "/v1/plans",
                Some(&json!({"said": "let the asker only plan"})),
            )
        });
        within(10, "the brain is asked", || {
            (calls(&obid).len() > asked).then_some(())
        });
        std::fs::write(obid.home.join("vault/secrets.json"), "not the vault").unwrap();
        let answer = turn.join().unwrap();
        assert_eq!(answer.status, 503, "{}", answer.text);
    });
    assert_eq!(calls(&obid).len(), asked + 1, "the brain was asked again");
    vault_holds(&obid, &secret);
    let turns = call(&obid, "GET", "/v1/conversation?limit=2", None).body;
    let last = turns.as_array().unwrap().last().unwrap().clone();
    assert_eq!(last["who"], "oby", "{turns}");
    assert!(
        last["text"]
            .as_str()
            .unwrap()
            .contains("The vault can't be read"),
        "{turns}"
    );
}

// ---------------------------------------------------------------------------------------------
// The actions on jobs and the inbox (#546, step 4).

/// A job from `POST /v1/jobs` with `task`, once its status is `status`.
fn job_that(
    obid: &Obid,
    title: &str,
    task: &str,
    mode: Option<&str>,
    status: &str,
) -> serde_json::Value {
    let mut job =
        json!({"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": task, "title": title});
    if let Some(mode) = mode {
        job["mode"] = json!(mode);
    }
    let answer = call(obid, "POST", "/v1/jobs", Some(&json!({"job": job})));
    assert!(
        answer.status == 200 || answer.status == 201,
        "{}",
        answer.text
    );
    let id = answer.body["id"].as_str().unwrap().to_owned();
    within(30, &format!("the job is {status}"), || {
        let job = call(obid, "GET", &format!("/v1/jobs/{id}"), None).body;
        (job["status"] == status).then_some(job)
    })
}

fn on_jobs(action: &str, ids: &[&str]) -> String {
    json!({"action": action, "reply": "", "dispatches": [], "question": null, "jobs": ids})
        .to_string()
}

fn get_job(obid: &Obid, id: &str) -> serde_json::Value {
    call(obid, "GET", &format!("/v1/jobs/{id}"), None).body
}

/// JobActionTests.tryAgainRestartsAFailedJob, dismissLetsAJobGo, eachActionReportsItsSteps and
/// oneMessageTriesTheFailedJobAgainAndDismissesTheOldOne: one message tries a failed job again
/// and lets another go, each a step, and the brain hears what was done between them.
#[test]
fn one_message_tries_a_failed_job_again_and_dismisses_the_old_one() {
    let folder = Folder::new("brain-try-again");
    let obid = started(&folder);
    let notch = job_that(&obid, "Notch three screens", "FAIL", None, "failed");
    let old = job_that(&obid, "Old PR job", "FAIL", None, "failed");
    let (notch, old) = (notch["id"].as_str().unwrap(), old["id"].as_str().unwrap());
    let events = follow_events(&obid);
    queue(
        &obid,
        &[
            on_jobs("retry_job", &[notch]),
            on_jobs("dismiss_job", &[old]),
            reply(""),
        ],
    );
    let answer = said(&obid, "try the notch job again and dismiss the old PR job");
    let text = answer["text"].as_str().unwrap();
    assert!(
        text.starts_with("Started Notch three screens again on Claude Code · Stub.")
            && text.ends_with("Let Old PR job go."),
        "{text}"
    );
    let heard = events_named(&events, "step", 10, |got| got.len() == 4);
    let texts: Vec<&str> = heard.iter().map(|e| e["text"].as_str().unwrap()).collect();
    assert_eq!(
        texts,
        [
            "Trying Notch three screens again",
            "Trying Notch three screens again",
            "Letting Old PR job go",
            "Letting Old PR job go"
        ]
    );
    assert_eq!(
        steps(&heard),
        [
            "1:retry_job:running",
            "1:retry_job:done",
            "2:dismiss_job:running",
            "2:dismiss_job:done"
        ]
    );
    assert!(get_job(&obid, old)["dismissed"].is_string());
    let notes = get_job(&obid, notch)["notes"].to_string();
    assert!(
        notes.contains("Try again, picking up where you left off."),
        "{notes}"
    );
    let calls = calls(&obid);
    assert_eq!(calls.len(), 3);
    assert!(read(calls[1].join("input")).contains("Started Notch three screens again"));
}

/// JobActionTests.aJobThatIsStillRunningCantBeTriedAgain, aJobThatNeedsNothingSaysWhyItStays and
/// startNowStartsAJobWaitingForItsStartWhen's last half: what can't happen says why, and fails.
#[test]
fn what_a_job_can_t_do_says_why() {
    let folder = Folder::new("brain-cant");
    let obid = started(&folder);
    let vault = running(&obid, "Vault secrets")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let done = job_that(&obid, "Finished work", "Nothing", None, "done")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    queue(&obid, &[on_jobs("retry_job", &[&vault])]);
    assert_eq!(
        said(&obid, "try the vault job again")["text"],
        "Couldn't try Vault secrets again: it's still running."
    );
    queue(&obid, &[on_jobs("dismiss_job", &[&done])]);
    assert_eq!(
        said(&obid, "dismiss the finished one")["text"],
        "Couldn't let Finished work go: This job doesn't need you: there's nothing to dismiss."
    );
    // obid starts every job at once: none waits for a Start when (#455).
    queue(&obid, &[on_jobs("start_now", &[&vault])]);
    assert_eq!(
        said(&obid, "start the vault job anyway")["text"],
        "Couldn't start Vault secrets: it isn't waiting for a Start when."
    );
    assert_eq!(calls(&obid).len(), 3);
}

/// JobActionTests.answeringAnInboxItemSettlesIt and anItemTakesTheUsersOwnWords: the brain names
/// an inbox item by its id from the briefing, with an option by its number or the user's words.
#[test]
fn answering_an_inbox_item_settles_it() {
    let folder = Folder::new("brain-inbox");
    let obid = started(&folder);
    let ask = r#"ASKS: [{"tool": "Bash", "input": {"command": "make lint"}}, {"tool": "Bash", "input": {"command": "make test"}}]"#;
    let job = job_that(&obid, "Vault secrets", ask, Some("ask"), "running");
    let id = job["id"].as_str().unwrap().to_owned();
    let item = within(30, "a permission waits", || {
        call(&obid, "GET", "/v1/inbox", None)
            .body
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["job"] == id.as_str() && i["text"] == "Run make lint")
            .cloned()
    });
    let item_id = item["id"].as_str().unwrap().to_owned();
    let answer = |option: serde_json::Value, words: serde_json::Value, item: &str| {
        json!({"action": "answer_inbox", "reply": "", "dispatches": [], "question": null, "jobs": [],
               "item": item, "option": option, "answer": words})
        .to_string()
    };
    queue(&obid, &[answer(json!(1), json!(null), &item_id), reply("")]);
    assert_eq!(
        said(&obid, "allow the vault job's command")["text"],
        "Answered Vault secrets's item: Allow."
    );
    assert!(read(calls(&obid)[0].join("input")).contains(&format!("Item id {item_id}.")));
    let settled = call(&obid, "GET", "/v1/inbox?state=done", None).body;
    assert!(
        settled
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == item_id.as_str() && i["answer"] == "Allow")
    );
    // The next one, in the user's own words: "allow" is the item's own option, whatever its case.
    let next = within(30, "the next permission waits", || {
        call(&obid, "GET", "/v1/inbox", None)
            .body
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["job"] == id.as_str() && i["text"] == "Run make test")
            .cloned()
    });
    let next_id = next["id"].as_str().unwrap().to_owned();
    queue(
        &obid,
        &[answer(json!(null), json!("allow"), &next_id), reply("")],
    );
    assert_eq!(
        said(&obid, "allow that too")["text"],
        "Answered Vault secrets's item: Allow."
    );
    let ended = within(30, "the job ends", || {
        let job = get_job(&obid, &id);
        (job["status"] == "done").then_some(job)
    });
    assert_eq!(ended["summary"], "answers: allow, allow");
}

/// set_setting: of the settings, obid keeps how many jobs run at once.
#[test]
fn the_brain_changes_how_many_jobs_run_at_once() {
    let folder = Folder::new("brain-setting");
    let obid = started(&folder);
    let setting = json!({"action": "set_setting", "reply": "", "dispatches": [], "question": null,
                         "setting": {"agent": null, "model": null, "effort": null, "complex_effort": null,
                                     "max_running": 3, "account": null, "lift": null}});
    queue(&obid, &[setting.to_string(), reply("")]);
    assert_eq!(
        said(&obid, "only three jobs at once")["text"],
        "Changed jobs at once from 6 to 3."
    );
    assert_eq!(
        call(&obid, "GET", "/v1/settings/jobs", None).body["maxRunning"],
        3
    );
    assert!(read(calls(&obid)[1].join("input")).contains("- Jobs at once: 3 (1 to 20)"));
}

/// NoDispatchCardTests.aPlanStartsItsJobsAndLinksThemToTheTurn: a plan's jobs start as it's made,
/// with their issue's files, joined to Oby's turn, and Oby says what started.
#[test]
fn a_plan_starts_its_jobs_and_links_them_to_the_turn() {
    let folder = Folder::new("brain-no-card");
    let obid = started(&folder);
    let two = json!({"action": "dispatch", "reply": "", "question": null, "jobs": [], "dispatches": [
        {"agent": "auto", "account": "auto", "repo": "obi-e2e/fixture-app", "base_branch": null, "pr": null, "issue": 176,
         "epic": null, "kind": "fix", "title": "Login screen", "task": "Fix #176", "inputs": [], "rounds": 1, "check": null,
         "complexity": "routine", "start_when": [], "mode": null, "reads": null},
        {"agent": "auto", "account": "auto", "repo": "obi-e2e/fixture-app", "base_branch": null, "pr": 33, "issue": null,
         "epic": null, "kind": "review", "title": null, "task": "Review PR #33", "inputs": [], "rounds": 1, "check": null,
         "complexity": "routine", "start_when": [], "mode": null, "reads": null}]});
    queue(&obid, &[two.to_string()]);
    let answer = said(&obid, "fix fixture-app #176 and review PR 33");
    assert_eq!(
        answer["text"],
        "On it. Claude Code is fixing fixture-app #176 (Login screen) on Stub, and Claude Code is reviewing fixture-app PR #33 on Stub."
    );
    let jobs = answer["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 2);
    assert_eq!(
        jobs[0]["files"],
        json!([
            "Engine/Accounts.swift",
            "Engine/Review.swift",
            "RunnerTests/"
        ])
    );
    let ids: Vec<&str> = jobs.iter().map(|j| j["id"].as_str().unwrap()).collect();
    let turns = call(&obid, "GET", "/v1/conversation", None).body;
    assert_eq!(
        turns.as_array().unwrap().last().unwrap()["jobs"],
        json!(ids)
    );
    assert_eq!(call(&obid, "GET", "/v1/inbox", None).body, json!([]));
}

/// NoDispatchCardTests.aCancelledOrLateTurnStartsNothing: a turn cancelled while its jobs' issues
/// were read starts nothing.
#[test]
fn a_turn_cancelled_while_its_jobs_are_made_starts_nothing() {
    let folder = Folder::new("brain-cancel-files");
    let obid = started(&folder);
    let slow = json!({"action": "dispatch", "reply": "On it.", "question": null, "jobs": [], "dispatches": [
        {"agent": "auto", "account": "auto", "repo": "obi-e2e/fixture-app", "issue": 777, "kind": "fix",
         "title": "Slow issue", "task": "Fix #777", "rounds": 1}]});
    queue(&obid, &[slow.to_string()]);
    let answer = std::thread::scope(|scope| {
        let asking = scope.spawn(|| said(&obid, "fix fixture-app #777"));
        within(5, "the brain is asked", || {
            (calls(&obid).len() == 1).then_some(())
        });
        // gh takes 2 seconds to read issue 777.
        std::thread::sleep(std::time::Duration::from_millis(700));
        call(&obid, "POST", "/v1/plans/cancel", None);
        asking.join().unwrap()
    });
    assert_eq!(answer["kind"], "none", "{answer}");
    assert_eq!(call(&obid, "GET", "/v1/jobs", None).body, json!([]));
}
