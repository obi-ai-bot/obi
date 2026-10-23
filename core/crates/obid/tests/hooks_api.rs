//! Webhooks into obid (#1128; docs/runner-api.md, "obid only: webhooks") on the real binary: a hook
//! made on loopback only, its secret in the vault and in no answer, event or log; a delivery to the
//! gateway's `/v1/hooks/{id}/deliver` with no device token, checked there: the signature, a
//! duplicate, the size.

mod support;

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

const ID: &str = "abcdefghij0123456789abcdefghij01";

fn started(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(
        &folder.0,
        &remote,
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude"),
    );
    config["gateway"] = json!("127.0.0.1:0");
    start(&folder.0, &config, None)
}

fn secret() -> String {
    format!("hook-{}-secret", uuid::Uuid::new_v4().simple())
}

fn sign(secret: &str, body: &[u8]) -> String {
    let key = aws_lc_rs::hmac::Key::new(aws_lc_rs::hmac::HMAC_SHA256, secret.as_bytes());
    format!(
        "sha256={}",
        hex::encode(aws_lc_rs::hmac::sign(&key, body).as_ref())
    )
}

/// A delivery to the gateway, as the control plane passes it on: the body and these headers only.
fn deliver(obid: &Obid, id: &str, body: &[u8], headers: &[(&str, &str)]) -> (u16, Value) {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.gateway.expect("a gateway"))).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let mut text = format!(
        "POST /v1/hooks/{id}/deliver HTTP/1.1\r\nHost: oby-abc.oby-devices.test\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n",
        body.len()
    );
    for (name, value) in headers {
        text.push_str(&format!("{name}: {value}\r\n"));
    }
    text.push_str("\r\n");
    stream.write_all(text.as_bytes()).unwrap();
    stream.write_all(body).unwrap();
    let mut raw = Vec::new();
    let _ = stream.read_to_end(&mut raw);
    let raw = String::from_utf8_lossy(&raw).into_owned();
    let (head, rest) = raw.split_once("\r\n\r\n").unwrap_or((&raw, ""));
    let status = head
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    (
        status,
        serde_json::from_str(rest.trim()).unwrap_or(Value::Null),
    )
}

#[test]
fn a_hook_is_made_on_loopback_and_its_deliveries_are_checked_at_the_gateway() {
    let folder = Folder::new("hooks");
    let mut obid = started(&folder);
    let secret = secret();
    let url = format!("https://oby-control.tetrix.pro/h/{ID}");
    let made = call(
        &obid,
        "POST",
        "/v1/hooks",
        Some(
            &json!({"id": ID, "url": url, "name": "github-obi", "source": "github",
                     "secret": secret, "repo": "obi-e2e/fixture-app"}),
        ),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    assert_eq!(made.body["name"], "github-obi");
    assert!(!made.text.contains(&secret));
    let listed = call(&obid, "GET", "/v1/hooks", None);
    assert_eq!(listed.body.as_array().unwrap().len(), 1);
    assert!(!listed.text.contains(&secret));
    let refused = call(
        &obid,
        "POST",
        "/v1/hooks",
        Some(
            &json!({"id": ID, "url": url, "name": "Bad Name", "source": "github", "secret": secret}),
        ),
    );
    assert_eq!(refused.status, 422);

    // GitHub's ping, signed: accepted, and the hook's row says so.
    let ping = br#"{"zen":"Design for failure.","hook_id":1}"#;
    let signature = sign(&secret, ping);
    let headers = [
        ("X-Hub-Signature-256", signature.as_str()),
        ("X-GitHub-Event", "ping"),
    ];
    assert_eq!(deliver(&obid, ID, ping, &headers).0, 202);
    let row = call(&obid, "GET", "/v1/hooks", None).body[0].clone();
    assert_eq!(row["lastDelivery"]["result"], "accepted");
    // The same body again: a duplicate, so a captured delivery can't be replayed into work.
    assert_eq!(
        deliver(&obid, ID, ping, &headers),
        (200, json!({"duplicate": true}))
    );
    // A wrong or missing signature, an unknown hook.
    assert_eq!(deliver(&obid, ID, b"{}", &headers).0, 401);
    assert_eq!(deliver(&obid, ID, b"{}", &[]).0, 401);
    assert_eq!(
        call(&obid, "GET", "/v1/hooks", None).body[0]["lastDelivery"]["result"],
        "bad signature"
    );
    assert_eq!(deliver(&obid, &"z".repeat(32), ping, &headers).0, 404);
    // Too large, refused before it's read whole.
    let big = vec![b'x'; 1024 * 1024 + 1];
    let big_signature = sign(&secret, &big);
    assert_eq!(
        deliver(&obid, ID, &big, &[("X-Hub-Signature-256", &big_signature)]).0,
        413
    );
    // The management routes aren't on the gateway.
    // (crate::gateway's unit test holds the allowlist; a delivery needs no device token.)

    // The secret is in no file of obid's but the vault, and in no log line.
    assert!(!obid.log().contains(&secret));
    assert!(
        !std::fs::read_to_string(obid.home.join("hooks.json"))
            .unwrap()
            .contains(&secret)
    );
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/hooks/{ID}"), None).status,
        204
    );
    assert_eq!(deliver(&obid, ID, ping, &headers).0, 404);
    assert!(obid.stop().success());
}
