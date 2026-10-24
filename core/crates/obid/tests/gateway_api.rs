//! The gateway (#446; docs/runner-api.md, "LAN gateway (#284)"), on the real obid binary: paired
//! phones reach obid only through it, with a device token, on the routes it lists; invitations
//! are made and devices revoked on the loopback API with the API token; and what it answers has
//! the vault's secrets, agents' session ids and the accounts' homes taken out. Ported from
//! RunnerTests/GatewayTests.swift.

mod support;

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

fn agent() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-claude")
}

/// obid with a gateway on a port the system picks.
fn started(folder: &Folder) -> Obid {
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["gateway"] = json!("127.0.0.1:0");
    start(&folder.0, &config, None)
}

/// One request to the gateway, with `token` as its bearer when there is one.
fn through(
    obid: &Obid,
    token: Option<&str>,
    method: &str,
    target: &str,
    body: Option<&Value>,
) -> Answer {
    let body = body.map(Value::to_string);
    let mut stream = TcpStream::connect(("127.0.0.1", obid.gateway.expect("a gateway"))).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    // The Host a phone sends through `tailscale serve`: never a loopback name.
    let mut text =
        format!("{method} {target} HTTP/1.1\r\nHost: mac.tail0000.ts.net\r\nConnection: close\r\n");
    if let Some(token) = token {
        text.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    match &body {
        Some(body) => text.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        )),
        None if method != "GET" => text.push_str("Content-Length: 0\r\n"),
        None => {}
    }
    text.push_str("\r\n");
    text.push_str(body.as_deref().unwrap_or(""));
    stream.write_all(text.as_bytes()).unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let raw = String::from_utf8(raw).unwrap();
    let (head, rest) = raw.split_once("\r\n\r\n").unwrap();
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    let text = if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        unchunk(rest)
    } else {
        rest.to_owned()
    };
    let body = serde_json::from_str(text.trim()).unwrap_or(Value::Null);
    Answer { status, body, text }
}

fn unchunk(mut body: &str) -> String {
    let mut out = String::new();
    loop {
        let Some((size, rest)) = body.split_once("\r\n") else {
            return out;
        };
        let size = usize::from_str_radix(size.trim(), 16).unwrap();
        if size == 0 {
            return out;
        }
        out.push_str(&rest[..size]);
        body = &rest[size + 2..];
    }
}

/// An invitation made on the loopback API, redeemed at the gateway: the device token.
fn paired(obid: &Obid) -> String {
    let invitation = call(
        obid,
        "POST",
        "/v1/pairing/invite",
        Some(
            &json!({"url": "https://mac.tail0000.ts.net:8443", "name": "My Mac",
                                       "hostname": "mac.tail0000.ts.net:8443"}),
        ),
    );
    assert_eq!(invitation.status, 200, "{}", invitation.text);
    let redeemed = through(
        obid,
        None,
        "POST",
        "/v1/pairing",
        Some(&json!({"credential": invitation.body["code"], "name": "Alice's iPhone"})),
    );
    assert_eq!(redeemed.status, 200, "{}", redeemed.text);
    redeemed.body["token"].as_str().unwrap().to_owned()
}

/// Ports GatewayTests.pairingIsMadeOnTheLoopbackAPIWithTheRunnersToken: only the API token makes
/// an invitation and manages devices; the gateway redeems it once, and a revoked device is out.
#[test]
fn pairing_is_made_on_the_loopback_api_with_the_api_token() {
    let folder = Folder::new("gateway-pairing");
    let obid = started(&folder);
    let invite = json!({"url": "https://mac.tail0000.ts.net:8443", "name": "My Mac",
                        "hostname": "mac.tail0000.ts.net:8443"});
    let refused = call_with_token(&obid, "wrong", "POST", "/v1/pairing/invite", Some(&invite));
    assert_eq!(refused.status, 401, "{}", refused.text);
    let bad = call(
        &obid,
        "POST",
        "/v1/pairing/invite",
        Some(&json!({"url": "ftp://mac"})),
    );
    assert_eq!(bad.status, 400, "{}", bad.text);

    let invitation = call(&obid, "POST", "/v1/pairing/invite", Some(&invite)).body;
    let code = invitation["code"].as_str().unwrap();
    assert!(
        code.len() == 6 && code.chars().all(|c| c.is_ascii_digit()),
        "{invitation}"
    );
    assert!(
        invitation["secret"].as_str().unwrap().len() >= 32,
        "{invitation}"
    );
    assert_eq!(invitation["url"], "https://mac.tail0000.ts.net:8443");
    assert_eq!(invitation["hostname"], "mac.tail0000.ts.net:8443");
    assert_eq!(invitation["name"], "My Mac");
    let link: Value = serde_json::from_str(invitation["link"].as_str().unwrap()).unwrap();
    assert_eq!(
        link,
        json!({"name": "My Mac", "hostname": "mac.tail0000.ts.net:8443"})
    );

    let wrong = through(
        &obid,
        None,
        "POST",
        "/v1/pairing",
        Some(&json!({"credential": "000000x"})),
    );
    assert_eq!(wrong.status, 401, "{}", wrong.text);
    let redeemed = through(
        &obid,
        None,
        "POST",
        "/v1/pairing",
        Some(&json!({"credential": invitation["secret"], "name": "Alice's iPhone"})),
    );
    assert_eq!(redeemed.status, 200, "{}", redeemed.text);
    assert_eq!(
        redeemed.body["link"],
        json!({"name": "My Mac", "hostname": "mac.tail0000.ts.net:8443"})
    );
    let token = redeemed.body["token"].as_str().unwrap();
    let again = through(
        &obid,
        None,
        "POST",
        "/v1/pairing",
        Some(&json!({"credential": code})),
    );
    assert_eq!(again.status, 410, "once only: {}", again.text);

    let listed = call(&obid, "GET", "/v1/pairing/devices", None);
    assert_eq!(listed.status, 200, "{}", listed.text);
    assert_eq!(listed.body.as_array().unwrap().len(), 1, "{}", listed.text);
    assert_eq!(listed.body[0]["name"], "Alice's iPhone");
    assert!(!listed.text.contains(token), "never a token");
    let kept = std::fs::read_to_string(obid.home.join("gateway-devices.json")).unwrap();
    assert!(!kept.contains(token), "only its digest is kept");
    assert!(
        !listed.text.contains(kept.split('"').nth(1).unwrap()),
        "never a digest"
    );
    let id = listed.body[0]["id"].as_str().unwrap();

    assert_eq!(
        through(&obid, Some(token), "GET", "/v1/status", None).status,
        200
    );
    let unrevoked = call_with_token(
        &obid,
        "wrong",
        "DELETE",
        &format!("/v1/pairing/devices/{id}"),
        None,
    );
    assert_eq!(unrevoked.status, 401);
    let revoked = call(&obid, "DELETE", &format!("/v1/pairing/devices/{id}"), None);
    assert_eq!(revoked.status, 204, "{}", revoked.text);
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/pairing/devices/{id}"), None).status,
        404
    );
    assert_eq!(
        through(&obid, Some(token), "GET", "/v1/status", None).status,
        401
    );
}

/// Ports GatewayTests.gatewayRouterRequiresTokensAndHidesUnlistedRoutes and
/// gatewayForwardsTheRunnersTokenToTheMacRunner: without a device token nothing passes; a route
/// the gateway doesn't list is `404` even with one, pairing's own endpoints included; a listed
/// route reaches obid's API; and neither token works where the other does.
#[test]
fn the_gateway_needs_a_device_token_and_passes_only_its_routes() {
    let folder = Folder::new("gateway-routes");
    let obid = started(&folder);
    let token = paired(&obid);

    assert_eq!(through(&obid, None, "GET", "/v1/status", None).status, 401);
    assert_eq!(
        through(&obid, Some("not-a-device"), "GET", "/v1/status", None).status,
        401
    );
    // The API token isn't a device token.
    assert_eq!(
        through(&obid, Some(TOKEN), "GET", "/v1/status", None).status,
        401
    );
    // And a device token isn't the API token.
    assert_eq!(
        call_with_token(&obid, &token, "GET", "/v1/status", None).status,
        401
    );
    assert_eq!(
        through(&obid, None, "GET", "/v1/connections", None).status,
        404
    );
    for (method, target) in [
        ("POST", "/v1/pairing/invite"),
        ("GET", "/v1/pairing/devices"),
        ("DELETE", "/v1/pairing/devices/abc"),
        ("GET", "/v1/connections"),
        ("PUT", "/v1/settings/jobs"),
        ("GET", "/v1/obid/plugins"),
        ("GET", "/app/"),
    ] {
        let answer = through(&obid, Some(&token), method, target, None);
        assert_eq!(answer.status, 404, "{method} {target}: {}", answer.text);
    }

    let status = through(&obid, Some(&token), "GET", "/v1/status", None);
    assert_eq!(status.status, 200, "{}", status.text);
    assert_eq!(status.body["runner"]["engine"], "obid", "{}", status.text);
    let jobs = through(&obid, Some(&token), "GET", "/v1/jobs?limit=5", None);
    assert_eq!(
        (jobs.status, jobs.body.clone()),
        (200, json!([])),
        "{}",
        jobs.text
    );
}

/// Ports GatewayTests.gatewayRouterRedactsSecretsInFiniteAndSSEResponses and
/// gatewayScrubsSessionIDsAndAccountHomes on obid's own answers: a job whose request holds a vault
/// secret and an account's home, run by an agent that has a session, comes back through the
/// gateway with the secret, the home and the session id taken out, in an answer and in an event.
#[test]
fn gateway_answers_lose_vault_secrets_session_ids_and_account_homes() {
    let folder = Folder::new("gateway-scrub");
    let obid = started(&folder);
    let token = paired(&obid);
    let home = folder.0.join("home/accounts/stub").display().to_string();
    let value = format!("gw-secret-{}", std::process::id());
    let mut child = Command::new(OBID)
        .args(["vault", "--config"])
        .arg(folder.0.join("config.json"))
        .args(["add", "gateway-test"])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(value.as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());

    let mut stream = TcpStream::connect(("127.0.0.1", obid.gateway.unwrap())).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    stream
        .write_all(format!("GET /v1/events HTTP/1.1\r\nHost: mac.tail0000.ts.net\r\nAuthorization: Bearer {token}\r\n\r\n").as_bytes())
        .unwrap();

    let dispatched = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(&json!({"job": {
        "repo": "obi-e2e/fixture-app", "kind": "investigate",
        "task": format!("Use {value} with the login in {home}")}})),
    );
    assert_eq!(dispatched.status, 201, "{}", dispatched.text);
    let id = dispatched.body["id"].as_str().unwrap().to_owned();
    let ended = call(&obid, "GET", &format!("/v1/jobs/{id}/wait"), None);
    assert_eq!(ended.status, 200, "{}", ended.text);
    assert!(
        ended.body["session"].is_string(),
        "the agent has a session: {}",
        ended.text
    );

    let job = through(&obid, Some(&token), "GET", &format!("/v1/jobs/{id}"), None);
    assert_eq!(job.status, 200, "{}", job.text);
    assert!(job.body["session"].is_null(), "{}", job.text);
    assert_eq!(
        job.body["request"], "Use [vault: gateway-test] with the login in [home]",
        "{}",
        job.text
    );
    for text in [
        &job.text,
        &through(&obid, Some(&token), "GET", "/v1/jobs", None).text,
    ] {
        assert!(!text.contains(&value) && !text.contains(&home), "{text}");
        assert!(
            !text.contains("00000000-0000-4000-8000-000000000001"),
            "{text}"
        );
    }

    let mut seen = Vec::new();
    let mut buffer = [0u8; 8192];
    while let Ok(n) = stream.read(&mut buffer) {
        if n == 0 {
            break;
        }
        seen.extend_from_slice(&buffer[..n]);
        if String::from_utf8_lossy(&seen).contains("[vault: gateway-test]") && seen.len() > 4096 {
            break;
        }
    }
    let events = String::from_utf8_lossy(&seen);
    assert!(events.contains("[vault: gateway-test]"), "{events}");
    assert!(
        !events.contains(&value) && !events.contains(&home),
        "{events}"
    );
}

/// One raw request to the gateway: `extra` header lines as given.
fn raw(obid: &Obid, extra: &str, body: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.gateway.unwrap())).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let text = format!(
        "POST /v1/pairing HTTP/1.1\r\nHost: mac.tail0000.ts.net\r\nConnection: close\r\n{extra}Content-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(text.as_bytes()).unwrap();
    let mut answer = String::new();
    stream.read_to_string(&mut answer).unwrap();
    (answer.split(' ').nth(1).unwrap().parse().unwrap(), answer)
}

/// What a web page could send can't redeem or use up an invitation: a request a browser makes
/// (it says its `Origin`) is `403`, and one that isn't JSON is `415` (a page can't send JSON
/// across origins without asking first). A phone's name keeps no control characters, so it
/// can't forge lines in obid's log.
#[test]
fn only_a_phone_redeems_an_invitation() {
    let folder = Folder::new("gateway-browser");
    let obid = started(&folder);
    let invitation = call(
        &obid,
        "POST",
        "/v1/pairing/invite",
        Some(&json!({"url": "https://mac.tail0000.ts.net:8443"})),
    )
    .body;
    let code = invitation["code"].as_str().unwrap();
    let body = json!({"credential": "wrong"}).to_string();
    for _ in 0..6 {
        let (status, answer) = raw(
            &obid,
            "Origin: https://evil.example\r\nContent-Type: application/json\r\n",
            &body,
        );
        assert_eq!(status, 403, "{answer}");
        let (status, answer) = raw(&obid, "Content-Type: text/plain\r\n", &body);
        assert_eq!(status, 415, "{answer}");
    }
    // None of those counted: the invitation still works.
    let named = json!({"credential": code, "name": "Phone\nERROR forged log line"}).to_string();
    let (status, answer) = raw(&obid, "Content-Type: application/json\r\n", &named);
    assert_eq!(status, 200, "{answer}");
    let listed = call(&obid, "GET", "/v1/pairing/devices", None);
    assert_eq!(
        listed.body[0]["name"], "PhoneERROR forged log line",
        "{}",
        listed.text
    );
    assert!(
        !obid.log().contains("\nERROR forged log line"),
        "{}",
        obid.log()
    );
}

/// Reads from `stream` until `done` says so, the connection closes or `seconds` pass: what came.
fn read_until(stream: &mut TcpStream, seconds: u64, done: impl Fn(&str) -> bool) -> (String, bool) {
    stream
        .set_read_timeout(Some(Duration::from_millis(200)))
        .unwrap();
    let give_up = std::time::Instant::now() + Duration::from_secs(seconds);
    let mut seen = Vec::new();
    let mut buffer = [0u8; 4096];
    while std::time::Instant::now() < give_up {
        match stream.read(&mut buffer) {
            Ok(0) => return (String::from_utf8_lossy(&seen).into_owned(), true),
            Ok(n) => seen.extend_from_slice(&buffer[..n]),
            Err(_) => {}
        }
        if done(&String::from_utf8_lossy(&seen)) {
            break;
        }
    }
    (String::from_utf8_lossy(&seen).into_owned(), false)
}

fn open(obid: &Obid, token: &str, target: &str) -> TcpStream {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.gateway.unwrap())).unwrap();
    stream
        .write_all(format!("GET {target} HTTP/1.1\r\nHost: mac.tail0000.ts.net\r\nAuthorization: Bearer {token}\r\n\r\n").as_bytes())
        .unwrap();
    stream
}

/// A phone revoked while it follows the event stream hears nothing more: its stream ends at the
/// next event.
#[test]
fn a_revoked_phone_loses_its_event_stream() {
    let folder = Folder::new("gateway-revoke-stream");
    let obid = started(&folder);
    let token = paired(&obid);
    let mut events = open(&obid, &token, "/v1/events");
    let (head, _) = read_until(&mut events, 10, |seen| seen.contains("\r\n\r\n"));
    assert!(head.starts_with("HTTP/1.1 200"), "{head}");
    let id = call(&obid, "GET", "/v1/pairing/devices", None).body[0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        call(&obid, "DELETE", &format!("/v1/pairing/devices/{id}"), None).status,
        204
    );
    assert_eq!(call(&obid, "POST", "/v1/clear", None).status, 200);
    // The stream's last chunk (`0`) ends it; the connection itself may stay open for another request.
    let (after, closed) = read_until(&mut events, 10, |seen| seen.contains("0\r\n\r\n"));
    assert!(
        closed || after.contains("0\r\n\r\n"),
        "the stream still runs: {after}"
    );
    assert!(
        !after.contains("clear"),
        "an event reached a revoked phone: {after}"
    );
}

/// `GET /v1/jobs/{id}/wait` goes through as obid sends it, a space at once and the job at its end,
/// so a phone's wait doesn't time out on a long job.
#[test]
fn a_wait_through_the_gateway_starts_at_once() {
    let folder = Folder::new("gateway-wait");
    let obid = started(&folder);
    let token = paired(&obid);
    let job = call(
        &obid,
        "POST",
        "/v1/jobs",
        Some(&json!({"job": {
        "repo": "obi-e2e/fixture-app", "kind": "investigate", "task": "SLEEP"}})),
    );
    assert_eq!(job.status, 201, "{}", job.text);
    let id = job.body["id"].as_str().unwrap().to_owned();
    let mut wait = open(&obid, &token, &format!("/v1/jobs/{id}/wait"));
    let (head, _) = read_until(&mut wait, 5, |seen| seen.contains("\r\n\r\n"));
    assert!(
        head.starts_with("HTTP/1.1 200"),
        "no answer within 5 s: {head:?}"
    );
    assert_eq!(
        call(&obid, "POST", &format!("/v1/jobs/{id}/stop"), None).status,
        200
    );
    let (rest, _) = read_until(&mut wait, 20, |seen| seen.contains(&id));
    assert!(rest.contains(&id), "{rest}");
}

/// A phone's FCM token is kept with the paired device that handed it over through the gateway,
/// and revoking the device drops it: a lost phone gets no more alerts.
#[test]
fn revoking_a_device_drops_its_push_token() {
    use aws_lc_rs::encoding::AsDer;
    use base64::Engine as _;
    let folder = Folder::new("gateway-push");
    let obid = started(&folder);
    let key = aws_lc_rs::rsa::KeyPair::generate(aws_lc_rs::rsa::KeySize::Rsa2048).unwrap();
    let der = base64::engine::general_purpose::STANDARD.encode(key.as_der().unwrap().as_ref());
    let label = ["PRIVATE", "KEY"].join(" ");
    let account = json!({"type": "service_account", "project_id": "oby-test",
        "private_key": format!("-----BEGIN {label}-----\n{der}\n-----END {label}-----\n"),
        "client_email": "push@oby-test.iam.gserviceaccount.com",
        "token_uri": "https://oauth2.googleapis.com/token"});
    let mut child = Command::new(OBID)
        .args(["vault", "--config"])
        .arg(folder.0.join("config.json"))
        .args(["add", "oby.fcm.serviceAccount"])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(account.to_string().as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());

    let token = paired(&obid);
    let fcm =
        json!({"token": "fcm-token:lost-phone", "platform": "fcm", "topic": "com.deskree.oby"});
    let answer = through(&obid, Some(&token), "POST", "/v1/notifications", Some(&fcm));
    assert_eq!(answer.status, 200, "{}", answer.text);
    assert_eq!(answer.body, json!({"push": true}));
    let id = call(&obid, "GET", "/v1/pairing/devices", None).body[0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let file = obid.home.join("push/fcm.json");
    let kept: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(
        kept,
        json!([{"token": "fcm-token:lost-phone", "device": id}])
    );

    let revoked = call(&obid, "DELETE", &format!("/v1/pairing/devices/{id}"), None);
    assert_eq!(revoked.status, 204, "{}", revoked.text);
    let kept: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(kept, json!([]));
}

/// An iPhone's registration with Deskree's push relay is kept with the paired device that handed
/// it over, its push key out of obid's log, and goes when the device is revoked.
#[test]
fn revoking_a_device_drops_its_iphone_relay_registration() {
    let folder = Folder::new("gateway-relay");
    let obid = started(&folder);
    let token = paired(&obid);
    use base64::Engine as _;
    // What the phone derives from its pushSecret (which obid never gets): 32 bytes, base64url.
    let signs = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([7_u8; 32]);
    // The test iPhone's X25519 public half (the one crate::push's CryptoKit vector uses).
    let public = "IWlFcnjzHXlyLYTNMzTi8Jn5yrH6_QwEDMtloT3gQiY";
    let apns = |relay: &str| {
        json!({"apns": {"pushId": "push-id-1", "pushKey": signs, "sealKey": public,
                        "relay": relay}})
    };
    // Only the control plane obid pushes through (pushRelay, Deskree's by default).
    for relay in ["http://relay.example", "https://evil.example"] {
        let refused = through(
            &obid,
            Some(&token),
            "POST",
            "/v1/notifications",
            Some(&apns(relay)),
        );
        assert_eq!(refused.status, 422, "{relay}: {}", refused.text);
    }
    let answer = through(
        &obid,
        Some(&token),
        "POST",
        "/v1/notifications",
        Some(&apns("https://oby-control.deskree.com/")),
    );
    assert_eq!(answer.status, 200, "{}", answer.text);
    assert_eq!(answer.body, json!({"push": true}));
    let id = call(&obid, "GET", "/v1/pairing/devices", None).body[0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let file = obid.home.join("push/relay.json");
    let kept: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(
        kept,
        json!([{"pushId": "push-id-1", "pushKey": signs, "sealKey": public,
                "relay": "https://oby-control.deskree.com", "device": id}])
    );
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let revoked = call(&obid, "DELETE", &format!("/v1/pairing/devices/{id}"), None);
    assert_eq!(revoked.status, 204, "{}", revoked.text);
    let kept: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(kept, json!([]));
    assert!(!obid.log().contains(&signs), "{}", obid.log());
}

/// A channel listener's review waiting for Approve, in obid's home before it starts.
fn seed_listener_review(config: &Value) {
    let config = obid::config::Config::parse(&config.to_string()).unwrap();
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        let events = obid::events::Events::new();
        let jobs = obid::jobs::Jobs::open(config.clone(), events.clone(), Err("no sandbox".into()))
            .unwrap();
        let (_stop, stopping) = tokio::sync::watch::channel(false);
        let link = obid::sphere::Link::open(config, jobs, events, stopping).unwrap();
        let notice = obid::watch::Notice {
            key: "review:obi-ai-bot/obi#835".into(),
            source: "slack".into(),
            ..Default::default()
        };
        let mut item = obid::sphere::inbox::watch_item("listen", "", &notice, 1_792_501_200);
        item.id = "listen-review-0123456789abcdef".into();
        item.options = vec!["Approve".into(), "Dismiss".into()];
        link.add_items(vec![item]);
    });
}

/// A phone can't Approve a channel listener's review, which it doesn't show yet, however the
/// item's id is spelled in the path; its Dismiss goes through.
#[test]
fn a_phone_cant_approve_a_listeners_review() {
    let folder = Folder::new("gateway-listen-approve");
    let remote = fixture(&folder.0.join("fixture"));
    let mut config = config(&folder.0, &remote, &agent());
    config["gateway"] = json!("127.0.0.1:0");
    seed_listener_review(&config);
    let obid = start(&folder.0, &config, None);
    let token = paired(&obid);
    for target in [
        "/v1/inbox/listen-review-0123456789abcdef/answer",
        "/v1/inbox/listen%2Dreview-0123456789abcdef/answer",
        "/v1/inbox/%6Cisten-review-0123456789abcdef/answer",
    ] {
        let answer = through(
            &obid,
            Some(&token),
            "POST",
            target,
            Some(&json!({"answer": "Approve"})),
        );
        assert_eq!(answer.status, 403, "{target}: {}", answer.text);
    }
    let dismissed = through(
        &obid,
        Some(&token),
        "POST",
        "/v1/inbox/listen%2Dreview-0123456789abcdef/answer",
        Some(&json!({"answer": "Dismiss"})),
    );
    assert_eq!(dismissed.status, 200, "{}", dismissed.text);
    assert_eq!(dismissed.body["state"], "done");
}

/// #896: the tunnel's routes are on obid's own API, never on the gateway: a paired phone can't put
/// or delete the tunnel's token.
#[test]
fn a_phone_cannot_reach_the_tunnel_routes() {
    let folder = Folder::new("gateway-tunnel");
    let obid = started(&folder);
    let token = paired(&obid);
    for method in ["PUT", "DELETE"] {
        let answer = through(
            &obid,
            Some(&token),
            method,
            "/v1/obid/tunnel",
            Some(&json!({"token": "abc"})),
        );
        assert!(
            matches!(answer.status, 403 | 404),
            "{method}: {} {}",
            answer.status,
            answer.text
        );
    }
}

// ---------------------------------------------------------------------------------------------
// Through the owner's Obysphere (docs/runner-api.md, "obid only: the phone relay"): the fake
// Sphere relays what the test's phone sends, and keeps every byte it relayed.

use futures_util::{SinkExt as _, StreamExt as _};
use obid::relay::envelope::{Opener, Phone, Sealer};
use obid::sphere::channel::{Frame, Kind};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A phone the test plays, as the iPhone does: its relay socket and its session's keys.
struct TestPhone {
    ws: Socket,
    sealer: Sealer,
    opener: Opener,
    next: u32,
    /// Every envelope it sent, as sent.
    sent: Vec<Vec<u8>>,
}

/// The relay socket with `token` as its bearer: the upgrade's status when it's refused.
async fn relay_socket(relay: &Value, token: &str) -> Result<Socket, u16> {
    let sphere = relay["sphere"]
        .as_str()
        .unwrap()
        .replace("http://", "ws://");
    let mut request = format!("{sphere}/v0.1/relay/{}", relay["id"].as_str().unwrap())
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("Authorization", format!("Bearer {token}").parse().unwrap());
    match tokio_tungstenite::connect_async(request).await {
        Ok((ws, _)) => Ok(ws),
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            Err(response.status().as_u16())
        }
        Err(e) => panic!("the relay socket: {e}"),
    }
}

/// The next binary frame, or the close code, within `seconds`; `None` when nothing came.
async fn next_binary(ws: &mut Socket, seconds: u64) -> Option<Result<Vec<u8>, u16>> {
    let until = tokio::time::Instant::now() + Duration::from_secs(seconds);
    loop {
        match tokio::time::timeout_at(until, ws.next()).await {
            Err(_) => return None,
            Ok(Some(Ok(Message::Binary(bytes)))) => return Some(Ok(bytes.to_vec())),
            Ok(Some(Ok(Message::Close(frame)))) => {
                return Some(Err(frame.map_or(1005, |f| u16::from(f.code))));
            }
            Ok(Some(Ok(_))) => {}
            Ok(_) => return Some(Err(1006)),
        }
    }
}

impl TestPhone {
    /// Opens its socket with the QR's relay token and starts a session with the QR's Mac key.
    async fn connect(relay: &Value) -> TestPhone {
        let mut ws = relay_socket(relay, relay["token"].as_str().unwrap())
            .await
            .expect("the relay lets the phone in");
        let key = base64::Engine::decode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            relay["key"].as_str().unwrap(),
        )
        .unwrap();
        let phone = Phone::hello(&key).unwrap();
        ws.send(Message::Binary(phone.hello.clone().into()))
            .await
            .unwrap();
        let welcome = next_binary(&mut ws, 10)
            .await
            .expect("a welcome")
            .expect("the socket stays open");
        let (sealer, opener) = phone.welcomed(&welcome).expect("the pinned Mac answers");
        TestPhone {
            ws,
            sealer,
            opener,
            next: 1,
            sent: Vec::new(),
        }
    }

    async fn send(&mut self, frame: Frame) {
        let sealed = self.sealer.seal(&frame.encode());
        self.sent.push(sealed.clone());
        self.ws.send(Message::Binary(sealed.into())).await.unwrap();
    }

    /// Sends a request on a new stream, as a phone calls the gateway: its id.
    async fn ask(
        &mut self,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Option<&Value>,
    ) -> u32 {
        let stream = self.next;
        self.next += 1;
        let mut headers = json!({});
        if let Some(token) = token {
            headers["authorization"] = json!(format!("Bearer {token}"));
        }
        if body.is_some() {
            headers["content-type"] = json!("application/json");
        }
        let head = json!({"method": method, "path": path, "headers": headers});
        self.send(Frame::json(stream, Kind::Open, &head)).await;
        if let Some(body) = body {
            self.send(Frame::new(
                stream,
                Kind::Data,
                body.to_string().into_bytes(),
            ))
            .await;
        }
        self.send(Frame::new(stream, Kind::End, Vec::new())).await;
        stream
    }

    /// The next frame the Mac sealed, within `seconds`.
    async fn frame(&mut self, seconds: u64) -> Option<Frame> {
        let sealed = next_binary(&mut self.ws, seconds).await?.ok()?;
        let plain = self.opener.open(&sealed).expect("the Mac's frames open");
        Frame::decode(&plain)
    }

    /// The whole answer on `stream`: its status, its head and its body.
    async fn answer(&mut self, stream: u32) -> (u16, Value, Value) {
        let mut head = Value::Null;
        let mut body = Vec::new();
        loop {
            let frame = self.frame(30).await.expect("an answer");
            if frame.stream != stream {
                continue;
            }
            match frame.kind {
                Kind::Open => head = frame.value().unwrap(),
                Kind::Data => body.extend_from_slice(&frame.payload),
                Kind::End => break,
                Kind::Reset => panic!("the answer broke off"),
            }
        }
        let status = head["status"].as_u64().unwrap() as u16;
        (
            status,
            head,
            serde_json::from_slice(&body).unwrap_or(Value::Null),
        )
    }

    async fn call(
        &mut self,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Option<&Value>,
    ) -> (u16, Value) {
        let stream = self.ask(method, path, token, body).await;
        let (status, _, body) = self.answer(stream).await;
        (status, body)
    }
}

/// obid with a gateway, joined to a new fake Sphere.
async fn joined(folder: &Folder) -> (FakeSphere, Obid) {
    let sphere = FakeSphere::start().await;
    let obid = started(folder);
    let membership =
        tokio::task::block_in_place(|| join_a(&obid, &sphere, &Owner::new("wellington")));
    assert_eq!(membership["state"], "joined");
    (sphere, obid)
}

/// An invitation through the Sphere, as the Mac app asks for it: no route, just a name.
fn relay_invitation(obid: &Obid) -> Value {
    let invitation = tokio::task::block_in_place(|| {
        call(
            obid,
            "POST",
            "/v1/pairing/invite",
            Some(&json!({"name": "My Mac"})),
        )
    });
    assert_eq!(invitation.status, 200, "{}", invitation.text);
    invitation.body
}

/// A phone paired through the relay: it, its device token, and the QR's relay.
async fn relay_paired(obid: &Obid, sphere: &FakeSphere, name: &str) -> (TestPhone, String, Value) {
    let invitation = relay_invitation(obid);
    let relay = invitation["relay"].clone();
    let id = relay["id"].as_str().unwrap().to_owned();
    tokio::task::block_in_place(|| {
        within(20, "obid's relay socket", || {
            sphere.lock().relay_macs.contains_key(&id).then_some(())
        })
    });
    let mut phone = TestPhone::connect(&relay).await;
    let (status, redeemed) = phone
        .call(
            "POST",
            "/v1/pairing",
            None,
            Some(&json!({"credential": invitation["secret"], "name": name})),
        )
        .await;
    assert_eq!(status, 200, "{redeemed}");
    let token = redeemed["token"].as_str().unwrap().to_owned();
    (phone, token, relay)
}

/// #1277: a phone paired through the owner's Obysphere pairs, calls and follows its events
/// sealed end to end; the Sphere relays only ciphertext, the device's token works nowhere else,
/// and forgetting the phone revokes its relay token.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn obid_seal_everything_between_a_paired_phone_and_the_gateway_end_to_end() {
    let folder = Folder::new("gateway-relay");
    let (sphere, obid) = joined(&folder).await;
    // No phone yet: no relay.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(sphere.lock().relays.is_empty());

    let invitation = relay_invitation(&obid);
    let relay = invitation["relay"].clone();
    assert_eq!(relay["sphere"], sphere.url.as_str(), "{invitation}");
    assert_eq!(invitation["url"], sphere.url.as_str());
    let link: Value = serde_json::from_str(invitation["link"].as_str().unwrap()).unwrap();
    assert_eq!(link["relay"], relay, "the QR carries the relay: {link}");
    assert_eq!(relay["token"].as_str().unwrap().len(), 43);
    assert_eq!(relay["key"].as_str().unwrap().len(), 43);
    let id = relay["id"].as_str().unwrap().to_owned();
    let hash = hex::encode(obi_protocol::keys::sha256(
        relay["token"].as_str().unwrap().as_bytes(),
    ));
    // The Sphere knows the phone's token by its digest only, before the phone comes.
    assert!(sphere.lock().relays[&id].1.contains(&hash));
    tokio::task::block_in_place(|| {
        within(20, "obid's relay socket", || {
            sphere.lock().relay_macs.contains_key(&id).then_some(())
        })
    });

    let mut phone = TestPhone::connect(&relay).await;
    let (status, redeemed) = phone
        .call(
            "POST",
            "/v1/pairing",
            None,
            Some(&json!({"credential": invitation["secret"], "name": "Alice's iPhone"})),
        )
        .await;
    assert_eq!(status, 200, "{redeemed}");
    let token = redeemed["token"].as_str().unwrap().to_owned();
    let (status, status_body) = phone.call("GET", "/v1/status", Some(&token), None).await;
    assert_eq!(status, 200, "{status_body}");
    assert!(status_body.is_object(), "{status_body}");
    // A route off the gateway's list is off through the relay too, and so is the hooks' own.
    let (status, _) = phone
        .call("GET", "/v1/pairing/devices", Some(&token), None)
        .await;
    assert_eq!(status, 404);
    let (status, _) = phone
        .call("POST", "/v1/hooks/abc/deliver", None, Some(&json!({})))
        .await;
    assert_eq!(status, 404);

    // The event stream: sealed frames as events happen.
    let events = phone.ask("GET", "/v1/events", Some(&token), None).await;
    let head = phone.frame(10).await.unwrap();
    assert_eq!((head.stream, head.kind), (events, Kind::Open));
    assert_eq!(
        head.value().unwrap()["headers"]["content-type"],
        "text/event-stream"
    );
    assert_eq!(
        tokio::task::block_in_place(|| call(&obid, "POST", "/v1/clear", None)).status,
        200
    );
    let event = loop {
        let frame = phone.frame(10).await.expect("an event");
        if frame.stream == events && frame.kind == Kind::Data {
            break String::from_utf8(frame.payload).unwrap();
        }
    };
    assert!(event.contains("event: clear"), "{event}");

    // The Sphere carried only ciphertext: no token, secret, name, route or answer in the clear.
    let seen = sphere.lock().relayed.clone();
    for clear in [
        token.as_str(),
        invitation["secret"].as_str().unwrap(),
        "Alice's iPhone",
        "/v1/status",
        "/v1/pairing",
        "event: clear",
        "deviceID",
        "Bearer",
    ] {
        assert!(
            !seen.windows(clear.len()).any(|w| w == clear.as_bytes()),
            "the Sphere saw {clear:?} in the clear"
        );
    }

    // The device's token works only sealed, never on the gateway's listener.
    let unsealed =
        tokio::task::block_in_place(|| through(&obid, Some(&token), "GET", "/v1/status", None));
    assert_eq!(unsealed.status, 401, "{}", unsealed.text);
    assert!(unsealed.text.contains("sealed"), "{}", unsealed.text);

    // Forgetting the phone ends its stream and revokes its relay token at the Sphere.
    let devices = tokio::task::block_in_place(|| call(&obid, "GET", "/v1/pairing/devices", None));
    assert_eq!(devices.body[0]["name"], "Alice's iPhone");
    let device = devices.body[0]["id"].as_str().unwrap().to_owned();
    let forgotten = tokio::task::block_in_place(|| {
        call(
            &obid,
            "DELETE",
            &format!("/v1/pairing/devices/{device}"),
            None,
        )
    });
    assert_eq!(forgotten.status, 204);
    tokio::task::block_in_place(|| {
        within(20, "the Sphere forgets the phone's token", || {
            (!sphere.lock().relays[&id].1.contains(&hash)).then_some(())
        })
    });
    let closed = loop {
        match next_binary(&mut phone.ws, 10).await {
            Some(Ok(_)) => continue,
            other => break other,
        }
    };
    assert_eq!(
        closed,
        Some(Err(4001)),
        "the phone's socket closes as revoked"
    );
    assert_eq!(
        relay_socket(&relay, relay["token"].as_str().unwrap())
            .await
            .err(),
        Some(401),
        "its relay token opens nothing"
    );
}

/// #1277's refusals: a replayed, changed or foreign envelope, a hello to another key, another
/// phone's device token, and pairing with no Obysphere get nothing, never a plaintext fallback.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_relay_refuses_replayed_changed_and_foreign_envelopes() {
    let folder = Folder::new("gateway-relay-refusals");
    let (sphere, obid) = joined(&folder).await;
    let (mut phone, token, relay) = relay_paired(&obid, &sphere, "Alice's iPhone").await;

    // A request, then the same envelopes again: the replay gets no answer.
    let first = phone.sent.len();
    let (status, _) = phone.call("GET", "/v1/status", Some(&token), None).await;
    assert_eq!(status, 200);
    let replayed: Vec<Vec<u8>> = phone.sent[first..].to_vec();
    for envelope in &replayed {
        phone
            .ws
            .send(Message::Binary(envelope.clone().into()))
            .await
            .unwrap();
    }
    assert!(phone.frame(2).await.is_none(), "a replay was answered");

    // A changed envelope gets nothing, and spends nothing: the next one is answered.
    let head = json!({"method": "GET", "path": "/v1/status",
                      "headers": {"authorization": format!("Bearer {token}")}});
    let mut sealed = phone
        .sealer
        .seal(&Frame::json(phone.next, Kind::Open, &head).encode());
    sealed[20] ^= 0x01;
    phone.ws.send(Message::Binary(sealed.into())).await.unwrap();
    assert!(
        phone.frame(2).await.is_none(),
        "a changed envelope was answered"
    );
    phone.next += 1;
    let (status, _) = phone.call("GET", "/v1/status", Some(&token), None).await;
    assert_eq!(status, 200, "the session goes on");

    // A request without a token, or with a wrong one, is the gateway's 401, sealed.
    let (status, _) = phone.call("GET", "/v1/status", None, None).await;
    assert_eq!(status, 401);
    let (status, _) = phone
        .call("GET", "/v1/status", Some("not-a-token"), None)
        .await;
    assert_eq!(status, 401);

    // A second phone, paired through its own relay token, can't use the first one's token: the
    // envelope, not the Sphere's routing, says which phone it is.
    let (mut other, other_token, _) = relay_paired(&obid, &sphere, "Bob's iPhone").await;
    let (status, said) = other.call("GET", "/v1/status", Some(&token), None).await;
    assert_eq!(status, 401, "{said}");
    assert_eq!(said["error"], "That device token isn't this phone's.");
    let (status, _) = other
        .call("GET", "/v1/status", Some(&other_token), None)
        .await;
    assert_eq!(status, 200);

    // A hello sealed to another key gets no welcome (on a new socket, which replaces the old).
    let mut ws = relay_socket(&relay, relay["token"].as_str().unwrap())
        .await
        .unwrap();
    let wrong = Phone::hello(&[9u8; 32]).unwrap();
    ws.send(Message::Binary(wrong.hello.into())).await.unwrap();
    assert!(
        next_binary(&mut ws, 2).await.is_none(),
        "a hello to another key was welcomed"
    );
    drop(ws);

    // An invitation that isn't this relay token's isn't redeemed through it.
    let invitation = relay_invitation(&obid);
    let (status, _) = other
        .call(
            "POST",
            "/v1/pairing",
            None,
            Some(&json!({"credential": invitation["secret"], "name": "Eve"})),
        )
        .await;
    assert_eq!(status, 401);

    // With no Obysphere, pairing says so; with a route of its own, it's the gateway's as before.
    let alone = Folder::new("gateway-relay-alone");
    let obid = started(&alone);
    let refused = tokio::task::block_in_place(|| {
        call(
            &obid,
            "POST",
            "/v1/pairing/invite",
            Some(&json!({"name": "My Mac"})),
        )
    });
    assert_eq!(refused.status, 409, "{}", refused.text);
    assert_eq!(
        refused.body["error"],
        "Join or host an Obysphere first (Settings › Obysphere)."
    );
    let routed = tokio::task::block_in_place(|| {
        call(
            &obid,
            "POST",
            "/v1/pairing/invite",
            Some(&json!({"url": "https://mac.tail0000.ts.net:8443"})),
        )
    });
    assert_eq!(routed.status, 200, "{}", routed.text);
    assert!(routed.body.get("relay").is_none(), "{}", routed.text);
}

/// Before its token ends, obid opens the relay's socket again with a new one, which replaces the
/// old (`4003`): the phone's socket stays, and its event stream goes on through the new one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_token_replaces_the_relays_socket_and_the_phone_sees_nothing() {
    let folder = Folder::new("gateway-relay-renew");
    let sphere = FakeSphere::start().await;
    // Tokens of 50 seconds: obid renews 45 seconds before the end, every 5 seconds.
    sphere.lock().token_lifetime = Some(50);
    let obid = started(&folder);
    tokio::task::block_in_place(|| join_a(&obid, &sphere, &Owner::new("wellington")));
    let (mut phone, token, relay) = relay_paired(&obid, &sphere, "Alice's iPhone").await;
    let id = relay["id"].as_str().unwrap().to_owned();
    let events = phone.ask("GET", "/v1/events", Some(&token), None).await;
    assert_eq!(phone.frame(10).await.unwrap().kind, Kind::Open);
    let opened = sphere.lock().relay_opens[&id];
    tokio::task::block_in_place(|| {
        within(30, "two new sockets with new tokens", || {
            (sphere.lock().relay_opens[&id] >= opened + 2).then_some(())
        })
    });
    assert_eq!(
        tokio::task::block_in_place(|| call(&obid, "POST", "/v1/clear", None)).status,
        200
    );
    let event = loop {
        let frame = phone.frame(10).await.expect("the stream goes on");
        if frame.stream == events && frame.kind == Kind::Data {
            break String::from_utf8(frame.payload).unwrap();
        }
    };
    assert!(event.contains("event: clear"), "{event}");
    let (status, _) = phone.call("GET", "/v1/status", Some(&token), None).await;
    assert_eq!(status, 200);
}
