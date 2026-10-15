//! The devices that may approve publishing (docs/runner-api.md, `POST /v1/devices`), as
//! Runner/Devices.swift keeps them: each by its P-256 key, in `home/devices.json`. A key obid knows
//! gets its id back at once, so an app registers every time it connects. A new key needs pairing
//! open: the owner touches `home/pairing` on obid's machine, and one device registers within 10
//! minutes, which uses it up. The API token can't be the gate on its own: agents run on the same
//! machine. They can't touch `pairing`: obid's home is hidden in their sandbox.

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
}
