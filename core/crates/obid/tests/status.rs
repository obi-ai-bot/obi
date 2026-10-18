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

/// A port nothing listens on now, for a test that checks obid never binds it. It is below the
/// systems' ephemeral ranges (Linux 32768 and up, macOS 49152 and up), where a port-0 bind, as by
/// an obid another test starts at the same time, never lands.
fn unused_port() -> u16 {
    let start = 20_000 + (std::process::id() % 10_000) as u16;
    (start..32_000)
        .chain(20_000..start)
        .find(|port| TcpListener::bind(("127.0.0.1", *port)).is_ok())
        .expect("a free port below 32000")
}

/// The documented example, in `folder`, listening on `port`. Tests that start obid pass 0: obid
/// binds a port the system picks and says which on its readiness line, so no two tests can race
/// for the same one.
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

/// Puts `token` in obid's `home/api-token` (0600, in a 0700 `home`), where obid takes its token
/// from: never from its environment (docs/runner-api.md, "obid only: configuration").
fn put_token(config: &Value, token: &str) {
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

/// Starts obid with `config` (written to `folder/config.json`) and waits for it to listen.
fn start(folder: &Path, config: &Value, token: Option<&str>) -> Obid {
    let path = folder.join("config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    let stderr = folder.join("obid.stderr");
    if let Some(token) = token {
        put_token(config, token);
    }
    let mut child = command(folder, &path)
        .stdout(Stdio::piped())
        .stderr(std::fs::File::create(&stderr).unwrap())
        .spawn()
        .unwrap();
    let asked: u16 = config["listen"]
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
    let port = listening_port(&line).unwrap_or_else(|| {
        panic!(
            "obid didn't start: {line:?} {}",
            std::fs::read_to_string(&stderr).unwrap_or_default()
        )
    });
    assert!(asked == 0 || asked == port, "{line:?}");
    Obid {
        child,
        port,
        stderr,
    }
}

/// The port in obid's readiness line, `obid listening on http://127.0.0.1:<port>`.
fn listening_port(line: &str) -> Option<u16> {
    line.trim()
        .strip_prefix("obid listening on http://127.0.0.1:")?
        .parse()
        .ok()
        .filter(|port| *port != 0)
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
    let config = config(&folder.0, 0);
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
        json!({"id": "default", "agent": "claude", "name": "Default", "payer": null, "label": null, "signedIn": false,
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
    assert_eq!(status["permissions"], json!({"mode": "sandbox"}));
    let worktrees = folder.0.join("home").join("worktrees");
    assert_eq!(
        status["cleanup"],
        json!({"path": worktrees.to_string_lossy(), "bytes": 0, "lastRun": null})
    );

    // The token put in home/api-token is taken as it is, never rewritten, nor said anywhere.
    assert_eq!(
        std::fs::read_to_string(folder.0.join("home").join("api-token")).unwrap(),
        format!("{TOKEN}\n")
    );
    assert!(!answer_contains(&status, TOKEN));
    assert!(
        !std::fs::read_to_string(&obid.stderr)
            .unwrap()
            .contains(TOKEN)
    );
}

/// #626: a Claude Code account is signed in when its login file is there (`.credentials.json` in
/// its `configDir`, else in the person's `~/.claude`): a login only in the macOS Keychain can't
/// reach a job's sandbox. obid only looks whether the file exists, never at what it holds.
#[test]
fn an_account_is_signed_in_when_its_login_file_is_there() {
    let folder = Folder::new("signed-in");
    let config = config(&folder.0, 0);
    let work = folder.0.join("accounts/work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join(".credentials.json"), "{}").unwrap();
    let obid = start(&folder.0, &config, Some(TOKEN));
    let host = format!("127.0.0.1:{}", obid.port);
    let signed_in = || -> Vec<Value> {
        let answer = get_status(&obid, &host, TOKEN);
        assert_eq!(answer.status, 200, "{}", answer.body);
        answer.body["accounts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a["signedIn"].clone())
            .collect()
    };
    assert_eq!(signed_in(), [json!(false), json!(true)]);
    // The default login, once `claude auth login` wrote it to a file.
    let person = folder.0.join("env-home/.claude");
    std::fs::create_dir_all(&person).unwrap();
    std::fs::write(person.join(".credentials.json"), "{}").unwrap();
    assert_eq!(signed_in(), [json!(true), json!(true)]);
    std::fs::remove_file(work.join(".credentials.json")).unwrap();
    assert_eq!(signed_in(), [json!(true), json!(false)]);
}

fn answer_contains(value: &Value, needle: &str) -> bool {
    value.to_string().contains(needle)
}

/// LoopbackTests.refusesEveryHostThatIsntLoopback: before the token is read, every `Host` that
/// isn't a loopback name is refused with 403, and so is a request with no `Host`.
#[test]
fn refuses_every_host_that_isnt_loopback() {
    let folder = Folder::new("hosts");
    let obid = start(&folder.0, &config(&folder.0, 0), Some(TOKEN));
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
    let obid = start(&folder.0, &config(&folder.0, 0), Some(TOKEN));
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
    let obid = start(&folder.0, &config(&folder.0, 0), Some(TOKEN));
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

/// LoopbackTests.oauthDiscoveryIs404 gives a Mac runner's OAuth discovery paths a plain 404
/// without a token. obid's contract (runner-api.md, "obid only: configuration") has no such
/// exception: anything without the token is 401, these paths included, and with the token they
/// are endpoints obid doesn't have, 404. A host that isn't loopback is 403 before either.
#[test]
fn oauth_discovery_needs_the_token() {
    let folder = Folder::new("oauth");
    let obid = start(&folder.0, &config(&folder.0, 0), Some(TOKEN));
    let bearer = format!("Bearer {TOKEN}");
    for path in [
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-protected-resource/v1/status",
        "/.well-known/oauth-authorization-server",
        "/.well-known/openid-configuration",
        "/register",
        "/authorize",
        "/token",
    ] {
        let answer = request(obid.port, "GET", path, &[("Host", "127.0.0.1")]);
        assert_eq!(answer.status, 401, "{path}");
        assert!(answer_contains(&answer.body, "API token"), "{path}");
        let answer = request(
            obid.port,
            "GET",
            path,
            &[("Host", "127.0.0.1"), ("Authorization", &bearer)],
        );
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

/// status.cleanup.bytes is measured when obid starts (and, once obid cleans up, after each pass),
/// as Engine/Cleanup.swift does, never on each request: what lands in the worktrees afterwards
/// doesn't change it until then.
#[test]
fn cleanup_bytes_are_measured_at_start_not_per_request() {
    let folder = Folder::new("cleanup-bytes");
    let worktrees = folder.0.join("home").join("worktrees");
    std::fs::create_dir_all(worktrees.join("job-1")).unwrap();
    std::fs::write(worktrees.join("job-1").join("file"), vec![7u8; 256 * 1024]).unwrap();
    let obid = start(&folder.0, &config(&folder.0, 0), Some(TOKEN));
    let first = get_status(&obid, "127.0.0.1", TOKEN);
    assert_eq!(first.status, 200);
    let bytes = first.body["cleanup"]["bytes"].as_u64().unwrap();
    assert!(bytes >= 256 * 1024, "measured at start: {bytes}");

    std::fs::create_dir_all(worktrees.join("job-2")).unwrap();
    std::fs::write(worktrees.join("job-2").join("file"), vec![7u8; 1024 * 1024]).unwrap();
    for _ in 0..3 {
        let again = get_status(&obid, "127.0.0.1", TOKEN);
        assert_eq!(again.body["cleanup"]["bytes"].as_u64(), Some(bytes));
    }
}

/// home holds the token, keys, clones and the database: obid makes it 0700, and tightens one that
/// is there already with group or world access.
#[cfg(unix)]
#[test]
fn home_is_the_owners_alone() {
    use std::os::unix::fs::PermissionsExt;
    let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;

    let folder = Folder::new("home-mode-new");
    let config = config(&folder.0, 0);
    drop(start(&folder.0, &config, None));
    assert_eq!(mode(&folder.0.join("home")), 0o700);

    let folder = Folder::new("home-mode-open");
    let home = folder.0.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o755)).unwrap();
    let config = self::config(&folder.0, 0);
    let obid = start(&folder.0, &config, None);
    assert_eq!(mode(&home), 0o700);
    assert_eq!(mode(&home.join("api-token")), 0o600);
    assert_eq!(get_status(&obid, "127.0.0.1", TOKEN).status, 401);
}

/// With no token in home/api-token, obid makes one on first start, keeps it in home/api-token (0600),
/// answers only to it, and uses the same one when it starts again.
#[test]
fn makes_and_keeps_its_own_token() {
    let folder = Folder::new("own-token");
    let config = config(&folder.0, 0);
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
    let port = unused_port();
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
    // Without `listen`: required but on macOS, where obid listens on 127.0.0.1:7777 (config.rs).
    if !cfg!(target_os = "macos") {
        with("listen", Value::Null, "listen");
    }
    with("home", json!("relative/home"), "absolute");
    with("owner", Value::Null, "owner");
    with("allowFileRemotes", json!(false), "allowFileRemotes");
    with("telemetri", json!(true), "telemetri");
    // Remotes git or ssh would read as options are refused before anything clones them.
    for remote in [
        "ssh://-oProxyCommand=touch /tmp/pwned/x",
        "-oProxyCommand=touch /tmp/x@h:p",
        "https://-x/r",
        "ssh://-oProxyCommand=x@github.com/o/r.git",
        // Local paths dressed as scp-like ssh remotes: git would clone them from the disk.
        "/tmp/x@h:p",
        "./x@h:p",
        "../../srv/other@h:repo.git",
    ] {
        with(
            "repos",
            json!([{"repo": "obi-e2e/fixture-app", "remote": remote, "defaultBranch": "main", "check": "node --test"}]),
            "isn't an https://, ssh or file:// URL",
        );
    }
    // A token in obid's environment, where other processes could read it, even a good one.
    cases.push((good.clone(), Some(TOKEN), "OBID_API_TOKEN is set"));
    // A token file that holds no usable token.
    cases.push((good.clone(), Some("too-short"), "no usable token"));

    for (config, token, says) in cases {
        let path = folder.0.join("config.json");
        std::fs::write(&path, config.to_string()).unwrap();
        let mut command = command(&folder.0, &path);
        match token {
            Some(token) if says == "OBID_API_TOKEN is set" => {
                put_token(&good, TOKEN);
                command.env("OBID_API_TOKEN", token);
            }
            Some(token) => put_token(&good, token),
            None => {}
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

/// Sends SIG`signal` to `pid` with the shell's built-in `kill`, which every POSIX shell has,
/// where a `kill` program isn't on every machine.
#[cfg(unix)]
fn send(signal: &str, pid: u32) {
    let sent = Command::new("sh")
        .args(["-c", r#"kill -s "$1" "$2""#, "sh", signal, &pid.to_string()])
        .status()
        .unwrap();
    assert!(sent.success(), "kill -s {signal} {pid}");
}

/// On SIGTERM or SIGINT obid stops taking requests and exits 0 within 10 seconds.
#[cfg(unix)]
#[test]
fn exits_0_on_sigterm_and_sigint() {
    for signal in ["TERM", "INT"] {
        let folder = Folder::new(&format!("signal-{signal}"));
        let mut obid = start(&folder.0, &config(&folder.0, 0), Some(TOKEN));
        assert_eq!(get_status(&obid, "127.0.0.1", TOKEN).status, 200);
        // An idle keep-alive connection must not hold obid up.
        let _idle = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
        send(signal, obid.child.id());
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

/// Waits up to 10 seconds for `child` to exit and gives its status.
fn exit_within_10_seconds(child: &mut Child, what: &str) -> std::process::ExitStatus {
    let began = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(
            began.elapsed() < Duration::from_secs(10),
            "{what}: still running after 10 seconds"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The signal handlers are in place before obid says it listens: SIGTERM or SIGINT the moment the
/// readiness line is out stops obid with exit 0 and never kills it with the signal. The signal is
/// sent by a shell's built-in `kill` as soon as the shell reads the line, so nothing is spawned in
/// between, and it is repeated because the window it guards is short.
#[cfg(unix)]
#[test]
fn a_signal_the_moment_obid_says_it_listens_exits_0() {
    for round in 0..10 {
        for signal in ["TERM", "INT"] {
            let folder = Folder::new(&format!("signal-ready-{signal}-{round}"));
            let path = folder.0.join("config.json");
            std::fs::write(&path, config(&folder.0, 0).to_string()).unwrap();
            put_token(&config(&folder.0, 0), TOKEN);
            let mut obid = command(&folder.0, &path)
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let line = Command::new("sh")
                .args([
                    "-c",
                    r#"IFS= read -r line; kill -s "$1" "$2"; printf '%s\n' "$line""#,
                    "sh",
                    signal,
                    &obid.id().to_string(),
                ])
                .stdin(Stdio::from(obid.stdout.take().unwrap()))
                .output()
                .unwrap();
            let line = String::from_utf8_lossy(&line.stdout);
            assert!(listening_port(&line).is_some(), "{line:?}");
            let status = exit_within_10_seconds(&mut obid, &format!("SIG{signal}"));
            assert_eq!(
                status.code(),
                Some(0),
                "SIG{signal}, round {round}: {status:?}"
            );
        }
    }
}

/// A SIGTERM while obid is still starting (here: measuring a large `home/worktrees`, which it
/// does before it listens) stops it with exit 0 too. obid writes `home/api-token` before that
/// measurement, so its appearing says obid is under way. A shell starts obid, watches for the
/// file in a busy loop and sends the signal with its built-in `kill` the moment it is there, then
/// reports obid's exit status (143 when SIGTERM killed it).
#[cfg(unix)]
#[test]
fn a_signal_while_obid_starts_exits_0() {
    let folder = Folder::new("signal-starting");
    let config = config(&folder.0, 0);
    let home = folder.0.join("home");
    for d in 0..100 {
        let dir = home.join("worktrees").join(format!("wt-{d}"));
        std::fs::create_dir_all(&dir).unwrap();
        for f in 0..200 {
            std::fs::write(dir.join(format!("f{f}")), b"x").unwrap();
        }
    }
    let path = folder.0.join("config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    let script = r#"
        "$1" serve --config "$2" >/dev/null 2>&1 &
        obid=$!
        n=0
        while [ ! -e "$3" ]; do
            n=$((n + 1))
            if [ "$n" -gt 2000000 ]; then kill -s KILL "$obid"; echo "no token"; exit 1; fi
        done
        kill -s TERM "$obid"
        wait "$obid"
        echo "$?"
    "#;
    std::fs::create_dir_all(folder.0.join("env-home")).unwrap();
    std::fs::create_dir_all(folder.0.join("tmp")).unwrap();
    let mut shell = Command::new("sh");
    shell
        .args(["-c", script, "sh", OBID])
        .arg(&path)
        .arg(home.join("api-token"))
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("HOME", folder.0.join("env-home"))
        .env("TMPDIR", folder.0.join("tmp"))
        .stdout(Stdio::piped());
    let mut shell = shell.spawn().unwrap();
    exit_within_10_seconds(&mut shell, "SIGTERM while starting");
    let mut said = String::new();
    shell
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut said)
        .unwrap();
    assert_eq!(
        said.trim(),
        "0",
        "obid's exit status after SIGTERM while starting"
    );
}
