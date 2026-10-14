//! obid as the apps and the e2e harness see it: the real binary, started with a configuration
//! file, asked over HTTP. Ported from RunnerTests/LoopbackTests.swift (the gate in front of every
//! endpoint) and checked against docs/runner-api.md ("GET /v1/status", "obid only:
//! configuration").

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const OBID: &str = env!("CARGO_BIN_EXE_obid");

/// A folder of the test's own, removed when it ends.
struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("obid-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        // macOS's temp folder is behind a symbolic link; obid is given the real path.
        Folder(path.canonicalize().unwrap())
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// The documented example, on a free port, in `folder`.
fn config(folder: &Path, port: u16) -> Value {
    json!({
        "listen": format!("127.0.0.1:{port}"),
        "home": folder.join("home"),
        "owner": "wellington",
        "agents": {"claude": {"bin": "claude", "accounts": [
            {"id": "default", "name": "Default", "configDir": null},
            {"id": "work", "name": "Work", "configDir": folder.join("accounts/work")}
        ]}},
        "repos": [{"repo": "obi-e2e/fixture-app", "remote": format!("file://{}", folder.join("remote.git").display()),
                   "defaultBranch": "main", "check": "node --test"}],
        "allowFileRemotes": true,
        "telemetry": false
    })
}

/// A running obid, stopped (SIGKILL) when dropped if the test didn't stop it.
struct Obid {
    child: Child,
    port: u16,
    stderr: PathBuf,
}

impl Drop for Obid {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn command(folder: &Path, config_path: &Path) -> Command {
    let mut command = Command::new(OBID);
    command
        .args(["serve", "--config"])
        .arg(config_path)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("HOME", folder.join("env-home"))
        .env("TMPDIR", folder.join("tmp"));
    std::fs::create_dir_all(folder.join("env-home")).unwrap();
    std::fs::create_dir_all(folder.join("tmp")).unwrap();
    command
}

/// Starts obid with `config` (written to `folder/config.json`) and waits for it to listen.
fn start(folder: &Path, config: &Value, token: Option<&str>) -> Obid {
    let path = folder.join("config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    let stderr = folder.join("obid.stderr");
    let mut command = command(folder, &path);
    if let Some(token) = token {
        command.env("OBID_API_TOKEN", token);
    }
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(std::fs::File::create(&stderr).unwrap())
        .spawn()
        .unwrap();
    let port: u16 = config["listen"]
        .as_str()
        .unwrap()
        .rsplit_once(':')
        .unwrap()
        .1
        .parse()
        .unwrap();
    // obid says where it listens, on stdout, once it does.
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    assert_eq!(
        line.trim(),
        format!("obid listening on http://127.0.0.1:{port}"),
        "obid didn't start: {}",
        std::fs::read_to_string(&stderr).unwrap_or_default()
    );
    Obid {
        child,
        port,
        stderr,
    }
}

struct Answer {
    status: u16,
    body: Value,
}

/// One HTTP/1.1 request, written by hand so the test controls every header, `Host` included.
fn request(port: u16, method: &str, target: &str, headers: &[(&str, &str)]) -> Answer {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut text = format!("{method} {target} HTTP/1.1\r\n");
    for (name, value) in headers {
        text.push_str(&format!("{name}: {value}\r\n"));
    }
    text.push_str("Connection: close\r\n\r\n");
    stream.write_all(text.as_bytes()).unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let raw = String::from_utf8(raw).unwrap();
    let (head, body) = raw.split_once("\r\n\r\n").unwrap();
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    let body = if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        unchunk(body)
    } else {
        body.to_string()
    };
    let body = if body.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&body).unwrap_or_else(|_| panic!("not JSON: {body:?}"))
    };
    Answer { status, body }
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

fn get_status(obid: &Obid, host: &str, token: &str) -> Answer {
    let bearer = format!("Bearer {token}");
    request(
        obid.port,
        "GET",
        "/v1/status",
        &[("Host", host), ("Authorization", &bearer)],
    )
}

const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

#[test]
fn status_answers_with_engine_obid() {
    let folder = Folder::new("status");
    let config = config(&folder.0, free_port());
    let obid = start(&folder.0, &config, Some(TOKEN));
    let host = format!("127.0.0.1:{}", obid.port);
    let answer = get_status(&obid, &host, TOKEN);
    assert_eq!(answer.status, 200, "{}", answer.body);
    let status = answer.body;

    // runner-api.md, "obid only: configuration": GET /v1/status adds "engine": "obid" to runner.
    assert_eq!(status["runner"]["engine"], "obid");
    assert_eq!(status["runner"]["version"], "0.2.0");
    assert!(
        status["runner"]["host"]
            .as_str()
            .is_some_and(|h| !h.is_empty())
    );

    // Every account in the configuration, as an Account object, before any job ran on it.
    let accounts = status["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 2);
    assert_eq!(
        accounts[0],
        json!({"id": "default", "agent": "claude", "name": "Default", "label": null, "signedIn": true,
               "fiveHour": null, "sevenDay": null, "fiveHourResets": null, "sevenDayResets": null,
               "running": 0, "fullUntil": null, "tetrix": null, "tetrixJobs": 0, "tetrixUsed": 0,
               "reserved": false, "reserveLiftedUntil": null})
    );
    assert_eq!(accounts[1]["id"], "work");
    assert_eq!(accounts[1]["name"], "Work");

    // The rest of the documented keys, with obid's values before any work.
    assert_eq!(
        status["models"],
        json!({"claude": {"model": "claude-opus-5-5", "effort": "xhigh", "complexEffort": "xhigh"},
               "codex": {"model": "gpt-6.1-sol", "effort": "high", "complexEffort": "high"},
               "cursor": {"model": "auto"}})
    );
    assert_eq!(status["maxRunning"], 6);
    assert_eq!(status["running"], 0);
    assert_eq!(status["clearedAt"], Value::Null);
    assert_eq!(status["github"], "owner");
    assert_eq!(status["checks"], "no app");
    assert_eq!(status["permissions"], json!({"mode": "bypass"}));
    let worktrees = folder.0.join("home").join("worktrees");
    assert_eq!(
        status["cleanup"],
        json!({"path": worktrees.to_string_lossy(), "bytes": 0, "lastRun": null})
    );

    // The token given in the environment is never written to home, nor said anywhere.
    assert!(!folder.0.join("home").join("api-token").exists());
    assert!(!answer_contains(&status, TOKEN));
    assert!(
        !std::fs::read_to_string(&obid.stderr)
            .unwrap()
            .contains(TOKEN)
    );
}

fn answer_contains(value: &Value, needle: &str) -> bool {
    value.to_string().contains(needle)
}

/// LoopbackTests.refusesEveryHostThatIsntLoopback: before the token is read, every `Host` that
/// isn't a loopback name is refused with 403, and so is a request with no `Host`.
#[test]
fn refuses_every_host_that_isnt_loopback() {
    let folder = Folder::new("hosts");
    let obid = start(&folder.0, &config(&folder.0, free_port()), Some(TOKEN));
    let bearer = format!("Bearer {TOKEN}");
    for host in [
        "evil.example",
        "evil.example:7777",
        "tetrix-lab.tail8de49b.ts.net:8443",
        "127.0.0.1.evil.example",
        "localhost.evil.example",
        "[::2]",
        "127.0.0.2",
        "0.0.0.0",
    ] {
        let answer = request(
            obid.port,
            "GET",
            "/v1/status",
            &[("Host", host), ("Authorization", &bearer)],
        );
        assert_eq!(answer.status, 403, "{host}");
        assert_eq!(
            answer.body,
            json!({"error": "This runner answers only on 127.0.0.1."}),
            "{host}"
        );
    }
    // No Host at all.
    let answer = request(
        obid.port,
        "GET",
        "/v1/status",
        &[("Authorization", &bearer)],
    );
    assert_eq!(answer.status, 403);
    // Two of them, one loopback.
    let answer = request(
        obid.port,
        "GET",
        "/v1/status",
        &[
            ("Host", "127.0.0.1"),
            ("Host", "evil.example"),
            ("Authorization", &bearer),
        ],
    );
    assert_eq!(answer.status, 403);
    // A loopback Host with another name in the request line (absolute form).
    let answer = request(
        obid.port,
        "GET",
        "http://evil.example/v1/status",
        &[("Host", "127.0.0.1"), ("Authorization", &bearer)],
    );
    assert_eq!(answer.status, 403);
    // Before the token: a wrong Host with no token is 403, not 401.
    let answer = request(obid.port, "GET", "/v1/status", &[("Host", "evil.example")]);
    assert_eq!(answer.status, 403);
}

/// LoopbackTests.letsLoopbackHostsInWithTheToken.
#[test]
fn lets_loopback_hosts_in_with_the_token() {
    let folder = Folder::new("loopback");
    let obid = start(&folder.0, &config(&folder.0, free_port()), Some(TOKEN));
    let port = obid.port.to_string();
    for host in [
        "127.0.0.1".to_string(),
        format!("127.0.0.1:{port}"),
        "localhost".into(),
        format!("localhost:{port}"),
        "LOCALHOST".into(),
        "[::1]".into(),
        format!("[::1]:{port}"),
    ] {
        let answer = get_status(&obid, &host, TOKEN);
        assert_eq!(answer.status, 200, "{host}");
    }
}

/// LoopbackTests.refusesWithoutTheToken and theRouterIsBehindTheGate: every path, known or not,
/// answers 401 without the token.
#[test]
fn refuses_without_the_token() {
    let folder = Folder::new("token");
    let obid = start(&folder.0, &config(&folder.0, free_port()), Some(TOKEN));
    let other = "cd".repeat(32);
    let wrong: Vec<Vec<(&str, String)>> = vec![
        vec![],
        vec![("Authorization", "Bearer ".into())],
        vec![("Authorization", format!("Bearer {other}"))],
        vec![(
            "Authorization",
            format!("Bearer {}", &TOKEN[..TOKEN.len() - 1]),
        )],
        vec![("Authorization", TOKEN.into())],
        vec![("Authorization", format!("Basic {TOKEN}"))],
        vec![("Authorization", format!("bearer {TOKEN}"))],
        vec![("Tailscale-User-Login", "well@example.com".into())],
        vec![
            ("Authorization", format!("Bearer {TOKEN}")),
            ("Authorization", format!("Bearer {other}")),
        ],
    ];
    for headers in &wrong {
        for path in ["/v1/status", "/v1/jobs", "/v1/nowhere"] {
            let mut all: Vec<(&str, &str)> = vec![("Host", "127.0.0.1")];
            all.extend(headers.iter().map(|(n, v)| (*n, v.as_str())));
            let answer = request(obid.port, "GET", path, &all);
            assert_eq!(answer.status, 401, "{path} {headers:?}");
            assert_eq!(
                answer.body,
                json!({"error": "This runner answers only requests with its API token."})
            );
        }
    }
    // With the token, an endpoint obid doesn't have yet is a 404 in the API's error shape.
    let bearer = format!("Bearer {TOKEN}");
    let answer = request(
        obid.port,
        "GET",
        "/v1/nowhere",
        &[("Host", "127.0.0.1"), ("Authorization", &bearer)],
    );
    assert_eq!(answer.status, 404);
    assert!(answer.body["error"].is_string());
    let answer = request(
        obid.port,
        "POST",
        "/v1/status",
        &[("Host", "127.0.0.1"), ("Authorization", &bearer)],
    );
    assert_eq!(answer.status, 405);
    assert!(answer.body["error"].is_string());
}

/// LoopbackTests.oauthDiscoveryIs404: a plain 404 without a token, after the host check.
#[test]
fn oauth_discovery_is_404() {
    let folder = Folder::new("oauth");
    let obid = start(&folder.0, &config(&folder.0, free_port()), Some(TOKEN));
    for path in [
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-authorization-server",
        "/.well-known/openid-configuration",
        "/register",
    ] {
        let answer = request(obid.port, "GET", path, &[("Host", "127.0.0.1")]);
        assert_eq!(answer.status, 404, "{path}");
    }
    let answer = request(
        obid.port,
        "GET",
        "/.well-known/openid-configuration",
        &[("Host", "evil.example")],
    );
    assert_eq!(answer.status, 403);
}

/// Without OBID_API_TOKEN, obid makes a token on first start, keeps it in home/api-token (0600),
/// answers only to it, and uses the same one when it starts again.
#[test]
fn makes_and_keeps_its_own_token() {
    let folder = Folder::new("own-token");
    let config = config(&folder.0, free_port());
    let token_file = folder.0.join("home").join("api-token");
    let first = {
        let obid = start(&folder.0, &config, None);
        let token = std::fs::read_to_string(&token_file).unwrap();
        let token = token.trim_end().to_string();
        assert_eq!(token.len(), 64);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&token_file).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert_eq!(get_status(&obid, "127.0.0.1", &token).status, 200);
        assert_eq!(get_status(&obid, "127.0.0.1", TOKEN).status, 401);
        assert!(
            !std::fs::read_to_string(&obid.stderr)
                .unwrap()
                .contains(&token)
        );
        token
    };
    let obid = start(&folder.0, &config, None);
    assert_eq!(get_status(&obid, "127.0.0.1", &first).status, 200);
}

/// Exits non-zero, saying why, with a configuration or token it can't use, and binds nothing.
#[test]
fn refuses_what_it_cant_use() {
    let folder = Folder::new("refuses");
    let port = free_port();
    let good = config(&folder.0, port);
    let mut cases: Vec<(Value, Option<&str>, &str)> = Vec::new();
    let mut with = |key: &str, value: Value, says: &'static str| {
        let mut config = good.clone();
        if value.is_null() {
            config.as_object_mut().unwrap().remove(key);
        } else {
            config[key] = value;
        }
        cases.push((config, Some(TOKEN), says));
    };
    with("listen", json!(format!("0.0.0.0:{port}")), "listen");
    with("listen", Value::Null, "listen");
    with("home", json!("relative/home"), "absolute");
    with("owner", Value::Null, "owner");
    with("allowFileRemotes", json!(false), "allowFileRemotes");
    with("telemetri", json!(true), "telemetri");
    cases.push((good.clone(), Some("too-short"), "OBID_API_TOKEN"));

    for (config, token, says) in cases {
        let path = folder.0.join("config.json");
        std::fs::write(&path, config.to_string()).unwrap();
        let mut command = command(&folder.0, &path);
        if let Some(token) = token {
            command.env("OBID_API_TOKEN", token);
        }
        let output = command.output().unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(!output.status.success(), "{says}: {stderr}");
        assert!(stderr.contains(says), "{says}: {stderr}");
        assert!(
            TcpStream::connect(("127.0.0.1", port)).is_err(),
            "{says}: something listens"
        );
    }

    // A config file that isn't there, or isn't JSON.
    let missing = command(&folder.0, &folder.0.join("nowhere.json"))
        .output()
        .unwrap();
    assert!(!missing.status.success());
    assert!(String::from_utf8_lossy(&missing.stderr).contains("nowhere.json"));
    std::fs::write(folder.0.join("bad.json"), "{").unwrap();
    let bad = command(&folder.0, &folder.0.join("bad.json"))
        .output()
        .unwrap();
    assert!(!bad.status.success());

    // No arguments: the usage, exit 2.
    let usage = Command::new(OBID).output().unwrap();
    assert_eq!(usage.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&usage.stderr).contains("obid serve --config"));
}

/// On SIGTERM or SIGINT obid stops taking requests and exits 0 within 10 seconds.
#[cfg(unix)]
#[test]
fn exits_0_on_sigterm_and_sigint() {
    for signal in ["TERM", "INT"] {
        let folder = Folder::new(&format!("signal-{signal}"));
        let mut obid = start(&folder.0, &config(&folder.0, free_port()), Some(TOKEN));
        assert_eq!(get_status(&obid, "127.0.0.1", TOKEN).status, 200);
        // An idle keep-alive connection must not hold obid up.
        let _idle = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
        let sent = Command::new("kill")
            .args([format!("-{signal}"), obid.child.id().to_string()])
            .status()
            .unwrap();
        assert!(sent.success());
        let began = Instant::now();
        let status = loop {
            if let Some(status) = obid.child.try_wait().unwrap() {
                break status;
            }
            assert!(
                began.elapsed() < Duration::from_secs(10),
                "SIG{signal}: still running after 10 seconds"
            );
            std::thread::sleep(Duration::from_millis(50));
        };
        assert_eq!(status.code(), Some(0), "SIG{signal}");
        assert!(TcpStream::connect(("127.0.0.1", obid.port)).is_err());
    }
}
