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
    let refused = through(
        &obid,
        Some(&token),
        "POST",
        "/v1/notifications",
        Some(&apns("http://relay.example")),
    );
    assert_eq!(refused.status, 422, "{}", refused.text);
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
