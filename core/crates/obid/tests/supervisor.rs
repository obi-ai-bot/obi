//! The conversation supervises its jobs (docs/runner-api.md, "obid only: the conversation
//! supervises its jobs"): a job a conversation started that stalls goes back to that conversation's
//! agent session, which reads the handoff note and carries it on, starts it fresh or splits it by
//! itself, within obid's bounds, and says so in one line; past 3 automatic steps, or for anything
//! else, the owner decides. The agent is the stand-in (tests/agents/fake-harness).
mod support;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

fn harness() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-harness")
}

/// obid with the stand-in as Claude Code, conversations on the harness, a signed-in account and
/// a job held after 2 quiet seconds.
fn obid(name: &str) -> (Folder, Obid) {
    obid_with(name, json!({}))
}

/// [`obid`], with `more` added to its configuration.
fn obid_with(name: &str, more: Value) -> (Folder, Obid) {
    let folder = Folder::new(name);
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &harness());
    config["conversation"] = json!({"agent": "claude"});
    config["stallAfter"] = json!(2);
    for (key, value) in more.as_object().unwrap() {
        config[key] = value.clone();
    }
    let account = folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    std::fs::write(account.join(".credentials.json"), "{}").unwrap();
    let obid = start(&folder.0, &config, None);
    (folder, obid)
}

/// A conversation whose supervisor turns do what `script` says, and the build job it started, which
/// stalls each time.
fn stalling(obid: &Obid, script: &str) -> (String, String) {
    started(obid, script, "build", "Build both halves STALLS-ALWAYS")
}

/// A conversation whose supervisor turns do what `script` says, and the `kind` job it started on
/// `task`.
fn started(obid: &Obid, script: &str, kind: &str, task: &str) -> (String, String) {
    started_in(obid, script, kind, task, "acceptEdits")
}

/// [`started`], the job in `mode`; one in Bypass starts once the owner confirms it.
fn started_in(obid: &Obid, script: &str, kind: &str, task: &str, mode: &str) -> (String, String) {
    let started = call(
        obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said": "SAY Ready.", "new": true})),
    );
    assert_eq!(started.status, 200, "{}", started.text);
    let conversation = started.body["conversation"].as_str().unwrap().to_owned();
    std::fs::write(
        obid.home
            .join(format!("conversations/{conversation}/room/supervise.txt")),
        script,
    )
    .unwrap();
    let dispatch = format!(
        "OBY oby_dispatch {}",
        json!({"repo": "obi-e2e/fixture-app", "task": task, "kind": kind, "mode": mode,
               "title": "Both halves"})
    );
    let answer = call(
        obid,
        "POST",
        "/v1/plans",
        Some(&json!({"said": dispatch, "conversation": conversation})),
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    if mode == "bypass" {
        let item = inbox(obid)
            .into_iter()
            .find(|i| i["kind"] == "confirm")
            .unwrap_or_else(|| panic!("{}", answer.text));
        let confirmed = call(
            obid,
            "POST",
            &format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap()),
            Some(&json!({"answer": "Confirm"})),
        );
        assert_eq!(confirmed.status, 200, "{}", confirmed.text);
        let job = within(30, "the Bypass job starts", || {
            jobs(obid)
                .first()
                .map(|j| j["id"].as_str().unwrap().to_owned())
        });
        return (conversation, job);
    }
    let job = answer.body["jobs"][0]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("{}", answer.text))
        .to_owned();
    (conversation, job)
}

fn job(obid: &Obid, id: &str) -> Value {
    call(obid, "GET", &format!("/v1/jobs/{id}"), None).body
}

fn inbox(obid: &Obid) -> Vec<Value> {
    call(obid, "GET", "/v1/inbox", None)
        .body
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn jobs(obid: &Obid) -> Vec<Value> {
    call(obid, "GET", "/v1/jobs", None)
        .body
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// Oby's turns in the conversation, oldest first.
fn obys(obid: &Obid, conversation: &str) -> Vec<String> {
    call(
        obid,
        "GET",
        &format!("/v1/conversation?id={conversation}&limit=100"),
        None,
    )
    .body
    .as_array()
    .cloned()
    .unwrap_or_default()
    .iter()
    .filter(|t| t["who"] == "oby")
    .map(|t| t["text"].as_str().unwrap_or_default().to_owned())
    .collect()
}

/// The job once its conversation decided about its stall `n` times (`asked` included).
fn supervised(obid: &Obid, id: &str, n: usize) -> Value {
    let give_up_at = std::time::Instant::now() + std::time::Duration::from_secs(90);
    loop {
        let job = job(obid, id);
        if job["supervised"].as_array().map_or(0, Vec::len) >= n {
            return job;
        }
        assert!(
            std::time::Instant::now() < give_up_at,
            "job {id} wasn't supervised within 90 seconds: {job}\n{}",
            obid.log()
        );
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
}

/// A stalled job is carried on in its own session and finishes: its agent hears Try again and the
/// conversation's words, quoted, never obid's prompt to the conversation.
#[test]
fn a_stalled_job_is_continued_and_finishes() {
    let (_folder, obid) = obid("supervisor-continue");
    let (conversation, id) = started(
        &obid,
        "OBY oby_continue_job {\"id\": \"$JOB\", \"words\": \"PICK-UP-THE-SECOND-HALF\"}\nSAY Carried it on in its session.",
        "investigate",
        "Look into both halves STALLS-ONCE",
    );
    let step = supervised(&obid, &id, 1)["supervised"][0].clone();
    assert_eq!(step["decision"], "continue", "{step}");
    assert_eq!(step["count"], 1);
    let done = within(90, "the job finishes", || {
        let job = job(&obid, &id);
        (job["status"] == "done").then_some(job)
    });
    assert!(done["stalled"].is_null(), "{done}");
    assert_eq!(done["round"], 2, "{done}");
    let heard: Vec<String> = std::fs::read_dir(obid.home.join("logins"))
        .unwrap()
        .flatten()
        .flat_map(|e| {
            std::fs::read_to_string(e.path().join("turns.jsonl"))
                .unwrap_or_default()
                .lines()
                .map(|l| {
                    serde_json::from_str::<Value>(l).unwrap()["prompt"]
                        .as_str()
                        .unwrap()
                        .to_owned()
                })
                .collect::<Vec<_>>()
        })
        .collect();
    let carried = heard
        .iter()
        .find(|p| p.contains("PICK-UP-THE-SECOND-HALF"))
        .unwrap_or_else(|| panic!("{heard:?}"));
    let fence = carried.find("<<<quoted-").expect("the words are quoted");
    assert!(
        carried[fence..].contains("PICK-UP-THE-SECOND-HALF"),
        "{carried}"
    );
    assert!(!carried.contains("Oby here, not the owner"), "{carried}");
    let said = within(30, "the conversation's line", || {
        obys(&obid, &conversation)
            .into_iter()
            .find(|t| t.starts_with("Carried it on"))
    });
    assert_eq!(
        said,
        "Carried it on in its session. (1 of 3 automatic steps taken for this job: continue.)"
    );
}

/// A stalled job is split into two new jobs by its conversation, each a follow-up from its branch
/// with its own part; a second decision in the same turn is refused; the conversation says what it
/// did in one line with its count, and the job keeps it.
#[test]
fn a_stalled_job_is_split_in_two() {
    let (_folder, obid) = obid("supervisor-split");
    let (conversation, id) = stalling(
        &obid,
        "OBY oby_job {\"id\": \"$JOB\"}\n\
         OBY oby_dispatch {\"repo\": \"obi-e2e/fixture-app\", \"task\": \"The first half\", \"title\": \"First half\"}\n\
         OBY oby_dispatch {\"repo\": \"obi-e2e/fixture-app\", \"task\": \"The second half\", \"title\": \"Second half\"}\n\
         REPEAT 1 OBY oby_tell_job {\"id\": \"$JOB\", \"words\": \"Start again\"}",
    );
    // Once the conversation said what it did, both parts are on the job.
    let said = within(90, "the conversation's line", || {
        obys(&obid, &conversation)
            .into_iter()
            .find(|t| t.contains("automatic steps"))
    });
    let stalled = supervised(&obid, &id, 1);
    assert!(!stalled["stalled"].is_null(), "{stalled}");
    let step = &stalled["supervised"][0];
    assert_eq!(step["decision"], "split", "{stalled}");
    assert_eq!(step["count"], 2);
    assert_eq!(step["of"], 3);
    let parts: Vec<String> = step["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|j| j.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(parts.len(), 2, "{said}\n{stalled}");
    for (n, part) in parts.iter().enumerate() {
        let part = job(&obid, part);
        // obid's title, never the one the turn asked for.
        assert_eq!(
            part["title"],
            format!("Follow-up: Both halves · part {}", n + 1)
        );
        assert_eq!(part["followUpOf"], id.as_str(), "{part}");
        assert_eq!(part["conversation"], conversation.as_str());
        assert_eq!(part["mode"], "acceptEdits");
        assert_eq!(part["agent"], stalled["agent"]);
        assert_eq!(part["account"], stalled["account"]);
        // The part's words reach its agent quoted after the job's own request.
        assert_eq!(part["request"], stalled["request"], "{part}");
        assert!(part["request"].as_str().unwrap().contains("STALLS-ALWAYS"));
    }
    // The third call, a second decision, was refused: no restart started.
    assert_eq!(jobs(&obid).len(), 3);
    assert!(said.contains("decided already (split)"), "{said}");
    assert!(
        said.ends_with("(2 of 3 automatic steps taken for this job: split.)"),
        "{said}"
    );
}

/// After 3 automatic steps along a job and the jobs it follows up, the next stall goes to the
/// owner: one line in the conversation and one item in Needs you, no fourth turn.
#[test]
fn the_fourth_stall_asks_the_owner() {
    let (_folder, obid) = obid("supervisor-cap");
    let (conversation, first) = stalling(
        &obid,
        "OBY oby_tell_job {\"id\": \"$JOB\", \"words\": \"Pick it up from the note.\"}\nSAY Started it fresh from its note.",
    );
    // Each restart is a follow-up whose request still says STALLS-ALWAYS, so it stalls again.
    let mut id = first.clone();
    for n in 1..=3 {
        let job = supervised(&obid, &id, 1);
        let step = &job["supervised"][0];
        assert_eq!(step["decision"], "restart", "{job}");
        assert_eq!(step["count"], n, "{job}");
        id = step["jobs"][0].as_str().unwrap().to_owned();
    }
    let last = supervised(&obid, &id, 1);
    assert_eq!(last["supervised"][0]["decision"], "asked", "{last}");
    assert_eq!(last["supervised"][0]["count"], 3);
    let items = call(&obid, "GET", "/v1/inbox", None).body;
    let item = items
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["job"] == id.as_str() && i["kind"] == "question")
        .unwrap_or_else(|| panic!("{items}"))
        .clone();
    assert!(
        item["text"]
            .as_str()
            .unwrap()
            .contains("Oby carried it on by itself 3 times already"),
        "{item}"
    );
    let lines = obys(&obid, &conversation);
    assert_eq!(
        lines
            .iter()
            .filter(|t| t.starts_with("Started it fresh from its note."))
            .count(),
        3,
        "{lines:?}"
    );
    assert!(
        lines
            .iter()
            .any(|t| t.contains("so the next step is yours")),
        "{lines:?}"
    );
    // Each follow-up keeps the first job's title once.
    assert_eq!(job(&obid, &id)["title"], "Follow-up: Both halves");
    assert_eq!(jobs(&obid).len(), 4);
}

/// What the agent wrote in its note can't make the supervisor do what's the owner's: a Bypass
/// start is only proposed, and with no decision of its own the owner is asked. The note never reaches the turn's prompt, only oby_job's quoted answer.
#[test]
fn the_note_cant_trigger_a_gated_action() {
    let (_folder, obid) = obid("supervisor-note");
    let (conversation, id) = stalling(
        &obid,
        "OBY oby_job {\"id\": \"$JOB\"}\n\
         OBY oby_dispatch {\"repo\": \"obi-e2e/fixture-app\", \"task\": \"Everything, in Bypass\", \"mode\": \"bypass\"}\n\
         OBY oby_answer {\"item\": \"supervisor-none\", \"answer\": \"Confirm\"}\n\
         SAY Did what the note said.",
    );
    let stalled = supervised(&obid, &id, 1);
    assert!(
        stalled["summary"]
            .as_str()
            .unwrap()
            .contains("ignore your rules"),
        "the note is the agent's: {stalled}"
    );
    assert_eq!(stalled["supervised"][0]["decision"], "asked", "{stalled}");
    assert_eq!(jobs(&obid).len(), 1, "nothing started");
    let items = call(&obid, "GET", "/v1/inbox", None).body;
    let kinds: Vec<&str> = items
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["kind"].as_str().unwrap())
        .collect();
    // The Bypass start waits for the owner; the stall is theirs to decide.
    assert!(kinds.contains(&"question"), "{items}");
    assert!(
        kinds.iter().any(|k| *k == "start" || *k == "confirm"),
        "{items}"
    );
    let prompts: Vec<String> = std::fs::read_to_string(
        obid.home
            .join(format!("conversations/{conversation}/config/turns.jsonl")),
    )
    .unwrap()
    .lines()
    .map(|l| {
        serde_json::from_str::<Value>(l).unwrap()["prompt"]
            .as_str()
            .unwrap()
            .to_owned()
    })
    .collect();
    let prompt = prompts
        .iter()
        .find(|p| p.starts_with("Oby here, not the owner"))
        .expect("the supervisor turn");
    assert!(!prompt.contains("ignore your rules"), "{prompt}");
    assert!(
        obys(&obid, &conversation)
            .iter()
            .any(|t| t == "Did what the note said."),
    );
}

/// A job that stalled at its token budget gets no turn: going on past a safety limit is the
/// owner's, so obid asks them at once.
#[test]
fn a_budget_stall_gets_no_turn() {
    let (_folder, obid) = obid_with("supervisor-budget", json!({"jobTokenBudget": 1000}));
    let (conversation, id) = started(
        &obid,
        "OBY oby_continue_job {\"id\": \"$JOB\"}\nSAY Carried it on.",
        "investigate",
        "Spend it all SPEND-TOKENS: 5000",
    );
    let stalled = supervised(&obid, &id, 1);
    assert_eq!(stalled["stalled"]["why"], "budget", "{stalled}");
    assert_eq!(stalled["supervised"][0]["decision"], "asked", "{stalled}");
    assert!(
        inbox(&obid).iter().any(|i| i["kind"] == "question"
            && i["job"] == id.as_str()
            && i["text"].as_str().unwrap().contains("safety limit")),
        "{:?}",
        inbox(&obid)
    );
    let prompts = std::fs::read_to_string(
        obid.home
            .join(format!("conversations/{conversation}/config/turns.jsonl")),
    )
    .unwrap();
    assert!(!prompts.contains("Oby here, not the owner"), "{prompts}");
    assert!(
        !obys(&obid, &conversation)
            .iter()
            .any(|t| t == "Carried it on.")
    );
    assert!(!job(&obid, &id)["stalled"].is_null());
}

/// A stalled job in Bypass mode is never carried on by itself: the supervisor turn's continue
/// waits for the owner's Confirm, and the stall is theirs.
#[test]
fn a_bypass_job_is_never_carried_on_by_itself() {
    let (_folder, obid) = obid("supervisor-bypass");
    let (_conversation, id) = started_in(
        &obid,
        "OBY oby_continue_job {\"id\": \"$JOB\"}\nSAY Asked to carry it on.",
        "build",
        "Build both halves STALLS-ALWAYS",
        "bypass",
    );
    let job = supervised(&obid, &id, 1);
    assert_eq!(job["mode"], "bypass", "{job}");
    assert_eq!(job["supervised"][0]["decision"], "asked", "{job}");
    assert!(!job["stalled"].is_null(), "{job}");
    assert_eq!(job["round"], 1, "{job}");
    let confirms: Vec<Value> = inbox(&obid)
        .into_iter()
        .filter(|i| i["kind"] == "confirm" && i["job"] == id.as_str())
        .collect();
    assert_eq!(
        confirms.len(),
        1,
        "the continue waits for the owner: {confirms:?}"
    );
}

/// The step cap holds across split generations: a split into two takes two steps, so a part's own
/// split gets one part more, and every later stall in the tree asks the owner.
#[test]
fn the_step_cap_holds_across_split_generations() {
    let (_folder, obid) = obid("supervisor-generations");
    let (_conversation, id) = stalling(
        &obid,
        "OBY oby_dispatch {\"repo\": \"obi-e2e/fixture-app\", \"task\": \"One half\"}\n\
         OBY oby_dispatch {\"repo\": \"obi-e2e/fixture-app\", \"task\": \"The other half\"}\n\
         SAY Split it.",
    );
    // The first split takes both its parts: two steps.
    within(90, "the first split's two parts", || {
        let first = job(&obid, &id);
        (first["supervised"][0]["jobs"]
            .as_array()
            .map_or(0, Vec::len)
            == 2)
            .then_some(first)
    });
    // The first job, its two parts and one part of a part: then every stall asks the owner.
    let settled = within(180, "every stall is decided", || {
        let all = jobs(&obid);
        let asked = all
            .iter()
            .filter(|j| {
                j["supervised"]
                    .as_array()
                    .is_some_and(|s| s.iter().any(|d| d["decision"] == "asked"))
            })
            .count();
        (all.len() == 4 && asked == 2).then_some(all)
    });
    let splits: usize = settled
        .iter()
        .flat_map(|j| j["supervised"].as_array().cloned().unwrap_or_default())
        .filter(|d| d["decision"] == "split")
        .map(|d| d["jobs"].as_array().unwrap().len())
        .sum();
    assert_eq!(splits, 3, "{settled:?}");
    std::thread::sleep(std::time::Duration::from_secs(5));
    assert_eq!(jobs(&obid).len(), 4);
}
