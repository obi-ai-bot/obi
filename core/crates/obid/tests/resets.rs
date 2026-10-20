//! A job a usage limit stopped is tried again by itself once its reset comes (#740), from its job
//! file, so a restart keeps waiting; one the owner dismissed or took on in a follow-up isn't. The
//! real obid binary with the stand-in agent (tests/agents/fake-claude).
mod support;

use std::path::Path;

use obid::job::{Job, Status};
use serde_json::{Value, json};
use support::*;

/// An interrupted job whose usage limit stopped it, due to be tried again a second ago.
fn limited(id: &str) -> Job {
    let mut job = Job::new(
        id.into(),
        "obi-e2e/fixture-app".into(),
        "research".into(),
        "Look around".into(),
        "claude".into(),
        "stub".into(),
    );
    let now = obi_protocol::time::now();
    job.branch = format!("oby/research-{id}");
    job.status = Status::Interrupted;
    job.session = Some(format!("{id}-0000-4000-8000-000000000000"));
    job.round = Some(1);
    job.started = Some(now - 120);
    job.finished = Some(now - 60);
    job.reason =
        Some("Claude AI usage limit reached. Oby tries again by itself after the reset.".into());
    job.next_step = Some(obid::job::TRY_AGAIN.into());
    job.resumes_at = Some(now - 1);
    job
}

fn job(obid: &Obid, id: &str) -> Value {
    call(obid, "GET", &format!("/v1/jobs/{id}"), None).body
}

/// Kept in the job files before obid starts (a restart): the due job is tried again in its own
/// session, its step and note Oby's, never words the owner said; a dismissed one and one a
/// follow-up took on aren't, and stop waiting.
#[test]
fn a_reset_job_is_tried_again_after_a_restart_unless_let_go() {
    let folder = Folder::new("resets");
    let remote = fixture(&folder.0.join("fixture"));
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude");
    let config = config(&folder.0, &remote, &agent);
    let due = limited("aaaa0001");
    let mut dismissed = limited("aaaa0002");
    dismissed.dismissed = Some(obi_protocol::time::now() - 30);
    let followed = limited("aaaa0003");
    let mut follow_up = limited("aaaa0004");
    follow_up.status = Status::Done;
    follow_up.resumes_at = None;
    follow_up.follow_up_of = Some(followed.id.clone());
    let dir = folder.0.join("home/jobs");
    std::fs::create_dir_all(&dir).unwrap();
    for job in [&due, &dismissed, &followed, &follow_up] {
        let path = dir.join(format!("{}.json", job.id));
        std::fs::write(path, serde_json::to_vec(job).unwrap()).unwrap();
    }
    let obid = start(&folder.0, &config, None);

    let again = within(60, "the due job was tried again", || {
        let job = job(&obid, &due.id);
        (job["round"] == 2 && job["status"] == "done").then_some(job)
    });
    assert_eq!(again["session"], json!(due.session), "{again}");
    assert_eq!(again["resumesAt"], Value::Null, "{again}");
    assert_eq!(again["reason"], Value::Null, "{again}");
    assert_eq!(
        again["notes"],
        json!(["Oby tried again after the usage reset."]),
        "{again}"
    );
    for (id, why) in [(&dismissed.id, "dismissed"), (&followed.id, "followed up")] {
        let job = within(30, &format!("the {why} job stopped waiting"), || {
            let job = job(&obid, id);
            job["resumesAt"].is_null().then_some(job)
        });
        assert_eq!(job["status"], "interrupted", "{why}: {job}");
        assert_eq!(job["round"], 1, "{why}: {job}");
        assert!(job["notes"].is_null(), "{why}: {job}");
    }
}
