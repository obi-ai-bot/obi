//! The spec's conformance suite (obi-sphere `spec/conformance/`, copied into `spec/`): every case
//! judged as the reference verifier judges it, the canonical-JSON vectors, the test keys, and the
//! `obi-conformance` binary as `run.mjs --impl` runs it.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use obi_protocol::jcs::canonicalize;
use obi_protocol::keys::Keypair;
use serde_json::Value;

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

fn cases() -> Vec<(String, Value)> {
    files(&spec().join("conformance/fixtures"))
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
        .collect()
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

#[test]
fn test_keys_derive_from_their_seed_strings() {
    let keys: Value = serde_json::from_str(
        &std::fs::read_to_string(spec().join("conformance/keys.json")).unwrap(),
    )
    .unwrap();
    for (name, key) in keys["keys"].as_object().unwrap() {
        let derived = Keypair::from_seed_string(key["seed_string"].as_str().unwrap());
        assert_eq!(
            derived.public_key(),
            key["public_key"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(derived.key_id(), key["key_id"].as_str().unwrap(), "{name}");
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
        let their_files: Vec<PathBuf> = files(&theirs.join(source))
            .into_iter()
            .map(|p| p.strip_prefix(theirs.join(source)).unwrap().to_path_buf())
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
    for file in ["conformance/jcs-vectors.json", "conformance/keys.json"] {
        if std::fs::read(spec().join(file)).unwrap() != std::fs::read(theirs.join(file)).unwrap() {
            differ.push(file.to_owned());
        }
    }
    assert!(
        differ.is_empty(),
        "spec/ differs from {}: {}; run sync-spec.sh",
        theirs.display(),
        differ.join(", ")
    );
}
