//! The spec's JSON Schemas (draft 2020-12), compiled in: `schemas/v0.1/` in obi-sphere's `spec/`,
//! copied into this crate's `spec/` (spec/README.md). Each is named as the reference verifier names
//! it: its path under `v0.1/` without `.schema.json` (`envelope`, `actions/review_request`,
//! `wire/jws-header`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::Value;

/// The `$id` every schema's path is relative to.
pub const SCHEMA_BASE: &str =
    "https://github.com/obi-ai-bot/obi-sphere/raw/main/spec/schemas/v0.1/";

/// Every schema: its name and its text.
pub const SCHEMAS: &[(&str, &str)] = &[
    (
        "actions/accept",
        include_str!("../spec/schemas/v0.1/actions/accept.schema.json"),
    ),
    (
        "actions/answer",
        include_str!("../spec/schemas/v0.1/actions/answer.schema.json"),
    ),
    (
        "actions/decline",
        include_str!("../spec/schemas/v0.1/actions/decline.schema.json"),
    ),
    (
        "actions/handoff",
        include_str!("../spec/schemas/v0.1/actions/handoff.schema.json"),
    ),
    (
        "actions/question",
        include_str!("../spec/schemas/v0.1/actions/question.schema.json"),
    ),
    (
        "actions/result",
        include_str!("../spec/schemas/v0.1/actions/result.schema.json"),
    ),
    (
        "actions/review_request",
        include_str!("../spec/schemas/v0.1/actions/review_request.schema.json"),
    ),
    (
        "actions/status",
        include_str!("../spec/schemas/v0.1/actions/status.schema.json"),
    ),
    (
        "agent-card",
        include_str!("../spec/schemas/v0.1/agent-card.schema.json"),
    ),
    (
        "audit-entry",
        include_str!("../spec/schemas/v0.1/audit-entry.schema.json"),
    ),
    (
        "common",
        include_str!("../spec/schemas/v0.1/common.schema.json"),
    ),
    (
        "envelope",
        include_str!("../spec/schemas/v0.1/envelope.schema.json"),
    ),
    (
        "wire/ack.request",
        include_str!("../spec/schemas/v0.1/wire/ack.request.schema.json"),
    ),
    (
        "wire/ack.response",
        include_str!("../spec/schemas/v0.1/wire/ack.response.schema.json"),
    ),
    (
        "wire/actor.claims",
        include_str!("../spec/schemas/v0.1/wire/actor.claims.schema.json"),
    ),
    (
        "wire/audit.response",
        include_str!("../spec/schemas/v0.1/wire/audit.response.schema.json"),
    ),
    (
        "wire/card-update.request",
        include_str!("../spec/schemas/v0.1/wire/card-update.request.schema.json"),
    ),
    (
        "wire/create-sphere.request",
        include_str!("../spec/schemas/v0.1/wire/create-sphere.request.schema.json"),
    ),
    (
        "wire/delegation.claims",
        include_str!("../spec/schemas/v0.1/wire/delegation.claims.schema.json"),
    ),
    (
        "wire/deliveries.response",
        include_str!("../spec/schemas/v0.1/wire/deliveries.response.schema.json"),
    ),
    (
        "wire/error",
        include_str!("../spec/schemas/v0.1/wire/error.schema.json"),
    ),
    (
        "wire/health.response",
        include_str!("../spec/schemas/v0.1/wire/health.response.schema.json"),
    ),
    (
        "wire/invitation.request",
        include_str!("../spec/schemas/v0.1/wire/invitation.request.schema.json"),
    ),
    (
        "wire/invitation.response",
        include_str!("../spec/schemas/v0.1/wire/invitation.response.schema.json"),
    ),
    (
        "wire/jws-header",
        include_str!("../spec/schemas/v0.1/wire/jws-header.schema.json"),
    ),
    (
        "wire/member",
        include_str!("../spec/schemas/v0.1/wire/member.schema.json"),
    ),
    (
        "wire/members.response",
        include_str!("../spec/schemas/v0.1/wire/members.response.schema.json"),
    ),
    (
        "wire/policy-put.request",
        include_str!("../spec/schemas/v0.1/wire/policy-put.request.schema.json"),
    ),
    (
        "wire/policy",
        include_str!("../spec/schemas/v0.1/wire/policy.schema.json"),
    ),
    (
        "wire/redeem.request",
        include_str!("../spec/schemas/v0.1/wire/redeem.request.schema.json"),
    ),
    (
        "wire/send.response",
        include_str!("../spec/schemas/v0.1/wire/send.response.schema.json"),
    ),
    (
        "wire/sphere",
        include_str!("../spec/schemas/v0.1/wire/sphere.schema.json"),
    ),
    (
        "actions/run_request",
        include_str!("../spec/schemas/v0.1/actions/run_request.schema.json"),
    ),
    (
        "actions/run_progress",
        include_str!("../spec/schemas/v0.1/actions/run_progress.schema.json"),
    ),
    (
        "actions/run_return",
        include_str!("../spec/schemas/v0.1/actions/run_return.schema.json"),
    ),
    (
        "actions/run_cancel",
        include_str!("../spec/schemas/v0.1/actions/run_cancel.schema.json"),
    ),
    (
        "actions/share_offer",
        include_str!("../spec/schemas/v0.1/actions/share_offer.schema.json"),
    ),
    (
        "actions/share_status",
        include_str!("../spec/schemas/v0.1/actions/share_status.schema.json"),
    ),
    (
        "actions/share_revoke",
        include_str!("../spec/schemas/v0.1/actions/share_revoke.schema.json"),
    ),
    (
        "runner-status",
        include_str!("../spec/schemas/v0.1/runner-status.schema.json"),
    ),
    (
        "channel-hello",
        include_str!("../spec/schemas/v0.1/channel-hello.schema.json"),
    ),
    (
        "wire/token.response",
        include_str!("../spec/schemas/v0.1/wire/token.response.schema.json"),
    ),
];

/// Every schema by its `$id`, ready for references between them. Compiling a validator for one
/// schema is done the first time it is used, so a process that checks one envelope compiles the
/// schemas an envelope needs and no more.
fn registry() -> &'static jsonschema::Registry<'static> {
    static REGISTRY: OnceLock<jsonschema::Registry<'static>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        // The texts are compiled into this crate: a schema that doesn't parse or compile is a bug
        // in the copy, caught by this crate's own tests, never something a peer can cause.
        jsonschema::Registry::new()
            .extend(
                SCHEMAS
                    .iter()
                    .map(|(name, _)| (format!("{SCHEMA_BASE}{name}.schema.json"), document(name))),
            )
            .and_then(|builder| builder.prepare())
            .unwrap_or_else(|e| panic!("the schemas don't form a registry: {e}"))
    })
}

fn document(name: &str) -> Value {
    // `common#/$defs/finding`: one definition inside a schema, by reference.
    if let Some((schema, pointer)) = name.split_once('#') {
        assert!(exists(schema), "no schema {schema}");
        return serde_json::json!({"$ref": format!("{SCHEMA_BASE}{schema}.schema.json#{pointer}")});
    }
    let text = SCHEMAS
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, text)| *text)
        .unwrap_or_else(|| panic!("no schema {name}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("schema {name} is not JSON: {e}"))
}

fn validator(name: &str) -> Arc<jsonschema::Validator> {
    static VALIDATORS: OnceLock<Mutex<HashMap<String, Arc<jsonschema::Validator>>>> =
        OnceLock::new();
    let validators = VALIDATORS.get_or_init(Default::default);
    if let Some(validator) = validators
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(name)
    {
        return validator.clone();
    }
    let compiled = Arc::new(
        jsonschema::draft202012::options()
            .with_registry(registry())
            .should_validate_formats(false)
            .build(&document(name))
            .unwrap_or_else(|e| panic!("schema {name} doesn't compile: {e}")),
    );
    validators
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(name.to_owned())
        .or_insert(compiled)
        .clone()
}

/// Whether `name` is one of the spec's schemas.
pub fn exists(name: &str) -> bool {
    SCHEMAS.iter().any(|(n, _)| *n == name)
}

/// What is wrong with `value` against the schema `name`, one line each, at most `limit`; empty
/// when it matches. `name` is one of [`SCHEMAS`], or one of its definitions, like
/// `common#/$defs/finding`. Panics on any other: callers name them in code.
pub fn errors(name: &str, value: &Value, limit: usize) -> Vec<String> {
    validator(name)
        .iter_errors(value)
        .take(limit)
        .map(|e| {
            let path = e.instance_path().to_string();
            format!("{} {e}", if path.is_empty() { "/" } else { &path })
        })
        .collect()
}

/// Whether `value` matches the schema `name`.
pub fn is_valid(name: &str, value: &Value) -> bool {
    validator(name).is_valid(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_schema_compiles_with_its_id() {
        for (name, text) in SCHEMAS {
            let value: Value = serde_json::from_str(text).unwrap();
            let _ = validator(name);
            assert_eq!(
                value["$id"],
                json!(format!("{SCHEMA_BASE}{name}.schema.json")),
                "{name}"
            );
        }
        assert!(is_valid(
            "wire/jws-header",
            &json!({"alg": "EdDSA", "kid": format!("ed25519:{}", "A".repeat(43)), "typ": "JWT"})
        ));
        assert!(!is_valid(
            "wire/jws-header",
            &json!({"alg": "none", "kid": "x", "typ": "JWT"})
        ));
        assert!(is_valid(
            "common#/$defs/finding",
            &json!({"id": "f-1", "severity": "nit", "file": "a.js", "line": 1, "title": "t", "detail": "d"})
        ));
        assert!(!is_valid(
            "common#/$defs/finding",
            &json!({"id": "f-1", "severity": "nit", "file": "../a.js", "line": 1, "title": "t", "detail": "d"})
        ));
    }

    #[test]
    fn data_text_refuses_control_and_bidi_characters() {
        let finding = |title: &str| {
            json!({"for": "review_request", "outcome": "changes_requested", "repo": "a/b",
                   "head_sha": "6d20146f366b9fac8907b5066c30ee39aaec09b3",
                   "findings": [{"id": "f-1", "severity": "major", "file": "src/a.js", "line": 1, "title": title, "detail": "d"}],
                   "acceptance": [{"index": 0, "kind": "tests_pass", "met": false}]})
        };
        assert!(is_valid(
            "actions/result",
            &finding("A title, with ünïcode")
        ));
        assert!(!is_valid("actions/result", &finding("two\nlines")));
        assert!(!is_valid(
            "actions/result",
            &finding("right\u{202e}to left")
        ));
        assert!(!is_valid("actions/result", &finding("nul\u{0}")));
    }
}
