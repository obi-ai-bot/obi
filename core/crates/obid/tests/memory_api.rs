//! Memory (#378, first part; docs/runner-api.md, "obid only: memory"): a suggestion becomes a
//! memory only on the owner's Remember, checked and secret-scanned on its way in, kept 0600 in
//! `home/memory/`, listed and deleted. Finding itself is covered in src/memory.rs.
mod support;

use std::os::unix::fs::PermissionsExt;

use serde_json::{Value, json};
use support::*;

fn suggestion(id: &str, title: &str, text: &str) -> Value {
    json!({"id": id, "scope": "user", "repo": null, "kind": "preference", "title": title,
           "text": text, "from": "You said it in 2 conversations",
           "sources": [{"quote": text, "place": "You, in “Release planning”", "link": null}]})
}

#[test]
fn a_suggestion_is_saved_only_on_remember_and_never_a_secret_or_a_wider_rule() {
    let folder = Folder::new("memory-api");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &stub_agent());
    let memory = folder.0.join("home/memory");
    std::fs::create_dir_all(&memory).unwrap();
    // Built here, so no token sits in the repository: what the scan must stop.
    let token = format!("ghp_{}", "Zq9Xw2Lm7Rt4".repeat(3));
    std::fs::write(
        memory.join("suggestions.json"),
        json!([
            suggestion(
                "s0000000a",
                "Tests with every fix",
                "Write tests with every fix."
            ),
            suggestion(
                "s0000000b",
                "Straight to main",
                "Push straight to main when it's green."
            ),
            suggestion(
                "s0000000c",
                "The token",
                &format!("Use {token} for GitHub.")
            ),
        ])
        .to_string(),
    )
    .unwrap();
    let obid = start(&folder.0, &config, None);

    let listed = call(&obid, "GET", "/v1/memory", None);
    assert_eq!(listed.status, 200, "{}", listed.text);
    assert_eq!(listed.body["memories"], json!([]));
    assert_eq!(listed.body["suggestions"].as_array().unwrap().len(), 3);
    assert_eq!(listed.body["question"], "Can I remember that?");

    // A rule AGENTS.md keeps fixed isn't widened, and a secret isn't kept: nothing is saved.
    let wider = call(
        &obid,
        "POST",
        "/v1/memory/suggestions/s0000000b/remember",
        None,
    );
    assert_eq!(wider.status, 422, "{}", wider.text);
    assert!(
        wider.text.contains("rule that stays fixed"),
        "{}",
        wider.text
    );
    let secret = call(
        &obid,
        "POST",
        "/v1/memory/suggestions/s0000000c/remember",
        None,
    );
    assert_eq!(secret.status, 422, "{}", secret.text);
    assert!(
        secret.text.contains("looks like a secret"),
        "{}",
        secret.text
    );
    assert!(
        !memory.join("user").exists()
            || std::fs::read_dir(memory.join("user"))
                .unwrap()
                .next()
                .is_none()
    );

    // Remember: one memory, 0600, listed with where it came from; the suggestion goes.
    let saved = call(
        &obid,
        "POST",
        "/v1/memory/suggestions/s0000000a/remember",
        None,
    );
    assert_eq!(saved.status, 201, "{}", saved.text);
    let id = saved.body["id"].as_str().unwrap().to_owned();
    assert_eq!(saved.body["source"], "found");
    let file = memory.join(format!("user/{id}.md"));
    assert_eq!(
        std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(
        std::fs::read_to_string(&file)
            .unwrap()
            .ends_with("---\nWrite tests with every fix.\n")
    );
    let listed = call(&obid, "GET", "/v1/memory", None);
    assert_eq!(
        listed.body["memories"][0]["text"],
        "Write tests with every fix."
    );
    assert_eq!(
        listed.body["memories"][0]["from"],
        "You said it in 2 conversations"
    );
    let waiting: Vec<&str> = listed.body["suggestions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap())
        .collect();
    assert_eq!(waiting, ["s0000000b", "s0000000c"]);
    let again = call(
        &obid,
        "POST",
        "/v1/memory/suggestions/s0000000a/remember",
        None,
    );
    assert_eq!(again.status, 404, "{}", again.text);

    // Not this: gone, nothing saved.
    let dismissed = call(
        &obid,
        "POST",
        "/v1/memory/suggestions/s0000000b/dismiss",
        None,
    );
    assert_eq!(dismissed.status, 204, "{}", dismissed.text);
    let listed = call(&obid, "GET", "/v1/memory", None);
    assert_eq!(listed.body["memories"].as_array().unwrap().len(), 1);
    assert_eq!(listed.body["suggestions"].as_array().unwrap().len(), 1);

    let deleted = call(&obid, "DELETE", &format!("/v1/memory/{id}"), None);
    assert_eq!(deleted.status, 204, "{}", deleted.text);
    assert!(!file.exists());
    let gone = call(&obid, "DELETE", &format!("/v1/memory/{id}"), None);
    assert_eq!(gone.status, 404, "{}", gone.text);
    let odd = call(&obid, "DELETE", "/v1/memory/..%2Fsuggestions", None);
    assert_eq!(odd.status, 404, "{}", odd.text);
    assert!(memory.join("suggestions.json").exists());
}

#[test]
fn a_scan_that_cant_run_saves_nothing() {
    let folder = Folder::new("memory-api-broken-scan");
    let remote = fixture(&folder.0.join("fixture"));
    let config = config(&folder.0, &remote, &stub_agent());
    let memory = folder.0.join("home/memory");
    std::fs::create_dir_all(&memory).unwrap();
    std::fs::write(
        memory.join("suggestions.json"),
        json!([suggestion(
            "s0000000a",
            "Tests with every fix",
            "Write tests with every fix."
        )])
        .to_string(),
    )
    .unwrap();
    let broken = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/bin-broken-gitleaks");
    let obid = start(&folder.0, &config, Some(&broken));

    let refused = call(
        &obid,
        "POST",
        "/v1/memory/suggestions/s0000000a/remember",
        None,
    );
    assert_eq!(refused.status, 503, "{}", refused.text);
    assert!(
        refused.text.contains("Nothing was saved"),
        "{}",
        refused.text
    );
    assert!(!memory.join("user").exists());
    let listed = call(&obid, "GET", "/v1/memory", None);
    assert_eq!(listed.body["memories"], json!([]));
    assert_eq!(listed.body["suggestions"].as_array().unwrap().len(), 1);
}
