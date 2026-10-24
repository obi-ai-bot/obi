//! The phone envelope (#1277; docs/runner-api.md, "obid only: the phone relay"): what a paired
//! phone and obid seal every request, answer and event in, end to end, so the Obysphere that
//! carries them (spec sphere-api.md section 9) reads none of it.
//!
//! The phone knows the Mac's X25519 key from the pairing QR. A session starts with the phone's
//! hello, sealed to that key with a new X25519 key of the phone's; the Mac answers a welcome with
//! a new key of its own, and both derive one key per direction from both agreements and the whole
//! hello (Noise NK's shape): only the Mac holding the pinned key can answer, a session's keys die
//! with it, and a hello the Sphere replays gets new keys that none of the old envelopes open
//! under. Every later envelope is ChaCha20-Poly1305 under its direction's key, its counter the
//! nonce and its header the associated data: a changed, replayed or older envelope, one turned
//! back the other way, or one claiming another version than the session's, doesn't open. Which
//! phone sent a request is the device token sealed inside it, never the Sphere's routing
//! (crate::gateway, `Relayed`).

use aws_lc_rs::{aead, agreement, digest, hkdf};

/// The envelope version this obid speaks.
pub const VERSION: u8 = 1;
/// An envelope's type, its second byte.
const HELLO: u8 = 1;
const WELCOME: u8 = 2;
const SEALED: u8 = 3;
/// The most bytes one envelope may be (sphere-api.md 9.3).
pub const MAX: usize = 262_144;
/// What a sealed envelope adds to its frame: version, type, counter and tag.
pub const OVERHEAD: usize = 2 + 8 + 16;
/// The most versions a hello may offer.
const OFFERS: usize = 16;

const HELLO_INFO: &[u8] = b"oby relay v1 hello";
const WELCOME_INFO: &[u8] = b"oby relay v1 welcome";
const PHONE_INFO: &[u8] = b"oby relay v1 phone>mac";
const MAC_INFO: &[u8] = b"oby relay v1 mac>phone";

/// Why an envelope was refused: one line for the log, never what it held.
pub type Refused = &'static str;

fn sealing(bytes: &[u8; 32]) -> aead::LessSafeKey {
    aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::CHACHA20_POLY1305, bytes).expect("a 32-byte key"),
    )
}

/// Four zero bytes, then the counter, big-endian.
fn nonce(counter: u64) -> aead::Nonce {
    let mut bytes = [0u8; 12];
    bytes[4..].copy_from_slice(&counter.to_be_bytes());
    aead::Nonce::assume_unique_for_key(bytes)
}

/// HKDF-SHA256 (RFC 5869), 32 bytes.
fn derive(salt: &[u8], ikm: &[u8], info: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    hkdf::Salt::new(hkdf::HKDF_SHA256, salt)
        .extract(ikm)
        .expand(&[info], hkdf::HKDF_SHA256)
        .and_then(|okm| okm.fill(&mut out))
        .expect("32 bytes is within HKDF's limit");
    out
}

fn sha256(parts: &[&[u8]]) -> Vec<u8> {
    let mut context = digest::Context::new(&digest::SHA256);
    for part in parts {
        context.update(part);
    }
    context.finish().as_ref().to_vec()
}

/// X25519, refusing a public key that isn't one and an all-zero result (RFC 7748 6.1).
fn agree(private: &agreement::PrivateKey, public: &[u8]) -> Result<[u8; 32], Refused> {
    agreement::agree(
        private,
        agreement::UnparsedPublicKey::new(&agreement::X25519, public),
        "that isn't an X25519 key this Mac agrees with",
        |shared| {
            <[u8; 32]>::try_from(shared)
                .ok()
                .filter(|s| s.iter().any(|b| *b != 0))
                .ok_or("that isn't an X25519 key this Mac agrees with")
        },
    )
}

fn public_of(private: &agreement::PrivateKey) -> [u8; 32] {
    let public = private
        .compute_public_key()
        .expect("an X25519 key has a public key");
    <[u8; 32]>::try_from(public.as_ref()).expect("an X25519 public key is 32 bytes")
}

fn x25519(bytes: &[u8]) -> Result<agreement::PrivateKey, Refused> {
    agreement::PrivateKey::from_private_key(&agreement::X25519, bytes)
        .map_err(|_| "that isn't an X25519 private key")
}

fn new_x25519() -> Result<agreement::PrivateKey, Refused> {
    agreement::PrivateKey::generate(&agreement::X25519).map_err(|_| "no X25519 key could be made")
}

/// One direction's sealing: its key, the session's version and the next counter.
pub struct Sealer {
    key: aead::LessSafeKey,
    version: u8,
    next: u64,
}

impl Sealer {
    /// `version 03 counter ciphertext`: the 10-byte header is the associated data.
    pub fn seal(&mut self, frame: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(OVERHEAD + frame.len());
        out.extend_from_slice(&[self.version, SEALED]);
        out.extend_from_slice(&self.next.to_be_bytes());
        let mut body = frame.to_vec();
        self.key
            .seal_in_place_append_tag(nonce(self.next), aead::Aad::from(&out[..]), &mut body)
            .expect("a frame is far below ChaCha20-Poly1305's limit");
        self.next += 1;
        out.extend_from_slice(&body);
        out
    }
}

/// What [`Opener::open`] answers for an envelope that opens but isn't the next one: one before it
/// is missing (the Sphere dropped it), so the session is over and the phone says hello again.
pub const GAP: Refused = "an envelope before this one is missing: the session is over";

/// The other direction's opening: exactly the next counter, every time.
pub struct Opener {
    key: aead::LessSafeKey,
    version: u8,
    next: u64,
}

impl Opener {
    /// The next envelope's frame. One already opened (replayed, older) or one that doesn't open
    /// (changed, another session's) is refused and spends nothing; one that opens with a counter
    /// past the next is [`GAP`].
    pub fn open(&mut self, envelope: &[u8]) -> Result<Vec<u8>, Refused> {
        if envelope.len() < OVERHEAD || envelope.len() > MAX || envelope[1] != SEALED {
            return Err("that isn't a sealed envelope");
        }
        if envelope[0] != self.version {
            return Err("that envelope claims another version than the session's");
        }
        let counter = u64::from_be_bytes(envelope[2..10].try_into().expect("8 bytes"));
        if counter < self.next {
            return Err("that envelope was replayed or came out of order");
        }
        let mut body = envelope[10..].to_vec();
        let plain = self
            .key
            .open_in_place(nonce(counter), aead::Aad::from(&envelope[..10]), &mut body)
            .map_err(|_| "that envelope doesn't open: changed, or not this session's")?
            .len();
        if counter > self.next {
            return Err(GAP);
        }
        self.next = counter + 1;
        body.truncate(plain);
        Ok(body)
    }
}

/// Both directions of a session, and the welcome that starts it on the phone.
pub struct Session {
    pub welcome: Vec<u8>,
    pub sealer: Sealer,
    pub opener: Opener,
}

/// The traffic keys of a session: from both agreements, salted with the hello and the Mac's key.
fn traffic(hello: &[u8], mac_ephemeral: &[u8], es: &[u8; 32], ee: &[u8; 32]) -> [[u8; 32]; 3] {
    let salt = sha256(&[hello, mac_ephemeral]);
    let ikm = [&es[..], &ee[..]].concat();
    [WELCOME_INFO, PHONE_INFO, MAC_INFO].map(|info| derive(&salt, &ikm, info))
}

fn hello_key(mac: &[u8], phone_ephemeral: &[u8], es: &[u8; 32]) -> aead::LessSafeKey {
    sealing(&derive(&[mac, phone_ephemeral].concat(), es, HELLO_INFO))
}

/// The Mac's static X25519 key: its public half goes in the pairing QR.
pub struct MacKey {
    private: agreement::PrivateKey,
    public: [u8; 32],
}

impl MacKey {
    pub fn generate() -> Result<(MacKey, [u8; 32]), Refused> {
        let mut seed = [0u8; 32];
        getrandom::fill(&mut seed).map_err(|_| "no X25519 key could be made")?;
        Ok((MacKey::from_bytes(&seed)?, seed))
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<MacKey, Refused> {
        let private = x25519(bytes)?;
        let public = public_of(&private);
        Ok(MacKey { private, public })
    }

    pub fn public(&self) -> [u8; 32] {
        self.public
    }

    /// Opens a phone's hello and starts its session with a new key of the Mac's.
    pub fn welcome(&self, hello: &[u8]) -> Result<Session, Refused> {
        self.welcome_with(hello, &new_x25519()?)
    }

    fn welcome_with(
        &self,
        hello: &[u8],
        ephemeral: &agreement::PrivateKey,
    ) -> Result<Session, Refused> {
        if hello.len() <= 34 + 16 || hello.len() > 34 + 16 + OFFERS || hello[..2] != [1, HELLO] {
            return Err("that isn't a hello");
        }
        let phone = &hello[2..34];
        let es = agree(&self.private, phone)?;
        let mut offered = hello[34..].to_vec();
        let offered = hello_key(&self.public, phone, &es)
            .open_in_place(nonce(0), aead::Aad::from(&hello[..34]), &mut offered)
            .map_err(|_| "the hello doesn't open: sealed to another key, or changed")?;
        let version = offered
            .iter()
            .copied()
            .filter(|v| *v == VERSION)
            .max()
            .ok_or("the phone offers no envelope version this Mac speaks")?;
        let mine = public_of(ephemeral);
        let [welcome_key, phone_key, mac_key] =
            traffic(hello, &mine, &es, &agree(ephemeral, phone)?);
        let mut welcome = vec![version, WELCOME];
        welcome.extend_from_slice(&mine);
        let mut body = vec![version];
        sealing(&welcome_key)
            .seal_in_place_append_tag(nonce(0), aead::Aad::from(&welcome[..]), &mut body)
            .expect("one byte seals");
        welcome.extend_from_slice(&body);
        Ok(Session {
            welcome,
            sealer: Sealer {
                key: sealing(&mac_key),
                version,
                next: 0,
            },
            opener: Opener {
                key: sealing(&phone_key),
                version,
                next: 0,
            },
        })
    }
}

/// The phone's side of a session: what the iPhone does, and what obid's tests do in its place.
pub struct Phone {
    ephemeral: agreement::PrivateKey,
    es: [u8; 32],
    offered: Vec<u8>,
    pub hello: Vec<u8>,
}

impl Phone {
    /// A hello to the Mac whose public key is `mac` (from the QR), offering this version.
    pub fn hello(mac: &[u8]) -> Result<Phone, Refused> {
        let mut seed = [0u8; 32];
        getrandom::fill(&mut seed).map_err(|_| "no X25519 key could be made")?;
        Phone::hello_with(mac, &seed, &[VERSION])
    }

    /// The same with a key and versions of the caller's: known answers and refusals in tests.
    pub fn hello_with(mac: &[u8], ephemeral: &[u8], offered: &[u8]) -> Result<Phone, Refused> {
        let ephemeral = x25519(ephemeral)?;
        let mine = public_of(&ephemeral);
        let es = agree(&ephemeral, mac)?;
        let mut hello = vec![1, HELLO];
        hello.extend_from_slice(&mine);
        let mut body = offered.to_vec();
        hello_key(mac, &mine, &es)
            .seal_in_place_append_tag(nonce(0), aead::Aad::from(&hello[..]), &mut body)
            .expect("a few bytes seal");
        hello.extend_from_slice(&body);
        Ok(Phone {
            ephemeral,
            es,
            offered: offered.to_vec(),
            hello,
        })
    }

    /// The session, from the Mac's welcome: only the Mac with the pinned key could have made it.
    pub fn welcomed(self, welcome: &[u8]) -> Result<(Sealer, Opener), Refused> {
        if welcome.len() != 34 + 1 + 16 || welcome[1] != WELCOME {
            return Err("that isn't a welcome");
        }
        let version = welcome[0];
        if !self.offered.contains(&version) {
            return Err("the welcome chose a version the phone didn't offer");
        }
        let mac = &welcome[2..34];
        let [welcome_key, phone_key, mac_key] =
            traffic(&self.hello, mac, &self.es, &agree(&self.ephemeral, mac)?);
        let mut body = welcome[34..].to_vec();
        let said = sealing(&welcome_key)
            .open_in_place(nonce(0), aead::Aad::from(&welcome[..34]), &mut body)
            .map_err(|_| "the welcome doesn't open: not from the Mac whose key the QR pinned")?;
        if said != [version] {
            return Err("the welcome's version isn't its header's");
        }
        Ok((
            Sealer {
                key: sealing(&phone_key),
                version,
                next: 0,
            },
            Opener {
                key: sealing(&mac_key),
                version,
                next: 0,
            },
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(from: u8) -> Vec<u8> {
        (from..from + 32).collect()
    }

    /// The known answer in docs/runner-api.md ("The envelope's known answer"), which the iPhone's
    /// tests check with CryptoKit: the Mac's key is bytes 0 to 31, the phone's new key 32 to 63
    /// and the Mac's new key 64 to 95.
    const MAC_PUBLIC: &str = "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f";
    const HELLO_HEX: &str = concat!(
        "0101358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254a2b39ce6bc84",
        "67ffdd094cfa4ea2258b59",
    );
    const WELCOME_HEX: &str = concat!(
        "010279a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a0944396b30ca",
        "3b9834e5d232b1f803e05b",
    );
    const REQUEST_HEX: &str = concat!(
        "01030000000000000000f5727141453120bc5930b45fc6041dd63ff38849669a6597b32e0126a0a4",
        "7e5b8fe24aa92a12c8cb0b0d802d00b9b406da400b17143ce5eb2c2ec1d382aea99104e392778331",
        "0d114581bd85e058d1ebfe3852a2b3daf14baac186d5bb8a9459923c8d5f80fc14bc380ab04ace82",
        "4f10",
    );
    const ANSWER_HEX: &str = concat!(
        "010300000000000000000a35fcb1ed7cde7ec716ca66cb4bfe2f07395d39e87ad3465de5430d5685",
        "48a6ff91920033e8ba5f0286bafa8e7381285da738f3788c0b3889dd22cf8b188f542334f708ec77",
        "c3267f435ac2e4c58b4d64",
    );
    const BODY_HEX: &str = concat!(
        "0103000000000000000104872ef5d6738d2ec970fec24a408375a3ad546947fe63f62b4aac3868fe",
        "9137",
    );
    const END_HEX: &str = "010300000000000000020715d08c652dc9cad1f99f67006dbe715414875ed5";
    const REQUEST: &[u8] = br#"{"method":"GET","path":"/v1/status","headers":{"authorization":"Bearer test-device-token"}}"#;
    const ANSWER: &[u8] = br#"{"status":200,"headers":{"content-type":"application/json"}}"#;

    fn frame(stream: u32, kind: u8, payload: &[u8]) -> Vec<u8> {
        [&stream.to_be_bytes()[..], &[kind], payload].concat()
    }

    fn vector() -> (Session, Sealer, Opener) {
        let mac = MacKey::from_bytes(&bytes(0)).unwrap();
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION]).unwrap();
        let session = mac
            .welcome_with(&phone.hello, &x25519(&bytes(64)).unwrap())
            .unwrap();
        let (sealer, opener) = phone.welcomed(&session.welcome).unwrap();
        (session, sealer, opener)
    }

    #[test]
    fn the_envelope_gives_its_known_answers() {
        let mac = MacKey::from_bytes(&bytes(0)).unwrap();
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION]).unwrap();
        let (mut session, mut phone_sealer, mut phone_opener) = vector();
        let request = phone_sealer.seal(&frame(1, 0, REQUEST));
        let answer = session.sealer.seal(&frame(1, 0, ANSWER));
        let body = session.sealer.seal(&frame(1, 1, br#"{"ok":true}"#));
        let end = session.sealer.seal(&frame(1, 2, b""));
        let got = [
            hex::encode(mac.public()),
            hex::encode(&phone.hello),
            hex::encode(&session.welcome),
            hex::encode(&request),
            hex::encode(&answer),
            hex::encode(&body),
            hex::encode(&end),
        ];
        let known = [
            MAC_PUBLIC,
            HELLO_HEX,
            WELCOME_HEX,
            REQUEST_HEX,
            ANSWER_HEX,
            BODY_HEX,
            END_HEX,
        ];
        assert_eq!(got, known.map(str::to_owned));
        assert_eq!(session.opener.open(&request).unwrap(), frame(1, 0, REQUEST));
        assert_eq!(phone_opener.open(&answer).unwrap(), frame(1, 0, ANSWER));
        assert_eq!(
            phone_opener.open(&body).unwrap(),
            frame(1, 1, br#"{"ok":true}"#)
        );
        assert_eq!(phone_opener.open(&end).unwrap(), frame(1, 2, b""));
    }

    #[test]
    fn a_session_carries_frames_both_ways() {
        let (mac_key, _) = MacKey::generate().unwrap();
        let phone = Phone::hello(&mac_key.public()).unwrap();
        let mut mac = mac_key.welcome(&phone.hello).unwrap();
        let (mut sealer, mut opener) = phone.welcomed(&mac.welcome).unwrap();
        for n in 0..3u8 {
            let sent = sealer.seal(&[n; 40]);
            assert_eq!(mac.opener.open(&sent).unwrap(), vec![n; 40]);
            let back = mac.sealer.seal(&[n; 7]);
            assert_eq!(opener.open(&back).unwrap(), vec![n; 7]);
        }
    }

    #[test]
    fn a_changed_envelope_doesnt_open() {
        let (mut session, mut sealer, _) = vector();
        let sealed = sealer.seal(&frame(1, 0, REQUEST));
        // Every byte matters: the header and counter are the associated data, the rest the
        // ciphertext and its tag.
        for at in 0..sealed.len() {
            let mut changed = sealed.clone();
            changed[at] ^= 0x01;
            assert!(session.opener.open(&changed).is_err(), "byte {at}");
        }
        let mut cut = sealed.clone();
        cut.pop();
        assert!(session.opener.open(&cut).is_err());
        // None of those spent the counter: the real one still opens.
        assert!(session.opener.open(&sealed).is_ok());
        // Nor does a changed hello or welcome.
        let mac = MacKey::from_bytes(&bytes(0)).unwrap();
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION]).unwrap();
        for at in 0..phone.hello.len() {
            let mut changed = phone.hello.clone();
            changed[at] ^= 0x01;
            assert!(mac.welcome(&changed).is_err(), "hello byte {at}");
        }
        let welcome = mac.welcome(&phone.hello).unwrap().welcome;
        let mut changed = welcome.clone();
        changed[40] ^= 0x01;
        assert!(phone.welcomed(&changed).is_err());
    }

    #[test]
    fn a_replayed_or_older_envelope_doesnt_open() {
        let (mut session, mut sealer, _) = vector();
        let first = sealer.seal(b"first");
        let second = sealer.seal(b"second");
        assert!(session.opener.open(&first).is_ok());
        assert!(session.opener.open(&second).is_ok());
        // Either again: replayed or older, refused.
        assert!(session.opener.open(&first).is_err());
        assert!(session.opener.open(&second).is_err());
        // A Mac's envelope sent back to it opens under neither of its keys.
        let mac_said = session.sealer.seal(b"to the phone");
        assert!(session.opener.open(&mac_said).is_err());
        // A hello the Sphere replays starts a new session: the old envelopes don't open in it.
        let mac = MacKey::from_bytes(&bytes(0)).unwrap();
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION]).unwrap();
        let mut again = mac.welcome(&phone.hello).unwrap();
        assert!(again.opener.open(&first).is_err());
    }

    /// Only the next envelope goes: a later one that opens proves one is missing, and nothing
    /// was skipped silently.
    #[test]
    fn a_missing_envelope_ends_the_session() {
        let (mut session, mut sealer, _) = vector();
        let first = sealer.seal(b"first");
        let second = sealer.seal(b"second");
        assert_eq!(session.opener.open(&second).err(), Some(GAP));
        // A forged one past the next doesn't open, so it proves nothing.
        let mut forged = sealer.seal(b"third");
        forged[30] ^= 0x01;
        assert_ne!(session.opener.open(&forged).err(), Some(GAP));
        // Nothing was spent: the first is still the next one.
        assert!(session.opener.open(&first).is_ok());
        assert!(session.opener.open(&second).is_ok());
    }

    #[test]
    fn a_downgrade_is_refused() {
        let (mut session, mut sealer, _) = vector();
        // The version byte is the session's, and part of what the tag covers.
        let mut older = sealer.seal(b"hi");
        older[0] = 0;
        assert_eq!(
            session.opener.open(&older).err().unwrap(),
            "that envelope claims another version than the session's"
        );
        // A hello offering no version this Mac speaks starts nothing.
        let mac = MacKey::from_bytes(&bytes(0)).unwrap();
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[0, 2]).unwrap();
        assert_eq!(
            mac.welcome(&phone.hello).err().unwrap(),
            "the phone offers no envelope version this Mac speaks"
        );
        // A welcome whose version the Sphere changed: one the phone didn't offer is refused
        // as such, and one it did offer doesn't open, the header being sealed with it.
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION]).unwrap();
        let mut welcome = mac.welcome(&phone.hello).unwrap().welcome;
        welcome[0] = 2;
        assert_eq!(
            phone.welcomed(&welcome).err().unwrap(),
            "the welcome chose a version the phone didn't offer"
        );
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION, 2]).unwrap();
        let mut welcome = mac.welcome(&phone.hello).unwrap().welcome;
        welcome[0] = 2;
        assert!(phone.welcomed(&welcome).is_err());
    }

    #[test]
    fn only_the_pinned_key_opens_or_answers() {
        let mac = MacKey::from_bytes(&bytes(0)).unwrap();
        let other = MacKey::from_bytes(&bytes(100)).unwrap();
        // A hello sealed to another key doesn't open here.
        let to_other = Phone::hello_with(&other.public(), &bytes(32), &[VERSION]).unwrap();
        assert_eq!(
            mac.welcome(&to_other.hello).err().unwrap(),
            "the hello doesn't open: sealed to another key, or changed"
        );
        // Whoever answers without the pinned key (the Sphere in the middle, with a key of its
        // own) is refused: it can't open the phone's hello, so its welcome is for another one.
        let phone = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION]).unwrap();
        assert!(other.welcome(&phone.hello).is_err());
        let forged = other.welcome(&to_other.hello).unwrap().welcome;
        assert_eq!(
            phone.welcomed(&forged).err().unwrap(),
            "the welcome doesn't open: not from the Mac whose key the QR pinned"
        );
        // A key that isn't one (all zeros, a low-order point) agrees with nothing.
        assert!(Phone::hello_with(&[0u8; 32], &bytes(32), &[VERSION]).is_err());
        let mut hello = Phone::hello_with(&mac.public(), &bytes(32), &[VERSION])
            .unwrap()
            .hello;
        hello[2..34].fill(0);
        assert!(mac.welcome(&hello).is_err());
    }
}
