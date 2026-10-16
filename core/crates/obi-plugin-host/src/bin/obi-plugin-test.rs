//! The plug-in the host's tests run (`tests/plugins/`): one program for every kind, speaking
//! `obi-plugin/0.1` over stdin and stdout and doing what its settings (`config` in
//! `initialize`) say, so a test can make it behave and misbehave. It writes what it saw into
//! its data folder (its working directory), where the test reads it:
//!
//! - `starts`: one line per start, with the time it started (milliseconds since 1970);
//! - `initialize.json`: the `initialize` params;
//! - `env.json`: its environment and working directory;
//! - `probe.json`: what each read, list, write, Unix socket connection and command in
//!   `config.probe` gave;
//! - `queries.json`: the `context/query` params, one per line;
//! - `emits.json`: the host's answers to the events it emitted;
//! - `beats`: a line five times a second from the process it started, with
//!   `config.spawnChild`;
//! - `detached-<start>` and `detached-beats-<start>`: with `config.spawnDetached`, a process
//!   that left its process group and session (`setsid`) and whose parent exited (so launchd,
//!   or the sandbox's PID namespace's first process, took it over) says it did, then appends a
//!   line five times a second;
//! - `shutdown`: made when `shutdown` arrives.
//!
//! `--kinds a,b` lists the kinds it serves unless `config.serve` says otherwise. Only the
//! tests use it.

use std::collections::BTreeMap;
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use obi_plugin_api::rpc::{Message, RequestId};
use serde_json::{Value, json};

type Out = Arc<Mutex<std::io::Stdout>>;

fn send(out: &Out, message: &Message) {
    let mut out = out.lock().unwrap_or_else(|p| p.into_inner());
    let _ = out.write_all(message.encode().as_bytes());
    let _ = out.flush();
}

fn write(name: &str, value: &Value) {
    let _ = std::fs::write(name, format!("{value:#}\n"));
}

fn append(name: &str, line: &str) {
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(name)
    {
        let _ = writeln!(file, "{line}");
    }
}

/// What the settings say, read once `initialize` brings them.
#[derive(Default)]
struct Behaviour {
    config: Value,
    /// Whether the failures it is told to have apply to this start: `config.failStarts` is
    /// how many starts fail (all, when left out).
    failing: bool,
}

impl Behaviour {
    fn text(&self, key: &str) -> Option<&str> {
        self.config.get(key).and_then(Value::as_str)
    }

    fn number(&self, key: &str) -> Option<u64> {
        self.config.get(key).and_then(Value::as_u64)
    }

    /// The failure `key` asks for, on a start that fails.
    fn fails(&self, key: &str, failure: &str) -> bool {
        self.failing && self.text(key) == Some(failure)
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut kinds: Vec<String> = Vec::new();
    while let Some(arg) = args.next() {
        if arg == "--kinds" {
            kinds = args
                .next()
                .unwrap_or_default()
                .split(',')
                .filter(|k| !k.is_empty())
                .map(str::to_owned)
                .collect();
        }
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    append("starts", &format!("start {now}"));
    let starts = std::fs::read_to_string("starts")
        .map(|s| s.lines().count() as u64)
        .unwrap_or(1);
    eprintln!("the test plug-in started (start {starts})");

    let out: Out = Arc::new(Mutex::new(std::io::stdout()));
    let mut behaviour = Behaviour::default();
    let mut pings = 0u64;
    let emitted: Arc<Mutex<BTreeMap<String, Value>>> = Arc::new(Mutex::new(BTreeMap::new()));
    let mut emit_count = 0usize;
    let mut ignoring_shutdown = false;

    let stdin = std::io::stdin();
    for line in stdin.lock().split(b'\n') {
        let Ok(line) = line else { break };
        let Ok(text) = String::from_utf8(line) else {
            continue;
        };
        let Ok(message) = Message::decode(&text) else {
            continue;
        };
        match message {
            Message::Request { id, method, params } => match method.as_str() {
                "initialize" => {
                    write("initialize.json", &params);
                    let config = params.get("config").cloned().unwrap_or(json!({}));
                    let fail_starts = config.get("failStarts").and_then(Value::as_u64);
                    behaviour = Behaviour {
                        failing: fail_starts.is_none_or(|n| starts <= n),
                        config,
                    };
                    record_environment();
                    if let Some(probe) = behaviour.config.get("probe") {
                        run_probe(probe);
                    }
                    if behaviour.config.get("spawnChild") == Some(&Value::Bool(true)) {
                        spawn_child();
                    }
                    if behaviour.config.get("spawnDetached") == Some(&Value::Bool(true)) {
                        spawn_detached(starts);
                    }
                    if behaviour.config.get("killWatcher") == Some(&Value::Bool(true)) {
                        spawn_detached(starts);
                        let parent = std::os::unix::process::parent_id();
                        std::thread::spawn(move || {
                            std::thread::sleep(Duration::from_millis(400));
                            let _ = std::process::Command::new("/bin/kill")
                                .args(["-KILL", &parent.to_string()])
                                .status();
                        });
                    }
                    for _ in 0..behaviour.number("stderrLines").unwrap_or(0) {
                        eprintln!("{}", "e".repeat(1000));
                    }
                    if behaviour.fails("initialize", "crash") {
                        std::process::exit(3);
                    }
                    if behaviour.fails("initialize", "silent") {
                        continue;
                    }
                    let served: Vec<Value> = match behaviour.config.get("serve") {
                        Some(Value::Array(serve)) => serve.clone(),
                        _ => kinds.iter().map(|k| json!(k)).collect(),
                    };
                    let mut served = served;
                    if behaviour.fails("initialize", "extra-kind") {
                        served.push(json!("events"));
                    }
                    let protocol = if behaviour.fails("initialize", "wrong-protocol") {
                        "obi-plugin/9"
                    } else {
                        "obi-plugin/0.1"
                    };
                    send(
                        &out,
                        &Message::response(id, &json!({"protocol": protocol, "kinds": served})),
                    );
                    if behaviour.fails("afterReady", "exit") {
                        std::thread::sleep(Duration::from_millis(100));
                        std::process::exit(4);
                    }
                    if let Some(Value::Array(events)) = behaviour.config.get("emit").cloned() {
                        emit_count = events.len();
                        for (i, event) in events.into_iter().enumerate() {
                            send(
                                &out,
                                &Message::Request {
                                    id: RequestId::String(format!("emit-{i:03}")),
                                    method: "events/emit".into(),
                                    params: event,
                                },
                            );
                        }
                    }
                    if behaviour.config.get("emitUnasked") == Some(&Value::Bool(true)) {
                        // A method obid doesn't take, and a log notification.
                        send(
                            &out,
                            &Message::request(
                                RequestId::String("other".into()),
                                "jobs/start",
                                &json!({}),
                            ),
                        );
                        send(
                            &out,
                            &Message::notification(
                                "log",
                                &json!({"level": "info", "message": "hello from the test plug-in"}),
                            ),
                        );
                        emit_count += 1;
                    }
                }
                "ping" => {
                    if behaviour.fails("ping", "silent") {
                        continue;
                    }
                    pings += 1;
                    send(&out, &Message::response(id, &json!({})));
                    if behaviour.failing
                        && behaviour
                            .number("exitAfterPings")
                            .is_some_and(|after| pings >= after)
                    {
                        std::thread::sleep(Duration::from_millis(50));
                        std::process::exit(5);
                    }
                }
                "context/query" => {
                    append("queries.json", &params.to_string());
                    let context = behaviour
                        .config
                        .get("context")
                        .cloned()
                        .unwrap_or(json!({}));
                    let delay = context.get("delayMs").and_then(Value::as_u64).unwrap_or(0);
                    if context.get("fail") == Some(&Value::Bool(true)) {
                        send(
                            &out,
                            &Message::error(Some(id), -32603, "the test plug-in fails on purpose"),
                        );
                        continue;
                    }
                    let count = context.get("items").and_then(Value::as_u64).unwrap_or(1);
                    let bytes = context
                        .get("textBytes")
                        .and_then(Value::as_u64)
                        .unwrap_or(10);
                    let items: Vec<Value> = (0..count)
                        .map(|i| {
                            json!({
                                "title": format!("item {i}"),
                                "source": "test",
                                "uri": format!("test://item/{i}"),
                                "text": "t".repeat(bytes as usize),
                            })
                        })
                        .collect();
                    let out = out.clone();
                    // Answered from a thread, so a slow answer doesn't hold the next request.
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(delay));
                        send(&out, &Message::response(id, &json!({"items": items})));
                    });
                }
                "shutdown" => {
                    write("shutdown", &json!(true));
                    if behaviour.text("shutdown") == Some("ignore") {
                        ignoring_shutdown = true;
                        continue;
                    }
                    send(&out, &Message::response(id, &json!({})));
                }
                _ => send(
                    &out,
                    &Message::error(Some(id), -32601, "the test plug-in has no such method"),
                ),
            },
            Message::Response {
                id: RequestId::String(id),
                result,
            } => {
                let mut emitted = emitted.lock().unwrap_or_else(|p| p.into_inner());
                emitted.insert(id, json!({"result": result}));
                if emitted.len() == emit_count {
                    write("emits.json", &json!(*emitted));
                }
            }
            Message::Error {
                id: Some(RequestId::String(id)),
                error,
            } => {
                let mut emitted = emitted.lock().unwrap_or_else(|p| p.into_inner());
                emitted.insert(
                    id,
                    json!({"error": {"code": error.code, "message": error.message}}),
                );
                if emitted.len() == emit_count {
                    write("emits.json", &json!(*emitted));
                }
            }
            _ => {}
        }
    }
    // stdin closed.
    if ignoring_shutdown {
        loop {
            std::thread::sleep(Duration::from_secs(60));
        }
    }
}

fn record_environment() {
    let env: BTreeMap<String, String> = std::env::vars().collect();
    let cwd = std::env::current_dir()
        .map(|dir| dir.display().to_string())
        .unwrap_or_default();
    write("env.json", &json!({"env": env, "cwd": cwd}));
}

/// Tries every read, list and write it is asked to, and writes what each gave.
fn run_probe(probe: &Value) {
    let paths = |key: &str| -> Vec<String> {
        probe
            .get(key)
            .and_then(Value::as_array)
            .map(|paths| {
                paths
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    };
    let outcome = |result: std::io::Result<String>| match result {
        Ok(what) => json!({"ok": true, "got": what}),
        Err(error) => json!({"ok": false, "error": error.to_string()}),
    };
    let mut results = serde_json::Map::new();
    for path in paths("read") {
        let result = std::fs::read_to_string(&path).map(|text| text.chars().take(200).collect());
        results.insert(format!("read {path}"), outcome(result));
    }
    for path in paths("list") {
        let result = std::fs::read_dir(&path).map(|entries| {
            let mut names: Vec<String> = entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names.join(",")
        });
        results.insert(format!("list {path}"), outcome(result));
    }
    for path in paths("write") {
        let result = std::fs::write(&path, "written by the test plug-in\n").map(|()| String::new());
        results.insert(format!("write {path}"), outcome(result));
    }
    for path in paths("connect") {
        let result = std::os::unix::net::UnixStream::connect(&path).map(|_| String::new());
        results.insert(format!("connect {path}"), outcome(result));
    }
    let commands: Vec<Vec<String>> = probe
        .get("run")
        .and_then(Value::as_array)
        .map(|commands| {
            commands
                .iter()
                .filter_map(Value::as_array)
                .map(|argv| {
                    argv.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .filter(|argv: &Vec<String>| !argv.is_empty())
                .collect()
        })
        .unwrap_or_default();
    for argv in commands {
        results.insert(format!("run {}", argv.join(" ")), run_command(&argv));
    }
    write("probe.json", &Value::Object(results));
}

/// Runs `argv` for at most five seconds: `ok` is whether it exited with 0, `got` what it
/// printed.
fn run_command(argv: &[String]) -> Value {
    let child = std::process::Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn();
    let mut child = match child {
        Ok(child) => child,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    let end_at = std::time::Instant::now() + Duration::from_secs(5);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if std::time::Instant::now() < end_at => {
                std::thread::sleep(Duration::from_millis(50));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let mut said = String::new();
    if let Some(mut out) = child.stdout.take() {
        let _ = std::io::Read::read_to_string(&mut out, &mut said);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = std::io::Read::read_to_string(&mut err, &mut said);
    }
    let said: String = said.chars().take(500).collect();
    match status {
        Some(status) => json!({"ok": status.success(), "got": said, "status": status.to_string()}),
        None => json!({"ok": false, "got": said, "error": "still running after 5 seconds"}),
    }
}

/// Starts a shell that appends a line to `beats` five times a second, for as long as it runs,
/// so a test can see that it ended with the plug-in (process ids inside a sandbox's own PID
/// namespace mean nothing outside it).
fn spawn_child() {
    if let Ok(child) = std::process::Command::new("/bin/sh")
        .args(["-c", "while true; do echo beat >> beats; sleep 0.2; done"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        let _ = std::fs::write("child.pid", child.id().to_string());
        std::mem::forget(child);
    }
}

/// Starts a process that leaves the plug-in's process group and session and is orphaned: Perl
/// forks, calls `setsid`, forks again and the session leader exits, so the last process's parent
/// is launchd (or the sandbox's PID namespace's first process). It writes `detached-<start>`
/// once it has, then appends a line to `detached-beats-<start>` five times a second, for as long
/// as it runs. Waits until that process is orphaned and beating before answering initialize,
/// so a deliberately failed start cannot kill it before the test has anything to observe.
fn spawn_detached(start: u64) {
    const DETACH: &str = r#"
use POSIX ();
my ($start) = @ARGV;
# Let the first parent exit well before this child is ready, exercising the startup race.
exit 0 if fork;
select(undef, undef, undef, 0.3);
my $sid = POSIX::setsid();
exit 0 if fork;
for (1 .. 50) { last if getppid() == 1; select(undef, undef, undef, 0.02); }
open(my $f, ">", "detached-$start.tmp") or exit 1;
print $f "sid=$sid pgrp=" . getpgrp() . " ppid=" . getppid() . "\n";
close $f;
rename("detached-$start.tmp", "detached-$start");
exec "/bin/sh", "-c", "while true; do echo beat >> detached-beats-$start; sleep 0.2; done";
"#;
    let _ = std::process::Command::new("/usr/bin/perl")
        .args(["-e", DETACH, &start.to_string()])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    // The first fork's parent exits before the detached child has necessarily run. Waiting
    // for that parent alone races afterReady's exit and the host's cleanup under load.
    let marker = format!("detached-{start}");
    let beats = format!("detached-beats-{start}");
    let deadline = std::time::Instant::now() + Duration::from_secs(4);
    while !std::path::Path::new(&marker).is_file()
        || !std::fs::metadata(&beats).is_ok_and(|m| m.len() > 0)
    {
        assert!(
            std::time::Instant::now() < deadline,
            "detached child did not become ready"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
