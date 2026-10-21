//! A job that runs on a teammate's Mac (#797; docs/runner-api.md, "obid only: sharing this Mac"),
//! through two real obids and the fake Sphere (tests/support), with its job channel relayed there.
//! Wellington's obid hosts; Sangam's sends one of Sangam's jobs to it. The VM is a stand-in
//! (tests/agents/fake-obi-vm) that plays the guest over the same sockets the real image uses, and
//! the model's API is a stand-in that records the credential it was called with: Sangam's own
//! Claude Code login (a stand-in one), added by Sangam's obid, never seen on Wellington's side.

mod support;

use std::path::Path;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use support::*;

const HOST_SCOPES: &str = "send:review_request send:question send:run_request send:share_offer reply receive directory:read audit:read";
/// Sangam's Claude Code login's access token (a stand-in, in the account's `.credentials.json`).
const LOGIN: &str = "test-claude-login-access-token-for-obid-tests-7f3a9c";
/// Wellington's company key, which Sangam's jobs on Wellington's share run on.
const HOST_KEY: &str = "test-host-company-key-for-obid-tests-only-2b81d4";

/// The model's API, as the guest's obid calls it: answers every `POST /v1/messages`, keeping each
/// call's credential and betas.
async fn model_api() -> (String, Arc<Mutex<Vec<String>>>) {
    let keys = Arc::new(Mutex::new(Vec::new()));
    let seen = keys.clone();
    let app = axum::Router::new().route(
        "/v1/messages",
        axum::routing::post(move |headers: axum::http::HeaderMap, body: axum::Json<Value>| {
            let seen = seen.clone();
            async move {
                let header = |n: &str| headers.get(n).and_then(|v| v.to_str().ok()).unwrap_or("").to_owned();
                seen.lock().unwrap().push(format!("{} {} [{}]", header("authorization"), header("x-api-key"), header("anthropic-beta")));
                // An Opus call costs $1.20 at list price (300,000 tokens in at $4 a million).
                let model = body["model"].as_str().unwrap_or("fake").to_owned();
                let input = if model.starts_with("claude-opus") { 300_000 } else { 10 };
                axum::Json(json!({"id": "msg_1", "type": "message", "role": "assistant", "model": model,
                                  "content": [{"type": "text", "text": "Hello from the model"}],
                                  "stop_reason": "end_turn", "usage": {"input_tokens": input, "output_tokens": 4}}))
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (url, keys)
}

struct Pair {
    sphere: FakeSphere,
    host: Obid,
    guest: Obid,
    keys: Arc<Mutex<Vec<String>>>,
    vm: std::path::PathBuf,
}

/// Wellington's obid (sharing its Mac: `mac` over the defaults, turned on) and Sangam's, both
/// joined, Sangam's signed in to Claude Code (a stand-in login).
async fn pair(host_folder: &Folder, guest_folder: &Folder, mac: Value, scenario: Value) -> Pair {
    let sphere = FakeSphere::start().await;
    let (api, keys) = model_api().await;
    let fake_vm = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/agents/fake-obi-vm");
    let vm = host_folder.0.join("vm");
    std::fs::create_dir_all(&vm).unwrap();
    for f in ["vmlinuz", "initrd", "root.img"] {
        std::fs::write(vm.join(f), b"stand-in").unwrap();
    }
    std::fs::write(vm.join("fake.json"), scenario.to_string()).unwrap();

    let remote = fixture(&host_folder.0.join("fixture"));
    let mut host_config = config(&host_folder.0, &remote, &stub_agent());
    host_config["vmHelper"] = json!(fake_vm);
    host_config["vmImage"] = json!(vm);
    host_config["guestModelApi"] = json!(api);
    // Wellington's Claude Code account pays per token, as its tool once said.
    std::fs::create_dir_all(host_folder.0.join("home")).unwrap();
    std::fs::write(
        host_folder.0.join("home/usage.json"),
        json!({"stub": {"priced": "api"}}).to_string(),
    )
    .unwrap();
    let host = start(&host_folder.0, &host_config, None);
    vault_add(&host_folder.0, HOST_KEY);

    let remote = fixture(&guest_folder.0.join("fixture"));
    let mut guest_config = config(&guest_folder.0, &remote, &stub_agent());
    guest_config["owner"] = json!("sangam");
    guest_config["guestModelApi"] = json!(api);
    let account = guest_folder.0.join("home/accounts/stub");
    std::fs::create_dir_all(&account).unwrap();
    let ends = (obi_protocol::time::now() + 86_400) * 1000;
    std::fs::write(
        account.join(".credentials.json"),
        json!({"claudeAiOauth": {"accessToken": LOGIN, "refreshToken": "test-refresh-never-used", "expiresAt": ends,
                                  "scopes": ["user:inference"], "subscriptionType": "max"}})
        .to_string(),
    )
    .unwrap();
    let guest = start(&guest_folder.0, &guest_config, None);

    tokio::task::block_in_place(|| {
        join_as(
            &host,
            &sphere,
            &Owner::new("wellington"),
            "obi-wellington",
            &["review_request", "run_request"],
            HOST_SCOPES,
        );
        join_as(
            &guest,
            &sphere,
            &Owner::new("sangam"),
            "obi-sangam",
            &["review_request", "share_offer"],
            HOST_SCOPES,
        );
        let mut settings =
            call(&host, "GET", "/v1/obid/sharing/mac", None).body["settings"].clone();
        assert_eq!(settings["on"], false, "off by default");
        settings["on"] = json!(true);
        for (k, v) in mac.as_object().unwrap() {
            settings[k] = v.clone();
        }
        let set = call(&host, "PUT", "/v1/obid/sharing/mac", Some(&settings));
        assert_eq!(set.status, 200, "{}", set.text);
        assert_eq!(set.body["ready"], true);
    });
    Pair {
        sphere,
        host,
        guest,
        keys,
        vm,
    }
}

/// Puts `key` in the obid's vault as the key of its account `stub`'s share.
fn vault_add(folder: &Path, key: &str) {
    let mut add = std::process::Command::new(OBID)
        .args(["vault", "--config"])
        .arg(folder.join("config.json"))
        .args(["add", "anthropic-api-key.stub"])
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    std::io::Write::write_all(add.stdin.as_mut().unwrap(), key.as_bytes()).unwrap();
    drop(add.stdin.take());
    assert!(add.wait().unwrap().success());
}

fn get(obid: &Obid, target: &str) -> Value {
    let answer = call(obid, "GET", target, None);
    assert_eq!(answer.status, 200, "GET {target}: {}", answer.text);
    answer.body
}

/// Sangam's job, on Wellington's Mac.
fn send_job(guest: &Obid) -> String {
    let made = call(
        guest,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "build", "task": "Say hello in guest.txt",
                              "title": "Say hello", "runsOn": "obi-wellington"}}),
        ),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    assert_eq!(
        made.body["runsOn"],
        json!({"obi": "obi-wellington", "owner": "wellington"})
    );
    made.body["id"].as_str().unwrap().to_owned()
}

/// Every file under `dir` that holds `needle`.
fn holding(dir: &Path, needle: &str) -> Vec<String> {
    let mut found = Vec::new();
    for entry in walk(dir) {
        if std::fs::read(&entry)
            .is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle.as_bytes()))
        {
            found.push(entry.display().to_string());
        }
    }
    found
}

fn walk(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() && !path.is_symlink() {
            out.extend(walk(&path));
        } else if path.is_file() {
            out.push(path);
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_job_runs_on_a_teammates_mac_with_the_owners_own_key_and_comes_back_with_its_commit() {
    let (hf, gf) = (Folder::new("share-host"), Folder::new("share-guest"));
    let p = pair(&hf, &gf, json!({"who": "everyone"}), json!({})).await;
    let job = tokio::task::block_in_place(|| {
        // Wellington's Mac shows as free to Sangam, never whether Wellington is at it.
        let macs = within(40, "Wellington's Mac in the list", || {
            let macs = get(&p.guest, "/v1/obid/sharing/macs");
            macs.as_array().filter(|m| !m.is_empty()).cloned()
        });
        assert_eq!(macs[0]["obi"], "obi-wellington");
        assert_eq!(macs[0]["free"], true);
        send_job(&p.guest)
    });
    let done = tokio::task::block_in_place(|| {
        within(90, "the job done", || {
            let j = get(&p.guest, &format!("/v1/jobs/{job}"));
            (j["status"] == "done" || j["status"] == "failed" || j["status"] == "interrupted")
                .then_some(j)
        })
    });
    assert_eq!(done["status"], "done", "{done}\n{}", p.guest.log());
    assert_eq!(done["commits"], 1);
    // The model was called from Sangam's Mac with Sangam's key, and only from there.
    // From Sangam's Mac, with Sangam's own login and its beta; the VM's placeholder dropped.
    assert_eq!(
        *p.keys.lock().unwrap(),
        vec![format!("Bearer {LOGIN}  [oauth-2025-04-20]")]
    );
    let seen = std::fs::read_to_string(p.vm.join("guest.log")).unwrap();
    assert!(seen.contains("cpus 4 memory 8192"), "{seen}");
    // The disk key came once, on its own socket, and isn't on the job's.
    assert!(seen.contains("key 64"), "{seen}");
    assert!(seen.contains("key-again refused"), "{seen}");
    assert!(seen.contains("key-on-control 404"), "{seen}");
    assert!(seen.contains("max-seconds 7380"), "{seen}");
    assert!(seen.contains("refused 403"), "{seen}");
    assert!(seen.contains("model 200 Hello from the model"), "{seen}");
    assert!(seen.contains("job Say hello on"), "{seen}");
    // The job's words reached its agent on the channel, and never the chain (#810).
    assert!(
        seen.contains("words ") && seen.contains("Say hello in guest.txt"),
        "{seen}"
    );
    // Only the job's code went, as one commit with no parent: none of the repository's history.
    assert!(
        seen.contains(r#"base "The job's code" parents "" commits 1"#),
        "{seen}"
    );
    // The key is nowhere on Wellington's side, and the relay saw only sealed frames.
    assert!(
        holding(&hf.0, LOGIN).is_empty(),
        "{:?}",
        holding(&hf.0, LOGIN)
    );
    // Only the access token is ever used, and only from Sangam's Mac: never the refresh token.
    assert!(holding(&hf.0, "test-refresh-never-used").is_empty());
    let relayed = p.sphere.lock().relayed.clone();
    assert!(!relayed.is_empty());
    for clear in [LOGIN.as_bytes(), b"Hello from the model", b"guest.txt"] {
        assert!(
            !relayed.windows(clear.len()).any(|w| w == clear),
            "the relay saw {:?}",
            String::from_utf8_lossy(clear)
        );
    }
    // The exchange: request, accept, progress, result with what the job used of the Mac.
    let recorded = p.sphere.recorded();
    let types: Vec<&str> = recorded
        .iter()
        .map(|e| e["type"].as_str().unwrap())
        .collect();
    assert_eq!(types.first(), Some(&"run_request"));
    assert!(types.contains(&"accept"), "{types:?}");
    // Only a pause or a resume is a run_progress; the job's words are in no entry (#810).
    assert!(
        recorded
            .iter()
            .filter(|e| e["type"] == "run_progress")
            .all(|e| e["body"]["state"] == "paused" || e["body"]["state"] == "resumed")
    );
    assert!(recorded[0]["body"].get("request").is_none());
    assert!(
        !serde_json::to_string(&recorded)
            .unwrap()
            .contains("in guest.txt"),
        "the job's words are in the chain"
    );
    let result = recorded
        .iter()
        .find(|e| e["type"] == "result")
        .expect("a result");
    assert_eq!(result["body"]["for"], "run_request");
    assert_eq!(result["body"]["host"]["cpu_seconds"], 3);
    assert_eq!(result["body"]["host"]["peak_memory_mb"], 42);
    // Wellington's obid keeps its own log of the host's use, and nothing of the job's.
    let log = std::fs::read_to_string(hf.0.join("home/sharing-log.jsonl")).unwrap();
    assert!(log.contains("\"fromOwner\":\"sangam\""), "{log}");
    tokio::task::block_in_place(|| {
        assert_eq!(get(&p.host, "/v1/obid/sharing/mac")["week"]["jobs"], 1);
        // Each side checks the chain and finds its own entries in it, as metadata only.
        for (obid, me) in [(&p.guest, "obi-sangam"), (&p.host, "obi-wellington")] {
            let audit = get(obid, "/v1/obid/sphere/audit");
            assert_eq!(audit["verified"], true, "{audit}");
            let entries = audit["entries"].as_array().unwrap();
            assert!(entries.iter().all(|e| e["from"] == me || e["to"] == me));
            let result = entries
                .iter()
                .find(|e| e["type"] == "result")
                .expect("the result");
            assert_eq!(result["host"]["cpu_seconds"], 3);
            assert!(
                entries
                    .iter()
                    .any(|e| e["type"] == "run_request" && e["repo"] == "obi-e2e/fixture-app")
            );
            assert!(!audit.to_string().contains("Say hello"), "{audit}");
        }
    });
    // Its folder goes once the host has sent its reply and let the channel go.
    tokio::task::block_in_place(|| {
        within(20, "the job's folder gone", || {
            (!hf.0
                .join("home/g")
                .read_dir()
                .is_ok_and(|mut d| d.next().is_some()))
            .then_some(())
        })
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_teammates_first_job_waits_for_the_owners_allow_and_from_now_on_isnt_asked_again() {
    let (hf, gf) = (
        Folder::new("share-ask-host"),
        Folder::new("share-ask-guest"),
    );
    let p = pair(&hf, &gf, json!({}), json!({})).await;
    tokio::task::block_in_place(|| {
        within(40, "Wellington's Mac in the list", || {
            get(&p.guest, "/v1/obid/sharing/macs")
                .as_array()
                .filter(|m| !m.is_empty())
                .cloned()
        });
        let first = send_job(&p.guest);
        let item = within(30, "the ask in Wellington's inbox", || {
            get(&p.host, "/v1/inbox")
                .as_array()
                .unwrap()
                .iter()
                .find(|i| i["obi"]["type"] == "run_request")
                .cloned()
        });
        assert_eq!(
            item["title"],
            "Sangam asks to use this Mac while you're away"
        );
        assert_eq!(
            item["options"],
            json!(["Allow", "Allow Sangam from now on", "Decline"])
        );
        assert_eq!(item["obi"]["quoted"]["title"], "Say hello");
        let answered = call(
            &p.host,
            "POST",
            &format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap()),
            Some(&json!({"answer": "Allow Sangam from now on"})),
        );
        assert_eq!(answered.status, 200, "{}", answered.text);
        let job = within(90, "the first job done", || {
            let j = get(&p.guest, &format!("/v1/jobs/{first}"));
            (j["status"] != "running" && j["status"] != "queued").then_some(j)
        });
        assert_eq!(job["status"], "done", "{job}");
        assert_eq!(
            get(&p.host, "/v1/obid/sharing/mac")["settings"]["allowed"],
            json!(["sangam"])
        );
        // The second job runs without asking.
        let second = send_job(&p.guest);
        let job = within(90, "the second job done", || {
            let j = get(&p.guest, &format!("/v1/jobs/{second}"));
            (j["status"] != "running" && j["status"] != "queued").then_some(j)
        });
        assert_eq!(job["status"], "done", "{job}");
        let asks = get(&p.host, "/v1/inbox?done=true")
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["obi"]["type"] == "run_request")
            .count();
        assert!(asks <= 1);
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stop_sends_the_job_back_with_its_commit_and_it_needs_its_owner() {
    let (hf, gf) = (
        Folder::new("share-stop-host"),
        Folder::new("share-stop-guest"),
    );
    let p = pair(
        &hf,
        &gf,
        json!({"who": "everyone"}),
        json!({"mode": "wait"}),
    )
    .await;
    tokio::task::block_in_place(|| {
        within(40, "Wellington's Mac in the list", || {
            get(&p.guest, "/v1/obid/sharing/macs")
                .as_array()
                .filter(|m| !m.is_empty())
                .cloned()
        });
        let job = send_job(&p.guest);
        let running = within(60, "the job running on Wellington's Mac", || {
            let mac = get(&p.host, "/v1/obid/sharing/mac");
            mac["jobs"]
                .as_array()
                .filter(|j| j.iter().any(|j| j["state"] == "running"))
                .cloned()
        });
        assert_eq!(running[0]["fromOwner"], "sangam");
        assert_eq!(running[0]["title"], "Say hello");
        let stopped = call(
            &p.host,
            "POST",
            "/v1/obid/sharing/mac/stop",
            Some(&json!({})),
        );
        assert_eq!(stopped.body["stopped"], 1);
        let job = within(90, "the job back", || {
            let j = get(&p.guest, &format!("/v1/jobs/{job}"));
            (j["status"] == "interrupted" || j["status"] == "failed" || j["status"] == "done")
                .then_some(j)
        });
        assert_eq!(job["status"], "interrupted", "{job}");
        let reason = job["reason"].as_str().unwrap_or("");
        assert!(
            reason
                .starts_with("Came back from Wellington's Mac: that Mac couldn't keep running it."),
            "{reason}"
        );
        // The chain says only that the host was unavailable: not that Wellington stopped it, nor
        // how long it ran.
        let back: Vec<Value> = p
            .sphere
            .recorded()
            .into_iter()
            .filter(|e| e["type"] == "run_return")
            .collect();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0]["body"]["reason"], "host_unavailable", "{}", back[0]);
        assert!(back[0]["body"].get("minutes").is_none(), "{}", back[0]);
        assert!(reason.contains("1 commit"), "{reason}");
        let seen = std::fs::read_to_string(p.vm.join("guest.log")).unwrap();
        assert!(seen.contains("return stopped"), "{seen}");
        // Run it here: the job that came back moves to this Mac, its commit kept.
        let id = job["id"].as_str().unwrap();
        let here = call(
            &p.guest,
            "PATCH",
            &format!("/v1/jobs/{id}"),
            Some(&json!({"runsOn": null})),
        );
        assert_eq!(here.status, 200, "{}", here.text);
        assert_eq!(here.body["runsOn"], Value::Null);
        assert!(
            here.body["changes"]
                .to_string()
                .contains("Moved to this Mac by you"),
            "{}",
            here.body["changes"]
        );
        let nowhere = call(
            &p.guest,
            "PATCH",
            &format!("/v1/jobs/{id}"),
            Some(&json!({"runsOn": "obi-nobody"})),
        );
        assert_eq!(nowhere.status, 422);
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_sharing_off_or_the_mac_busy_a_job_is_declined_with_the_reason() {
    let (hf, gf) = (
        Folder::new("share-off-host"),
        Folder::new("share-off-guest"),
    );
    let p = pair(&hf, &gf, json!({"who": "everyone"}), json!({})).await;
    tokio::task::block_in_place(|| {
        within(40, "Wellington's Mac in the list", || {
            get(&p.guest, "/v1/obid/sharing/macs")
                .as_array()
                .filter(|m| !m.is_empty())
                .cloned()
        });
        // The owner is at the Mac: not free.
        std::fs::write(
            hf.0.join("env-home/fake-signals.json"),
            json!({"idleSeconds": 3, "onAC": true, "lowPower": false, "thermal": "nominal"})
                .to_string(),
        )
        .unwrap();
        let job = send_job(&p.guest);
        let declined = within(60, "the job declined", || {
            let j = get(&p.guest, &format!("/v1/jobs/{job}"));
            (j["status"] == "interrupted").then_some(j)
        });
        assert_eq!(
            declined["reason"],
            "Wellington's Mac isn't free now. Try again later, or run it here."
        );
        // Sharing off: policy.
        let mut settings = get(&p.host, "/v1/obid/sharing/mac")["settings"].clone();
        settings["on"] = json!(false);
        assert_eq!(
            call(&p.host, "PUT", "/v1/obid/sharing/mac", Some(&settings)).status,
            200
        );
        let job = send_job(&p.guest);
        let declined = within(60, "the job declined", || {
            let j = get(&p.guest, &format!("/v1/jobs/{job}"));
            (j["status"] == "interrupted").then_some(j)
        });
        assert_eq!(
            declined["reason"],
            "Wellington's Mac doesn't take your jobs. Run it here instead."
        );
        let reasons: Vec<Value> = p
            .sphere
            .recorded()
            .iter()
            .filter(|e| e["type"] == "decline")
            .map(|e| e["body"]["reason"].clone())
            .collect();
        assert_eq!(reasons, vec![json!("not_free"), json!("policy")]);

        // A secret already in the repository, not one the job adds: the whole tree that would go
        // is scanned, so nothing goes.
        let token: String = format!("ghp_{}", uuid::Uuid::new_v4().simple())
            .chars()
            .take(40)
            .collect();
        let token = format!("{token}{}", "Q7".repeat(2));
        let work = gf.0.join("secret-work");
        let git = |args: &[&str]| {
            let out = std::process::Command::new("git")
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .current_dir(&gf.0)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
        };
        let remote = gf.0.join("fixture/remote.git");
        git(&[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            work.to_str().unwrap(),
        ]);
        std::fs::write(work.join("deploy.env"), format!("GITHUB_TOKEN={token}\n")).unwrap();
        let w = work.to_str().unwrap();
        git(&["-C", w, "add", "-A"]);
        git(&["-C", w, "commit", "-q", "-m", "Deploy settings"]);
        git(&["-C", w, "push", "-q", "origin", "HEAD:main"]);
        let sent_before = p
            .sphere
            .recorded()
            .iter()
            .filter(|e| e["type"] == "run_request")
            .count();
        let job = send_job(&p.guest);
        let refused = within(60, "the job refused", || {
            let j = get(&p.guest, &format!("/v1/jobs/{job}"));
            (j["status"] == "failed" || j["status"] == "interrupted").then_some(j)
        });
        assert!(
            refused
                .to_string()
                .contains("The secret scan found a possible secret"),
            "{refused}"
        );
        assert!(!refused.to_string().contains(&token));
        let sent_after = p
            .sphere
            .recorded()
            .iter()
            .filter(|e| e["type"] == "run_request")
            .count();
        assert_eq!(sent_before, sent_after, "nothing went to Wellington's Mac");
    });
}

/// Sangam's job on Wellington's share of an API account (#809).
fn send_on_share(guest: &Obid, grant: &str) -> String {
    let made = call(
        guest,
        "POST",
        "/v1/jobs",
        Some(
            &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "build", "task": "Say hello in guest.txt", "title": "Say hello",
                             "model": "claude-opus-5-5", "runsOn": {"obi": "obi-wellington", "grant": grant}}}),
        ),
    );
    assert_eq!(made.status, 201, "{}", made.text);
    assert_eq!(made.body["runsOn"]["grant"], grant);
    made.body["id"].as_str().unwrap().to_owned()
}

fn ended(guest: &Obid, job: &str) -> Value {
    within(90, "the job to end", || {
        let j = get(guest, &format!("/v1/jobs/{job}"));
        (j["status"] != "running" && j["status"] != "queued").then_some(j)
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_share_of_an_api_account_runs_on_its_mac_with_its_key_metered_until_used_then_revoked() {
    let (hf, gf) = (
        Folder::new("share-api-host"),
        Folder::new("share-api-guest"),
    );
    let p = pair(&hf, &gf, json!({"who": "people", "people": []}), json!({})).await;
    tokio::task::block_in_place(|| {
        // Only the account that pays per token can be shared; the key is in Wellington's vault.
        let sharing = get(&p.host, "/v1/obid/sharing/grants");
        assert_eq!(sharing["key"], true);
        assert!(sharing["grants"].as_array().unwrap().is_empty());
        assert_eq!(sharing["accounts"][0]["plan"], "api", "{sharing}");
        let refused = call(
            &p.host,
            "PUT",
            "/v1/obid/sharing/grants",
            Some(
                &json!({"account": "nobody", "who": "sangam", "share": 10, "budgetCents": 1000, "resetsDay": 1}),
            ),
        );
        assert_eq!(refused.status, 422);
        // 10% of a $10 month for Sangam: $1.
        let put = call(
            &p.host,
            "PUT",
            "/v1/obid/sharing/grants",
            Some(
                &json!({"account": "stub", "who": "sangam", "share": 10, "budgetCents": 1000, "resetsDay": 1}),
            ),
        );
        assert_eq!(put.status, 200, "{}", put.text);
        assert_eq!(put.body["limitCents"], 100);
        // Each share's key is its account's own in the vault.
        assert_eq!(put.body["keyName"], "anthropic-api-key.stub");
        let listed = get(&p.host, "/v1/obid/sharing/grants");
        assert_eq!(listed["grants"][0]["keyInVault"], true, "{listed}");
        let grant = put.body["id"].as_str().unwrap().to_owned();
        let shared = within(40, "the share on Sangam's Oby", || {
            let s = get(&p.guest, "/v1/obid/sharing/shared");
            s["shares"].as_array().filter(|s| !s.is_empty()).cloned()
        });
        assert_eq!(shared[0]["grant"], grant.as_str());
        assert_eq!(shared[0]["account"], "Stub");
        assert_eq!(
            (shared[0]["share"].clone(), shared[0]["limitCents"].clone()),
            (json!(10), json!(100))
        );

        // The first job runs there, on Wellington's key, though Wellington's Mac is offered to
        // nobody: the share is the yes. Its one call costs $1.20: the call finishes, and the share
        // is used.
        let first = ended(&p.guest, &send_on_share(&p.guest, &grant));
        let reason = first["reason"].as_str().unwrap_or("");
        assert!(
            first["status"] == "done"
                || reason.contains("your share of Wellington's account is used"),
            "{first}\n{}",
            p.guest.log()
        );
        assert_eq!(first["commits"], 1, "{first}");
        assert_eq!(*p.keys.lock().unwrap(), vec![format!(" {HOST_KEY} []")]);
        let seen = std::fs::read_to_string(p.vm.join("guest.log")).unwrap();
        assert!(seen.contains("model 200 Hello from the model"), "{seen}");
        // The job's cost is in the chain with its end (#810).
        assert!(p.sphere.recorded().iter().any(|e| matches!(
            e["type"].as_str(),
            Some("result" | "run_return")
        ) && e["body"]["cost_cents"] == 121));
        // Both meters say $1.21 ($1.20008, rounded up).
        let grants = get(&p.host, "/v1/obid/sharing/grants");
        assert_eq!(grants["grants"][0]["usedCents"]["sangam"], 121, "{grants}");
        within(40, "Sangam's meter", || {
            let s = get(&p.guest, "/v1/obid/sharing/shared");
            (s["shares"][0]["usedCents"] == 121).then_some(())
        });
        // Wellington hears it, and the next job isn't taken.
        let item = within(20, "the share-used card", || {
            get(&p.host, "/v1/inbox")
                .as_array()
                .unwrap()
                .iter()
                .find(|i| i["obi"]["type"] == "share_used")
                .cloned()
        });
        assert_eq!(item["title"], "Sangam used the share of Stub");
        assert_eq!(
            item["options"],
            json!(["Share 20% more this month", "Leave it"])
        );
        let second = ended(&p.guest, &send_on_share(&p.guest, &grant));
        assert_eq!(second["status"], "interrupted");
        assert_eq!(
            second["reason"],
            "Your share of Wellington's account is used for this month. Run it on your own account instead."
        );
        assert_eq!(p.keys.lock().unwrap().len(), 1, "no call was made for it");

        // 20% more this month: $3, $1.80 left, and the next job runs.
        let more = call(
            &p.host,
            "POST",
            &format!("/v1/inbox/{}/answer", item["id"].as_str().unwrap()),
            Some(&json!({"answer": "Share 20% more this month"})),
        );
        assert_eq!(more.status, 200, "{}", more.text);
        within(40, "the larger share on Sangam's Oby", || {
            let s = get(&p.guest, "/v1/obid/sharing/shared");
            (s["shares"][0]["limitCents"] == 300).then_some(())
        });
        let third = ended(&p.guest, &send_on_share(&p.guest, &grant));
        assert_eq!(third["status"], "done", "{third}");

        // The key is nowhere on Sangam's side or in the VM's folder, and the relay saw no clear text.
        assert!(
            holding(&gf.0, HOST_KEY).is_empty(),
            "{:?}",
            holding(&gf.0, HOST_KEY)
        );
        assert!(holding(&p.vm, HOST_KEY).is_empty());
        let relayed = p.sphere.lock().relayed.clone();
        assert!(
            !relayed
                .windows(HOST_KEY.len())
                .any(|w| w == HOST_KEY.as_bytes())
        );
        let recorded = p.sphere.recorded();
        assert!(recorded.iter().all(|e| !e.to_string().contains(HOST_KEY)));
        let types: Vec<&str> = recorded
            .iter()
            .map(|e| e["type"].as_str().unwrap())
            .collect();
        assert!(
            types.contains(&"share_offer") && types.contains(&"share_status"),
            "{types:?}"
        );
        assert!(
            recorded
                .iter()
                .any(|e| e["type"] == "run_request"
                    && e["body"]["account"]["grant"] == grant.as_str())
        );
        assert!(
            recorded
                .iter()
                .any(|e| e["type"] == "decline" && e["body"]["reason"] == "share_used")
        );

        // Taken back: Sangam's Oby stops showing it, and no job can be placed on it.
        assert_eq!(
            call(
                &p.host,
                "DELETE",
                &format!("/v1/obid/sharing/grants/{grant}"),
                None
            )
            .status,
            204
        );
        within(40, "the share gone from Sangam's Oby", || {
            let s = get(&p.guest, "/v1/obid/sharing/shared");
            s["shares"].as_array().filter(|s| s.is_empty()).map(|_| ())
        });
        assert!(
            p.sphere
                .recorded()
                .iter()
                .any(|e| e["type"] == "share_revoke")
        );
        let refused = call(
            &p.guest,
            "POST",
            "/v1/jobs",
            Some(
                &json!({"job": {"repo": "obi-e2e/fixture-app", "kind": "build", "task": "x", "title": "x",
                                                "runsOn": {"obi": "obi-wellington", "grant": grant}}}),
            ),
        );
        assert_eq!(refused.status, 422, "{}", refused.text);
    });
}
