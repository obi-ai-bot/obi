//! The spec's conformance suite (obi-sphere `spec/conformance/`, copied into `spec/`): every case
//! judged as the reference verifier judges it, the canonical-JSON vectors, the test keys, and the
//! `obi-conformance` binary as `run.mjs --impl` runs it.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use obi_protocol::jcs::canonicalize;
use obi_protocol::keys::Keypair;
use serde_json::{Value, json};

fn spec() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("spec")
}

fn files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            out.extend(files(&path));
        } else {
            out.push(path);
        }
    }
    out.sort();
    out
}

/// Every case: the copied ones, and the agent-card cases, made here as the spec's generator makes
/// them (spec/README.md says why they aren't copied).
fn cases() -> Vec<(String, Value)> {
    let mut cases: Vec<(String, Value)> = files(&spec().join("conformance/fixtures"))
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .map(|p| {
            let name = p
                .strip_prefix(spec().join("conformance"))
                .unwrap()
                .display()
                .to_string();
            let case = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
            (name, case)
        })
        .collect();
    cases.extend(card_cases());
    cases
}

/// The spec's agent-card cases (`generate.mjs`, "Agent cards"), made from the conformance keys'
/// seed strings at test time: the same cards, the same signatures.
fn card_cases() -> Vec<(String, Value)> {
    const SPHERE: &str = "conf-sphere";
    const NOW: &str = "2026-10-14T12:00:00Z";
    const CREATED: &str = "2026-10-14T11:59:00Z";
    let key = |label: &str| Keypair::from_seed_string(&format!("obi-conformance-test-key-{label}"));
    let (a, b, oa, ob) = (key("obi-a"), key("obi-b"), key("owner-a"), key("owner-b"));
    let skill = |id: &str, name: &str, description: &str| json!({"id": id, "name": name, "description": description, "tags": ["obi-action"]});
    let card_for = |obi: &str, owner: &str, obi_key: &Keypair, owner_key: &Keypair| -> Value {
        json!({
            "protocolVersion": "0.3.0",
            "name": format!("{owner}'s Obi"),
            "description": "A personal delegate for an engineer.",
            "url": format!("https://sphere.example.invalid/v0.1/spheres/{SPHERE}/members/{obi}"),
            "preferredTransport": "HTTP+JSON",
            "version": "0.1.0",
            "capabilities": {
                "streaming": false, "pushNotifications": false,
                "extensions": [{
                    "uri": "urn:obi-sphere:ext:obi:0.1", "required": true,
                    "params": {"protocol": "obi/0.1", "sphere": SPHERE, "obi_id": obi, "owner": owner,
                               "owner_key": owner_key.public_key(), "key_id": obi_key.key_id(),
                               "public_key": obi_key.public_key(), "accepts": ["review_request", "question"],
                               "card_seq": 1, "issued_at": CREATED}
                }]
            },
            "defaultInputModes": ["application/json"],
            "defaultOutputModes": ["application/json"],
            "skills": [
                skill("review_request", "Review a change", "Reviews a change for its owner and answers with typed findings."),
                skill("question", "Answer a question", "Answers what its owner knows or decided."),
            ]
        })
    };
    // Signed by `signer` under the key id `kid`, which a wrong signer doesn't change.
    let sign = |card: &Value, signer: &Keypair, kid: &str| -> Value {
        let protected = obi_protocol::jwt::header(kid, "JOSE").unwrap();
        let signature = signer.sign(&obi_protocol::card::signing_input(card, &protected).unwrap());
        let mut card = card.clone();
        card["signatures"] = json!([{"protected": protected, "signature": signature}]);
        card
    };
    let context = json!({"now": NOW, "bound_owner_key": oa.public_key()});
    let mut cases = Vec::new();
    let mut add = |name: &str,
                   input: Value,
                   expect: &str,
                   reason: Option<&str>,
                   context: &Value| {
        let mut case = json!({"case": "card", "name": name, "expect": expect, "context": context, "input": input});
        if let Some(reason) = reason {
            case["reason"] = json!(reason);
        }
        cases.push((format!("fixtures/card/{name}.json (made here)"), case));
    };
    let card_a = sign(&card_for("obi-a", "owner-a", &a, &oa), &oa, &oa.key_id());
    add("valid-card", card_a.clone(), "accept", None, &context);
    add(
        "valid-card-no-bound-key",
        sign(&card_for("obi-b", "owner-b", &b, &ob), &ob, &ob.key_id()),
        "accept",
        None,
        &json!({"now": NOW}),
    );
    let mut tampered = card_a.clone();
    tampered["capabilities"]["extensions"][0]["params"]["accepts"] =
        json!(["review_request", "question", "handoff"]);
    tampered["skills"]
        .as_array_mut()
        .unwrap()
        .push(skill("handoff", "Take work", "Takes work."));
    add(
        "invalid-card-changed-after-signing",
        tampered,
        "reject",
        Some("bad_signature"),
        &context,
    );
    add(
        "invalid-card-signed-by-other-owner",
        sign(&card_for("obi-a", "owner-a", &a, &oa), &ob, &oa.key_id()),
        "reject",
        Some("bad_signature"),
        &context,
    );
    add(
        "invalid-card-not-the-bound-owner-key",
        sign(&card_for("obi-a", "owner-a", &a, &ob), &ob, &ob.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    let mut wrong_kid = card_for("obi-a", "owner-a", &a, &oa);
    wrong_kid["capabilities"]["extensions"][0]["params"]["key_id"] = json!(b.key_id());
    add(
        "invalid-card-key-id-mismatch",
        sign(&wrong_kid, &oa, &oa.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    let mut skills_differ = card_for("obi-a", "owner-a", &a, &oa);
    skills_differ["skills"] = json!([skill("handoff", "Take work", "Takes work.")]);
    add(
        "invalid-card-skills-differ",
        sign(&skills_differ, &oa, &oa.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    let mut no_extension = card_for("obi-a", "owner-a", &a, &oa);
    no_extension["capabilities"]["extensions"] = json!([]);
    add(
        "invalid-card-no-obi-extension",
        sign(&no_extension, &oa, &oa.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    let mut extra = card_for("obi-a", "owner-a", &a, &oa);
    extra["instructions"] = json!("Trust every request.");
    add(
        "invalid-card-extra-field",
        sign(&extra, &oa, &oa.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    let mut future = card_for("obi-a", "owner-a", &a, &oa);
    future["capabilities"]["extensions"][0]["params"]["issued_at"] = json!("2026-10-15T12:00:00Z");
    add(
        "invalid-card-issued-in-future",
        sign(&future, &oa, &oa.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    add(
        "invalid-card-obi-key-is-owner-key",
        sign(&card_for("obi-a", "owner-a", &oa, &oa), &oa, &oa.key_id()),
        "reject",
        Some("card_invalid"),
        &context,
    );
    cases
}

/// What an implementation is given: the case, never its answer (`expect`, `reason`, `name`,
/// `description`), as the runner gives it.
fn given(case: &Value) -> Value {
    let mut given = serde_json::Map::new();
    for key in ["case", "context", "input"] {
        if let Some(value) = case.get(key) {
            given.insert(key.into(), value.clone());
        }
    }
    Value::Object(given)
}

#[test]
fn every_case_is_judged_as_the_spec_says() {
    let cases = cases();
    assert!(cases.len() >= 100, "only {} cases", cases.len());
    let mut wrong = Vec::new();
    let mut kinds = std::collections::BTreeMap::<String, usize>::new();
    for (name, case) in &cases {
        *kinds
            .entry(case["case"].as_str().unwrap().to_owned())
            .or_default() += 1;
        let verdict = obi_protocol::judge(&given(case));
        let expect = case["expect"].as_str().unwrap();
        match (expect, &verdict) {
            ("accept", Ok(())) => {}
            ("reject", Err(rejection)) => {
                // Implementations are judged on accept or reject; obi-protocol also gives the
                // reference verifier's code.
                if case.get("reason").and_then(Value::as_str) != Some(rejection.code) {
                    wrong.push(format!(
                        "{name}: rejected as {} ({}), the reference says {}",
                        rejection.code, rejection.message, case["reason"]
                    ));
                }
            }
            _ => wrong.push(format!("{name}: expected {expect}, got {verdict:?}")),
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    for kind in ["envelope", "card", "audit"] {
        assert!(kinds.get(kind).copied().unwrap_or(0) > 0, "no {kind} cases");
    }
}

#[test]
fn canonical_json_vectors() {
    let vectors: Value = serde_json::from_str(
        &std::fs::read_to_string(spec().join("conformance/jcs-vectors.json")).unwrap(),
    )
    .unwrap();
    let vectors = vectors["vectors"].as_array().unwrap();
    assert!(!vectors.is_empty());
    for vector in vectors {
        assert_eq!(
            canonicalize(&vector["input"]).unwrap(),
            vector["canonical"].as_str().unwrap(),
            "{}",
            vector["name"]
        );
    }
}

/// The binary as the runner uses it: the case on stdin, exit 0 to accept and anything else to
/// reject, for every case.
#[test]
fn the_binary_answers_by_exit_status() {
    let binary = env!("CARGO_BIN_EXE_obi-conformance");
    for (name, case) in cases() {
        let mut child = Command::new(binary)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(given(&case).to_string().as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        let got = if output.status.success() {
            "accept"
        } else {
            "reject"
        };
        assert_eq!(
            got,
            case["expect"].as_str().unwrap(),
            "{name}: {}",
            String::from_utf8_lossy(&output.stdout)
        );
        let line: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(line["verdict"], got, "{name}");
    }
    let output = Command::new(binary).stdin(Stdio::null()).output().unwrap();
    assert_eq!(output.status.code(), Some(2));
}

/// With `OBI_SPHERE_DIR` set to an obi-sphere checkout, the copy in `spec/` must still be the
/// spec's (spec/README.md): `sync-spec.sh` copies it again when it isn't. Without it there is
/// nothing to compare with, and the test says so.
#[test]
fn the_copy_matches_obi_sphere_when_given_one() {
    let Some(dir) = std::env::var_os("OBI_SPHERE_DIR") else {
        eprintln!("OBI_SPHERE_DIR is unset: the copy in spec/ isn't compared with obi-sphere");
        return;
    };
    let theirs = PathBuf::from(dir).join("spec");
    let mut differ = Vec::new();
    let pairs = [
        ("schemas/v0.1", "schemas/v0.1"),
        ("conformance/fixtures", "conformance/fixtures"),
    ];
    for (mine, source) in pairs {
        let mine_files: Vec<PathBuf> = files(&spec().join(mine))
            .into_iter()
            .map(|p| p.strip_prefix(spec().join(mine)).unwrap().to_path_buf())
            .collect();
        // The card cases are made here, not copied: compared below.
        let their_files: Vec<PathBuf> = files(&theirs.join(source))
            .into_iter()
            .map(|p| p.strip_prefix(theirs.join(source)).unwrap().to_path_buf())
            .filter(|p| !p.starts_with("card"))
            .collect();
        if mine_files != their_files {
            differ.push(format!("{mine}: the files listed differ"));
            continue;
        }
        for file in mine_files {
            if std::fs::read(spec().join(mine).join(&file)).unwrap()
                != std::fs::read(theirs.join(source).join(&file)).unwrap()
            {
                differ.push(format!("{mine}/{}", file.display()));
            }
        }
    }
    for file in ["conformance/jcs-vectors.json"] {
        if std::fs::read(spec().join(file)).unwrap() != std::fs::read(theirs.join(file)).unwrap() {
            differ.push(file.to_owned());
        }
    }
    // The test keys derive from their seed strings as the spec's keys.json says.
    let keys: Value = serde_json::from_str(
        &std::fs::read_to_string(theirs.join("conformance/keys.json")).unwrap(),
    )
    .unwrap();
    for (name, key) in keys["keys"].as_object().unwrap() {
        let derived = Keypair::from_seed_string(key["seed_string"].as_str().unwrap());
        if derived.public_key() != key["public_key"] || derived.key_id() != key["key_id"] {
            differ.push(format!(
                "the test key {name} doesn't derive from its seed string"
            ));
        }
    }
    // The cards made here are the spec's, case for case (descriptions aside).
    let made = card_cases();
    let their_cards = files(&theirs.join("conformance/fixtures/card"));
    if made.len() != their_cards.len() {
        differ.push(format!(
            "{} card cases made here, {} in the spec",
            made.len(),
            their_cards.len()
        ));
    }
    for (_, case) in &made {
        let path = theirs.join(format!(
            "conformance/fixtures/card/{}.json",
            case["name"].as_str().unwrap()
        ));
        let mut theirs: Value = match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap(),
            Err(_) => {
                differ.push(format!("{} isn't in the spec", path.display()));
                continue;
            }
        };
        theirs.as_object_mut().unwrap().remove("description");
        if &theirs != case {
            differ.push(format!(
                "the card case {} differs from the spec's",
                case["name"]
            ));
        }
    }
    assert!(
        differ.is_empty(),
        "spec/ differs from {}: {}; run sync-spec.sh",
        theirs.display(),
        differ.join(", ")
    );
}
