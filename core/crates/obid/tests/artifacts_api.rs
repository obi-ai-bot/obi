//! Artifacts (docs/runner-api.md, "obid only: artifacts"), on the real obid binary: a job's
//! `.obi/artifacts/` is published when it ends and listed on the job; the API lists, shows,
//! serves (with the artifact policy), renames and deletes them; a link or a secret is never
//! published, a path out of an artifact never served; and a paired phone reads them through the
//! gateway, bytes and headers as they are.

mod support;

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

const POLICY: &str = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' data: blob:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; connect-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox allow-scripts";
const PNG: [u8; 12] = [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xfe, 0x00, 0x80,
];

fn agent() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude")
}

/// One GET on `port` with `token`, as raw as it comes: the status, the head (lower case) and the
/// body's bytes.
fn raw_get(port: u16, host: &str, token: &str, target: &str) -> (u16, String, Vec<u8>) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    write!(
        stream,
        "GET {target} HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8(raw[..end].to_vec())
        .unwrap()
        .to_ascii_lowercase();
    let mut body = raw[end + 4..].to_vec();
    if head.contains("transfer-encoding: chunked") {
        let mut out = Vec::new();
        loop {
            let line = body.windows(2).position(|w| w == b"\r\n").unwrap();
            let size =
                usize::from_str_radix(std::str::from_utf8(&body[..line]).unwrap().trim(), 16)
                    .unwrap();
            if size == 0 {
                break;
            }
            out.extend_from_slice(&body[line + 2..line + 2 + size]);
            body = body[line + 4 + size..].to_vec();
        }
        body = out;
    }
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    (status, head, body)
}

fn header<'a>(head: &'a str, name: &str) -> Vec<&'a str> {
    head.lines()
        .filter_map(|l| l.strip_prefix(&format!("{name}: ")))
        .collect()
}

/// A research job whose agent writes `.obi/artifacts/` (tests/agents/fake-claude, ARTIFACTS),
/// waited on to its end.
fn job_with_artifacts(obid: &Obid) -> Value {
    job_doing(obid, "ARTIFACTS")
}

/// A research job with `task`, waited on to its end.
fn job_doing(obid: &Obid, task: &str) -> Value {
    let answer = call(
        obid,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "research", "task": task, "title": "Make artifacts"}}),
        ),
    );
    assert_eq!(answer.status, 201, "{}", answer.text);
    let id = answer.body["id"].as_str().unwrap();
    let job = call(obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(job.status, 200, "{}", job.text);
    assert_eq!(job.body["status"], "done", "{}", job.text);
    job.body
}

/// The artifacts listed on `job`, by title.
fn by_title(obid: &Obid, job: &Value) -> Vec<(String, Value)> {
    let mut all: Vec<(String, Value)> = job["artifacts"]
        .as_array()
        .unwrap_or_else(|| panic!("no artifacts on {job}"))
        .iter()
        .map(|a| {
            assert_eq!(a.as_object().unwrap().len(), 2, "{a}");
            assert_eq!(a["version"], 1, "{a}");
            let artifact = call(
                obid,
                "GET",
                &format!("/v1/artifacts/{}", a["id"].as_str().unwrap()),
                None,
            );
            assert_eq!(artifact.status, 200, "{}", artifact.text);
            (
                artifact.body["title"].as_str().unwrap().to_owned(),
                artifact.body,
            )
        })
        .collect();
    all.sort_by(|a, b| a.0.cmp(&b.0));
    all
}

/// A job ends: each entry of its `.obi/artifacts/` is an artifact of that job (`artifact`
/// events, `artifacts` on the job), but for the link and the one holding a secret, which say why
/// in `artifactProblems`. Its files are served with their type, the artifact policy and nosniff;
/// nothing else is (hidden names, `..`, another version, a bad id). Renamed, then deleted.
#[test]
fn a_jobs_artifacts_are_published_when_it_ends() {
    let folder = Folder::new("artifacts-job");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote, &agent()), None);
    let events = follow_events(&obid);
    let job = job_with_artifacts(&obid);
    let job_id = job["id"].as_str().unwrap();
    let artifacts = by_title(&obid, &job);
    let titles: Vec<&str> = artifacts.iter().map(|(t, _)| t.as_str()).collect();
    assert_eq!(titles, ["chart", "notes", "page"], "{job}");
    let problems = job["artifactProblems"].as_array().unwrap();
    assert_eq!(problems.len(), 3, "{job}");
    // The entry whose name is a key: refused, and its name never said (#648's review, F2).
    assert_eq!(
        problems[0], "Not published: a name in it looks like a secret, so obid doesn't say it.",
        "{job}"
    );
    assert!(!job.to_string().contains("QWERTYUIOP"), "{job}");
    assert!(
        problems[1]
            .as_str()
            .unwrap()
            .starts_with("away.md: Not published: .obi/artifacts/away.md is a link"),
        "{job}"
    );
    assert!(
        problems[2]
            .as_str()
            .unwrap()
            .starts_with("leak.md: Not published: the secret scan found")
            && problems[2].as_str().unwrap().contains("AWS access key"),
        "{job}"
    );
    let published = events_named(&events, "artifact", 30, |got| got.len() >= 3);
    for (title, artifact) in &artifacts {
        assert_eq!(artifact["job"], job_id);
        assert_eq!(artifact["conversation"], Value::Null);
        assert!(
            published.contains(&json!({"id": artifact["id"], "version": 1, "title": title,
                "kind": artifact["kind"], "conversation": null, "job": job_id})),
            "{published:?}"
        );
    }
    let (chart, notes, page) = (&artifacts[0].1, &artifacts[1].1, &artifacts[2].1);
    assert_eq!(page["kind"], "html");
    assert_eq!(
        page["versions"][0]["files"],
        json!(["index.html", "style.css"])
    );
    assert_eq!(page["versions"][0]["version"], 1);
    assert_eq!(notes["kind"], "markdown");
    assert_eq!(chart["kind"], "image");
    // Listed, newest first, by job or conversation.
    let listed = call(&obid, "GET", &format!("/v1/artifacts?job={job_id}"), None);
    assert_eq!(listed.body.as_array().unwrap().len(), 3, "{}", listed.text);
    assert_eq!(
        call(&obid, "GET", "/v1/artifacts?job=another", None).body,
        json!([])
    );
    assert_eq!(
        call(&obid, "GET", "/v1/artifacts?conversation=c1", None).body,
        json!([])
    );

    // Served with their type, the policy and nosniff; the png byte for byte.
    let page_id = page["id"].as_str().unwrap();
    let file = |id: &str, rest: &str| {
        raw_get(
            obid.port,
            "127.0.0.1",
            TOKEN,
            &format!("/v1/artifacts/{id}/{rest}"),
        )
    };
    let (status, head, body) = file(page_id, "1/index.html");
    assert_eq!(status, 200, "{head}");
    assert_eq!(header(&head, "content-type"), ["text/html; charset=utf-8"]);
    assert_eq!(
        header(&head, "content-security-policy"),
        [POLICY.to_ascii_lowercase()]
    );
    assert_eq!(header(&head, "x-content-type-options"), ["nosniff"]);
    assert!(String::from_utf8(body).unwrap().contains("<h1>Hello</h1>"));
    let (status, head, _) = file(page_id, "1/style.css");
    assert_eq!(
        (status, header(&head, "content-type")),
        (200, vec!["text/css; charset=utf-8"])
    );
    assert_eq!(
        header(&head, "content-security-policy"),
        [POLICY.to_ascii_lowercase()]
    );
    let (status, head, body) = file(chart["id"].as_str().unwrap(), "1/chart.png");
    assert_eq!(
        (status, header(&head, "content-type")),
        (200, vec!["image/png"])
    );
    assert_eq!(
        header(&head, "content-security-policy"),
        [POLICY.to_ascii_lowercase()]
    );
    assert_eq!(body, PNG);
    let (status, head, _) = file(notes["id"].as_str().unwrap(), "1/notes.md");
    assert_eq!(
        (status, header(&head, "content-type")),
        (200, vec!["text/markdown; charset=utf-8"])
    );

    // Nothing else.
    for target in [
        format!("{page_id}/1/.hidden"),
        format!("{page_id}/1/../artifact.json"),
        format!("{page_id}/1/%2e%2e/artifact.json"),
        format!("{page_id}/1/%2e%2e/%2e%2e/%2e%2e/api-token"),
        format!("{page_id}/1/..%2f..%2f..%2fapi-token"),
        format!("{page_id}/2/index.html"),
        format!("{page_id}/x/index.html"),
        format!("{page_id}/1/missing.html"),
        "..%2f..%2fapi-token/1/x".to_owned(),
        "%2e%2e/1/api-token".to_owned(),
    ] {
        let (status, _, body) = raw_get(
            obid.port,
            "127.0.0.1",
            TOKEN,
            &format!("/v1/artifacts/{target}"),
        );
        assert_eq!(status, 404, "{target}");
        assert!(!String::from_utf8_lossy(&body).contains(TOKEN), "{target}");
    }
    assert_eq!(
        call(&obid, "GET", "/v1/artifacts/not-an-id", None).status,
        404
    );
    assert_eq!(
        raw_get(
            obid.port,
            "127.0.0.1",
            "wrong",
            &format!("/v1/artifacts/{page_id}/1/index.html")
        )
        .0,
        401
    );
    // The link and the secret were never kept.
    let kept = std::fs::read_dir(obid.home.join("artifacts"))
        .unwrap()
        .count();
    assert_eq!(kept, 3);

    // Renamed; a bad title or body refused.
    let renamed = call(
        &obid,
        "PATCH",
        &format!("/v1/artifacts/{page_id}"),
        Some(&json!({"title": " Landing page "})),
    );
    assert_eq!(
        (renamed.status, renamed.body["title"].clone()),
        (200, json!("Landing page")),
        "{}",
        renamed.text
    );
    assert_eq!(
        call(
            &obid,
            "PATCH",
            &format!("/v1/artifacts/{page_id}"),
            Some(&json!({"title": "a\nb"}))
        )
        .status,
        422
    );
    assert_eq!(
        call(
            &obid,
            "PATCH",
            &format!("/v1/artifacts/{page_id}"),
            Some(&json!({"name": "x"}))
        )
        .status,
        400
    );
    assert_eq!(
        call(
            &obid,
            "PATCH",
            "/v1/artifacts/00000000-0000-4000-8000-000000000000",
            Some(&json!({"title": "x"}))
        )
        .status,
        404
    );
    // Deleted, with its files.
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/artifacts/{page_id}"), None).status,
        204
    );
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/artifacts/{page_id}"), None).status,
        404
    );
    assert_eq!(
        call(&obid, "GET", &format!("/v1/artifacts/{page_id}"), None).status,
        404
    );
    assert_eq!(file(page_id, "1/index.html").0, 404);
    assert!(!obid.home.join("artifacts").join(page_id).exists());
    let gone = events_named(&events, "artifact", 10, |got| {
        got.iter().any(|e| e["deleted"] == true)
    });
    assert!(
        gone.contains(&json!({"id": page_id, "deleted": true})),
        "{gone:?}"
    );
}

/// A paired phone lists and reads artifacts through the gateway, each file as it is (a png's
/// bytes untouched) with the policy and nosniff; renaming and deleting stay on the loopback API.
#[test]
fn a_phone_reads_artifacts_through_the_gateway() {
    let folder = Folder::new("artifacts-gateway");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["gateway"] = json!("127.0.0.1:0");
    let obid = start(&folder.0, &config, None);
    let job = job_with_artifacts(&obid);
    let artifacts = by_title(&obid, &job);
    let (chart, page) = (&artifacts[0].1, &artifacts[2].1);
    let invitation = call(
        &obid,
        "POST",
        "/v1/pairing/invite",
        Some(
            &json!({"url": "https://mac.tail0000.ts.net:8443", "name": "My Mac", "hostname": "mac.tail0000.ts.net:8443"}),
        ),
    );
    assert_eq!(invitation.status, 200, "{}", invitation.text);
    let gateway = obid.gateway.unwrap();
    let mut stream = TcpStream::connect(("127.0.0.1", gateway)).unwrap();
    let body = json!({"credential": invitation.body["code"], "name": "Alice's iPhone"}).to_string();
    write!(stream, "POST /v1/pairing HTTP/1.1\r\nHost: mac.tail0000.ts.net\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    let mut said = String::new();
    stream.read_to_string(&mut said).unwrap();
    let token = said
        .split("\"token\":\"")
        .nth(1)
        .and_then(|t| t.split('"').next())
        .unwrap_or_else(|| panic!("{said}"))
        .to_owned();
    let phone = |target: &str| raw_get(gateway, "mac.tail0000.ts.net", &token, target);

    let (status, _, body) = phone(&format!(
        "/v1/artifacts?job={}",
        job["id"].as_str().unwrap()
    ));
    assert_eq!(status, 200);
    assert_eq!(
        serde_json::from_slice::<Value>(&body)
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        3
    );
    let (status, _, body) = phone(&format!("/v1/artifacts/{}", page["id"].as_str().unwrap()));
    assert_eq!(status, 200);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["kind"],
        "html"
    );
    let (status, head, body) = phone(&format!(
        "/v1/artifacts/{}/1/chart.png",
        chart["id"].as_str().unwrap()
    ));
    assert_eq!(status, 200, "{head}");
    assert_eq!(header(&head, "content-type"), ["image/png"]);
    assert_eq!(
        header(&head, "content-security-policy"),
        [POLICY.to_ascii_lowercase()]
    );
    assert_eq!(header(&head, "x-content-type-options"), ["nosniff"]);
    assert_eq!(body, PNG);
    let (status, head, body) = phone(&format!(
        "/v1/artifacts/{}/1/index.html",
        page["id"].as_str().unwrap()
    ));
    assert_eq!(status, 200);
    assert_eq!(
        header(&head, "content-security-policy"),
        [POLICY.to_ascii_lowercase()]
    );
    assert!(String::from_utf8(body).unwrap().contains("<h1>Hello</h1>"));
    // Only GET.
    for method in ["PATCH", "DELETE"] {
        let mut stream = TcpStream::connect(("127.0.0.1", gateway)).unwrap();
        write!(stream, "{method} /v1/artifacts/{} HTTP/1.1\r\nHost: mac.tail0000.ts.net\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{{\"title\": \"x\"}}", page["id"].as_str().unwrap()).unwrap();
        let mut said = String::new();
        stream.read_to_string(&mut said).unwrap();
        assert!(said.starts_with("HTTP/1.1 404"), "{method}: {said}");
    }
    assert_eq!(
        call(
            &obid,
            "GET",
            &format!("/v1/artifacts/{}", page["id"].as_str().unwrap()),
            None
        )
        .body["title"],
        "page"
    );
}

/// A job publishes at most 20 entries of its `.obi/artifacts/`, the first by name; the rest are
/// refused in one line (#648's review, F3).
#[test]
fn a_job_publishes_at_most_twenty_artifacts() {
    let folder = Folder::new("artifacts-many");
    let remote = fixture(&folder.0.join("fixture"));
    let obid = start(&folder.0, &config(&folder.0, &remote, &agent()), None);
    let job = job_doing(&obid, "ARTIFACTS_MANY");
    assert_eq!(job["artifacts"].as_array().unwrap().len(), 20, "{job}");
    assert_eq!(
        job["artifactProblems"],
        json!(["5 more entries: Not published: a job publishes at most 20 artifacts."]),
        "{job}"
    );
    let titles: Vec<String> = by_title(&obid, &job).into_iter().map(|(t, _)| t).collect();
    assert_eq!(titles.first().map(String::as_str), Some("n00"));
    assert_eq!(titles.last().map(String::as_str), Some("n19"));
}
