//! Ed25519 keys and signatures, base64url and key ids (spec/identity.md, "Keys").
//!
//! A public key travels as its 32 raw bytes in base64url without padding; its key id is
//! `ed25519:` and base64url of SHA-256 over those bytes. A signature is 64 bytes, base64url.

use base64::Engine as _;
use base64::engine::DecodePaddingMode;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

/// base64url without padding.
pub fn b64url(bytes: impl AsRef<[u8]>) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Decodes base64url without padding; `None` for anything else (padding, `+`, `/`, junk). Unused
/// bits in the last character are ignored, as Node's decoder (the reference verifier's) ignores them.
pub fn from_b64url(text: &str) -> Option<Vec<u8>> {
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::URL_SAFE,
        GeneralPurposeConfig::new()
            .with_encode_padding(false)
            .with_decode_padding_mode(DecodePaddingMode::RequireNone)
            .with_decode_allow_trailing_bits(true),
    );
    LENIENT.decode(text).ok()
}

/// SHA-256.
pub fn sha256(bytes: impl AsRef<[u8]>) -> [u8; 32] {
    Sha256::digest(bytes.as_ref()).into()
}

/// The key id of a base64url public key, or `None` when it isn't 32 bytes.
pub fn key_id_of(public_key: &str) -> Option<String> {
    let raw = from_b64url(public_key)?;
    (raw.len() == 32).then(|| format!("ed25519:{}", b64url(sha256(&raw))))
}

/// Checks an Ed25519 signature (RFC 8032) by a base64url public key over `message`. False for a key
/// or signature that isn't well formed.
pub fn verify_bytes(public_key: &str, message: &[u8], signature: &str) -> bool {
    let Some(raw) = from_b64url(public_key) else {
        return false;
    };
    let Ok(raw) = <[u8; 32]>::try_from(raw.as_slice()) else {
        return false;
    };
    let Ok(key) = VerifyingKey::from_bytes(&raw) else {
        return false;
    };
    let Some(sig) = from_b64url(signature) else {
        return false;
    };
    let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else {
        return false;
    };
    key.verify(message, &ed25519_dalek::Signature::from_bytes(&sig))
        .is_ok()
}

/// An Ed25519 key pair. Its private half never leaves it: no `Debug`, no serialization; only
/// [`Keypair::seed`] hands the 32-byte seed out, for whoever stores it.
pub struct Keypair {
    signing: SigningKey,
}

impl Keypair {
    /// The key whose RFC 8032 seed is `seed`.
    pub fn from_seed(seed: &[u8; 32]) -> Keypair {
        Keypair {
            signing: SigningKey::from_bytes(seed),
        }
    }

    /// A conformance test key: the seed is SHA-256 of the seed string (spec/conformance/README.md,
    /// "Keys"). Anyone can derive it: never use one for anything but tests.
    pub fn from_seed_string(seed_string: &str) -> Keypair {
        Keypair::from_seed(&sha256(seed_string.as_bytes()))
    }

    /// The 32-byte seed, for storing the key.
    pub fn seed(&self) -> [u8; 32] {
        self.signing.to_bytes()
    }

    /// The public key, base64url.
    pub fn public_key(&self) -> String {
        b64url(self.signing.verifying_key().as_bytes())
    }

    /// The key id.
    pub fn key_id(&self) -> String {
        format!(
            "ed25519:{}",
            b64url(sha256(self.signing.verifying_key().as_bytes()))
        )
    }

    /// An Ed25519 signature over `message`, base64url.
    pub fn sign(&self, message: &[u8]) -> String {
        b64url(self.signing.sign(message).to_bytes())
    }
}

impl std::fmt::Debug for Keypair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Keypair")
            .field("key_id", &self.key_id())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conformance_keys_derive_as_the_spec_says() {
        // spec/conformance/keys.json
        let key = Keypair::from_seed_string("obi-conformance-test-key-obi-a");
        assert_eq!(
            key.public_key(),
            "ntsfB6eWkZc1OaiYP3IQWc8ULKnQgLnlTcEu78Ix1kM"
        );
        assert_eq!(
            key.key_id(),
            "ed25519:z6WLmvO2TG4LaAn2ppQXKN2Po5NJVyWEm4RIFgMBs-M"
        );
        assert_eq!(key_id_of(&key.public_key()).unwrap(), key.key_id());
    }

    #[test]
    fn signatures_verify_only_unchanged() {
        let key = Keypair::from_seed_string("a test key");
        let sig = key.sign(b"hello");
        assert!(verify_bytes(&key.public_key(), b"hello", &sig));
        assert!(!verify_bytes(&key.public_key(), b"hellO", &sig));
        assert!(!verify_bytes(&key.public_key(), b"hello", "AAAA"));
        assert!(!verify_bytes("short", b"hello", &sig));
        let other = Keypair::from_seed_string("another");
        assert!(!verify_bytes(&other.public_key(), b"hello", &sig));
    }
}
