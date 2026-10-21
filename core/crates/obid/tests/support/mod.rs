//! What the Sphere tests share: a folder of their own, the e2e fixture, the real obid binary asked
//! over HTTP, and a fake Sphere the tests control.
//!
//! The fake Sphere speaks sphere-api.md's calls that an Obi makes (redeem, the token exchange, the
//! directory, send, deliveries, ack) with the spec's own checks from obi-protocol, and it records
//! what it was sent. A test can make it refuse sends with `429 rate_limited` (D3) or a policy
//! refusal, hold its answer to a send it already recorded, and queue a delivery it never checked,
//! as a misbehaving relay would.

#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::{Form, Path as UrlPath, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use obi_protocol::keys::Keypair;
use obi_protocol::{DirectoryKey, Keys, card, chain, envelope, jwt, time};
use serde_json::{Map, Value, json};

pub const OBID: &str = env!("CARGO_BIN_EXE_obid");
pub const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
pub const SPHERE: &str = "e2e";
pub const CANARY: &str = "OBI-E2E-DATA-CANARY";

/// A folder of the test's own, removed when it ends.
pub struct Folder(pub PathBuf);

impl Folder {
    pub fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("obid-sphere-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Folder(path.canonicalize().unwrap())
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        // OBID_TEST_KEEP=1 keeps it, for reading the logs.
        if std::env::var_os("OBID_TEST_KEEP").is_some() {
            eprintln!("kept {}", self.0.display());
            return;
        }
        let _ = Command::new("chmod")
            .args(["-R", "u+w"])
            .arg(&self.0)
            .status();
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// This repository's root.
pub fn obi() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .unwrap()
}

/// The e2e fixture's bare remote, built by the harness's own code (e2e/lib/fixture.mjs).
pub fn fixture(root: &Path) -> PathBuf {
    let module = obi().join("e2e/lib/fixture.mjs");
    let script = format!(
        "import {{ buildFixture }} from {:?}; console.log(JSON.stringify(buildFixture(process.argv[1])));",
        module.to_str().unwrap()
    );
    let output = Command::new("node")
        .args(["--input-type=module", "-e", &script, root.to_str().unwrap()])
        .output()
        .expect("node runs");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let built: Value = serde_json::from_slice(&output.stdout).unwrap();
    PathBuf::from(built["remote"].as_str().unwrap())
}

/// The scenario's brief (e2e/fixtures/messages/brief.json).
pub fn brief() -> Value {
    let text = std::fs::read_to_string(obi().join("e2e/fixtures/messages/brief.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

/// The scenario's expected result body (e2e/fixtures/messages/result.example.json).
pub fn expected_result() -> Value {
    let text =
        std::fs::read_to_string(obi().join("e2e/fixtures/messages/result.example.json")).unwrap();
    serde_json::from_str::<Value>(&text).unwrap()["body"].clone()
}

// ---------------------------------------------------------------------------------------------
// obid, the real binary

pub struct Obid {
    pub child: Child,
    pub port: u16,
    /// The gateway's port, when the configuration has a `gateway`.
    pub gateway: Option<u16>,
    pub home: PathBuf,
    pub folder: PathBuf,
    pub stderr: PathBuf,
}

impl Drop for Obid {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Obid {
    /// SIGTERM, and its exit status once it has gone (within 10 seconds).
    pub fn stop(&mut self) -> std::process::ExitStatus {
        let _ = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(self.child.id() as i32),
            nix::sys::signal::Signal::SIGTERM,
        );
        let give_up_at = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            assert!(
                Instant::now() < give_up_at,
                "obid didn't exit within 10 seconds"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// What obid logged.
    pub fn log(&self) -> String {
        std::fs::read_to_string(&self.stderr).unwrap_or_default()
    }
}

/// obid's configuration: owner wellington, the fixture repository with `node --test` (its
/// `file://` remote's pull requests on whatever `gh` the test puts first on `PATH`), and
/// `agent` as Claude Code's binary. Conversations run on obid's plan loop, which these tests
/// drive; tests/conversation_harness.rs turns the agent session on.
pub fn config(folder: &Path, remote: &Path, agent: &Path) -> Value {
    json!({
        "conversation": {"agent": "plan"},
        "listen": "127.0.0.1:0",
        "home": folder.join("home"),
        "owner": "wellington",
        "agents": {"claude": {"bin": agent,
                              "accounts": [{"id": "stub", "name": "Stub", "configDir": folder.join("home/accounts/stub")}]}},
        "repos": [{"repo": "obi-e2e/fixture-app", "remote": format!("file://{}", remote.display()),
                   "defaultBranch": "main", "check": "node --test", "pullRequests": true}],
        "allowFileRemotes": true,
        "telemetry": false
    })
}

/// Puts `token` in obid's `home/api-token` (0600, in a 0700 `home`), where obid takes its token
/// from: never from its environment (docs/runner-api.md, "obid only: configuration").
pub fn put_token(config: &Value, token: &str) {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let home = Path::new(config["home"].as_str().expect("home"));
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(home)
        .unwrap();
    let path = home.join("api-token");
    let _ = std::fs::remove_file(&path);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    std::io::Write::write_all(&mut file, format!("{token}\n").as_bytes()).unwrap();
}

/// The e2e stub agent.
pub fn stub_agent() -> PathBuf {
    obi().join("e2e/stub-agent/stub-agent")
}

/// Starts obid with `config`, `PATH` the test's own with `path_first` before it.
pub fn start(folder: &Path, config: &Value, path_first: Option<&Path>) -> Obid {
    start_with(folder, config, path_first, &[])
}

/// [`start`], with `env` set over what a test's obid is given.
pub fn start_with(
    folder: &Path,
    config: &Value,
    path_first: Option<&Path>,
    env: &[(&str, &str)],
) -> Obid {
    let path = folder.join("config.json");
    put_token(config, TOKEN);
    std::fs::write(&path, config.to_string()).unwrap();
    std::fs::create_dir_all(folder.join("env-home")).unwrap();
    // The fake planner's state is its account's folder; unboxed, obid gives the brain a config
    // folder of its own (#651), so it finds the account's from obid's HOME. Boxed, it can write
    // nothing that outlives its call (#655), so it asks the state server below, whose address it
    // finds in the test's folder.
    if let Some(dir) = config["agents"]["claude"]["accounts"][0]["configDir"].as_str() {
        std::fs::create_dir_all(dir).unwrap();
        let link = folder.join("env-home/.fake-planner");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(dir, link).unwrap();
        let url = planner_state(PathBuf::from(dir));
        std::fs::write(folder.join("fake-planner-url"), url).unwrap();
    }
    std::fs::create_dir_all(folder.join("tmp")).unwrap();
    let stderr = folder.join("obid.stderr");
    // The fake gh (tests/agents/gh) always comes before the person's own: obid reads GitHub by
    // itself (crate::github_work), and a test never reaches their real gh login.
    let mut dirs: Vec<PathBuf> = path_first.map(Path::to_path_buf).into_iter().collect();
    dirs.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents"));
    dirs.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    let search = std::env::join_paths(dirs).unwrap();
    let mut child = Command::new(OBID)
        .args(["serve", "--config"])
        .arg(&path)
        .env_clear()
        .env("PATH", search)
        .env("HOME", folder.join("env-home"))
        .env("TMPDIR", folder.join("tmp"))
        .env("OBID_LOG", "info")
        // Every refresh reads (crate::github_work): tests refresh more often than 15 seconds.
        .env("OBID_GITHUB_REFRESH_SECONDS", "0")
        // Never the person's real Keychain: a stand-in `security` that finds nothing and says
        // it was asked (tests/agents/fake-security).
        .env(
            "OBID_SECURITY_BIN",
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-security"),
        )
        // No conversation's Claude Code started ahead (crate::brain::harness::prestart), but in the
        // tests of it: its processes would weigh on every other test's time.
        .env("OBID_PRESTART", "off")
        // The brains' time never depends on how busy the machine running the tests is.
        .env("OBID_LOAD", "0")
        .envs(env.iter().copied())
        .stdout(Stdio::piped())
        .stderr(
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&stderr)
                .unwrap(),
        )
        .spawn()
        .unwrap();
    let mut line = String::new();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    stdout.read_line(&mut line).unwrap();
    let gateway = config.get("gateway").map(|_| {
        let mut said = String::new();
        stdout.read_line(&mut said).unwrap();
        said.trim()
            .strip_prefix("obid gateway listening on http://127.0.0.1:")
            .and_then(|p| p.parse().ok())
            .unwrap_or_else(|| panic!("no gateway: {said:?}"))
    });
    let port = line
        .trim()
        .strip_prefix("obid listening on http://127.0.0.1:")
        .and_then(|p| p.parse().ok())
        .unwrap_or_else(|| {
            panic!(
                "obid didn't start: {line:?} {}",
                std::fs::read_to_string(&stderr).unwrap_or_default()
            )
        });
    Obid {
        child,
        port,
        gateway,
        home: folder.join("home"),
        folder: folder.to_path_buf(),
        stderr,
    }
}

/// The fake planner's state for its boxed calls (tests/agents/fake-planner): an HTTP server on
/// 127.0.0.1 that records a call in `state/calls/<n>` (its `args`, `input`, `pwd` and `work.md`)
/// and answers the first line of `state/plans`, taking it out, under the same lock the unboxed
/// planner takes. Its address, `http://127.0.0.1:<port>/`.
pub fn planner_state(state: PathBuf) -> String {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let url = format!(
        "http://127.0.0.1:{}/",
        listener.local_addr().unwrap().port()
    );
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = planner_call(&state, stream);
        }
    });
    url
}

fn planner_call(state: &Path, stream: TcpStream) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut length = 0;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        let line = line.trim();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    let call: Value = serde_json::from_slice(&body).unwrap_or_default();
    let lock = state.join("lock");
    std::fs::create_dir_all(state.join("calls"))?;
    while std::fs::create_dir(&lock).is_err() {
        std::thread::sleep(Duration::from_millis(50));
    }
    let n = std::fs::read_dir(state.join("calls"))?.count() + 1;
    let dir = state.join("calls").join(n.to_string());
    std::fs::create_dir_all(&dir)?;
    let args: Vec<&str> = call["args"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    std::fs::write(
        dir.join("args"),
        args.iter().map(|a| format!("{a}\n")).collect::<String>(),
    )?;
    std::fs::write(dir.join("input"), call["input"].as_str().unwrap_or(""))?;
    std::fs::write(
        dir.join("pwd"),
        format!("{}\n", call["pwd"].as_str().unwrap_or("")),
    )?;
    if let Some(work) = call["work"].as_str() {
        std::fs::write(dir.join("work.md"), work)?;
    }
    let plans = std::fs::read_to_string(state.join("plans")).unwrap_or_default();
    let (first, rest) = plans.split_once('\n').unwrap_or((plans.as_str(), ""));
    let first = first.to_owned();
    std::fs::write(state.join("plans"), rest)?;
    std::fs::remove_dir(&lock)?;
    let mut stream = stream;
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{first}",
        first.len()
    )
}

pub struct Answer {
    pub status: u16,
    pub body: Value,
    pub text: String,
}

/// One request to obid, with its token.
pub fn call(obid: &Obid, method: &str, target: &str, body: Option<&Value>) -> Answer {
    call_with_token(obid, TOKEN, method, target, body)
}

pub fn call_with_token(
    obid: &Obid,
    token: &str,
    method: &str,
    target: &str,
    body: Option<&Value>,
) -> Answer {
    let body = body.map(Value::to_string);
    let mut stream = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(150)))
        .unwrap();
    let mut text = format!(
        "{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n"
    );
    match &body {
        Some(body) => text.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        )),
        None if method == "POST" => text.push_str("Content-Length: 0\r\n"),
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
        let (size, rest) = body.split_once("\r\n").unwrap();
        let size = usize::from_str_radix(size.trim(), 16).unwrap();
        if size == 0 {
            return out;
        }
        out.push_str(&rest[..size]);
        body = &rest[size + 2..];
    }
}

/// Asks `probe` every 100 ms until it answers `Some`, for at most `seconds`.
pub fn within<T>(seconds: u64, what: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let give_up_at = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(value) = probe() {
            return value;
        }
        assert!(
            Instant::now() < give_up_at,
            "within {seconds} seconds: {what}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Follows `GET /v1/events`: every event, `(name, data)`, as it comes.
pub fn follow_events(obid: &Obid) -> std::sync::mpsc::Receiver<(String, Value)> {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .write_all(
            format!("GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\n\r\n")
                .as_bytes(),
        )
        .unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.starts_with("HTTP/1.1 200"), "{line}");
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut event = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
            let text = line.trim();
            if let Some(name) = text.strip_prefix("event: ") {
                event = name.to_owned();
            } else if let Some(data) = text.strip_prefix("data: ")
                && let Ok(value) = serde_json::from_str(data)
                && sender.send((event.clone(), value)).is_err()
            {
                return;
            }
        }
    });
    // The stream is followed before anything changes.
    std::thread::sleep(Duration::from_millis(200));
    receiver
}

/// The events named `name` that came within `seconds`, until `enough` says so.
pub fn events_named(
    events: &std::sync::mpsc::Receiver<(String, Value)>,
    name: &str,
    seconds: u64,
    mut enough: impl FnMut(&[Value]) -> bool,
) -> Vec<Value> {
    let give_up_at = Instant::now() + Duration::from_secs(seconds);
    let mut got = Vec::new();
    while !enough(&got) {
        let left = give_up_at.saturating_duration_since(Instant::now());
        match events.recv_timeout(left) {
            Ok((event, data)) if event == name => got.push(data),
            Ok(_) => {}
            Err(_) => panic!("within {seconds} seconds, the {name} events were {got:?}"),
        }
    }
    got
}

// ---------------------------------------------------------------------------------------------
// Owners and Obis the test plays

/// An owner: a key the test holds.
pub struct Owner {
    pub id: String,
    pub key: Keypair,
}

impl Owner {
    pub fn new(id: &str) -> Owner {
        Owner {
            id: id.into(),
            key: Keypair::from_seed_string(&format!("obid sphere test owner {id}")),
        }
    }

    /// A delegation to `obi` with `scope`, living an hour.
    pub fn delegation(&self, obi: &str, scope: &str) -> String {
        let now = time::now();
        jwt::sign(
            &json!({"iss": self.id, "sub": self.id, "aud": format!("obi-sphere:{SPHERE}"),
                    "iat": now, "exp": now + 3600, "jti": uuid::Uuid::new_v4().to_string(),
                    "scope": scope, "may_act": {"sub": obi}}),
            &self.key,
        )
        .unwrap()
    }
}

pub const OBI_SCOPES: &str =
    "send:review_request send:question reply receive directory:read audit:read";

/// Makes A's key and card and joins it to the fake Sphere with its invitation: the membership.
pub fn join_a(obid: &Obid, sphere: &FakeSphere, owner: &Owner) -> Value {
    join_a_accepting(obid, sphere, owner, &["review_request"])
}

/// [`join_a`], with a card that accepts `accepts`.
pub fn join_a_accepting(
    obid: &Obid,
    sphere: &FakeSphere,
    owner: &Owner,
    accepts: &[&str],
) -> Value {
    let key = call(obid, "POST", "/v1/obid/sphere/key", None);
    assert_eq!(key.status, 200, "{}", key.text);
    let made = call(
        obid,
        "POST",
        "/v1/obid/sphere/card",
        Some(
            &json!({"url": sphere.url, "sphere": SPHERE, "obiId": "obi-wellington",
                     "name": "Wellington's Obi", "ownerKey": owner.key.public_key(),
                     "accepts": accepts}),
        ),
    );
    assert_eq!(made.status, 200, "{}", made.text);
    let unsigned = made.body["card"].as_object().unwrap().clone();
    let signed = card::sign(&unsigned, &owner.key).unwrap();
    let invitation = sphere.invite(&owner.id, "obi-wellington");
    let joined = call(
        obid,
        "POST",
        "/v1/obid/sphere/join",
        Some(&json!({"url": sphere.url, "sphere": SPHERE,
                     "invitation": {"id": invitation.0, "secret": invitation.1},
                     "card": signed, "delegation": owner.delegation("obi-wellington", OBI_SCOPES)})),
    );
    assert_eq!(joined.status, 200, "{}", joined.text);
    joined.body
}

/// Makes an obid's key and card (`obi`, accepting `accepts`) and joins it with `scopes`.
pub fn join_as(
    obid: &Obid,
    sphere: &FakeSphere,
    owner: &Owner,
    obi: &str,
    accepts: &[&str],
    scopes: &str,
) -> Value {
    let key = call(obid, "POST", "/v1/obid/sphere/key", None);
    assert_eq!(key.status, 200, "{}", key.text);
    let made = call(
        obid,
        "POST",
        "/v1/obid/sphere/card",
        Some(
            &json!({"url": sphere.url, "sphere": SPHERE, "obiId": obi, "name": format!("{}'s Obi", owner.id),
                     "ownerKey": owner.key.public_key(), "accepts": accepts}),
        ),
    );
    assert_eq!(made.status, 200, "{}", made.text);
    let signed = card::sign(made.body["card"].as_object().unwrap(), &owner.key).unwrap();
    let invitation = sphere.invite(&owner.id, obi);
    let joined = call(
        obid,
        "POST",
        "/v1/obid/sphere/join",
        Some(
            &json!({"url": sphere.url, "sphere": SPHERE, "invitation": {"id": invitation.0, "secret": invitation.1},
                     "card": signed, "delegation": owner.delegation(obi, scopes)}),
        ),
    );
    assert_eq!(joined.status, 200, "{}", joined.text);
    joined.body
}

/// An Obi the test plays, through the fake Sphere's HTTP API like any Obi.
pub struct TestObi {
    pub id: String,
    pub owner: Owner,
    pub key: Keypair,
    pub client: obi_protocol::client::Client,
    pub token: String,
}

impl TestObi {
    /// Joins `id` (owner `owner`) to the fake Sphere: redeem, then a token.
    pub async fn join(sphere: &FakeSphere, id: &str, owner: &str) -> TestObi {
        TestObi::join_accepting(sphere, id, owner, &["review_request"]).await
    }

    /// [`TestObi::join`], with a card that accepts `accepts`.
    pub async fn join_accepting(
        sphere: &FakeSphere,
        id: &str,
        owner: &str,
        accepts: &[&str],
    ) -> TestObi {
        let owner = Owner::new(owner);
        let key = Keypair::from_seed_string(&format!("obid sphere test obi {id}"));
        let accepts: Vec<String> = accepts.iter().map(|a| (*a).to_owned()).collect();
        let (owner_key, key_id, public_key) =
            (owner.key.public_key(), key.key_id(), key.public_key());
        let issued_at = time::format(time::now());
        let unsigned = obi_protocol::identity::unsigned_card(&obi_protocol::identity::CardFields {
            sphere_url: &sphere.url,
            sphere: SPHERE,
            obi_id: id,
            owner: &owner.id,
            owner_key: &owner_key,
            name: "A test Obi",
            description: obi_protocol::identity::DEFAULT_DESCRIPTION,
            version: "0.1.0",
            key_id: &key_id,
            public_key: &public_key,
            accepts: &accepts,
            card_seq: 1,
            issued_at: &issued_at,
        });
        let signed = card::sign(&unsigned, &owner.key).unwrap();
        let client = obi_protocol::client::Client::new(&sphere.url, SPHERE).unwrap();
        let (invitation, secret) = sphere.invite(&owner.id, id);
        client
            .redeem(&invitation, &secret, &owner_key, &signed)
            .await
            .unwrap();
        let actor = obi_protocol::identity::actor_assertion(
            id,
            SPHERE,
            &key,
            time::now(),
            &uuid::Uuid::new_v4().to_string(),
        )
        .unwrap();
        let token = client
            .token(&owner.delegation(id, OBI_SCOPES), &actor)
            .await
            .unwrap()
            .access_token;
        TestObi {
            id: id.into(),
            owner,
            key,
            client,
            token,
        }
    }

    /// A signed request to `to`, expiring `expires_in` seconds from now.
    pub fn request(&self, to: &str, kind: &str, body: Value, expires_in: i64) -> Value {
        let id = uuid::Uuid::new_v4().to_string();
        let now = time::now();
        self.sign(
            json!({"protocol": "obi/0.1", "id": id, "type": kind, "from": self.id, "to": to,
                         "sphere": SPHERE, "correlation_id": id, "created_at": time::format(now),
                         "expires_at": time::format(now + expires_in), "key_id": self.key.key_id(),
                         "body": body}),
        )
    }

    /// A signed reply to `request`.
    pub fn reply(&self, request: &Value, kind: &str, body: Value) -> Value {
        let now = time::now();
        self.sign(
            json!({"protocol": "obi/0.1", "id": uuid::Uuid::new_v4().to_string(), "type": kind,
                         "from": self.id, "to": request["from"], "sphere": SPHERE,
                         "correlation_id": request["id"], "in_reply_to": request["id"],
                         "created_at": time::format(now), "expires_at": time::format(now + 3600),
                         "key_id": self.key.key_id(), "body": body}),
        )
    }

    pub fn sign(&self, unsigned: Value) -> Value {
        envelope::sign(unsigned.as_object().unwrap(), &self.key).unwrap()
    }

    pub async fn send(&self, envelope: &Value) -> obi_protocol::client::Sent {
        self.client.send(&self.token, envelope).await.unwrap()
    }

    /// Waits for deliveries until `count` envelopes have come, acknowledging each: the envelopes.
    pub async fn receive(&self, count: usize, seconds: u64) -> Vec<Value> {
        let give_up_at = Instant::now() + Duration::from_secs(seconds);
        let mut got = Vec::new();
        while got.len() < count {
            assert!(
                Instant::now() < give_up_at,
                "{} got {} of {count} messages within {seconds} seconds: {got:?}",
                self.id,
                got.len()
            );
            let list = self.client.deliveries(&self.token, 50, 1).await.unwrap();
            if list.is_empty() {
                continue;
            }
            let ids: Vec<String> = list.iter().map(|d| d.delivery_id.clone()).collect();
            got.extend(list.into_iter().map(|d| d.envelope));
            self.client.ack(&self.token, &ids).await.unwrap();
        }
        got
    }

    /// Waits for deliveries until the reply to `request` comes, acknowledging each: that reply.
    /// Whatever else comes first is passed over.
    pub async fn receive_reply_to(&self, request: &Value, seconds: u64) -> Value {
        let give_up_at = Instant::now() + Duration::from_secs(seconds);
        let mut passed = Vec::new();
        loop {
            assert!(
                Instant::now() < give_up_at,
                "{} got no reply to {} within {seconds} seconds, only: {passed:?}",
                self.id,
                request["id"]
            );
            let list = self.client.deliveries(&self.token, 50, 1).await.unwrap();
            if list.is_empty() {
                continue;
            }
            let ids: Vec<String> = list.iter().map(|d| d.delivery_id.clone()).collect();
            self.client.ack(&self.token, &ids).await.unwrap();
            for envelope in list.into_iter().map(|d| d.envelope) {
                if envelope["in_reply_to"] == request["id"] {
                    return envelope;
                }
                passed.push(envelope);
            }
        }
    }

    /// Whatever is waiting now, after `seconds`, acknowledged.
    pub async fn waiting_after(&self, seconds: u64) -> Vec<Value> {
        tokio::time::sleep(Duration::from_secs(seconds)).await;
        let list = self.client.deliveries(&self.token, 50, 0).await.unwrap();
        let ids: Vec<String> = list.iter().map(|d| d.delivery_id.clone()).collect();
        if !ids.is_empty() {
            self.client.ack(&self.token, &ids).await.unwrap();
        }
        list.into_iter().map(|d| d.envelope).collect()
    }
}

// ---------------------------------------------------------------------------------------------
// The fake Sphere

#[derive(Default)]
pub struct SphereState {
    pub invitations: HashMap<String, (String, String, String)>,
    pub bound: HashMap<String, String>,
    pub members: Vec<Value>,
    pub tokens: HashMap<String, String>,
    pub entries: Vec<Value>,
    /// (delivery id, to, seq, recorded at, envelope, acknowledged)
    pub queue: Vec<(String, String, u64, String, Value, bool)>,
    /// How many of an Obi's next sends answer `429 rate_limited`.
    pub rate_limit: HashMap<String, u32>,
    /// Requests refused with `403 policy_denied`.
    pub deny_requests: bool,
    /// Every send's body as it arrived, with its sender and the status answered.
    pub sends: Vec<(String, String, u16)>,
    /// The next send of this type is recorded and delivered, and its answer waits until the test
    /// lets it go: a slow way back to the sender (`FakeSphere::hold_next`).
    pub hold: Option<(String, Arc<tokio::sync::Notify>)>,
    /// Job channels: each side's sender, by exchange and Obi (sphere-api.md 6.3).
    pub channels: HashMap<
        String,
        HashMap<String, tokio::sync::mpsc::UnboundedSender<axum::extract::ws::Message>>,
    >,
    /// The bytes the relay forwarded, every frame together: what a packet capture would see.
    pub relayed: Vec<u8>,
    /// Runner statuses, by Obi, as put.
    pub runners: HashMap<String, Value>,
}

#[derive(Clone)]
pub struct FakeSphere {
    pub url: String,
    pub state: Arc<Mutex<SphereState>>,
}

fn sphere_error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        axum::Json(json!({"error": {"code": code, "message": message}})),
    )
        .into_response()
}

fn new_token() -> String {
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).unwrap();
    hex::encode(bytes)
}

impl FakeSphere {
    pub async fn start() -> FakeSphere {
        let state = Arc::new(Mutex::new(SphereState::default()));
        let app = Router::new()
            .route(
                "/v0.1/spheres/{sphere}/invitations/{id}/redeem",
                post(redeem),
            )
            .route("/v0.1/oauth/token", post(token))
            .route("/v0.1/spheres/{sphere}/members", get(members))
            .route("/v0.1/spheres/{sphere}/messages", post(send))
            .route("/v0.1/spheres/{sphere}/deliveries", get(deliveries))
            .route("/v0.1/spheres/{sphere}/deliveries/ack", post(ack))
            .route("/v0.1/spheres/{sphere}/channels/{cid}", get(channel))
            .route("/v0.1/spheres/{sphere}/audit", get(audit))
            .route(
                "/v0.1/spheres/{sphere}/members/{obi}/runner",
                axum::routing::put(put_runner).delete(delete_runner),
            )
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        FakeSphere { url, state }
    }

    pub fn lock(&self) -> std::sync::MutexGuard<'_, SphereState> {
        self.state.lock().unwrap()
    }

    /// Holds the answer to the next send of type `kind`: the Sphere records it and delivers it,
    /// and answers the sender only once the test calls `notify_one` on what this returns.
    pub fn hold_next(&self, kind: &str) -> Arc<tokio::sync::Notify> {
        let release = Arc::new(tokio::sync::Notify::new());
        self.lock().hold = Some((kind.to_owned(), release.clone()));
        release
    }

    /// An invitation for `obi` of `owner`: its id and secret.
    pub fn invite(&self, owner: &str, obi: &str) -> (String, String) {
        let id = uuid::Uuid::new_v4().to_string();
        let secret = new_token();
        self.lock()
            .invitations
            .insert(id.clone(), (secret.clone(), owner.into(), obi.into()));
        (id, secret)
    }

    /// Queues `envelope` for `to` without any check, as a relay that doesn't check would.
    pub fn inject(&self, to: &str, envelope: Value) {
        let mut state = self.lock();
        let seq = state.entries.len() as u64 + 1000;
        state.queue.push((
            uuid::Uuid::new_v4().to_string(),
            to.into(),
            seq,
            time::format(time::now()),
            envelope,
            false,
        ));
    }

    /// Records `envelope` in the chain and queues it for `to`, without the checks a request gets
    /// (a Sphere that relays a type the receiver's card doesn't accept).
    pub fn record_unchecked(&self, to: &str, envelope: Value) {
        let mut state = self.lock();
        let recorded_at = time::format(time::now());
        state.entries = chain::append(&state.entries, SPHERE, &envelope, &recorded_at).unwrap();
        let seq = state.entries.len() as u64;
        state.queue.push((
            uuid::Uuid::new_v4().to_string(),
            to.into(),
            seq,
            recorded_at,
            envelope,
            false,
        ));
    }

    /// The envelopes recorded in the chain, in order.
    pub fn recorded(&self) -> Vec<Value> {
        self.lock()
            .entries
            .iter()
            .map(|e| e["envelope"].clone())
            .collect()
    }

    /// Whether every delivery queued for `obi` has been acknowledged.
    pub fn all_acked(&self, obi: &str) -> bool {
        self.lock().queue.iter().filter(|d| d.1 == obi).all(|d| d.5)
    }
}

fn keys(state: &SphereState) -> Keys {
    let mut keys = Keys::new();
    for m in &state.members {
        for k in m["keys"].as_array().unwrap() {
            keys.insert(
                k["key_id"].as_str().unwrap().into(),
                DirectoryKey {
                    obi: m["obi"].as_str().unwrap().into(),
                    public_key: k["public_key"].as_str().unwrap().into(),
                    ranged: true,
                    valid_from_seq: k["valid_from_seq"].as_u64().unwrap(),
                    valid_until_seq: k["valid_until_seq"].as_u64(),
                },
            );
        }
    }
    keys
}

fn bearer(state: &SphereState, headers: &HeaderMap) -> Option<String> {
    let header = headers.get("authorization")?.to_str().ok()?;
    state.tokens.get(header.strip_prefix("Bearer ")?).cloned()
}

async fn redeem(
    State(state): State<Arc<Mutex<SphereState>>>,
    UrlPath((_, id)): UrlPath<(String, String)>,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    let mut state = state.lock().unwrap();
    let Some((secret, owner, obi)) = state.invitations.get(&id).cloned() else {
        return sphere_error(
            StatusCode::FORBIDDEN,
            "invitation_invalid",
            "no such invitation",
        );
    };
    if body["secret"] != secret {
        return sphere_error(
            StatusCode::FORBIDDEN,
            "invitation_invalid",
            "no such invitation",
        );
    }
    let card_value = body["card"].clone();
    if let Err(r) = card::verify(
        &card_value,
        &card::Context {
            now: Some(time::now()),
            bound_owner_key: None,
        },
    ) {
        return sphere_error(StatusCode::BAD_REQUEST, "card_invalid", &r.message);
    }
    let params = card::params(&card_value).unwrap().clone();
    if params["obi_id"] != obi.as_str()
        || params["owner"] != owner.as_str()
        || params["owner_key"] != body["owner_key"]
    {
        return sphere_error(
            StatusCode::BAD_REQUEST,
            "card_invalid",
            "the card isn't the invitation's",
        );
    }
    state.invitations.remove(&id);
    let owner_key = params["owner_key"].as_str().unwrap().to_owned();
    state.bound.insert(owner.clone(), owner_key.clone());
    let member = json!({
        "obi": obi, "owner": owner, "owner_key": owner_key,
        "owner_key_id": obi_protocol::keys::key_id_of(&owner_key),
        "status": "active", "joined_at": time::format(time::now()), "card": card_value,
        "keys": [{"key_id": params["key_id"], "public_key": params["public_key"],
                  "valid_from_seq": state.entries.len() + 1, "valid_until_seq": null}]
    });
    state.members.push(member.clone());
    (StatusCode::CREATED, axum::Json(member)).into_response()
}

async fn token(
    State(state): State<Arc<Mutex<SphereState>>>,
    Form(form): Form<HashMap<String, String>>,
) -> Response {
    let oauth = |code: &str| {
        (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({"error": code, "error_description": "refused"})),
        )
            .into_response()
    };
    let mut state = state.lock().unwrap();
    let (Some(subject), Some(actor)) = (
        form.get("subject_token").and_then(|t| jwt::parse(t)),
        form.get("actor_token").and_then(|t| jwt::parse(t)),
    ) else {
        return oauth("invalid_request");
    };
    let owner = subject.claims["iss"].as_str().unwrap_or("").to_owned();
    let Some(owner_key) = state.bound.get(&owner) else {
        return oauth("invalid_grant");
    };
    if !subject.verifies_with(owner_key) {
        return oauth("invalid_grant");
    }
    let obi = actor.claims["sub"].as_str().unwrap_or("").to_owned();
    if subject.claims["may_act"]["sub"] != obi.as_str() {
        return oauth("invalid_grant");
    }
    let Some(member) = state
        .members
        .iter()
        .find(|m| m["obi"] == obi.as_str() && m["status"] == "active")
    else {
        return oauth("invalid_grant");
    };
    let current = member["keys"]
        .as_array()
        .unwrap()
        .iter()
        .find(|k| k["valid_until_seq"].is_null())
        .unwrap();
    if !actor.verifies_with(current["public_key"].as_str().unwrap()) {
        return oauth("invalid_grant");
    }
    let token = new_token();
    state.tokens.insert(token.clone(), obi);
    axum::Json(json!({"access_token": token, "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                      "token_type": "Bearer", "expires_in": 3600, "scope": OBI_SCOPES}))
        .into_response()
}

async fn members(State(state): State<Arc<Mutex<SphereState>>>, headers: HeaderMap) -> Response {
    let state = state.lock().unwrap();
    if bearer(&state, &headers).is_none() {
        return sphere_error(StatusCode::UNAUTHORIZED, "unauthorized", "no token");
    }
    let members: Vec<Value> = state
        .members
        .iter()
        .map(|m| {
            let mut m = m.clone();
            if let Some(runner) = state.runners.get(m["obi"].as_str().unwrap_or("")) {
                m["runner"] = runner.clone();
            }
            m
        })
        .collect();
    axum::Json(json!({"sphere": SPHERE, "members": members})).into_response()
}

/// `GET …/audit?from_seq=&limit=`: the chain as recorded (sphere-api.md section 7).
async fn audit(
    State(state): State<Arc<Mutex<SphereState>>>,
    headers: HeaderMap,
    axum::extract::Query(query): axum::extract::Query<HashMap<String, String>>,
) -> Response {
    let state = state.lock().unwrap();
    if bearer(&state, &headers).is_none() {
        return sphere_error(StatusCode::UNAUTHORIZED, "unauthorized", "no token");
    }
    let from: usize = query
        .get("from_seq")
        .and_then(|s| s.parse().ok())
        .unwrap_or(1)
        .max(1);
    let limit: usize = query
        .get("limit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(500);
    let entries: Vec<Value> = state
        .entries
        .iter()
        .skip(from - 1)
        .take(limit)
        .cloned()
        .collect();
    let head = state.entries.last().map_or(
        json!({"seq": 0, "hash": obi_protocol::ZERO_HASH}),
        |e| json!({"seq": e["seq"], "hash": e["hash"]}),
    );
    axum::Json(json!({"sphere": SPHERE, "entries": entries, "head": head})).into_response()
}

/// `PUT …/members/{obi}/runner`: kept as put, shown to every member (the Sphere's own tests check
/// who sees it).
async fn put_runner(
    State(state): State<Arc<Mutex<SphereState>>>,
    UrlPath((_, obi)): UrlPath<(String, String)>,
    headers: HeaderMap,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    let mut state = state.lock().unwrap();
    if bearer(&state, &headers).as_deref() != Some(obi.as_str()) {
        return sphere_error(StatusCode::FORBIDDEN, "forbidden", "not this Obi");
    }
    if !obi_protocol::schema::is_valid("runner-status", &body) {
        return sphere_error(
            StatusCode::BAD_REQUEST,
            "bad_request",
            "not a runner status",
        );
    }
    state.runners.insert(obi.clone(), body);
    let member = state
        .members
        .iter()
        .find(|m| m["obi"] == obi.as_str())
        .cloned()
        .unwrap_or_default();
    axum::Json(member).into_response()
}

async fn delete_runner(
    State(state): State<Arc<Mutex<SphereState>>>,
    UrlPath((_, obi)): UrlPath<(String, String)>,
    headers: HeaderMap,
) -> Response {
    let mut state = state.lock().unwrap();
    if bearer(&state, &headers).as_deref() != Some(obi.as_str()) {
        return sphere_error(StatusCode::FORBIDDEN, "forbidden", "not this Obi");
    }
    state.runners.remove(&obi);
    let member = state
        .members
        .iter()
        .find(|m| m["obi"] == obi.as_str())
        .cloned()
        .unwrap_or_default();
    axum::Json(member).into_response()
}

/// `GET …/channels/{cid}` (WebSocket): pairs the two Obis of an exchange and forwards their binary
/// frames, keeping a copy of every byte it saw.
async fn channel(
    State(state): State<Arc<Mutex<SphereState>>>,
    UrlPath((_, cid)): UrlPath<(String, String)>,
    headers: HeaderMap,
    ws: axum::extract::ws::WebSocketUpgrade,
) -> Response {
    let Some(obi) = bearer(&state.lock().unwrap(), &headers) else {
        return sphere_error(StatusCode::UNAUTHORIZED, "unauthorized", "no token");
    };
    ws.on_upgrade(move |socket| channel_side(state, cid, obi, socket))
}

async fn channel_side(
    state: Arc<Mutex<SphereState>>,
    cid: String,
    obi: String,
    socket: axum::extract::ws::WebSocket,
) {
    use axum::extract::ws::Message;
    use futures_util::{SinkExt, StreamExt};
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    {
        let mut s = state.lock().unwrap();
        let sides = s.channels.entry(cid.clone()).or_default();
        sides.insert(obi.clone(), tx);
        if sides.len() == 2 {
            for tx in sides.values() {
                let _ = tx.send(Message::Text(r#"{"peer":"joined"}"#.into()));
            }
        }
    }
    tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(m).await.is_err() {
                break;
            }
        }
    });
    while let Some(Ok(m)) = stream.next().await {
        if let Message::Binary(bytes) = m {
            let mut s = state.lock().unwrap();
            s.relayed.extend_from_slice(&bytes);
            if let Some(sides) = s.channels.get(&cid) {
                for (other, tx) in sides {
                    if *other != obi {
                        let _ = tx.send(Message::Binary(bytes.clone()));
                    }
                }
            }
        }
    }
    let mut s = state.lock().unwrap();
    if let Some(sides) = s.channels.get_mut(&cid) {
        sides.remove(&obi);
        for tx in sides.values() {
            let _ = tx.send(Message::Text(r#"{"peer":"left"}"#.into()));
        }
    }
}

/// An answer the Sphere holds until the test lets it go.
#[derive(Clone)]
struct Held(Arc<tokio::sync::Notify>);

async fn send(
    State(state): State<Arc<Mutex<SphereState>>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let response = record(&state, &headers, &body);
    if let Some(Held(release)) = response.extensions().get::<Held>().cloned() {
        release.notified().await;
    }
    response
}

fn record(state: &Mutex<SphereState>, headers: &HeaderMap, body: &[u8]) -> Response {
    let mut state = state.lock().unwrap();
    let Some(sender) = bearer(&state, headers) else {
        return sphere_error(StatusCode::UNAUTHORIZED, "unauthorized", "no token");
    };
    let text = String::from_utf8_lossy(body).into_owned();
    let answer = |state: &mut SphereState, status: StatusCode, response: Response| {
        state
            .sends
            .push((sender.clone(), text.clone(), status.as_u16()));
        response
    };
    let Ok(env) = serde_json::from_slice::<Value>(body) else {
        return answer(
            &mut state,
            StatusCode::BAD_REQUEST,
            sphere_error(StatusCode::BAD_REQUEST, "invalid_envelope", "not JSON"),
        );
    };
    // Check 8: a retry of what was recorded answers the original.
    if let Some(entry) = state
        .entries
        .iter()
        .find(|e| e["envelope"]["id"] == env["id"])
    {
        let same = entry["envelope"] == env;
        let original = json!({"id": env["id"], "seq": entry["seq"], "entry_hash": entry["hash"], "recorded_at": entry["recorded_at"]});
        return if same {
            answer(
                &mut state,
                StatusCode::OK,
                axum::Json(original).into_response(),
            )
        } else {
            answer(
                &mut state,
                StatusCode::CONFLICT,
                sphere_error(
                    StatusCode::CONFLICT,
                    "duplicate",
                    "another message has this id",
                ),
            )
        };
    }
    if let Some(left) = state.rate_limit.get_mut(&sender)
        && *left > 0
    {
        *left -= 1;
        let mut response = sphere_error(
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limited",
            "concurrent writes",
        );
        response
            .headers_mut()
            .insert("retry-after", "1".parse().unwrap());
        return answer(&mut state, StatusCode::TOO_MANY_REQUESTS, response);
    }
    let context = envelope::Context {
        now: Some(time::now()),
        sphere: Some(SPHERE.into()),
        receiver: env["to"].as_str().map(str::to_owned),
        keys: keys(&state),
        seq: None,
        seen_ids: Vec::new(),
    };
    if let Err(r) = envelope::verify(&env, &context) {
        return answer(
            &mut state,
            StatusCode::BAD_REQUEST,
            sphere_error(StatusCode::BAD_REQUEST, r.code, &r.message),
        );
    }
    if env["from"] != sender.as_str() {
        return answer(
            &mut state,
            StatusCode::FORBIDDEN,
            sphere_error(
                StatusCode::FORBIDDEN,
                "forbidden",
                "from isn't the token's actor",
            ),
        );
    }
    let kind = env["type"].as_str().unwrap_or("");
    if obi_protocol::REQUEST_TYPES.contains(&kind) {
        if state.deny_requests {
            return answer(
                &mut state,
                StatusCode::FORBIDDEN,
                sphere_error(StatusCode::FORBIDDEN, "policy_denied", "no rule allows it"),
            );
        }
    } else {
        let all: Vec<Value> = state
            .entries
            .iter()
            .map(|e| e["envelope"].clone())
            .collect();
        let request = all.iter().find(|e| e["id"] == env["in_reply_to"]);
        let earlier: Vec<&Value> = all
            .iter()
            .filter(|e| e["in_reply_to"] == env["in_reply_to"] && !e["in_reply_to"].is_null())
            .collect();
        if let Some(problem) = chain::exchange_problem(&env, request, &earlier) {
            return answer(
                &mut state,
                StatusCode::CONFLICT,
                sphere_error(StatusCode::CONFLICT, "bad_reply", &problem),
            );
        }
    }
    let recorded_at = time::format(time::now());
    let entries = chain::append(&state.entries, SPHERE, &env, &recorded_at).unwrap();
    let entry = entries.last().unwrap().clone();
    state.entries = entries;
    let seq = entry["seq"].as_u64().unwrap();
    let to = env["to"].as_str().unwrap().to_owned();
    state.queue.push((
        uuid::Uuid::new_v4().to_string(),
        to,
        seq,
        recorded_at.clone(),
        env.clone(),
        false,
    ));
    let sent = json!({"id": env["id"], "seq": seq, "entry_hash": entry["hash"], "recorded_at": recorded_at});
    let mut response = (StatusCode::ACCEPTED, axum::Json(sent)).into_response();
    if let Some((_, release)) = state.hold.take_if(|(held, _)| *held == kind) {
        response.extensions_mut().insert(Held(release));
    }
    answer(&mut state, StatusCode::ACCEPTED, response)
}

async fn deliveries(
    State(state): State<Arc<Mutex<SphereState>>>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let wait: u64 = query.get("wait").and_then(|w| w.parse().ok()).unwrap_or(0);
    // A short hold, so the tests are quick: the spec lets a Sphere answer sooner.
    let give_up_at = Instant::now() + Duration::from_millis((wait * 1000).min(1500));
    loop {
        {
            let state = state.lock().unwrap();
            let Some(obi) = bearer(&state, &headers) else {
                return sphere_error(StatusCode::UNAUTHORIZED, "unauthorized", "no token");
            };
            let list: Vec<Value> = state
                .queue
                .iter()
                .filter(|d| d.1 == obi && !d.5)
                .map(
                    |d| json!({"delivery_id": d.0, "seq": d.2, "relayed_at": d.3, "envelope": d.4}),
                )
                .collect();
            if !list.is_empty() || Instant::now() >= give_up_at {
                return axum::Json(json!({"deliveries": list})).into_response();
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn ack(
    State(state): State<Arc<Mutex<SphereState>>>,
    headers: HeaderMap,
    axum::Json(body): axum::Json<Map<String, Value>>,
) -> Response {
    let mut state = state.lock().unwrap();
    let Some(obi) = bearer(&state, &headers) else {
        return sphere_error(StatusCode::UNAUTHORIZED, "unauthorized", "no token");
    };
    let ids: Vec<String> = body["delivery_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect();
    let mut acked = 0;
    for d in state.queue.iter_mut() {
        if d.1 == obi && !d.5 && ids.contains(&d.0) {
            d.5 = true;
            acked += 1;
        }
    }
    axum::Json(json!({"acked": acked})).into_response()
}
