//! Many conversations with Oby (#493): listing and paging them, renaming, pinning and deleting
//! them, the jobs a conversation's plan started and their events, the single thread from before
//! becoming the first conversation, and apps that send no conversation.
mod support;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

fn planner() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-planner")
}

fn obid(folder: &Folder) -> (Obid, Value) {
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    (
        start(&folder.0, &config, Some(planner().parent().unwrap())),
        config,
    )
}

/// `POST /v1/plans` with `body`, answered `200`.
fn plan(obid: &Obid, body: Value) -> Value {
    let answer = call(obid, "POST", "/v1/plans", Some(&body));
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body
}

fn conversations(obid: &Obid, query: &str) -> Vec<Value> {
    let answer = call(obid, "GET", &format!("/v1/conversations{query}"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body.as_array().unwrap().clone()
}

fn turns(obid: &Obid, query: &str) -> Vec<Value> {
    let answer = call(obid, "GET", &format!("/v1/conversation{query}"), None);
    assert_eq!(answer.status, 200, "{}", answer.text);
    answer.body.as_array().unwrap().clone()
}

/// Every event that came within `seconds`, until `enough` says so.
fn heard_until(
    events: &std::sync::mpsc::Receiver<(String, Value)>,
    seconds: u64,
    enough: impl Fn(&[(String, Value)]) -> bool,
) -> Vec<(String, Value)> {
    let give_up_at = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
    let mut heard = Vec::new();
    while !enough(&heard) {
        let left = give_up_at.saturating_duration_since(std::time::Instant::now());
        match events.recv_timeout(left) {
            Ok(event) => heard.push(event),
            Err(_) => panic!("within {seconds} seconds, the events were {heard:?}"),
        }
    }
    heard
}

fn ids(list: &[Value]) -> Vec<&str> {
    list.iter().map(|c| c["id"].as_str().unwrap()).collect()
}

fn texts(list: &[Value]) -> Vec<&str> {
    list.iter().map(|t| t["text"].as_str().unwrap()).collect()
}

#[test]
fn conversations_are_listed_paged_renamed_pinned_and_deleted() {
    let folder = Folder::new("conversations");
    let (mut obid, config) = obid(&folder);
    let events = follow_events(&obid);

    let first = plan(&obid, json!({"said": "first question", "new": true}));
    let a = first["conversation"].as_str().unwrap().to_owned();
    let b = plan(
        &obid,
        json!({"said": "second question\nwith more", "new": true}),
    )["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    let c = plan(&obid, json!({"said": "third", "new": true}))["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(first["kind"], "reply");
    assert_eq!(first["text"], "Fine.");
    assert!(a != b && b != c && a != c);
    let made = events_named(&events, "conversation", 10, |got| got.len() == 3);
    assert_eq!(ids(&made), [&a, &b, &c]);

    // Newest first, titled from their first line.
    let listed = conversations(&obid, "");
    assert_eq!(ids(&listed), [&c, &b, &a]);
    let titles: Vec<&str> = listed
        .iter()
        .map(|c| c["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["Third", "Second question", "First question"]);
    for conversation in &listed {
        let keys: Vec<&str> = conversation
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(keys.len(), 5, "{conversation}");
        assert_eq!(conversation["pinned"], false);
        assert!(conversation["created"].is_string() && conversation["lastActivity"].is_string());
    }

    // Paging.
    assert_eq!(ids(&conversations(&obid, "?limit=2")), [&c, &b]);
    assert_eq!(
        ids(&conversations(&obid, &format!("?after={b}&limit=2"))),
        [&a]
    );
    assert!(conversations(&obid, &format!("?after={a}")).is_empty());
    assert_eq!(
        call(&obid, "GET", "/v1/conversations?after=nope", None).status,
        404
    );
    assert_eq!(
        call(&obid, "GET", "/v1/conversations?limit=0", None).status,
        422
    );
    assert_eq!(
        call(&obid, "GET", "/v1/conversations?limit=x", None).status,
        422
    );

    // Carrying on an older one brings it to the top, and its turns are its own.
    let again = plan(&obid, json!({"said": "follow-up", "conversation": a}));
    assert_eq!(again["conversation"], a.as_str());
    assert_eq!(ids(&conversations(&obid, "")), [&a, &c, &b]);
    let thread = turns(&obid, &format!("?id={a}"));
    assert_eq!(
        texts(&thread),
        ["first question", "Fine.", "follow-up", "Fine."]
    );
    assert!(thread.iter().all(|t| t["conversation"] == a.as_str()));
    let prompt = std::fs::read_to_string(folder.0.join("env-home/plan-input")).unwrap();
    assert!(prompt.contains("User: first question"), "{prompt}");
    assert!(!prompt.contains("second question"), "{prompt}");
    assert_eq!(
        texts(&turns(&obid, &format!("?id={b}"))),
        ["second question\nwith more", "Fine."]
    );
    // No id: the latest.
    assert_eq!(texts(&turns(&obid, "")), texts(&thread));
    assert_eq!(texts(&turns(&obid, &format!("?id={a}&limit=1"))), ["Fine."]);
    let before = thread[2]["id"].as_str().unwrap();
    assert_eq!(
        texts(&turns(&obid, &format!("?id={a}&before={before}"))),
        ["first question", "Fine."]
    );
    assert_eq!(
        call(
            &obid,
            "GET",
            &format!("/v1/conversation?id={b}&before={before}"),
            None
        )
        .status,
        404
    );
    assert_eq!(
        call(&obid, "GET", "/v1/conversation?id=nope", None).status,
        404
    );

    // Rename and pin.
    let renamed = call(
        &obid,
        "PATCH",
        &format!("/v1/conversations/{a}"),
        Some(&json!({"title": "  Vault questions  "})),
    );
    assert_eq!(renamed.status, 200, "{}", renamed.text);
    assert_eq!(renamed.body["title"], "Vault questions");
    assert_eq!(renamed.body["pinned"], false);
    let pinned = call(
        &obid,
        "PATCH",
        &format!("/v1/conversations/{b}"),
        Some(&json!({"pinned": true})),
    );
    assert_eq!(pinned.status, 200, "{}", pinned.text);
    assert_eq!(pinned.body["pinned"], true);
    assert_eq!(pinned.body["title"], "Second question");
    let changed = events_named(&events, "conversation", 10, |got| got.len() == 2);
    assert_eq!(changed[0]["title"], "Vault questions");
    assert_eq!(changed[1]["pinned"], true);
    // Pinned first, then newest first.
    assert_eq!(ids(&conversations(&obid, "")), [&b, &a, &c]);
    assert_eq!(
        ids(&conversations(&obid, &format!("?after={b}&limit=1"))),
        [&a]
    );
    for (body, status) in [
        (json!({}), 422),
        (json!({"title": " "}), 422),
        (json!({"title": "two\nlines"}), 422),
        (json!({"title": "x".repeat(101)}), 422),
        (json!({"pinned": "yes"}), 400),
        (json!({"colour": "red"}), 400),
    ] {
        let refused = call(
            &obid,
            "PATCH",
            &format!("/v1/conversations/{c}"),
            Some(&body),
        );
        assert_eq!(refused.status, status, "{body}: {}", refused.text);
    }
    assert_eq!(
        call(
            &obid,
            "PATCH",
            "/v1/conversations/nope",
            Some(&json!({"pinned": true}))
        )
        .status,
        404
    );

    // Delete.
    let deleted = call(&obid, "DELETE", &format!("/v1/conversations/{c}"), None);
    assert_eq!(deleted.status, 204, "{}", deleted.text);
    let gone = events_named(&events, "conversation", 10, |got| got.len() == 1);
    assert_eq!(gone[0], json!({"id": c, "deleted": true}));
    assert_eq!(ids(&conversations(&obid, "")), [&b, &a]);
    assert_eq!(
        call(&obid, "GET", &format!("/v1/conversation?id={c}"), None).status,
        404
    );
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/conversations/{c}"), None).status,
        404
    );
    assert!(!obid.home.join(format!("conversations/{c}.json")).exists());
    let refused = call(
        &obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said": "hi", "conversation": c})),
    );
    assert_eq!(refused.status, 404, "{}", refused.text);
    let both = call(
        &obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said": "hi", "conversation": a, "new": true})),
    );
    assert_eq!(both.status, 422, "{}", both.text);
    assert_eq!(
        ids(&conversations(&obid, "")),
        [&b, &a],
        "a refused plan makes nothing"
    );

    // Kept as they were across a restart, each a private file.
    let listed = conversations(&obid, "");
    assert_eq!(obid.stop().code(), Some(0));
    for id in [&a, &b] {
        use std::os::unix::fs::PermissionsExt;
        let file = obid.home.join(format!("conversations/{id}.json"));
        let mode = std::fs::metadata(&file).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "{}", file.display());
    }
    let restarted = start(&folder.0, &config, Some(planner().parent().unwrap()));
    assert_eq!(conversations(&restarted, ""), listed);
    assert_eq!(
        texts(&turns(&restarted, &format!("?id={a}"))),
        texts(&thread)
    );
    assert_eq!(texts(&turns(&restarted, "")), texts(&thread));
}

#[test]
fn jobs_and_their_events_land_in_the_conversation_that_started_them() {
    let folder = Folder::new("conversation-jobs");
    let (obid, _) = obid(&folder);
    let events = follow_events(&obid);

    let other = plan(&obid, json!({"said": "how is it going?", "new": true}))["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    let dispatched = plan(&obid, json!({"said": "fix oby #176 and #198", "new": true}));
    let started = dispatched["conversation"].as_str().unwrap().to_owned();
    assert_ne!(other, started);
    let jobs = dispatched["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 2, "{dispatched}");
    let job_ids: Vec<String> = jobs
        .iter()
        .map(|j| j["id"].as_str().unwrap().to_owned())
        .collect();
    assert!(jobs.iter().all(|j| j["conversation"] == started.as_str()));
    // Oby's turn with the job cards is in the conversation that started them.
    let thread = turns(&obid, &format!("?id={started}"));
    assert_eq!(thread[1]["jobs"], json!(job_ids));
    assert_eq!(thread[1]["conversation"], started.as_str());

    // Talking in another conversation meanwhile changes nothing about where the jobs belong.
    let elsewhere = plan(
        &obid,
        json!({"said": "and the vault one?", "conversation": other}),
    );
    assert_eq!(elsewhere["conversation"], other.as_str());
    let ended: Vec<Value> = job_ids
        .iter()
        .map(|id| {
            let answer = call(&obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
            assert_eq!(answer.status, 200, "{}", answer.text);
            answer.body
        })
        .collect();
    // The fake Claude Code fails as an agent: each job fails.
    for job in &ended {
        assert_eq!(job["status"], "failed", "{job}");
        assert_eq!(job["conversation"], started.as_str(), "{job}");
    }

    // Every event of theirs, to the last (how each ended), carries its conversation, and so does
    // every turn.
    let failed_at_last = |heard: &[(String, Value)], id: &str| {
        heard
            .iter()
            .rev()
            .find(|(name, job)| name == "job" && job["id"] == id)
            .is_some_and(|(_, job)| job["status"] == "failed")
    };
    let heard = heard_until(&events, 30, |heard| {
        job_ids.iter().all(|id| failed_at_last(heard, id))
            && heard.iter().filter(|(name, _)| name == "turn").count() == 6
    });
    let theirs: Vec<&Value> = heard
        .iter()
        .filter(|(name, job)| name == "job" && job_ids.iter().any(|id| job["id"] == id.as_str()))
        .map(|(_, job)| job)
        .collect();
    assert!(theirs.len() >= 4, "{theirs:?}");
    assert!(
        theirs.iter().all(|j| j["conversation"] == started.as_str()),
        "{theirs:?}"
    );
    let places: Vec<&str> = heard
        .iter()
        .filter(|(name, _)| name == "turn")
        .map(|(_, turn)| turn["conversation"].as_str().unwrap())
        .collect();
    assert_eq!(places, [&other, &other, &started, &started, &other, &other]);

    // A job dispatched whole (`POST /v1/jobs`) belongs to no conversation.
    let whole = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "Look around"}}),
        ),
    );
    assert_eq!(whole.status, 201, "{}", whole.text);
    assert_eq!(whole.body["conversation"], Value::Null);

    // Deleting the conversation keeps its jobs, which still say where they started.
    assert_eq!(
        call(
            &obid,
            "DELETE",
            &format!("/v1/conversations/{started}"),
            None
        )
        .status,
        204
    );
    for id in &job_ids {
        let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None);
        assert_eq!(job.status, 200, "{}", job.text);
        assert_eq!(job.body["conversation"], started.as_str());
    }
}

/// The thread obid kept before #493, as it wrote it.
fn old_thread() -> Value {
    json!([
        {"id": "7c1e2f30-0000-4000-8000-000000000001", "who": "user",
         "text": "review oby PR #33\nplease", "at": "2026-10-11T09:12:00Z", "jobs": []},
        {"id": "7c1e2f30-0000-4000-8000-000000000002", "who": "oby",
         "text": "On it.", "at": "2026-10-11T09:12:04Z", "jobs": ["9f08fd10"]},
        {"id": "7c1e2f30-0000-4000-8000-000000000003", "who": "user",
         "text": "and the vault one?", "at": "2026-10-11T09:13:00Z", "jobs": []}
    ])
}

fn put_old_thread(home: &Path) {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(home)
        .unwrap();
    std::fs::write(home.join("conversation.json"), old_thread().to_string()).unwrap();
}

#[test]
fn the_single_thread_from_before_becomes_the_first_conversation() {
    let folder = Folder::new("conversation-migration");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &planner());
    let home = folder.0.join("home");
    put_old_thread(&home);
    let mut obid = start(&folder.0, &config, None);

    let id = "7c1e2f30-0000-4000-8000-000000000001";
    assert_eq!(
        conversations(&obid, ""),
        [
            json!({"id": id, "title": "Review oby PR #33", "pinned": false,
                "created": "2026-10-11T09:12:00Z", "lastActivity": "2026-10-11T09:13:00Z"})
        ]
    );
    let moved = turns(&obid, "");
    let mut expected = old_thread();
    for turn in expected.as_array_mut().unwrap() {
        turn["conversation"] = json!(id);
    }
    assert_eq!(Value::Array(moved.clone()), expected);
    assert_eq!(turns(&obid, &format!("?id={id}")), moved);
    assert!(!home.join("conversation.json").exists());
    assert!(home.join(format!("conversations/{id}.json")).is_file());

    // An app from before carries it on, and the brain reads it.
    let answer = plan(&obid, json!({"said": "hello"}));
    assert_eq!(answer["conversation"], id);
    let prompt = std::fs::read_to_string(folder.0.join("env-home/plan-input")).unwrap();
    assert!(
        prompt.contains("User: review oby PR #33\nplease\nOby: On it.\nUser: and the vault one?"),
        "{prompt}"
    );
    assert_eq!(turns(&obid, "").len(), 5);

    // A move cut short (the conversation written, the old file still there) isn't made twice.
    assert_eq!(obid.stop().code(), Some(0));
    std::fs::write(home.join("conversation.json"), old_thread().to_string()).unwrap();
    let restarted = start(&folder.0, &config, None);
    assert_eq!(ids(&conversations(&restarted, "")), [id]);
    assert_eq!(turns(&restarted, "").len(), 5);
    assert!(!home.join("conversation.json").exists());
}

#[test]
fn apps_that_send_no_conversation_keep_one_thread() {
    let folder = Folder::new("conversation-old-apps");
    let (obid, _) = obid(&folder);
    assert!(turns(&obid, "").is_empty());
    assert!(conversations(&obid, "").is_empty());

    // The first words make the first conversation; the next carry it on.
    let first = plan(&obid, json!({"said": "hello"}));
    let second = plan(&obid, json!({"said": "again"}));
    assert_eq!(first["conversation"], second["conversation"]);
    let id = first["conversation"].as_str().unwrap().to_owned();
    assert_eq!(ids(&conversations(&obid, "")), [&id]);
    let thread = turns(&obid, "");
    assert_eq!(texts(&thread), ["hello", "Fine.", "again", "Fine."]);
    // Its paging, as before.
    let last = turns(&obid, "?limit=1");
    assert_eq!(texts(&last), ["Fine."]);
    let before = last[0]["id"].as_str().unwrap().to_owned();
    assert_eq!(
        texts(&turns(&obid, &format!("?before={before}&limit=1"))),
        ["again"]
    );

    // Another app starts a new conversation: an app from before now shows it, the latest, and
    // still pages back through the one it was showing (`before` names a turn of it).
    let newer = plan(&obid, json!({"said": "something else", "new": true}))["conversation"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(newer, id);
    assert_eq!(texts(&turns(&obid, "")), ["something else", "Fine."]);
    assert_eq!(
        texts(&turns(&obid, &format!("?before={before}&limit=1"))),
        ["again"]
    );
    assert_eq!(
        call(&obid, "GET", "/v1/conversation?before=nope", None).status,
        404
    );
    let carried = plan(&obid, json!({"said": "and then?"}));
    assert_eq!(carried["conversation"], newer.as_str());
    assert_eq!(ids(&conversations(&obid, "")), [&newer, &id]);
}
