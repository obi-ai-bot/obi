//! The Sphere's audit chain (sphere-api.md, "Audit chain"): each entry's hash, appending one, the
//! exchange rules (protocol.md section 4), and what a verifier checks over a whole chain (7.1).

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::jcs::{self, JcsError};
use crate::keys::{self, sha256};
use crate::{
    AUDIT_HASH_PREFIX, CLOCK_SKEW_SECONDS, Keys, REPLY_TYPES, REQUEST_TYPES, RUN_REPLY_TYPES,
    Rejection, SENDER_REPLY_TYPES, SHARE_REPLY_TYPES, TERMINAL_TYPES, ZERO_HASH, envelope, schema,
    time,
};

/// An entry's hash: SHA-256, lower-case hex, over `obi/0.1 audit\n` and the canonical JSON of
/// every member but `hash`.
pub fn entry_hash(entry: &Value) -> Result<String, JcsError> {
    let mut rest = entry.as_object().cloned().unwrap_or_default();
    rest.remove("hash");
    let mut input = AUDIT_HASH_PREFIX.as_bytes().to_vec();
    input.extend(jcs::canonical_bytes(&Value::Object(rest))?);
    Ok(hex::encode(sha256(&input)))
}

/// `entries` with one more, for `envelope` recorded at `recorded_at`.
pub fn append(
    entries: &[Value],
    sphere: &str,
    envelope: &Value,
    recorded_at: &str,
) -> Result<Vec<Value>, JcsError> {
    let prev = entries
        .last()
        .and_then(|e| e["hash"].as_str())
        .unwrap_or(ZERO_HASH);
    let mut entry = json!({"sphere": sphere, "seq": entries.len() + 1, "prev": prev,
                           "recorded_at": recorded_at, "envelope": envelope});
    entry["hash"] = Value::String(entry_hash(&entry)?);
    let mut all = entries.to_vec();
    all.push(entry);
    Ok(all)
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

/// The exchange rules, as the Sphere applies them at send and a chain's verifier at each reply:
/// why `reply` breaks them, given the request its `in_reply_to` names (if any) and the replies to
/// that request that came before it, in order; `None` when it doesn't.
pub fn exchange_problem(
    reply: &Value,
    request: Option<&Value>,
    earlier: &[&Value],
) -> Option<String> {
    let Some(request) = request.filter(|r| REQUEST_TYPES.contains(&text(r, "type"))) else {
        return Some("replies to no earlier request".into());
    };
    let kind = text(reply, "type");
    let asked = text(request, "type");
    // run_cancel, share_status and share_revoke are the replies the request's own sender sends,
    // to its receiver.
    if SENDER_REPLY_TYPES.contains(&kind) {
        if request.get("from") != reply.get("from") || request.get("to") != reply.get("to") {
            return Some(format!(
                "only the request's sender sends a {kind}, to its receiver"
            ));
        }
    } else if request.get("from") != reply.get("to") || request.get("to") != reply.get("from") {
        return Some("only the request's receiver replies, to its sender".into());
    }
    if RUN_REPLY_TYPES.contains(&kind) && asked != "run_request" {
        return Some(format!("a {kind} belongs to a run_request, not a {asked}"));
    }
    // A share_offer's exchange takes share_status, share_revoke and decline, and they belong to it
    // alone (a decline to any request).
    if asked == "share_offer" && !SHARE_REPLY_TYPES.contains(&kind) {
        return Some(format!("a share_offer takes no {kind}"));
    }
    if asked != "share_offer" && kind != "decline" && SHARE_REPLY_TYPES.contains(&kind) {
        return Some(format!("a {kind} belongs to a share_offer, not a {asked}"));
    }
    if earlier
        .iter()
        .any(|e| TERMINAL_TYPES.contains(&text(e, "type")))
    {
        return Some("the exchange already ended".into());
    }
    let accepted = earlier.iter().any(|e| text(e, "type") == "accept");
    if kind == "accept" && accepted {
        return Some("accepted twice".into());
    }
    if kind == "result" {
        let answers = reply["body"]["for"].as_str().unwrap_or("");
        if answers != asked {
            return Some(format!("a result for {answers} answers a {asked}"));
        }
        if !accepted {
            return Some(format!(
                "a {asked} is answered by a result only after an accept"
            ));
        }
    }
    // A run_return comes back only from a job that was accepted.
    if kind == "run_return" && !accepted {
        return Some("a run_request is answered by a run_return only after an accept".into());
    }
    // An answer answers a question, and nothing else; an accept before it is allowed, not needed.
    if kind == "answer" && asked != "question" {
        return Some(format!("an answer answers a question, not a {asked}"));
    }
    // No words in a guest job's or a share's exchange: a decline there has no note, and a guest
    // job's takes no status, whose states and note would say when its host's owner is there (rule 9).
    if kind == "status" && asked == "run_request" {
        return Some("a run_request takes no status".into());
    }
    if kind == "decline"
        && (asked == "run_request" || asked == "share_offer")
        && reply["body"].get("note").is_some()
    {
        return Some(format!("a decline of a {asked} has no note"));
    }
    // Nor why its host declined, which would say when its owner is at the Mac or what its rules
    // are: only the guest's own doing keeps its reason.
    if kind == "decline"
        && asked == "run_request"
        && (!matches!(
            reply["body"]["reason"].as_str(),
            Some("unavailable" | "expired" | "out_of_scope" | "share_used")
        ) || reply["body"].get("by_rule").is_some())
    {
        return Some(
            "a decline of a run_request says only unavailable, expired, out_of_scope or share_used, with no by_rule".into(),
        );
    }
    None
}

/// Checks a whole chain from seq 1, `{sphere, entries}`, against the key history `keys`.
pub fn verify(chain: &Value, keys: &Keys) -> Result<(), Rejection> {
    let (Some(sphere), Some(entries)) = (
        chain.get("sphere").and_then(Value::as_str),
        chain.get("entries").and_then(Value::as_array),
    ) else {
        return Err(Rejection::new(
            "bad_request",
            "a chain is {sphere, entries}",
        ));
    };
    let mut prev = ZERO_HASH.to_owned();
    let mut last_time: Option<i64> = None;
    // A recorded_at that isn't a time compares as nothing, as NaN does in the reference.
    let mut last_unreadable = false;
    let mut by_id: HashMap<String, Value> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for (i, entry) in entries.iter().enumerate() {
        let at = format!("entry {}", i + 1);
        let errors = schema::errors("audit-entry", entry, 3);
        if !errors.is_empty() {
            return Err(Rejection::new(
                "invalid_envelope",
                format!("{at}: {}", errors.join("; ")),
            ));
        }
        if entry["seq"].as_u64() != Some(i as u64 + 1) {
            return Err(Rejection::new(
                "conflict",
                format!("{at}: seq is {}", entry["seq"]),
            ));
        }
        if text(entry, "sphere") != sphere {
            return Err(Rejection::new(
                "wrong_sphere",
                format!("{at}: sphere {}", text(entry, "sphere")),
            ));
        }
        if text(entry, "prev") != prev {
            return Err(Rejection::new(
                "conflict",
                format!("{at}: prev does not link to the entry before"),
            ));
        }
        let hash =
            entry_hash(entry).map_err(|e| Rejection::new("invalid_envelope", e.to_string()))?;
        if hash != text(entry, "hash") {
            return Err(Rejection::new(
                "conflict",
                format!("{at}: hash does not match its content"),
            ));
        }
        let recorded = time::parse_lenient(text(entry, "recorded_at"));
        if let (Some(time), Some(last)) = (recorded, last_time)
            && !last_unreadable
            && time < last
        {
            return Err(Rejection::new(
                "conflict",
                format!("{at}: recorded_at goes back in time"),
            ));
        }
        last_time = recorded;
        last_unreadable = recorded.is_none();
        let env = &entry["envelope"];
        let problems = envelope::semantic_problems(env);
        if !problems.is_empty() {
            return Err(Rejection::new(
                "invalid_envelope",
                format!("{at}: {}", problems.join("; ")),
            ));
        }
        if text(env, "sphere") != sphere {
            return Err(Rejection::new(
                "wrong_sphere",
                format!("{at}: envelope for {}", text(env, "sphere")),
            ));
        }
        let created = time::parse(text(env, "created_at"));
        let expires = time::parse(text(env, "expires_at"));
        let Some(recorded) = recorded else {
            return Err(Rejection::new(
                "expired",
                format!("{at}: recorded after it expired"),
            ));
        };
        if created.is_some_and(|c| c > recorded + CLOCK_SKEW_SECONDS) {
            return Err(Rejection::new(
                "clock_skew",
                format!("{at}: created after it was recorded"),
            ));
        }
        if expires.is_none_or(|e| e <= recorded) {
            return Err(Rejection::new(
                "expired",
                format!("{at}: recorded after it expired"),
            ));
        }
        let key_id = text(env, "key_id");
        let from = text(env, "from");
        let key = keys
            .get(key_id)
            .filter(|k| k.obi == from && keys::key_id_of(&k.public_key).as_deref() == Some(key_id))
            .ok_or_else(|| {
                Rejection::new(
                    "unknown_key",
                    format!("{at}: {key_id} is not a key of {from}"),
                )
            })?;
        let seq = i as u64 + 1;
        if !key.valid_at(Some(seq)) {
            return Err(Rejection::new(
                "unknown_key",
                format!("{at}: {key_id} was not valid at seq {seq}"),
            ));
        }
        let input = envelope::signing_input(env)
            .map_err(|e| Rejection::new("invalid_envelope", e.to_string()))?;
        if !keys::verify_bytes(&key.public_key, &input, text(env, "signature")) {
            return Err(Rejection::new(
                "bad_signature",
                format!("{at}: the sender's signature does not verify"),
            ));
        }
        let id = text(env, "id").to_owned();
        if by_id.contains_key(&id) {
            return Err(Rejection::new(
                "duplicate",
                format!("{at}: {id} is in the chain twice"),
            ));
        }
        if REPLY_TYPES.contains(&text(env, "type")) {
            let in_reply_to = text(env, "in_reply_to");
            let earlier: Vec<&Value> = order
                .iter()
                .map(|id| &by_id[id])
                .filter(|e| {
                    REPLY_TYPES.contains(&text(e, "type")) && text(e, "in_reply_to") == in_reply_to
                })
                .collect();
            if let Some(problem) = exchange_problem(env, by_id.get(in_reply_to), &earlier) {
                return Err(Rejection::new("bad_reply", format!("{at}: {problem}")));
            }
        }
        by_id.insert(id.clone(), env.clone());
        order.push(id);
        prev = hash;
    }
    Ok(())
}
