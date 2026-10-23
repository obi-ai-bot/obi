//! Sentry through the real binary (#1127; docs/runner-api.md, "obid only: Sentry"): a read-only
//! token connected over the API, a project followed and mapped to a repository, a new error
//! after the first read offered once in the inbox, and `Look into it` starting an investigate job
//! with the stack trace quoted and none of the product's users' data. Sentry is a stub on
//! 127.0.0.1 that answers only GETs.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use support::*;

/// Sentry's answers: the token's scopes, the projects, the search (empty until `found` is set),
/// and issue 7 with its latest event. Every request line it got is kept.
fn stub_sentry(found: Arc<AtomicBool>, got: Arc<Mutex<Vec<String>>>) -> String {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let url = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = answer(stream, &found, &got);
        }
    });
    url
}

fn issue() -> Value {
    json!({"id": "7", "shortId": "API-7", "title": "ZeroDivisionError: division by zero",
           "culprit": "app/api.py in handler", "level": "error", "status": "unresolved",
           "substatus": "new", "count": "3", "firstSeen": "2026-10-23T03:12:00.5Z",
           "lastSeen": "2026-10-23T03:20:00Z", "permalink": "https://acme.sentry.io/issues/7/",
           "project": {"id": "11", "slug": "api", "name": "API"}})
}

fn answer(stream: TcpStream, found: &AtomicBool, got: &Mutex<Vec<String>>) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut first = String::new();
    reader.read_line(&mut first)?;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        if line.trim().is_empty() {
            break;
        }
    }
    got.lock().unwrap().push(first.trim().to_owned());
    let path = first
        .split(' ')
        .nth(1)
        .unwrap_or("")
        .split('?')
        .next()
        .unwrap_or("");
    let body = match path {
        "/api/0/" => json!({"auth": {"scopes": ["event:read", "org:read", "project:read"]},
                            "user": {"email": "owner@example.test"}}),
        "/api/0/organizations/acme/projects/" => {
            json!([{"id": "11", "slug": "api", "name": "API"}])
        }
        "/api/0/organizations/acme/issues/" if found.load(Ordering::SeqCst) => json!([issue()]),
        "/api/0/organizations/acme/issues/" => json!([]),
        "/api/0/organizations/acme/issues/7/" => issue(),
        "/api/0/organizations/acme/issues/7/events/latest/" => json!({
            "user": {"email": "customer@example.test", "ip_address": "203.0.113.9"},
            "tags": [{"key": "environment", "value": "production"}],
            "entries": [{"type": "request", "data": {"data": "REQUEST-BODY"}},
                        {"type": "exception", "data": {"values": [{"type": "ZeroDivisionError",
                         "value": "division by zero", "stacktrace": {"frames": [
                            {"filename": "app/api.py", "function": "handler", "lineNo": 42,
                             "inApp": true, "vars": {"card": "FRAME-VAR"}}]}}]}}]}),
        _ => Value::Null,
    };
    let (status, text) = if body.is_null() {
        ("404 Not Found", "{}".to_owned())
    } else {
        ("200 OK", body.to_string())
    };
    let mut stream = stream;
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
        text.len()
    )
}

#[test]
fn sentry_offers_a_new_error_and_look_into_it_quotes_the_trace() {
    let folder = Folder::new("sentry");
    let remote = fixture(&folder.0.join("fixture"));
    let mut obid = start(&folder.0, &config(&folder.0, &remote, &stub_agent()), None);
    let found = Arc::new(AtomicBool::new(false));
    let got = Arc::new(Mutex::new(Vec::new()));
    let url = stub_sentry(found.clone(), got.clone());
    let token = format!("sntryu_{}", "4f1c9a7e2b8d4c6fa0e3b5d7c9f1a2b4");

    let connected = call(
        &obid,
        "PUT",
        "/v1/sentry",
        Some(&json!({"url": url, "org": "acme", "token": token})),
    );
    assert_eq!(connected.status, 200, "{}", connected.text);
    assert_eq!(
        connected.body["projects"],
        json!([{"slug": "api", "name": "API", "follow": false, "repo": null}])
    );
    assert_eq!(connected.body["repos"], json!(["obi-e2e/fixture-app"]));
    assert!(!connected.text.contains(&token));
    // Following it reads now: the first read only notes what's there.
    let follow = json!({"follow": true, "repo": "obi-e2e/fixture-app"});
    let followed = call(&obid, "PATCH", "/v1/sentry/projects/api", Some(&follow));
    assert_eq!(followed.status, 200, "{}", followed.text);
    within(15, "the first read", || {
        call(&obid, "GET", "/v1/sentry", None).body["checkedAt"]
            .as_str()
            .map(str::to_owned)
    });
    // A new error, then a read: one offer.
    found.store(true, Ordering::SeqCst);
    assert_eq!(
        call(&obid, "PATCH", "/v1/sentry/projects/api", Some(&follow)).status,
        200
    );
    let offer = within(15, "the Sentry offer", || {
        call(&obid, "GET", "/v1/inbox", None)
            .body
            .as_array()?
            .iter()
            .find(|i| i["title"] == "Sentry: API-7")
            .cloned()
    });
    assert_eq!(offer["kind"], "pluginEvent");
    assert_eq!(
        offer["text"],
        "Sentry says API-7 in api is new: 3 events since 2026-10-23T03:12:00Z."
    );
    assert_eq!(
        offer["options"],
        json!([
            "Look into it",
            "Look into it, and from now on for api",
            "Dismiss"
        ])
    );

    let started = call(
        &obid,
        "POST",
        &format!("/v1/inbox/{}/answer", offer["id"].as_str().unwrap()),
        Some(&json!({"answer": "Look into it"})),
    );
    assert_eq!(started.status, 200, "{}", started.text);
    let id = started.body["job"].as_str().unwrap().to_owned();
    let job = call(&obid, "GET", &format!("/v1/jobs/{id}"), None).body;
    assert_eq!(
        (&job["kind"], &job["title"]),
        (&json!("investigate"), &json!("Sentry: API-7"))
    );
    assert_eq!(
        job["task"],
        "Look into Sentry issue API-7 in api. What Sentry reported is quoted in .obi/inputs/sentry-API-7.md."
    );
    let quoted = within(30, "the quoted trace in the job's worktree", || {
        std::fs::read_to_string(
            obid.home
                .join(format!("worktrees/{id}/.obi/inputs/sentry-API-7.md")),
        )
        .ok()
    });
    assert!(
        quoted.contains("ZeroDivisionError: division by zero"),
        "{quoted}"
    );
    assert!(
        quoted.contains("at handler (app/api.py:42) [in app]"),
        "{quoted}"
    );
    for users in [
        "customer@example.test",
        "203.0.113.9",
        "REQUEST-BODY",
        "FRAME-VAR",
    ] {
        assert!(!quoted.contains(users), "{users}: {quoted}");
    }
    let calls = got.lock().unwrap().clone();
    assert!(
        calls.iter().all(|line| line.starts_with("GET ")),
        "{calls:?}"
    );
    // Disconnecting forgets the token.
    assert_eq!(call(&obid, "DELETE", "/v1/sentry", None).status, 204);
    assert_eq!(
        call(&obid, "GET", "/v1/sentry", None).body["connected"],
        false
    );
    assert!(obid.stop().success());
}
