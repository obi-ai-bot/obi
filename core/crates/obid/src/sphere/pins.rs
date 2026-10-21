//! The owner keys this Obi trusts (spec identity.md, "Pinning, in every Obi"; docs/runner-api.md,
//! "obid only: Obi-to-Obi"): the first owner key it saw for each owner, kept in
//! `home/sphere/pins.json` (0600). The Sphere binds owner keys too, but a Sphere's operator could
//! serve one of its own; with the pin, a card (and so an Obi key, and a job channel's hello) is
//! trusted only when it verifies with the owner key pinned here. A changed key is never followed by
//! itself: that member isn't trusted until this owner has compared the new key's fingerprint with
//! that person and accepted it. It also keeps the highest `card_seq` trusted for each Obi, and
//! refuses a lower one: a Sphere can't serve an older card whose key was rotated away.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use obi_protocol::time;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::store;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pin {
    /// The owner's Ed25519 public key, base64url.
    pub key: String,
    pub first_seen: i64,
    /// A different key the directory showed since, waiting for this owner's OK.
    #[serde(default)]
    pub changed_to: Option<String>,
}

/// An owner key's fingerprint, as owners compare it: its key id, `ed25519:…`.
pub fn fingerprint(key: &str) -> String {
    obi_protocol::keys::key_id_of(key).unwrap_or_default()
}

/// What `home/sphere/pins.json` keeps.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct Kept {
    /// By owner.
    owners: BTreeMap<String, Pin>,
    /// The highest `card_seq` trusted, by Obi.
    cards: BTreeMap<String, u64>,
    /// Every Obi key a trusted card signed, by Obi and key id: the only older keys obid takes from
    /// the directory (to check old chain entries), whatever the Sphere lists.
    keys: BTreeMap<String, BTreeMap<String, String>>,
}

pub struct Pins {
    path: PathBuf,
    pins: Mutex<Kept>,
}

impl Pins {
    pub fn open(home: &Path) -> Pins {
        let path = home.join("sphere").join("pins.json");
        let pins = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Pins {
            path,
            pins: Mutex::new(pins),
        }
    }

    fn save(&self, pins: &Kept) {
        let saved = self
            .path
            .parent()
            .map_or(Ok(()), store::make_private_dir)
            .and_then(|()| {
                let text = serde_json::to_vec_pretty(pins).map_err(std::io::Error::other)?;
                store::write_private(&self.path, &text)
            });
        if let Err(e) = saved {
            tracing::error!("can't keep the pinned owner keys: {e}");
        }
    }

    /// Whether a card of `owner`'s, signed with `key`, may be trusted: pinned now when it's the
    /// first key seen for that owner; a different one is noted for the owner's OK, and isn't.
    pub fn check(&self, owner: &str, key: &str, now: i64) -> bool {
        let mut kept = self.pins.lock().unwrap();
        let pins = &mut kept.owners;
        match pins.get_mut(owner) {
            Some(pin) if pin.key == key => true,
            Some(pin) => {
                if pin.changed_to.as_deref() != Some(key) {
                    tracing::warn!(
                        "sphere: {owner}'s owner key changed to {}: not trusted until you accept it",
                        fingerprint(key)
                    );
                    pin.changed_to = Some(key.to_owned());
                    let copy = kept.clone();
                    drop(kept);
                    self.save(&copy);
                }
                false
            }
            None => {
                pins.insert(
                    owner.to_owned(),
                    Pin {
                        key: key.to_owned(),
                        first_seen: now,
                        changed_to: None,
                    },
                );
                let copy = kept.clone();
                drop(kept);
                self.save(&copy);
                true
            }
        }
    }

    /// Whether `obi`'s card, at `card_seq`, may be trusted: not when an earlier read trusted a
    /// higher one. The highest is kept.
    pub fn check_card(&self, obi: &str, card_seq: u64) -> bool {
        let mut kept = self.pins.lock().unwrap();
        let highest = kept.cards.get(obi).copied().unwrap_or(0);
        if card_seq < highest {
            tracing::warn!(
                "sphere: {obi}'s card is older ({card_seq}) than one already seen ({highest}): not trusted"
            );
            return false;
        }
        if card_seq > highest {
            kept.cards.insert(obi.to_owned(), card_seq);
            let copy = kept.clone();
            drop(kept);
            self.save(&copy);
        }
        true
    }

    /// Keeps `obi`'s key `id`, which a card obid trusted signed.
    pub fn keep_key(&self, obi: &str, id: &str, public_key: &str) {
        let mut kept = self.pins.lock().unwrap();
        let keys = kept.keys.entry(obi.to_owned()).or_default();
        if keys.contains_key(id) {
            return;
        }
        keys.insert(id.to_owned(), public_key.to_owned());
        let copy = kept.clone();
        drop(kept);
        self.save(&copy);
    }

    /// Whether a card obid trusted once signed `obi`'s key `id`, `public_key`.
    pub fn knows_key(&self, obi: &str, id: &str, public_key: &str) -> bool {
        self.pins
            .lock()
            .unwrap()
            .keys
            .get(obi)
            .and_then(|k| k.get(id))
            .is_some_and(|k| k == public_key)
    }

    /// The owner accepts `owner`'s changed key, named by its fingerprint (what they compared).
    pub fn accept(&self, owner: &str, fingerprint_seen: &str, now: i64) -> Result<Value, String> {
        let mut kept = self.pins.lock().unwrap();
        let pin = kept
            .owners
            .get_mut(owner)
            .ok_or_else(|| format!("No key is pinned for {owner}."))?;
        let new = pin
            .changed_to
            .clone()
            .ok_or_else(|| format!("{owner}'s key hasn't changed."))?;
        if fingerprint(&new) != fingerprint_seen {
            return Err(format!(
                "That isn't {owner}'s new key's fingerprint: compare it with them again."
            ));
        }
        *pin = Pin {
            key: new,
            first_seen: now,
            changed_to: None,
        };
        let answer = to_json(owner, pin);
        let copy = kept.clone();
        drop(kept);
        self.save(&copy);
        Ok(answer)
    }

    /// `GET /v1/obid/sphere/pins`: every pinned owner, with the fingerprint to compare.
    pub fn to_json(&self) -> Value {
        json!(
            self.pins
                .lock()
                .unwrap()
                .owners
                .iter()
                .map(|(owner, pin)| to_json(owner, pin))
                .collect::<Vec<_>>()
        )
    }
}

fn to_json(owner: &str, pin: &Pin) -> Value {
    json!({"owner": owner, "fingerprint": fingerprint(&pin.key), "firstSeen": time::format(pin.first_seen),
           "changedTo": pin.changed_to.as_deref().map(fingerprint)})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_key_is_pinned_and_a_changed_one_waits_for_the_owner() {
        let home = std::env::temp_dir().join(format!("obid-pins-{}", uuid::Uuid::new_v4()));
        let a = obi_protocol::keys::Keypair::from_seed(&[1; 32]).public_key();
        let b = obi_protocol::keys::Keypair::from_seed(&[2; 32]).public_key();
        let pins = Pins::open(&home);
        assert!(pins.check("sangam", &a, 10));
        assert!(pins.check("sangam", &a, 20));
        // The Sphere shows another key: not trusted, and kept for the owner's OK, across restarts.
        assert!(!pins.check("sangam", &b, 30));
        let pins = Pins::open(&home);
        assert!(!pins.check("sangam", &b, 40));
        assert_eq!(pins.to_json()[0]["changedTo"], fingerprint(&b));
        assert!(pins.accept("sangam", &fingerprint(&a), 50).is_err());
        assert!(pins.accept("sangam", &fingerprint(&b), 50).is_ok());
        assert!(pins.check("sangam", &b, 60) && !pins.check("sangam", &a, 70));
        // A card older than one already trusted isn't, even after a restart.
        assert!(pins.check_card("obi-sangam", 2) && pins.check_card("obi-sangam", 2));
        assert!(!Pins::open(&home).check_card("obi-sangam", 1));
        assert!(pins.check_card("obi-sangam", 3));
        // The Obi keys trusted cards signed, kept across restarts; no other.
        pins.keep_key("obi-sangam", "ed25519:k1", "K1");
        assert!(Pins::open(&home).knows_key("obi-sangam", "ed25519:k1", "K1"));
        assert!(!pins.knows_key("obi-sangam", "ed25519:k1", "K2"));
        assert!(!pins.knows_key("obi-sangam", "ed25519:k2", "K2"));
        let _ = std::fs::remove_dir_all(home);
    }
}
