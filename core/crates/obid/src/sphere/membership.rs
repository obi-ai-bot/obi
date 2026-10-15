//! The Obi's key and its place in one Sphere (docs/runner-api.md, "obid only: Sphere membership"),
//! as obid keeps them in its home:
//!
//! - `keys/obi.key` (0600): the Obi key's 32-byte seed, hex. It never leaves obid: no answer, event,
//!   log or agent ever sees it, and the job sandbox hides `home` from agents.
//! - `sphere/membership.json` (0600): the Sphere, the Obi's id and its owner-signed card.
//! - `sphere/delegation.jwt` (0600): the owner's delegation, never shown again once kept.

use std::path::{Path, PathBuf};

use obi_protocol::keys::Keypair;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store;

/// A Sphere joined.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Membership {
    /// `joined` or `revoked`.
    pub state: String,
    pub url: String,
    pub sphere: String,
    pub obi_id: String,
    pub card: Value,
    pub joined_at: i64,
}

impl Membership {
    /// The request types the card accepts.
    pub fn accepts(&self) -> Vec<String> {
        obi_protocol::card::params(&self.card)
            .and_then(|p| p.get("accepts"))
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The card's `card_seq`.
    pub fn card_seq(&self) -> u64 {
        obi_protocol::card::params(&self.card)
            .and_then(|p| p.get("card_seq"))
            .and_then(Value::as_u64)
            .unwrap_or(0)
    }
}

/// Where the key and the membership are kept.
pub struct Files {
    key: PathBuf,
    membership: PathBuf,
    delegation: PathBuf,
}

impl Files {
    pub fn new(home: &Path) -> Files {
        Files {
            key: home.join("keys").join("obi.key"),
            membership: home.join("sphere").join("membership.json"),
            delegation: home.join("sphere").join("delegation.jwt"),
        }
    }

    /// The Obi key, when it has been made.
    pub fn load_key(&self) -> std::io::Result<Option<Keypair>> {
        match std::fs::read_to_string(&self.key) {
            Ok(text) => {
                let bytes = hex::decode(text.trim())
                    .ok()
                    .and_then(|b| <[u8; 32]>::try_from(b).ok())
                    .ok_or_else(|| {
                        std::io::Error::other(format!("{} isn't a key", self.key.display()))
                    })?;
                Ok(Some(Keypair::from_seed(&bytes)))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Makes the Obi key and keeps it (0600, in a 0700 folder).
    pub fn make_key(&self) -> std::io::Result<Keypair> {
        let mut seed = [0u8; 32];
        getrandom::fill(&mut seed).map_err(|e| std::io::Error::other(e.to_string()))?;
        store::make_private_dir(self.key.parent().expect("the key has a folder"))?;
        store::write_private(&self.key, hex::encode(seed).as_bytes())?;
        Ok(Keypair::from_seed(&seed))
    }

    pub fn load_membership(&self) -> Option<Membership> {
        let bytes = std::fs::read(&self.membership).ok()?;
        serde_json::from_slice(&bytes)
            .map_err(|e| tracing::error!("{} doesn't read: {e}", self.membership.display()))
            .ok()
    }

    pub fn save_membership(&self, membership: &Membership) -> std::io::Result<()> {
        store::make_private_dir(self.membership.parent().expect("a folder"))?;
        let text = serde_json::to_vec_pretty(membership).map_err(std::io::Error::other)?;
        store::write_private(&self.membership, &text)
    }

    pub fn load_delegation(&self) -> Option<String> {
        std::fs::read_to_string(&self.delegation)
            .ok()
            .map(|t| t.trim().to_owned())
    }

    pub fn save_delegation(&self, delegation: &str) -> std::io::Result<()> {
        store::make_private_dir(self.delegation.parent().expect("a folder"))?;
        store::write_private(&self.delegation, delegation.as_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_key_is_made_once_and_kept_private() {
        let home = std::env::temp_dir().join(format!("obid-key-test-{}", std::process::id()));
        let files = Files::new(&home);
        assert!(files.load_key().unwrap().is_none());
        let key = files.make_key().unwrap();
        let again = files.load_key().unwrap().unwrap();
        assert_eq!(key.key_id(), again.key_id());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(home.join("keys/obi.key"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
            let mode = std::fs::metadata(home.join("keys"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o700);
        }
        let _ = std::fs::remove_dir_all(&home);
    }
}
