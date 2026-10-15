//! JWS (RFC 7515) with EdDSA (RFC 8037): owner and Obi assertions (compact JWTs) and the agent
//! card's detached signature. Every protected header is `{alg: EdDSA, kid, typ}` as canonical
//! JSON, base64url (spec/identity.md; wire/jws-header.schema.json).

use serde_json::{Value, json};

use crate::jcs::{self, JcsError};
use crate::keys::{Keypair, b64url, from_b64url, verify_bytes};
use crate::schema;

/// A protected header, encoded.
pub fn header(kid: &str, typ: &str) -> Result<String, JcsError> {
    Ok(b64url(jcs::canonical_bytes(
        &json!({"alg": "EdDSA", "kid": kid, "typ": typ}),
    )?))
}

/// A compact JWT: `header.claims.signature`, the claims as canonical JSON.
pub fn sign(claims: &Value, key: &Keypair) -> Result<String, JcsError> {
    let head = header(&key.key_id(), "JWT")?;
    let body = b64url(jcs::canonical_bytes(claims)?);
    let signature = key.sign(format!("{head}.{body}").as_bytes());
    Ok(format!("{head}.{body}.{signature}"))
}

/// A compact JWT taken apart: its header and claims, unchecked.
#[derive(Debug, Clone, PartialEq)]
pub struct Parts {
    pub header: Value,
    pub claims: Value,
    /// What the signature covers: `header.claims` as sent.
    pub signed: String,
    pub signature: String,
}

/// Splits a compact JWT, or `None` when it isn't three base64url parts of JSON with a header the
/// spec allows (`alg` EdDSA, a `kid`, `typ` JWT).
pub fn parse(token: &str) -> Option<Parts> {
    let mut parts = token.split('.');
    let (head, body, signature) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let header: Value = serde_json::from_slice(&from_b64url(head)?).ok()?;
    let claims: Value = serde_json::from_slice(&from_b64url(body)?).ok()?;
    if !schema::is_valid("wire/jws-header", &header) || header["typ"] != "JWT" {
        return None;
    }
    Some(Parts {
        header,
        claims,
        signed: format!("{head}.{body}"),
        signature: signature.to_owned(),
    })
}

impl Parts {
    /// Whether the signature verifies with the base64url public key `public_key`.
    pub fn verifies_with(&self, public_key: &str) -> bool {
        verify_bytes(public_key, self.signed.as_bytes(), &self.signature)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_parses() {
        let key = Keypair::from_seed_string("owner");
        let token = sign(&json!({"iss": "wellington", "aud": "obi-sphere:e2e"}), &key).unwrap();
        let parts = parse(&token).unwrap();
        assert_eq!(parts.header["kid"], key.key_id());
        assert_eq!(parts.claims["iss"], "wellington");
        assert!(parts.verifies_with(&key.public_key()));
        assert!(!parts.verifies_with(&Keypair::from_seed_string("other").public_key()));
        assert!(parse("a.b").is_none());
    }
}
