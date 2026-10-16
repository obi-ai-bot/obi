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
