//! The devices that may approve publishing (docs/runner-api.md, `POST /v1/devices`), as
//! Runner/Devices.swift keeps them: each by its P-256 key, in `home/devices.json`. A key obid knows
//! gets its id back at once, so an app registers every time it connects. A new key needs pairing
//! open: the owner touches `home/pairing` on obid's machine, and one device registers within 10
//! minutes, which uses it up. The API token can't be the gate on its own: agents run on the same
//! machine. They can't touch `pairing`: obid's home is hidden in their sandbox.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use base64::Engine as _;
use serde::{Deserialize, Serialize};

/// How long `pairing` stays open after the owner touched it.
const PAIRING_OPEN: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Device {
    id: String,
    name: String,
    /// P-256, X9.63 (65 bytes, uncompressed), base64.
    public_key: String,
    registered: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    devices: Vec<Device>,
    /// SHA-256 of each signed approval message and its signed timestamp, shared with the Mac
    /// runner's `devices.json` so a phone approval can't be replayed after a restart.
    #[serde(default)]
    used: HashMap<String, String>,
}

/// Why a device didn't register.
#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// `422`: the key isn't a P-256 public key.
    Malformed(String),
    /// `403`: a new key while pairing is closed; the line to show.
    PairingClosed(String),
    /// `500`: obid couldn't keep it.
    Unkept(String),
}

pub struct Devices {
    file: PathBuf,
    pairing: PathBuf,
    saved: Mutex<Saved>,
}

impl Devices {
    /// The devices kept in `home/devices.json`. A file that doesn't read is left as it is and
    /// counts as none: no device can approve until one registers again.
    pub fn open(home: &Path) -> Devices {
        let file = home.join("devices.json");
        let saved = match std::fs::read(&file) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|_| {
                tracing::error!(
                    "can't read {}: no device can approve until one registers again",
                    file.display()
                );
                Saved::default()
            }),
            Err(_) => Saved::default(),
        };
        for device in &saved.devices {
            tracing::info!("device {}: {}", device.id, device.name);
        }
        Devices {
            file,
            pairing: home.join("pairing"),
            saved: Mutex::new(saved),
        }
    }

    /// Where the owner opens pairing.
    pub fn pairing(&self) -> &Path {
        &self.pairing
    }

    /// The publishing key (X9.63, base64) of the registered device `id`, or none for a device obid
    /// doesn't know: what checks its approval to publish by hand (crate::approval).
    pub fn public_key(&self, id: &str) -> Option<String> {
        let saved = self.saved.lock().unwrap_or_else(|e| e.into_inner());
        saved
            .devices
            .iter()
            .find(|d| d.id == id)
            .map(|d| d.public_key.clone())
    }

    /// Registers a device's publishing key and answers its id: the one it has for a key it knows,
    /// a new one for a new key while pairing is open (and pairing is closed again).
    pub fn register(
        &self,
        name: &str,
        public_key: &str,
        now: SystemTime,
    ) -> Result<String, Refused> {
        if !is_p256_public_key(public_key) {
            return Err(Refused::Malformed(
                "publicKey isn't a P-256 public key (X9.63, base64).".into(),
            ));
        }
        let mut saved = self.saved.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(known) = saved.devices.iter().find(|d| d.public_key == public_key) {
            return Ok(known.id.clone());
        }
        let open = std::fs::metadata(&self.pairing)
            .and_then(|m| m.modified())
            .is_ok_and(|opened| {
                now.duration_since(opened)
                    .map_or(true, |age| age < PAIRING_OPEN)
            });
        if !open {
            return Err(Refused::PairingClosed(format!(
                "To add this device, run `touch {}` on obid's machine, then try again within 10 minutes.",
                self.pairing.display()
            )));
        }
        let seconds = now
            .duration_since(SystemTime::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64);
        let device = Device {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.to_owned(),
            public_key: public_key.to_owned(),
            registered: obi_protocol::time::format(seconds),
        };
        saved.devices.push(device.clone());
        let bytes = serde_json::to_vec_pretty(&*saved).map_err(|e| Refused::Unkept(e.to_string()));
        if let Err(e) = bytes.and_then(|b| {
            crate::store::write_private(&self.file, &b).map_err(|e| Refused::Unkept(e.to_string()))
        }) {
            saved.devices.pop();
            return Err(e);
        }
        let _ = std::fs::remove_file(&self.pairing);
        tracing::info!("registered device {}: {}", device.id, device.name);
        Ok(device.id)
    }

    /// Checks the phone's signed approval sentence for a sensitive connection change. A
    /// signature is tied to the exact action and timestamp, expires after two minutes, and is
    /// accepted once and kept in `devices.json`, across restarts.
    pub fn approves_connection(&self, value: &serde_json::Value, action: &str) -> bool {
        let Some(device) = value.get("device").and_then(serde_json::Value::as_str) else {
            return false;
        };
        let Some(signed_at) = value.get("signedAt").and_then(serde_json::Value::as_str) else {
            return false;
        };
        let Some(signature) = value.get("signature").and_then(serde_json::Value::as_str) else {
            return false;
        };
        if value.get("action").and_then(serde_json::Value::as_str) != Some(action) {
            return false;
        }
        let Some(seconds) = obi_protocol::time::parse(signed_at) else {
            return false;
        };
        if (obi_protocol::time::now() - seconds).abs() > 120 {
            return false;
        }
        use base64::Engine as _;
        use p256::ecdsa::signature::Verifier as _;
        let Ok(signature_bytes) = base64::engine::general_purpose::STANDARD.decode(signature)
        else {
            return false;
        };
        let Ok(signature) = p256::ecdsa::Signature::from_der(&signature_bytes) else {
            return false;
        };
        let Some(public_key) = self.public_key(device) else {
            return false;
        };
        let Ok(key_bytes) = base64::engine::general_purpose::STANDARD.decode(public_key) else {
            return false;
        };
        let Ok(key) = p256::ecdsa::VerifyingKey::from_sec1_bytes(&key_bytes) else {
            return false;
        };
        let signed_message = format!("oby-connection\n{action}\n{signed_at}");
        if key.verify(signed_message.as_bytes(), &signature).is_err() {
            return false;
        }
        let mut message = device.as_bytes().to_vec();
        message.extend_from_slice(signed_message.as_bytes());
        let hash = hex::encode(obi_protocol::keys::sha256(message));
        let mut saved = self.saved.lock().unwrap_or_else(|e| e.into_inner());
        let now = obi_protocol::time::now();
        saved
            .used
            .retain(|_, at| obi_protocol::time::parse(at).is_some_and(|at| now - at < 600));
        if saved.used.contains_key(&hash) {
            return false;
        }
        saved.used.insert(hash.clone(), signed_at.to_owned());
        let kept = serde_json::to_vec_pretty(&*saved)
            .ok()
            .is_some_and(|bytes| crate::store::write_private(&self.file, &bytes).is_ok());
        if !kept {
            saved.used.remove(&hash);
        }
        kept
    }
}

/// A P-256 public key as the apps send it: X9.63 uncompressed (`04`, then X and Y, 65 bytes),
/// base64, and a point on the curve.
pub fn is_p256_public_key(text: &str) -> bool {
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(text) else {
        return false;
    };
    bytes.len() == 65 && bytes[0] == 4 && p256::PublicKey::from_sec1_bytes(&bytes).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::elliptic_curve::sec1::ToEncodedPoint;

    /// A device's key, from a fixed private scalar: no randomness, no key in the source.
    pub(crate) fn key(scalar: u8) -> String {
        let secret = p256::SecretKey::from_slice(&[scalar; 32]).unwrap();
        let point = secret.public_key().to_encoded_point(false);
        base64::engine::general_purpose::STANDARD.encode(point.as_bytes())
    }

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("obid-devices-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn keys() {
        assert!(is_p256_public_key(&key(1)));
        let raw = base64::engine::general_purpose::STANDARD
            .decode(key(1))
            .unwrap();
        for bad in [
            "BJ3x".to_owned(),
            "not base64!".to_owned(),
            base64::engine::general_purpose::STANDARD.encode([4u8; 65]),
            // The raw representation (X and Y, no prefix), as RunnerTests sends it.
            base64::engine::general_purpose::STANDARD.encode(&raw[1..]),
        ] {
            assert!(!is_p256_public_key(&bad), "{bad}");
        }
    }

    #[test]
    fn a_registered_key_survives_a_restart() {
        let home = folder("restart");
        std::fs::write(home.join("pairing"), "").unwrap();
        let id = Devices::open(&home)
            .register("Mac", &key(3), SystemTime::now())
            .unwrap();
        let again = Devices::open(&home);
        assert_eq!(again.register("Mac", &key(3), SystemTime::now()), Ok(id));
        let _ = std::fs::remove_dir_all(&home);
    }

    /// What a phone sends to approve a connection change: `message` signed with `scalar`'s key.
    fn signed(
        scalar: u8,
        device: &str,
        action: &str,
        signed_at: &str,
        message: &str,
    ) -> serde_json::Value {
        use p256::ecdsa::signature::Signer as _;
        let key = p256::ecdsa::SigningKey::from_slice(&[scalar; 32]).unwrap();
        let signature: p256::ecdsa::Signature = key.sign(message.as_bytes());
        serde_json::json!({"device": device, "action": action, "signedAt": signed_at,
            "signature": base64::engine::general_purpose::STANDARD.encode(signature.to_der().as_bytes())})
    }

    /// A connection change goes through only with a registered device's signature over obid's
    /// own sentence, `"oby-connection\n<action>\n<signedAt>"`, signed within two minutes, once,
    /// even across a restart (ConnectionTests.agentsUseConnectedAppsWithoutEverSeeingTheLogin's
    /// approvals, and what it can't reach: the clock and the other kinds of signed sentence).
    #[test]
    fn a_connection_change_needs_one_fresh_signature_from_a_registered_device() {
        let home = folder("connection-approval");
        std::fs::write(
            home.join("devices.json"),
            serde_json::json!({"devices": [{"id": "phone", "name": "Phone", "publicKey": key(9),
                "registered": "2026-10-16T00:00:00Z"}]})
            .to_string(),
        )
        .unwrap();
        let devices = Devices::open(&home);
        let action = "Connect mail: agents' read-only calls to the MCP server https://mail.example.com/mcp carry the vault secret mail-token as Authorization: Bearer.";
        let at = |offset: i64| obi_protocol::time::format(obi_protocol::time::now() + offset);
        let now = at(0);
        let good = |signed_at: &str| {
            signed(
                9,
                "phone",
                action,
                signed_at,
                &format!("oby-connection\n{action}\n{signed_at}"),
            )
        };

        // What is refused, none of it using an approval up.
        let refused = [
            ("no device", {
                let mut a = good(&now);
                a.as_object_mut().unwrap().remove("device");
                a
            }),
            (
                "an unknown device",
                signed(
                    9,
                    "laptop",
                    action,
                    &now,
                    &format!("oby-connection\n{action}\n{now}"),
                ),
            ),
            (
                "another key",
                signed(
                    8,
                    "phone",
                    action,
                    &now,
                    &format!("oby-connection\n{action}\n{now}"),
                ),
            ),
            (
                "another action, signed",
                signed(
                    9,
                    "phone",
                    "Disconnect mail.",
                    &now,
                    &format!("oby-connection\nDisconnect mail.\n{now}"),
                ),
            ),
            (
                "another action, claimed",
                signed(
                    9,
                    "phone",
                    "Disconnect mail.",
                    &now,
                    &format!("oby-connection\n{action}\n{now}"),
                ),
            ),
            (
                "another time than signed",
                signed(
                    9,
                    "phone",
                    action,
                    &at(1),
                    &format!("oby-connection\n{action}\n{now}"),
                ),
            ),
            (
                "a publish approval",
                signed(
                    9,
                    "phone",
                    action,
                    &now,
                    &format!("oby-publish\njob1\n{action}\n{now}"),
                ),
            ),
            ("the bare action", signed(9, "phone", action, &now, action)),
            ("three minutes ago", good(&at(-180))),
            ("three minutes ahead", good(&at(180))),
            ("no time", good("yesterday")),
            ("no signature", {
                let mut a = good(&now);
                a["signature"] = serde_json::json!("not base64!");
                a
            }),
            ("a signature that isn't DER", {
                let mut a = good(&now);
                a["signature"] = serde_json::json!("AAAA");
                a
            }),
        ];
        for (why, approval) in &refused {
            assert!(!devices.approves_connection(approval, action), "{why}");
        }

        let approval = good(&now);
        assert!(devices.approves_connection(&approval, action));
        assert!(!devices.approves_connection(&approval, action), "used once");
        assert!(
            !Devices::open(&home).approves_connection(&approval, action),
            "used once, after a restart"
        );
        // Another one, signed a second later, goes through: each is its own.
        assert!(Devices::open(&home).approves_connection(&good(&at(1)), action));
        let _ = std::fs::remove_dir_all(&home);
    }
}
