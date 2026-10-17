//! A registered device's approval to publish one job by hand (docs/runner-api.md, `POST
//! /v1/jobs/{id}/publish`), as Runner/Devices.swift checks it: the device's P-256 key signed
//! `"oby-publish\n<job id>\n<action>\n<signedAt>"` behind Face ID or Touch ID (ECDSA with
//! SHA-256, DER, base64). obid lets it through once: from a registered device, with a signature
//! that matches its key, for exactly obid's own sentence, signed within two minutes, and never
//! used before. The API token alone can't publish by hand: agents run on the same machine.
//!
//! What was used is kept in `home/approvals.json` (0600) for 10 minutes, so a restart doesn't
//! open a replay.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use base64::Engine as _;
use p256::ecdsa::signature::Verifier as _;

/// How far `signedAt` may be from now, either way.
const FRESH: i64 = 120;
/// How long a used approval is remembered: well past the time it could be fresh.
const REMEMBERED: i64 = 600;

/// What a device sends to publish by hand.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    pub device: String,
    pub action: String,
    pub signed_at: String,
    pub signature: String,
}

/// The approvals used in the last 10 minutes: the hash of each device's id and signed message,
/// and when it was signed.
pub struct Approvals {
    file: PathBuf,
    used: Mutex<HashMap<String, i64>>,
    /// Until when no approval goes through, when the file was there and didn't read: what it held
    /// could have been used, so a replay can't be ruled out until it would be stale.
    unread_until: Option<i64>,
}

impl Approvals {
    /// The approvals kept in `home/approvals.json`. When the file is there and doesn't read, no
    /// approval goes through for 10 minutes.
    pub fn open(home: &Path) -> Approvals {
        let file = home.join("approvals.json");
        let (used, unread_until) = match std::fs::read(&file) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (HashMap::new(), None),
            read => match read.ok().and_then(|b| serde_json::from_slice(&b).ok()) {
                Some(used) => (used, None),
                None => {
                    tracing::error!(
                        "can't read {}: no approval goes through for 10 minutes",
                        file.display()
                    );
                    (HashMap::new(), Some(obi_protocol::time::now() + REMEMBERED))
                }
            },
        };
        Approvals {
            file,
            used: Mutex::new(used),
            unread_until,
        }
    }

    /// Lets `approval` through once for publishing `job` by `action`, obid's own sentence, at
    /// `now` (seconds since the epoch). `key` is the registered device's public key (X9.63,
    /// base64), or none for a device obid doesn't know. `Err` is the line to show (`403`).
    pub fn check(
        &self,
        approval: &Approval,
        job: &str,
        action: &str,
        key: Option<&str>,
        now: i64,
    ) -> Result<(), String> {
        let message = format!(
            "oby-publish\n{job}\n{}\n{}",
            approval.action, approval.signed_at
        );
        if self.unread_until.is_some_and(|until| now < until) {
            return Err(
                "obid couldn't read the approvals it used. Approve it again in 10 minutes.".into(),
            );
        }
        let Some(key) = key.and_then(verifying_key) else {
            return Err("That device isn't registered with this runner.".into());
        };
        let signature = base64::engine::general_purpose::STANDARD
            .decode(approval.signature.trim())
            .ok()
            .and_then(|der| p256::ecdsa::Signature::from_der(&der).ok());
        if signature.is_none_or(|s| key.verify(message.as_bytes(), &s).is_err()) {
            return Err("The signature doesn't match the device's key.".into());
        }
        if approval.action != action {
            return Err("The device approved something else. Approve it again.".into());
        }
        let signed_at = obi_protocol::time::parse(&approval.signed_at)
            .filter(|at| (at - now).abs() <= FRESH)
            .ok_or("The approval is more than two minutes old. Approve it again.")?;
        // The signed message, not the signature: an ECDSA signature can be rewritten into another
        // valid one.
        let hash = hex::encode(obi_protocol::keys::sha256(
            [approval.device.as_bytes(), message.as_bytes()].concat(),
        ));
        let mut used = self.used.lock().unwrap_or_else(|e| e.into_inner());
        used.retain(|_, at| now - *at < REMEMBERED);
        if used.contains_key(&hash) {
            return Err("That approval was already used. Approve it again.".into());
        }
        used.insert(hash, signed_at);
        let bytes = serde_json::to_vec(&*used).map_err(|e| e.to_string())?;
        if let Err(e) = crate::store::write_private(&self.file, &bytes) {
            // Not kept, so not used: a replay after a restart must not get through either.
            tracing::error!("can't keep the used approvals: {e}");
            return Err("obid couldn't keep the approval. Approve it again.".into());
        }
        Ok(())
    }
}

/// The verifying key in a device's registered public key, or none.
fn verifying_key(public_key: &str) -> Option<p256::ecdsa::VerifyingKey> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(public_key)
        .ok()?;
    p256::ecdsa::VerifyingKey::from_sec1_bytes(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Signer as _;
    use p256::elliptic_curve::sec1::ToEncodedPoint;

    const NOW: i64 = 1_791_582_173;

    /// A device's key, from a fixed private scalar: no randomness, no key in the source.
    fn device(scalar: u8) -> (p256::ecdsa::SigningKey, String) {
        let secret = p256::SecretKey::from_slice(&[scalar; 32]).unwrap();
        let public = secret.public_key().to_encoded_point(false);
        (
            p256::ecdsa::SigningKey::from(secret),
            base64::engine::general_purpose::STANDARD.encode(public.as_bytes()),
        )
    }

    fn approval(key: &p256::ecdsa::SigningKey, job: &str, action: &str, at: i64) -> Approval {
        let signed_at = obi_protocol::time::format(at);
        let signature: p256::ecdsa::Signature =
            key.sign(format!("oby-publish\n{job}\n{action}\n{signed_at}").as_bytes());
        Approval {
            device: "d1".into(),
            action: action.into(),
            signed_at,
            signature: base64::engine::general_purpose::STANDARD.encode(signature.to_der()),
        }
    }

    fn home(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("obid-approval-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn once_fresh_signed_and_for_exactly_the_sentence() {
        let home = home("once");
        let approvals = Approvals::open(&home);
        let (key, public) = device(7);
        let (other, other_public) = device(8);
        let action = "Push oby/fix-1 to o/r and open a pull request into dev.";
        let good = approval(&key, "j1", action, NOW);
        // Unknown device, a signature by another key, another job, another sentence, stale.
        assert!(
            approvals
                .check(&good, "j1", action, None, NOW)
                .unwrap_err()
                .contains("isn't registered")
        );
        assert!(
            approvals
                .check(&good, "j1", action, Some(&other_public), NOW)
                .unwrap_err()
                .contains("signature")
        );
        assert!(
            approvals
                .check(&good, "j2", action, Some(&public), NOW)
                .unwrap_err()
                .contains("signature")
        );
        let elsewhere = approval(&key, "j1", "Push something else.", NOW);
        assert!(
            approvals
                .check(&elsewhere, "j1", action, Some(&public), NOW)
                .unwrap_err()
                .contains("something else")
        );
        let stale = approval(&key, "j1", action, NOW - 121);
        assert!(
            approvals
                .check(&stale, "j1", action, Some(&public), NOW)
                .unwrap_err()
                .contains("two minutes")
        );
        let _ = other;
        // Once, and not again after a restart.
        assert_eq!(
            approvals.check(&good, "j1", action, Some(&public), NOW),
            Ok(())
        );
        assert!(
            approvals
                .check(&good, "j1", action, Some(&public), NOW + 1)
                .unwrap_err()
                .contains("already used")
        );
        let reopened = Approvals::open(&home);
        assert!(
            reopened
                .check(&good, "j1", action, Some(&public), NOW + 1)
                .unwrap_err()
                .contains("already used")
        );
        // A file that doesn't read: nothing goes through, not even a new approval.
        std::fs::write(home.join("approvals.json"), "{broken").unwrap();
        let unread = Approvals::open(&home);
        let now = obi_protocol::time::now();
        let fresh = approval(&key, "j1", action, now);
        assert!(
            unread
                .check(&fresh, "j1", action, Some(&public), now)
                .unwrap_err()
                .contains("couldn't read")
        );
        let _ = std::fs::remove_dir_all(&home);
    }
}
