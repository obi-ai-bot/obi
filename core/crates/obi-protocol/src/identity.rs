//! An Obi's identity in its Sphere (identity.md): the agent card it asks its owner to sign, the
//! owner's delegation it checks before it keeps one, and the actor assertions it signs with its
//! own key for each token exchange.

use serde_json::{Map, Value, json};

use crate::keys::{self, Keypair};
use crate::{CARD_EXTENSION_URI, CLOCK_SKEW_SECONDS, MAX_LIFETIME_SECONDS, PROTOCOL, jwt, schema};

/// What an A2A card says about the protocol it speaks.
pub const A2A_PROTOCOL_VERSION: &str = "0.3.0";

/// The longest an actor assertion may live (identity.md 4.1).
pub const ACTOR_ASSERTION_SECONDS: i64 = 300;

/// A card's description when the owner gives none.
pub const DEFAULT_DESCRIPTION: &str = "A personal delegate for an engineer.";

/// The `audience` every assertion for `sphere` names.
pub fn audience(sphere: &str) -> String {
    format!("obi-sphere:{sphere}")
}

/// The skill a card lists for a request type it accepts: `{id, name, description, tags}`.
pub fn skill(request_type: &str) -> Value {
    let (name, description) = match request_type {
        "review_request" => (
            "Review a change",
            "Reviews a change for its owner and answers with typed findings.",
        ),
        "question" => (
            "Answer a question",
            "Answers what its owner knows or decided.",
        ),
        _ => (
            "Take on handed-off work",
            "Runs a piece of work for its owner and answers with a typed result.",
        ),
    };
    json!({"id": request_type, "name": name, "description": description, "tags": ["obi-action"]})
}

/// The fields of a card an Obi builds around its own key.
#[derive(Debug, Clone)]
pub struct CardFields<'a> {
    /// The Sphere's base URL, like `http://127.0.0.1:8787`, without a trailing `/`.
    pub sphere_url: &'a str,
    pub sphere: &'a str,
    pub obi_id: &'a str,
    pub owner: &'a str,
    pub owner_key: &'a str,
    pub name: &'a str,
    pub description: &'a str,
    pub version: &'a str,
    pub key_id: &'a str,
    pub public_key: &'a str,
    pub accepts: &'a [String],
    pub card_seq: u64,
    pub issued_at: &'a str,
}

/// The agent card without signatures (identity.md 2): what the owner signs.
pub fn unsigned_card(fields: &CardFields<'_>) -> Map<String, Value> {
    let params = json!({
        "protocol": PROTOCOL,
        "sphere": fields.sphere,
        "obi_id": fields.obi_id,
        "owner": fields.owner,
        "owner_key": fields.owner_key,
        "key_id": fields.key_id,
        "public_key": fields.public_key,
        "accepts": fields.accepts,
        "card_seq": fields.card_seq,
        "issued_at": fields.issued_at,
    });
    let card = json!({
        "protocolVersion": A2A_PROTOCOL_VERSION,
        "name": fields.name,
        "description": fields.description,
        "url": format!("{}/v0.1/spheres/{}/members/{}", fields.sphere_url, fields.sphere, fields.obi_id),
        "preferredTransport": "HTTP+JSON",
        "version": fields.version,
        "capabilities": {
            "streaming": false,
            "pushNotifications": false,
            "extensions": [{"uri": CARD_EXTENSION_URI, "required": true, "params": params}],
        },
        "defaultInputModes": ["application/json"],
        "defaultOutputModes": ["application/json"],
        "skills": fields.accepts.iter().map(|a| skill(a)).collect::<Vec<_>>(),
    });
    match card {
        Value::Object(map) => map,
        _ => unreachable!("a card is an object"),
    }
}

/// What is wrong with an unsigned card against the card schema, as if it were signed: empty when
/// it would pass once the owner signs it.
pub fn unsigned_card_problems(card: &Map<String, Value>) -> Vec<String> {
    let mut signed = card.clone();
    // A well-formed placeholder: the schema checks the signature's shape, not its value.
    signed.insert(
        "signatures".into(),
        json!([{"protected": "eyJhbGciOiJFZERTQSJ9", "signature": "A".repeat(86)}]),
    );
    schema::errors("agent-card", &Value::Object(signed), 5)
}

/// An actor assertion (identity.md 4.1): `iss` and `sub` the Obi, signed with its current key,
/// living [`ACTOR_ASSERTION_SECONDS`] from `now`, with the single-use `jti` given (a UUID).
pub fn actor_assertion(
    obi_id: &str,
    sphere: &str,
    key: &Keypair,
    now: i64,
    jti: &str,
) -> Result<String, crate::jcs::JcsError> {
    jwt::sign(
        &json!({"iss": obi_id, "sub": obi_id, "aud": audience(sphere), "iat": now,
                "exp": now + ACTOR_ASSERTION_SECONDS, "jti": jti}),
        key,
    )
}

/// What an Obi expects of the delegation its owner hands it.
#[derive(Debug, Clone)]
pub struct DelegationCheck<'a> {
    /// The owner key the card names: the delegation must be signed by it.
    pub owner_key: &'a str,
    pub owner: &'a str,
    pub sphere: &'a str,
    pub obi_id: &'a str,
    pub now: i64,
    /// Scopes it must grant, at least.
    pub needs: &'a [&'a str],
}

/// Checks an owner's delegation (an owner assertion with `may_act`, identity.md 4.1) before the Obi
/// keeps it: signed by the owner key, for this owner, Sphere and Obi, not expired, within the
/// lifetime the spec allows, granting what the Obi needs. Answers its claims, or why not.
pub fn check_delegation(token: &str, check: &DelegationCheck<'_>) -> Result<Value, String> {
    let parts = jwt::parse(token)
        .ok_or("the delegation isn't a compact JWT with the header {alg: EdDSA, kid, typ: JWT}")?;
    if keys::key_id_of(check.owner_key).as_deref() != parts.header["kid"].as_str() {
        return Err("the delegation's kid isn't the owner key's id".into());
    }
    if !parts.verifies_with(check.owner_key) {
        return Err("the delegation's signature doesn't verify with the owner key".into());
    }
    let claims = parts.claims;
    let errors = schema::errors("wire/delegation.claims", &claims, 3);
    if !errors.is_empty() {
        return Err(format!(
            "the delegation's claims don't match the spec: {}",
            errors.join("; ")
        ));
    }
    let text = |key: &str| claims[key].as_str().unwrap_or("");
    if text("iss") != check.owner || text("sub") != check.owner {
        return Err(format!(
            "the delegation is for {}, not the owner {}",
            text("sub"),
            check.owner
        ));
    }
    if text("aud") != audience(check.sphere) {
        return Err(format!(
            "the delegation's audience is {}, not {}",
            text("aud"),
            audience(check.sphere)
        ));
    }
    if claims["may_act"]["sub"].as_str() != Some(check.obi_id) {
        return Err(format!(
            "the delegation doesn't let {} act (may_act.sub)",
            check.obi_id
        ));
    }
    let iat = claims["iat"].as_i64().unwrap_or(0);
    let exp = claims["exp"].as_i64().unwrap_or(0);
    if exp <= check.now {
        return Err("the delegation has expired".into());
    }
    if iat > check.now + CLOCK_SKEW_SECONDS {
        return Err("the delegation was issued in the future".into());
    }
    if exp - iat > MAX_LIFETIME_SECONDS {
        return Err(format!(
            "the delegation lives {} seconds, more than {MAX_LIFETIME_SECONDS}",
            exp - iat
        ));
    }
    let granted: Vec<&str> = text("scope").split(' ').collect();
    let missing: Vec<&str> = check
        .needs
        .iter()
        .copied()
        .filter(|s| !granted.contains(s))
        .collect();
    if !missing.is_empty() {
        return Err(format!(
            "the delegation doesn't grant {}",
            missing.join(" and ")
        ));
    }
    Ok(claims)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{card, time};

    const UUID: &str = "8a6c1f4e-5d2b-4c7a-9e3f-1b2c3d4e5f60";

    #[test]
    fn a_card_the_owner_signs_passes_the_cards_checks() {
        let owner = Keypair::from_seed_string("owner");
        let obi = Keypair::from_seed_string("obi");
        let accepts = vec!["review_request".to_owned()];
        let (owner_key, key_id, public_key) = (owner.public_key(), obi.key_id(), obi.public_key());
        let unsigned = unsigned_card(&CardFields {
            sphere_url: "http://127.0.0.1:8787",
            sphere: "e2e",
            obi_id: "obi-wellington",
            owner: "wellington",
            owner_key: &owner_key,
            name: "Wellington's Obi",
            description: DEFAULT_DESCRIPTION,
            version: "0.1.0",
            key_id: &key_id,
            public_key: &public_key,
            accepts: &accepts,
            card_seq: 1,
            issued_at: "2026-10-14T12:00:00Z",
        });
        assert!(unsigned_card_problems(&unsigned).is_empty());
        assert_eq!(
            unsigned["url"],
            "http://127.0.0.1:8787/v0.1/spheres/e2e/members/obi-wellington"
        );
        let signed = card::sign(&unsigned, &owner).unwrap();
        let context = card::Context {
            now: time::parse("2026-10-14T12:00:00Z"),
            bound_owner_key: Some(owner.public_key()),
        };
        card::verify(&signed, &context).unwrap();
    }

    fn delegation(owner: &Keypair, claims: Value) -> String {
        jwt::sign(&claims, owner).unwrap()
    }

    #[test]
    fn delegations() {
        let owner = Keypair::from_seed_string("owner");
        let now = 1_800_000_000;
        let good = json!({"iss": "wellington", "sub": "wellington", "aud": "obi-sphere:e2e", "iat": now,
                          "exp": now + 3600, "jti": UUID,
                          "scope": "send:review_request reply receive directory:read audit:read",
                          "may_act": {"sub": "obi-wellington"}});
        let owner_key = owner.public_key();
        let check = DelegationCheck {
            owner_key: &owner_key,
            owner: "wellington",
            sphere: "e2e",
            obi_id: "obi-wellington",
            now,
            needs: &["receive", "reply"],
        };
        check_delegation(&delegation(&owner, good.clone()), &check).unwrap();
        let wrong = |change: &dyn Fn(&mut Value)| {
            let mut claims = good.clone();
            change(&mut claims);
            check_delegation(&delegation(&owner, claims), &check).unwrap_err()
        };
        assert!(wrong(&|c| c["may_act"]["sub"] = json!("obi-ernesto")).contains("may_act"));
        assert!(wrong(&|c| c["aud"] = json!("obi-sphere:other")).contains("audience"));
        assert!(wrong(&|c| c["exp"] = json!(now - 1)).contains("expired"));
        assert!(wrong(&|c| c["scope"] = json!("send:review_request receive")).contains("reply"));
        assert!(wrong(&|c| c["sub"] = json!("ernesto")).contains("not the owner"));
        let other = Keypair::from_seed_string("someone else");
        assert!(
            check_delegation(&delegation(&other, good.clone()), &check)
                .unwrap_err()
                .contains("kid")
        );
        assert!(check_delegation("not.a.jwt", &check).is_err());
    }

    #[test]
    fn actor_assertions_are_signed_by_the_obi() {
        let obi = Keypair::from_seed_string("obi");
        let token = actor_assertion("obi-wellington", "e2e", &obi, 100, UUID).unwrap();
        let parts = jwt::parse(&token).unwrap();
        assert!(parts.verifies_with(&obi.public_key()));
        assert!(schema::is_valid("wire/actor.claims", &parts.claims));
        assert_eq!(parts.claims["exp"], 400);
    }
}
