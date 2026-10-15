//! The Obi-to-Obi protocol v0.1, as obi-ai-bot/obi-sphere's `spec/` defines it (`protocol.md`,
//! `identity.md`, `sphere-api.md`, the JSON Schemas and the conformance suite): canonical JSON,
//! Ed25519 keys and signatures, the typed messages, and the checks a receiver makes on envelopes,
//! agent cards and audit chains. Its behavior follows the spec's reference verifier,
//! `spec/conformance/lib/obi.mjs`, check for check; `cargo test -p obi-protocol` judges every
//! conformance case, and the `obi-conformance` binary is what `run.mjs --impl` runs.

pub mod card;
pub mod chain;
pub mod envelope;
pub mod jcs;
pub mod jwt;
pub mod keys;
pub mod schema;
pub mod time;
pub mod types;

use serde_json::Value;

/// The protocol version every document names.
pub const PROTOCOL: &str = "obi/0.1";
/// What an envelope's signing input starts with (protocol.md, "Signing").
pub const ENVELOPE_SIGNING_PREFIX: &str = "obi/0.1 envelope\n";
/// What an audit entry's hashing input starts with (sphere-api.md, "Audit chain").
pub const AUDIT_HASH_PREFIX: &str = "obi/0.1 audit\n";
/// The agent card extension that carries the Obi's own fields (identity.md, "Agent card").
pub const CARD_EXTENSION_URI: &str = "urn:obi-sphere:ext:obi:0.1";
/// The most an envelope may weigh, canonical.
pub const MAX_ENVELOPE_BYTES: usize = 65_536;
/// The longest a message may live.
pub const MAX_LIFETIME_SECONDS: i64 = 2_592_000;
/// How far ahead of the receiver's clock a message may be made.
pub const CLOCK_SKEW_SECONDS: i64 = 300;
/// `prev` of the first audit entry.
pub const ZERO_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";
/// The action types that start an exchange.
pub const REQUEST_TYPES: [&str; 3] = ["review_request", "question", "handoff"];
/// The action types that answer one.
pub const REPLY_TYPES: [&str; 4] = ["status", "accept", "decline", "result"];
/// The replies that end an exchange.
pub const TERMINAL_TYPES: [&str; 2] = ["decline", "result"];

/// How much a finding matters: nit 1, minor 2, major 3, blocker 4.
pub fn severity_rank(severity: &str) -> Option<u8> {
    match severity {
        "nit" => Some(1),
        "minor" => Some(2),
        "major" => Some(3),
        "blocker" => Some(4),
        _ => None,
    }
}

/// A refusal: the spec's error code (sphere-api.md's, or `wrong_recipient`, the receiver's own)
/// and one line saying why.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{code}: {message}")]
pub struct Rejection {
    pub code: &'static str,
    pub message: String,
}

impl Rejection {
    pub fn new(code: &'static str, message: impl Into<String>) -> Rejection {
        Rejection {
            code,
            message: message.into(),
        }
    }
}

/// The recommended stable id of a finding (protocol.md, "Findings"): `f-` and the first 16 hex of
/// SHA-256 over `file\nline\ntitle`.
pub fn finding_id(file: &str, line: u64, title: &str) -> String {
    let digest = keys::sha256(format!("{file}\n{line}\n{title}").as_bytes());
    format!("f-{}", &hex::encode(digest)[..16])
}

/// A directory key as a verifier is given it: `{obi, public_key, valid_from_seq?, valid_until_seq?}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectoryKey {
    pub obi: String,
    pub public_key: String,
    /// Whether it carries a validity range at all (either field present, even as null).
    pub ranged: bool,
    /// The first audit seq it signs, 1 when not given.
    pub valid_from_seq: u64,
    /// The last, or `None` while it is the Obi's current key.
    pub valid_until_seq: Option<u64>,
}

impl DirectoryKey {
    /// From the context's JSON; `None` when it isn't a key at all.
    pub fn from_value(value: &Value) -> Option<DirectoryKey> {
        let object = value.as_object()?;
        let ranged =
            object.contains_key("valid_from_seq") || object.contains_key("valid_until_seq");
        Some(DirectoryKey {
            obi: object.get("obi")?.as_str()?.to_owned(),
            public_key: object.get("public_key")?.as_str()?.to_owned(),
            ranged,
            valid_from_seq: object
                .get("valid_from_seq")
                .and_then(Value::as_u64)
                .unwrap_or(1),
            valid_until_seq: object.get("valid_until_seq").and_then(Value::as_u64),
        })
    }

    /// Whether it may sign the message recorded at `seq`; with no `seq` (a message not yet
    /// recorded), whether it is current (protocol.md section 10, "Which key is valid for a message").
    pub fn valid_at(&self, seq: Option<u64>) -> bool {
        if !self.ranged {
            return true;
        }
        match seq {
            None => self.valid_until_seq.is_none(),
            Some(seq) => {
                seq >= self.valid_from_seq && self.valid_until_seq.is_none_or(|until| seq <= until)
            }
        }
    }
}

/// The directory a verifier is given: key id to key.
pub type Keys = std::collections::BTreeMap<String, DirectoryKey>;

/// Reads the context's `keys` (`{key_id: {obi, public_key, …}}`); entries that aren't keys are
/// left out, so a message signed with one is refused as an unknown key.
pub fn keys_from_value(value: Option<&Value>) -> Keys {
    value
        .and_then(Value::as_object)
        .map(|keys| {
            keys.iter()
                .filter_map(|(id, key)| DirectoryKey::from_value(key).map(|k| (id.clone(), k)))
                .collect()
        })
        .unwrap_or_default()
}

/// One conformance case (spec/conformance/README.md, "Case format"): `{case, context, input}`.
/// What the `obi-conformance` binary answers for the case on its stdin.
pub fn judge(case: &Value) -> Result<(), Rejection> {
    let context = case.get("context").cloned().unwrap_or(Value::Null);
    let input = case.get("input").cloned().unwrap_or(Value::Null);
    match case.get("case").and_then(Value::as_str) {
        Some("envelope") => {
            let context = envelope::Context::from_value(&context);
            envelope::verify(&input, &context)
        }
        Some("card") => card::verify(&input, &card::Context::from_value(&context)),
        Some("audit") => chain::verify(&input, &keys_from_value(context.get("keys"))),
        other => Err(Rejection::new(
            "bad_request",
            format!("unknown case kind {}", other.unwrap_or("(none)")),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finding_ids_are_the_scenarios() {
        // e2e/SCENARIO.md, "The two known findings".
        assert_eq!(
            finding_id(
                "src/average.js",
                4,
                "average() divides by zero for an empty list"
            ),
            "f-8424ac27bbfa2630"
        );
        assert_eq!(
            finding_id("src/greet.js", 2, "Unused variable `trimmed`"),
            "f-e82e5a31927dc589"
        );
    }

    #[test]
    fn key_validity() {
        let key = |ranged, from, until| DirectoryKey {
            obi: "a".into(),
            public_key: String::new(),
            ranged,
            valid_from_seq: from,
            valid_until_seq: until,
        };
        assert!(key(false, 1, Some(3)).valid_at(Some(9)));
        assert!(key(true, 2, None).valid_at(None));
        assert!(!key(true, 2, Some(5)).valid_at(None));
        assert!(key(true, 2, Some(5)).valid_at(Some(5)));
        assert!(!key(true, 2, Some(5)).valid_at(Some(6)));
        assert!(!key(true, 2, None).valid_at(Some(1)));
    }
}
