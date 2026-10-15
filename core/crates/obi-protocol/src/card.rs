//! Agent cards: the owner's signature over one (identity.md 2.1), and what a verifier checks
//! (identity.md 2.2, "Verifying a card").

use serde_json::{Map, Value};

use crate::jcs::{self, JcsError};
use crate::keys::{self, Keypair, b64url, from_b64url};
use crate::{CLOCK_SKEW_SECONDS, Rejection, jwt, schema, time};

/// What the owner signs: `protected.` and base64url of the card without `signatures`, canonical.
pub fn signing_input(card: &Value, protected: &str) -> Result<Vec<u8>, JcsError> {
    let mut unsigned = card.as_object().cloned().unwrap_or_default();
    unsigned.remove("signatures");
    Ok(format!(
        "{protected}.{}",
        b64url(jcs::canonical_bytes(&Value::Object(unsigned))?)
    )
    .into_bytes())
}

/// The card signed by the owner's key: one signature, `{protected, signature}`, replacing any.
pub fn sign(unsigned: &Map<String, Value>, owner: &Keypair) -> Result<Value, JcsError> {
    let mut card = unsigned.clone();
    card.remove("signatures");
    let protected = jwt::header(&owner.key_id(), "JOSE")?;
    let signature = owner.sign(&signing_input(&Value::Object(card.clone()), &protected)?);
    card.insert(
        "signatures".into(),
        serde_json::json!([{"protected": protected, "signature": signature}]),
    );
    Ok(Value::Object(card))
}

/// What a card is judged against: `{now, bound_owner_key?}`.
#[derive(Debug, Clone, Default)]
pub struct Context {
    pub now: Option<i64>,
    /// The owner key the Sphere has bound for the card's owner, when it has one.
    pub bound_owner_key: Option<String>,
}

impl Context {
    pub fn from_value(value: &Value) -> Context {
        Context {
            now: value
                .get("now")
                .and_then(Value::as_str)
                .and_then(time::parse_lenient),
            bound_owner_key: value
                .get("bound_owner_key")
                .and_then(Value::as_str)
                .filter(|key| !key.is_empty())
                .map(str::to_owned),
        }
    }
}

/// The Obi extension's `params`: the fields obid and the Sphere read off a card.
pub fn params(card: &Value) -> Option<&Map<String, Value>> {
    card.get("capabilities")?
        .get("extensions")?
        .get(0)?
        .get("params")?
        .as_object()
}

/// The card's checks, in the reference verifier's order.
pub fn verify(card: &Value, context: &Context) -> Result<(), Rejection> {
    let invalid = |message: &str| Err(Rejection::new("card_invalid", message));
    let errors = schema::errors("agent-card", card, 5);
    if !errors.is_empty() {
        return Err(Rejection::new("card_invalid", errors.join("; ")));
    }
    let Some(params) = params(card) else {
        return invalid("no Obi extension");
    };
    let text = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or("");
    let public_key = text("public_key");
    let owner_key = text("owner_key");
    if keys::key_id_of(public_key).as_deref() != Some(text("key_id")) {
        return invalid("key_id does not match public_key");
    }
    if owner_key == public_key {
        return invalid("the Obi's key must not be its owner's key");
    }
    let mut skills: Vec<&str> = card["skills"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| s.get("id").and_then(Value::as_str))
        .collect();
    let mut accepts: Vec<&str> = params
        .get("accepts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    skills.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    accepts.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    if skills.join(",") != accepts.join(",") {
        return invalid("skills and accepts differ");
    }
    let tail = format!(
        "/v0.1/spheres/{}/members/{}",
        text("sphere"),
        text("obi_id")
    );
    if !card["url"].as_str().unwrap_or("").ends_with(&tail) {
        return Err(Rejection::new(
            "card_invalid",
            format!("url must end with {tail}"),
        ));
    }
    if let Some(bound) = &context.bound_owner_key
        && bound != owner_key
    {
        return invalid("signed by another key than the owner's bound key");
    }
    let signature = &card["signatures"][0];
    let protected = signature["protected"].as_str().unwrap_or("");
    let header: Option<Value> = from_b64url(protected)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .and_then(|text| serde_json::from_str(&text).ok());
    let Some(header) = header else {
        return invalid("the protected header is not JSON");
    };
    if !schema::is_valid("wire/jws-header", &header) || header["typ"] != "JOSE" {
        return invalid("the protected header must be {alg: EdDSA, kid, typ: JOSE}");
    }
    if keys::key_id_of(owner_key).as_deref() != header["kid"].as_str() {
        return invalid("kid is not the owner key's id");
    }
    let input = signing_input(card, protected)
        .map_err(|e| Rejection::new("card_invalid", e.to_string()))?;
    if !keys::verify_bytes(
        owner_key,
        &input,
        signature["signature"].as_str().unwrap_or(""),
    ) {
        return Err(Rejection::new(
            "bad_signature",
            "the owner's signature does not verify",
        ));
    }
    if let (Some(now), Some(issued)) = (context.now, time::parse_lenient(text("issued_at")))
        && issued > now + CLOCK_SKEW_SECONDS
    {
        return invalid("issued in the future");
    }
    Ok(())
}
