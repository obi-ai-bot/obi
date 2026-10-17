//! A review another Obi asked for hands its agent the request and the diff as files
//! (`.obi/inputs/obi-request.json`, the diff beside it): both have the owner's vault secrets taken
//! out before they're written (docs/runner-api.md, "obid only: the vault", "Agents"). Run in this
//! process, as tests/review_job.rs runs a review: the e2e fixture, the stub agent, the job sandbox.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use obid::config::Config;
use obid::events::Events;
use obid::jobs::{Jobs, ObiReview};
use obid::sandbox::Sandbox;
use serde_json::{Value, json};

struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path =
            std::env::temp_dir().join(format!("obid-vault-review-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Folder(path.canonicalize().unwrap())
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = Command::new("chmod")
            .args(["-R", "u+w"])
            .arg(&self.0)
            .status();
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn obi() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .unwrap()
}

/// The e2e fixture's bare remote (e2e/lib/fixture.mjs).
fn fixture(root: &Path) -> PathBuf {
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

fn brief() -> Value {
    let text = std::fs::read_to_string(obi().join("e2e/fixtures/messages/brief.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

/// A part of the request (its goal) and a line the fixture's diff adds (src/average.js): both
/// put in the vault as the owner's secrets, written as `obid vault` writes the file.
const IN_REQUEST: &str = "Add an average helper to the fixture app";
const IN_DIFF: &str = "for (const value of values) total += value;";

#[tokio::test(flavor = "multi_thread")]
async fn a_reviews_request_and_diff_reach_the_agent_without_the_vaults_secrets() {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let folder = Folder::new("inputs");
    let remote = fixture(&folder.0.join("fixture"));
    let home = folder.0.join("home");
    let config = Config::parse(
        &json!({
            "listen": "127.0.0.1:0",
            "home": home,
            "owner": "wellington",
            "agents": {"claude": {"bin": obi().join("e2e/stub-agent/stub-agent"),
                                  "accounts": [{"id": "stub", "name": "Stub", "configDir": home.join("accounts/stub")}]}},
            "repos": [{"repo": "obi-e2e/fixture-app", "remote": format!("file://{}", remote.display()),
                       "defaultBranch": "main", "check": null}],
            "allowFileRemotes": true,
            "telemetry": false
        })
        .to_string(),
    )
    .unwrap();
    obid::prepare_home(&config).unwrap();
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(home.join("vault"))
        .unwrap();
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(home.join("vault/secrets.json"))
        .unwrap();
    std::io::Write::write_all(
        &mut file,
        json!({"secrets": {"in-request": IN_REQUEST, "in-diff": IN_DIFF}})
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    obid::vault::install(&home, &obid::vault::Location::File);

    let jobs = Jobs::open(
        config,
        Events::new(),
        Sandbox::detect(Path::new(env!("CARGO_BIN_EXE_obid"))),
    )
    .unwrap();
    let job = jobs
        .start_obi_review(ObiReview {
            correlation_id: "5f0e8c1a-3b2d-4e6f-8a9b-0c1d2e3f4a5b".into(),
            request_id: "5f0e8c1a-3b2d-4e6f-8a9b-0c1d2e3f4a5b".into(),
            from: "obi-ernesto".into(),
            from_owner: "ernesto".into(),
            body: brief(),
        })
        .unwrap();
    tokio::time::timeout(Duration::from_secs(120), jobs.wait(&job.id))
        .await
        .unwrap()
        .unwrap();
    let inputs = home.join("worktrees").join(&job.id).join(".obi/inputs");
    let request = std::fs::read_to_string(inputs.join("obi-request.json")).unwrap();
    assert!(!request.contains(IN_REQUEST), "{request}");
    let quoted: Value = serde_json::from_str(&request).unwrap();
    assert_eq!(
        quoted["body"]["goal"],
        "[vault: in-request] (OBI-E2E-DATA-CANARY goal)"
    );
    let mut diffs = 0;
    for entry in std::fs::read_dir(&inputs).unwrap() {
        let path = entry.unwrap().path();
        let text = String::from_utf8_lossy(&std::fs::read(&path).unwrap()).into_owned();
        assert!(!text.contains(IN_DIFF), "{}: {text}", path.display());
        assert!(!text.contains(IN_REQUEST), "{}: {text}", path.display());
        if text.contains("[vault: in-diff]") {
            diffs += 1;
        }
    }
    assert_eq!(diffs, 1, "the diff holds the marker");
}
