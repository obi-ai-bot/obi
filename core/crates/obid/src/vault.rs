//! The owner's vault (#457, ported from Engine/Vault.swift and Runner/VaultCommand.swift): secrets
//! the owner adds for connections they make, which obid uses in its own calls and never shows.
//!
//! - **Where** ([`Location`]). On a Mac whose obid runs in the Mac app's runner home, the Swift
//!   runner's own Keychain items (service `com.deskree.oby.runner.vault`), so the owner's secrets
//!   carry over; anywhere else `home/vault/secrets.json`, as the Swift runner's `FileVault` keeps
//!   them: a folder only obid's user may open (0700) holding a file only that user may read (0600).
//!   A folder or file anyone else may read, that someone else owns, or that is a link isn't read:
//!   the vault can't be read until it's fixed, and then nothing goes out. The configuration's
//!   `vault` can say either. `home` is what every job's and plug-in's sandbox hides
//!   (docs/ARCHITECTURE.md 5.3). No items, or no file, is an empty vault.
//! - **How values come in.** `obid vault --config <path> add NAME` with the value on stdin (typed
//!   without echo at a terminal), never as an argument or in an environment variable, where other
//!   processes of the same user read it (docs/ARCHITECTURE.md 5.3, "What the sandbox can't hide").
//!   A common word or a weak pattern is refused. No API takes or returns a value.
//! - **Where values go.** They join `crate::secrets::known()` as `vault <name>`, read again
//!   whenever the store changed (`obid vault add` while obid runs), so the log layer
//!   (`crate::logs`), the publish gate (`crate::scan`, `crate::publish`) and every text obid
//!   redacts take them out, plain and in every encoded form `crate::secrets` knows. obid's own
//!   calls read one with [`value`].
//! - **Answers.** Every `/v1` answer has them taken out (`[vault: <name>]`), and is `503` with the
//!   reason when the vault can't be read, after the request was carried out, so a stop always
//!   stops ([`answers`]; docs/runner-api.md, "No vault secret").
//! - **Agents.** [`for_agent`] and [`for_agent_bytes`] are what an agent may get, and fail when the
//!   vault can't be read.
//! - **Failing closed.** [`check`] says why the vault can't be read: the publish gate and the scan
//!   send nothing then. The log layer keeps redacting with the values it learned last.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes, HttpBody as _};
use axum::extract::Request;
use axum::http::{StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use futures_util::StreamExt as _;
use serde_json::Value;

use crate::secrets::Secrets;

/// The shortest value the vault takes: a shorter one would match ordinary text everywhere.
pub const SHORTEST: usize = crate::secrets::SHORTEST;
/// The longest value the vault takes.
pub const LONGEST: usize = 64 * 1024;

/// How often, at most, reading `known()` checks whether the vault changed. [`check`] always does.
const QUIET_EVERY: Duration = Duration::from_millis(250);

/// The vault's folder in obid's `home`.
pub fn folder(home: &Path) -> PathBuf {
    home.join("vault")
}

/// Why `name` can't name a secret, or none: letters, digits, `.`, `_` and `-`, so a name is safe
/// in a log line or a finding.
pub fn name_problem(name: &str) -> Option<&'static str> {
    let bytes = name.as_bytes();
    let fits = !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    (!fits).then_some("A secret's name is up to 64 letters, digits, dots, dashes or underscores.")
}

/// Why the vault won't keep `value`, or none. Besides its size: a common word or a weak pattern
/// (`postgres`, `changeme`, `00000000`) is refused, since every push holding it would be refused
/// and every answer would have it taken out (`image: postgres:16` in a compose file).
pub fn value_problem(value: &str) -> Option<String> {
    if value.len() < SHORTEST || value.trim().is_empty() {
        return Some(format!("A secret is at least {SHORTEST} characters."));
    }
    if value.len() > LONGEST {
        return Some("A secret is at most 64 KB.".to_owned());
    }
    weak(value).then(|| {
        "That value looks like a common word or a simple pattern, not a secret: every push holding it would be refused and every answer would have it taken out. Add the real secret.".to_owned()
    })
}

/// Words a value isn't, with or without digits and marks after it.
const COMMON: &[&str] = &[
    "password",
    "passwd",
    "changeme",
    "postgres",
    "postgresql",
    "mysql",
    "mariadb",
    "redis",
    "mongodb",
    "admin",
    "administrator",
    "root",
    "secret",
    "letmein",
    "welcome",
    "qwerty",
    "default",
    "example",
    "guest",
    "test",
    "testing",
    "localhost",
    "user",
    "username",
];

/// Whether `value` is a common word, a weak pattern, or too short a run of one kind of character
/// to be told apart from ordinary text: fewer than 6 different characters, a common word (with
/// digits or marks after it), or under 50 bits by its length and the kinds of characters in it.
fn weak(value: &str) -> bool {
    let distinct: std::collections::BTreeSet<char> = value.chars().collect();
    if distinct.len() < 6 {
        return true;
    }
    let lower = value.to_lowercase();
    let word = lower.trim_end_matches(|c: char| !c.is_alphabetic());
    if COMMON.contains(&word) {
        return true;
    }
    let mut alphabet = 0u32;
    if value.chars().any(|c| c.is_ascii_lowercase()) {
        alphabet += 26;
    }
    if value.chars().any(|c| c.is_ascii_uppercase()) {
        alphabet += 26;
    }
    if value.chars().any(|c| c.is_ascii_digit()) {
        alphabet += 10;
    }
    if value.chars().any(|c| !c.is_ascii_alphanumeric()) {
        alphabet += 33;
    }
    let bits = value.chars().count() as f64 * f64::from(alphabet).log2();
    bits < 50.0
}

/// `value` without the whitespace a paste puts around it (spaces, tabs, line breaks): a token
/// copied with a trailing space would otherwise never match what goes out.
fn trimmed(value: &str) -> &str {
    value.trim()
}

// ---------------------------------------------------------------------------------------------
// Where the vault is

/// The Keychain service the Swift runner's items are under on a Mac (Engine/Vault.swift,
/// `KeychainVault.runnerService`): obid uses the same items, so the owner's secrets carry over.
pub const RUNNER_SERVICE: &str = "com.deskree.oby.runner.vault";

/// Where the vault keeps its secrets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Location {
    /// `home/vault/secrets.json` (Engine/Vault.swift, `FileVault`).
    File,
    /// Generic passwords in the login Keychain under `service`, one per secret, the name as the
    /// account (Engine/Vault.swift, `KeychainVault`). macOS only.
    Keychain { service: String },
}

impl Location {
    /// Where the vault is when the configuration doesn't say: on a Mac whose obid runs in the Mac
    /// app's runner home (`~/Library/Application Support/Oby/Runner`, runner-api.md "The Mac app on
    /// the same Mac"), the Swift runner's Keychain items; anywhere else a file in `home`, so another
    /// obid on the same Mac (a test's, a second home) never reads or changes the owner's secrets.
    pub fn default_for(home: &Path) -> Location {
        let runner_home = nix::unistd::User::from_uid(nix::unistd::getuid())
            .ok()
            .flatten()
            .map(|user| user.dir.join("Library/Application Support/Oby/Runner"));
        if cfg!(target_os = "macos") && runner_home.as_deref() == Some(home) {
            Location::Keychain {
                service: RUNNER_SERVICE.into(),
            }
        } else {
            Location::File
        }
    }

    /// `vault` as the configuration writes it: `{"store": "file"}`, or `{"store": "keychain"}`
    /// with an optional `service` (the Swift runner's when left out).
    pub fn parse(store: &str, service: Option<&str>) -> Result<Location, String> {
        match (store, service) {
            ("file", None) => Ok(Location::File),
            ("file", Some(_)) => Err("a file vault takes no service.".into()),
            ("keychain", _) if !cfg!(target_os = "macos") => {
                Err("the Keychain is macOS's: on this machine the vault is a file (\"store\": \"file\").".into())
            }
            ("keychain", Some(service)) if service.trim().is_empty() => {
                Err("service is empty.".into())
            }
            ("keychain", service) => Ok(Location::Keychain {
                service: service.unwrap_or(RUNNER_SERVICE).to_owned(),
            }),
            _ => Err(format!("store is {store:?}: \"file\" or \"keychain\".")),
        }
    }

    fn store(&self, home: &Path) -> Box<dyn Store> {
        match self {
            Location::File => Box::new(FileStore::new(folder(home))),
            #[cfg(target_os = "macos")]
            Location::Keychain { service } => Box::new(keychain::KeychainStore::new(service)),
            #[cfg(not(target_os = "macos"))]
            Location::Keychain { .. } => Box::new(Unavailable),
        }
    }
}

/// Where a vault keeps its secrets (Engine/Vault.swift, `VaultStore`). Errors name the secret or
/// the place, never a value.
pub trait Store: Send + Sync {
    /// Changes whenever the secrets may have changed, here or elsewhere. Cheap: no value is read.
    /// Fails when the store can't be read as it is now.
    fn stamp(&self) -> Result<String, String>;
    /// Every secret; none when there's no vault yet.
    fn read(&self) -> Result<BTreeMap<String, String>, String>;
    /// One secret, or none.
    fn value(&self, name: &str) -> Result<Option<String>, String> {
        Ok(self.read()?.remove(name))
    }
    fn save(&self, value: &str, name: &str) -> Result<(), String>;
    /// Removes `name`; whether it was there.
    fn remove(&self, name: &str) -> Result<bool, String>;
    /// Tidies what an interrupted save left, when obid starts.
    fn tidy(&self) {}
}

/// A Keychain asked for where there's none: every read fails, so nothing goes out.
#[cfg(not(target_os = "macos"))]
struct Unavailable;

#[cfg(not(target_os = "macos"))]
impl Store for Unavailable {
    fn stamp(&self) -> Result<String, String> {
        Err("there's no Keychain on this machine.".into())
    }
    fn read(&self) -> Result<BTreeMap<String, String>, String> {
        self.stamp().map(|_| BTreeMap::new())
    }
    fn save(&self, _: &str, _: &str) -> Result<(), String> {
        self.stamp().map(|_| ())
    }
    fn remove(&self, _: &str) -> Result<bool, String> {
        self.stamp().map(|_| false)
    }
}

// ---------------------------------------------------------------------------------------------
// The file

/// `secrets.json` in a folder only obid's user may open (Engine/Vault.swift, `FileVault`). Errors
/// name the place, never a value. A save or a removal holds `.lock` in the folder (`flock`), so two
/// `obid vault add` runs at once each keep their secret.
pub struct FileStore {
    folder: PathBuf,
    /// One read-and-write at a time in this process.
    lock: Mutex<()>,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Saved {
    secrets: BTreeMap<String, String>,
}

impl FileStore {
    pub fn new(folder: PathBuf) -> FileStore {
        FileStore {
            folder,
            lock: Mutex::new(()),
        }
    }

    pub fn file(&self) -> PathBuf {
        self.folder.join("secrets.json")
    }

    fn read_unlocked(&self) -> Result<BTreeMap<String, String>, String> {
        if private(&self.folder, true)?.is_none() || private(&self.file(), false)?.is_none() {
            return Ok(BTreeMap::new());
        }
        let file = self.file();
        let bytes = read_no_follow(&file)
            .map_err(|e| format!("Can't read the vault at {} ({e}).", file.display()))?;
        serde_json::from_slice::<Saved>(&bytes)
            .map(|saved| saved.secrets)
            .map_err(|_| {
                format!(
                    "The vault at {} isn't what obid writes: move it aside, then add the secrets again with `obid vault --config <path> add NAME`.",
                    file.display()
                )
            })
    }

    /// `body` with the folder made (0700) and its `.lock` held: in this process and across
    /// processes. What an interrupted save left is removed first.
    fn locked<T>(&self, body: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        let _held = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let folder = &self.folder;
        if let Some(parent) = folder.parent() {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .map_err(|e| format!("Can't make {} ({e}).", parent.display()))?;
        }
        match std::fs::DirBuilder::new().mode(0o700).create(folder) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => {
                return Err(format!(
                    "Can't make the vault's folder {} ({e}).",
                    folder.display()
                ));
            }
        }
        private(folder, true)?;
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(folder.join(".lock"))
            .and_then(|lock| lock.lock().map(|()| lock))
            .map_err(|e| format!("Can't lock the vault in {} ({e}).", folder.display()))?;
        self.remove_leftovers();
        let done = body();
        drop(lock);
        done
    }

    /// The temporary files a save that was interrupted left (`.secrets-<uuid>.json`).
    fn remove_leftovers(&self) {
        let Ok(entries) = std::fs::read_dir(&self.folder) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with(".secrets-") && name.ends_with(".json") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }

    /// The file in place of the old one: created 0600 (and never through a link) before a byte
    /// is written, synced, renamed over it, and the folder synced so the rename lasts.
    fn write(&self, secrets: &BTreeMap<String, String>) -> Result<(), String> {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let folder = &self.folder;
        let data = serde_json::to_vec_pretty(&Saved {
            secrets: secrets.clone(),
        })
        .map_err(|e| format!("Can't write the vault ({e})."))?;
        let temporary = folder.join(format!(".secrets-{}.json", uuid::Uuid::new_v4()));
        let written = (|| -> std::io::Result<()> {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(nix::libc::O_NOFOLLOW)
                .open(&temporary)?;
            // Whatever the umask made of it, on the file obid holds open (fchmod).
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            file.write_all(&data)?;
            file.sync_all()?;
            std::fs::rename(&temporary, self.file())?;
            std::fs::File::open(folder)?.sync_all()
        })();
        written.map_err(|e| {
            let _ = std::fs::remove_file(&temporary);
            format!("Can't save the vault in {} ({e}).", folder.display())
        })
    }
}

impl Store for FileStore {
    /// The file's inode, size and time, after the same checks as reading it (each save is a new
    /// file), so a chmod that lets others read it fails even with the values learned. `none` with
    /// no vault yet.
    fn stamp(&self) -> Result<String, String> {
        use std::os::unix::fs::MetadataExt;
        if private(&self.folder, true)?.is_none() {
            return Ok("none".into());
        }
        let Some(info) = private(&self.file(), false)? else {
            return Ok("none".into());
        };
        Ok(format!(
            "{} {} {}.{}",
            info.ino(),
            info.size(),
            info.mtime(),
            info.mtime_nsec()
        ))
    }

    fn read(&self) -> Result<BTreeMap<String, String>, String> {
        let _held = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.read_unlocked()
    }

    fn save(&self, value: &str, name: &str) -> Result<(), String> {
        self.locked(|| {
            let mut secrets = self.read_unlocked()?;
            secrets.insert(name.to_owned(), value.to_owned());
            self.write(&secrets)
        })
    }

    fn remove(&self, name: &str) -> Result<bool, String> {
        if private(&self.folder, true)?.is_none() {
            return Ok(false);
        }
        self.locked(|| {
            let mut secrets = self.read_unlocked()?;
            if secrets.remove(name).is_none() {
                return Ok(false);
            }
            self.write(&secrets)?;
            Ok(true)
        })
    }

    fn tidy(&self) {
        if matches!(private(&self.folder, true), Ok(Some(_))) {
            let _ = self.locked(|| Ok(()));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The Keychain

/// The Mac's vault (Engine/Vault.swift, `KeychainVault`): generic passwords in the owner's login
/// Keychain under one service, one per secret, the secret's name as the account and `Oby vault:
/// <name>` as the label, as the Swift runner makes them, so its items and obid's are the same.
/// Listing reads the names and dates alone, never a value.
///
/// The login Keychain is named by its path, from the user database (`getpwuid`), in every search,
/// add, update and removal, never found through `$HOME`: an obid started with another `HOME` would
/// otherwise see no items at all, an empty vault, and take nothing out.
///
/// Measured on a Mac (2026-10-17): another program of the same user reads and updates these items
/// without being asked (macOS adds it to the item's access list), so against such a program the
/// Keychain holds them no better than the file does (#577); only the program that made an item may
/// delete it, and every new build of obid that reads one is added to its access list again.
#[cfg(target_os = "macos")]
mod keychain {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use core_foundation::base::TCFType as _;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFMutableDictionary;
    use core_foundation::string::CFString;
    use security_framework::item::{
        ItemAddOptions, ItemAddValue, ItemClass, ItemSearchOptions, ItemUpdateOptions,
        ItemUpdateValue, Limit, Location, SearchResult,
    };
    use security_framework::os::macos::keychain::SecKeychain;

    use super::Store;

    /// errSecItemNotFound.
    const NOT_FOUND: i32 = -25300;
    /// errSecInvalidOwnerEdit: another program made the item, and only it may delete it.
    const NOT_OURS: i32 = -25244;

    pub struct KeychainStore {
        service: String,
    }

    impl KeychainStore {
        pub fn new(service: &str) -> KeychainStore {
            KeychainStore {
                service: service.to_owned(),
            }
        }

        /// The owner's login Keychain, by its path.
        fn login(&self) -> Result<SecKeychain, String> {
            let path: PathBuf = nix::unistd::User::from_uid(nix::unistd::getuid())
                .ok()
                .flatten()
                .map(|user| user.dir.join("Library/Keychains/login.keychain-db"))
                .ok_or(
                    "obid can't find its user's home folder, so it can't find the login Keychain.",
                )?;
            if !path.is_file() {
                return Err(format!("There's no login Keychain at {}.", path.display()));
            }
            SecKeychain::open(&path)
                .map_err(|e| format!("Can't open the login Keychain at {} ({e}).", path.display()))
        }

        /// A search for this vault's items (one, with `account`), in the login Keychain only.
        fn search(&self, account: Option<&str>) -> Result<ItemSearchOptions, String> {
            let mut search = ItemSearchOptions::new();
            search
                .class(ItemClass::generic_password())
                .service(&self.service)
                .keychains(&[self.login()?]);
            if let Some(account) = account {
                search.account(account);
            }
            Ok(search)
        }

        /// Every item's attributes (`acct` its name, `mdat` when it last changed), never its data.
        fn items(&self, account: Option<&str>) -> Result<Vec<BTreeMap<String, String>>, String> {
            let mut search = self.search(account)?;
            search.load_attributes(true).limit(Limit::All);
            match search.search() {
                Ok(found) => Ok(found
                    .iter()
                    .filter_map(SearchResult::simplify_dict)
                    .map(|item| item.into_iter().collect())
                    .collect()),
                Err(e) if e.code() == NOT_FOUND => Ok(Vec::new()),
                Err(e) => Err(format!(
                    "Couldn't list the vault in the Keychain ({}: {e}): unlock the login Keychain, or allow obid in Keychain Access.",
                    self.service
                )),
            }
        }
    }

    impl Store for KeychainStore {
        /// Each item's name and when it last changed: Keychain Access, `security` or the Swift
        /// runner can change one outside obid.
        fn stamp(&self) -> Result<String, String> {
            let mut lines: Vec<String> = self
                .items(None)?
                .iter()
                .map(|item| {
                    format!(
                        "{} {}",
                        item.get("acct").map_or("?", String::as_str),
                        item.get("mdat").map_or("", String::as_str)
                    )
                })
                .collect();
            lines.sort();
            Ok(lines.join("\n"))
        }

        fn read(&self) -> Result<BTreeMap<String, String>, String> {
            let mut secrets = BTreeMap::new();
            for item in self.items(None)? {
                let Some(name) = item.get("acct") else {
                    continue;
                };
                if let Some(value) = self.value(name)? {
                    secrets.insert(name.clone(), value);
                }
            }
            Ok(secrets)
        }

        fn value(&self, name: &str) -> Result<Option<String>, String> {
            let mut search = self.search(Some(name))?;
            search.load_data(true).limit(1);
            match search.search() {
                Ok(found) => Ok(found.into_iter().find_map(|item| match item {
                    SearchResult::Data(bytes) => Some(String::from_utf8_lossy(&bytes).into_owned()),
                    _ => None,
                })),
                Err(e) if e.code() == NOT_FOUND => Ok(None),
                Err(e) => Err(format!(
                    "Couldn't read {name} in the Keychain ({e}): unlock the login Keychain, or allow obid in Keychain Access."
                )),
            }
        }

        /// An item already there gets the new value and keeps its attributes; a new one is made
        /// with the Swift runner's label and accessibility.
        fn save(&self, value: &str, name: &str) -> Result<(), String> {
            let data = CFData::from_buffer(value.as_bytes());
            let saved = if self.items(Some(name))?.is_empty() {
                let mut add = ItemAddOptions::new(ItemAddValue::Data {
                    class: ItemClass::generic_password(),
                    data,
                });
                add.set_service(&self.service)
                    .set_account_name(name)
                    .set_label(format!("Oby vault: {name}"))
                    .set_location(Location::FileKeychain(self.login()?));
                // kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, as the Swift
                // runner sets it ("pdmn" and "aku" are those constants' values). ItemAddOptions
                // can't carry it, so its query is added to by hand (the deprecated way in).
                let accessible = CFString::from_static_string("pdmn");
                let when_unlocked = CFString::from_static_string("aku");
                #[allow(deprecated)]
                let mut query = CFMutableDictionary::from(&add.to_dictionary());
                query.set(accessible.as_CFTypeRef(), when_unlocked.as_CFTypeRef());
                #[allow(deprecated)]
                security_framework::item::add_item(query.to_immutable())
            } else {
                let mut update = ItemUpdateOptions::new();
                update.set_value(ItemUpdateValue::Data(data));
                security_framework::item::update_item(&self.search(Some(name))?, &update)
            };
            saved.map_err(|e| format!("Couldn't save {name} in the Keychain ({e})."))
        }

        fn remove(&self, name: &str) -> Result<bool, String> {
            if self.items(Some(name))?.is_empty() {
                return Ok(false);
            }
            match self.search(Some(name))?.delete() {
                Ok(()) => Ok(true),
                Err(e) if e.code() == NOT_FOUND => Ok(false),
                Err(e) if e.code() == NOT_OURS => Err(format!(
                    "{name} was added to the Keychain by another program (Oby's runner): only it may remove it, so remove it there, or in Keychain Access."
                )),
                Err(e) => Err(format!("Couldn't remove {name} from the Keychain ({e}).")),
            }
        }
    }
}

/// The file's bytes, refusing a link in its place.
fn read_no_follow(path: &Path) -> std::io::Result<Vec<u8>> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW)
        .open(path)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// What `lstat` says of `path` when it's there and only obid's user may read it; none when it
/// isn't there. Refuses a link or the wrong kind of thing, one someone else owns, and one anyone
/// else may read.
fn private(path: &Path, directory: bool) -> Result<Option<std::fs::Metadata>, String> {
    use std::os::unix::fs::MetadataExt;
    let info = match std::fs::symlink_metadata(path) {
        Ok(info) => info,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(format!("Can't read the vault at {} ({e}).", path.display()));
        }
    };
    let kind = info.file_type();
    if (directory && !kind.is_dir()) || (!directory && !kind.is_file()) {
        return Err(format!(
            "The vault's {} isn't a {}: put the real {} there, not a link.",
            path.display(),
            if directory { "folder" } else { "file" },
            if directory { "folder" } else { "file" }
        ));
    }
    if info.uid() != nix::unistd::geteuid().as_raw() {
        return Err(format!(
            "The vault's {} belongs to another user: only obid's user may own it (chown it to that user).",
            path.display()
        ));
    }
    let mode = info.mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(format!(
            "Others may read the vault's {} (mode {mode:o}): run chmod {} on it.",
            path.display(),
            if directory { "700" } else { "600" }
        ));
    }
    Ok(Some(info))
}

// ---------------------------------------------------------------------------------------------
// The vault

/// The vault: its store, the values it learned (into its own set, whose markers read
/// `[vault: <name>]`, and into the set obid's log and publish gate read), and the store's stamp
/// when it learned them.
pub struct Vault {
    store: Box<dyn Store>,
    known: Arc<Secrets>,
    secrets: Secrets,
    learned: Mutex<Learned>,
}

#[derive(Default)]
struct Learned {
    /// The store's stamp when the values were read from it; none until then and after a change here.
    stamp: Option<String>,
    names: BTreeSet<String>,
    checked: Option<Instant>,
}

/// The name a vault secret has in `known()`: apart from obid's own secrets (`api-token`, …).
fn known_name(name: &str) -> String {
    format!("vault {name}")
}

impl Vault {
    /// The vault in `store`, whose values join `known`.
    pub fn new(store: Box<dyn Store>, known: Arc<Secrets>) -> Vault {
        Vault {
            store,
            known,
            secrets: Secrets::labelled("vault"),
            learned: Mutex::new(Learned::default()),
        }
    }

    /// The vault in `folder/secrets.json`, whose values join `known`.
    pub fn file(folder: PathBuf, known: Arc<Secrets>) -> Vault {
        Vault::new(Box::new(FileStore::new(folder)), known)
    }

    /// The value of the secret `name`, read from the store as it is now, after the same check
    /// every reader gets: fails when the vault can't be read, and is none when it has no such
    /// secret. Its value is in `known()` already, as `vault <name>`.
    pub fn value(&self, name: &str) -> Result<Option<String>, String> {
        self.check()?;
        self.store.value(name)
    }

    /// The secrets' names, sorted. Never their values.
    pub fn names(&self) -> Result<Vec<String>, String> {
        Ok(self.store.read()?.into_keys().collect())
    }

    /// Adds `value` as `name`, or replaces it. Line breaks around it (a paste) are dropped. Errors
    /// name the secret, never the value.
    pub fn add(&self, value: &str, name: &str) -> Result<(), String> {
        let value = trimmed(value);
        if let Some(problem) = name_problem(name) {
            return Err(problem.into());
        }
        if let Some(problem) = value_problem(value) {
            return Err(problem);
        }
        let mut learned = self.learned.lock().unwrap_or_else(|e| e.into_inner());
        self.store.save(value, name)?;
        self.known.learn(&known_name(name), value);
        self.secrets.learn(name, value);
        learned.names.insert(name.to_owned());
        learned.stamp = None;
        Ok(())
    }

    /// Removes `name`; whether the vault had it.
    pub fn remove(&self, name: &str) -> Result<bool, String> {
        if let Some(problem) = name_problem(name) {
            return Err(problem.into());
        }
        let mut learned = self.learned.lock().unwrap_or_else(|e| e.into_inner());
        let had = self.store.remove(name)?;
        self.known.forget(&known_name(name));
        self.secrets.forget(name);
        learned.names.remove(name);
        learned.stamp = None;
        Ok(had)
    }

    /// Reads the vault again when its file changed, and says why it can't be read. Then the
    /// values learned before stay learned (a log line is still redacted with them), and whatever
    /// asked sends nothing.
    pub fn check(&self) -> Result<(), String> {
        let mut learned = self.learned.lock().unwrap_or_else(|e| e.into_inner());
        learned.checked = Some(Instant::now());
        let stamp = self.store.stamp()?;
        if learned.stamp.as_deref() == Some(stamp.as_str()) {
            return Ok(());
        }
        let values = self.store.read()?;
        for gone in learned.names.iter().filter(|n| !values.contains_key(*n)) {
            self.known.forget(&known_name(gone));
            self.secrets.forget(gone);
        }
        for (name, value) in &values {
            self.known.learn(&known_name(name), value);
            self.secrets.learn(name, value);
        }
        learned.names = values.into_keys().collect();
        learned.stamp = Some(stamp);
        Ok(())
    }

    /// [`Vault::check`] at most every [`QUIET_EVERY`], saying nothing: what reading `known()` does.
    fn check_quietly(&self) {
        let due = self
            .learned
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .checked
            .is_none_or(|at| at.elapsed() >= QUIET_EVERY);
        if due {
            let _ = self.check();
        }
    }

    /// `text` with the vault's secrets, plain or encoded, taken out (`[vault: <name>]`); when one
    /// still hides in it some other way, the whole text is the marker. Fails when the vault can't
    /// be read.
    pub fn redact(&self, text: &str) -> Result<String, String> {
        self.check()?;
        Ok(self.redact_checked(text))
    }

    fn redact_checked(&self, text: &str) -> String {
        let clean = self.secrets.redact(text);
        let left = self.secrets.names_in(&clean);
        if left.is_empty() {
            clean
        } else {
            self.secrets.marker(&left)
        }
    }

    /// JSON as it may leave obid: every string in it, keys too, with the vault's secrets taken
    /// out. None when nothing changed, so a clean answer goes as it was, byte for byte. Text that
    /// isn't JSON is redacted as text. Fails when the vault can't be read.
    pub fn scrubbed(&self, bytes: &[u8]) -> Result<Option<Vec<u8>>, String> {
        self.check()?;
        Ok(self.scrubbed_checked(bytes))
    }

    fn scrubbed_checked(&self, bytes: &[u8]) -> Option<Vec<u8>> {
        if self.secrets.is_empty() {
            return None;
        }
        if let Ok(mut value) = serde_json::from_slice::<Value>(bytes) {
            return self
                .scrub(&mut value)
                .then(|| serde_json::to_vec(&value).unwrap_or_default());
        }
        let text = String::from_utf8_lossy(bytes);
        let clean = self.redact_checked(&text);
        (clean != text).then(|| clean.into_bytes())
    }

    /// Whether anything in `value` changed.
    fn scrub(&self, value: &mut Value) -> bool {
        match value {
            Value::String(text) => {
                let clean = self.redact_checked(text);
                let changed = clean != *text;
                *text = clean;
                changed
            }
            Value::Array(items) => items
                .iter_mut()
                .fold(false, |changed, item| self.scrub(item) | changed),
            Value::Object(fields) => {
                let mut changed = false;
                let taken = std::mem::take(fields);
                for (key, mut item) in taken {
                    changed |= self.scrub(&mut item);
                    let clean = self.redact_checked(&key);
                    changed |= clean != key;
                    fields.insert(clean, item);
                }
                changed
            }
            _ => false,
        }
    }

    /// One frame of an event stream (`event:`, `data:`, comments), each `data:` line's JSON
    /// scrubbed as [`Vault::scrubbed`] does and every other line redacted.
    fn scrubbed_events(&self, frame: &[u8]) -> Option<Vec<u8>> {
        if self.secrets.is_empty() {
            return None;
        }
        let text = String::from_utf8_lossy(frame);
        let clean: Vec<String> = text
            .split('\n')
            .map(|line| match line.strip_prefix("data:") {
                Some(data) => {
                    let (space, payload) = data.strip_prefix(' ').map_or(("", data), |p| (" ", p));
                    let payload = match self.scrubbed_checked(payload.as_bytes()) {
                        Some(clean) => String::from_utf8_lossy(&clean).into_owned(),
                        None => payload.to_owned(),
                    };
                    format!("data:{space}{payload}")
                }
                None => self.redact_checked(line),
            })
            .collect();
        let clean = clean.join("\n");
        (clean != text).then(|| clean.into_bytes())
    }
}

// ---------------------------------------------------------------------------------------------
// obid's vault

static SHARED: RwLock<Option<Arc<Vault>>> = RwLock::new(None);

/// Opens the vault in `home/vault` as obid's, learns what it holds into `known()`, and has
/// `known()` read it again whenever it changed. Said in the log when it can't be read: then every
/// `/v1` answer is `503` and nothing is published until it's fixed.
pub fn install(home: &Path, location: &Location) -> Arc<Vault> {
    let known = crate::secrets::known();
    let store = location.store(home);
    store.tidy();
    let vault = Arc::new(Vault::new(store, known.clone()));
    let weak = Arc::downgrade(&vault);
    known.refresh_with(Arc::new(move || {
        if let Some(vault) = weak.upgrade() {
            vault.check_quietly();
        }
    }));
    *SHARED.write().unwrap_or_else(|e| e.into_inner()) = Some(vault.clone());
    if let Err(why) = vault.check() {
        tracing::warn!(
            "the vault can't be read, so obid answers 503 and publishes nothing until it's fixed: {why}"
        );
    }
    vault
}

/// obid's vault, once [`install`]ed.
pub fn shared() -> Option<Arc<Vault>> {
    SHARED.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// The value of obid's vault secret `name`, for obid's own call on a connection the owner made
/// (Engine/Vault.swift, `Vault.use`): what connections (#444) read a secret through. It is read
/// from the store as it is now, after the same check as every other reader, so it fails (`the
/// vault can't be read: …`) whenever an answer would be `503` and a publish would send nothing; it
/// is none when the vault has no such secret, or no vault is installed. The value is already in
/// `crate::secrets::known()` as `vault <name>`, so the log, the scan and every redaction take it
/// out: don't learn it again under another name. Never put it in a log line, an answer, an
/// argument or an environment.
pub fn value(name: &str) -> Result<Option<String>, String> {
    match shared() {
        Some(vault) => vault
            .value(name)
            .map_err(|why| format!("the vault can't be read: {why}")),
        None => Ok(None),
    }
}

/// Why obid's vault can't be read, as the scan says it (`the vault can't be read: …`), or nothing.
/// Without a vault installed there's nothing to look for.
pub fn check() -> Result<(), String> {
    match shared() {
        Some(vault) => vault
            .check()
            .map_err(|why| format!("the vault can't be read: {why}")),
        None => Ok(()),
    }
}

/// `text` as an agent may get it: the vault's secrets, plain or encoded, taken out. Fails, saying
/// why, when the vault can't be read: then nothing goes to an agent.
pub fn for_agent(text: &str) -> Result<String, String> {
    match shared() {
        Some(vault) => vault
            .redact(text)
            .map_err(|why| unreadable_for_agents(&why)),
        None => Ok(text.to_owned()),
    }
}

/// A file's bytes as an agent may get them (`.obi/inputs/`): JSON with every string scrubbed,
/// other text redacted, the vault's secrets taken out either way. Fails like [`for_agent`] when
/// the vault can't be read.
pub fn for_agent_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    match shared() {
        Some(vault) => vault
            .scrubbed(bytes)
            .map(|clean| clean.unwrap_or_else(|| bytes.to_vec()))
            .map_err(|why| unreadable_for_agents(&why)),
        None => Ok(bytes.to_vec()),
    }
}

fn unreadable_for_agents(why: &str) -> String {
    format!(
        "The vault can't be read, so obid gave the agent nothing: {why} Once it's fixed, tell the job to go on."
    )
}

/// Every `/v1` answer, after the gate let the request in (docs/runner-api.md, "No vault secret"):
/// the request is always carried out first, so a stop, a stop-all or a permission's answer takes
/// effect whatever the vault (Runner/API.swift does the same); then its answer is `503` with the
/// reason when the vault can't be read, and otherwise every string of a JSON answer,
/// and every other text answer, with the vault's secrets taken out. An answer with a length is
/// scrubbed whole; a streamed one (the event stream, `/wait`) a frame at a time, and it ends at the
/// first frame the vault can't be read for. Files that aren't text (a check's bundle) go as they
/// are, and so do the web app's files under `/app/`, which hold no data.
pub async fn answers(request: Request, next: Next) -> Response {
    if !request.uri().path().starts_with("/v1/") {
        return next.run(request).await;
    }
    let Some(vault) = shared() else {
        return next.run(request).await;
    };
    let response = next.run(request).await;
    if let Err(why) = vault.check() {
        return unreadable(&why);
    }
    let kind = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    let events = kind.starts_with("text/event-stream");
    let text = kind.is_empty()
        || kind.starts_with("application/json")
        || kind.starts_with("text/")
        || kind.contains("+json");
    if !text {
        return response;
    }
    let (mut parts, body) = response.into_parts();
    if !events && body.size_hint().exact().is_some() {
        let bytes = match axum::body::to_bytes(body, usize::MAX).await {
            Ok(bytes) => bytes,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
        return match vault.scrubbed(&bytes) {
            Ok(None) => Response::from_parts(parts, Body::from(bytes)),
            Ok(Some(clean)) => {
                parts.headers.remove(header::CONTENT_LENGTH);
                Response::from_parts(parts, Body::from(clean))
            }
            Err(why) => unreadable(&why),
        };
    }
    parts.headers.remove(header::CONTENT_LENGTH);
    let frames = body
        .into_data_stream()
        .map(move |frame| match frame {
            Ok(bytes) => {
                vault.check().ok()?;
                let clean = if events {
                    vault.scrubbed_events(&bytes)
                } else {
                    vault.scrubbed_checked(&bytes)
                };
                Some(Ok(clean.map_or(bytes, Bytes::from)))
            }
            Err(e) => Some(Err(e)),
        })
        .take_while(|frame| std::future::ready(frame.is_some()))
        .filter_map(std::future::ready);
    Response::from_parts(parts, Body::from_stream(frames))
}

fn unreadable(why: &str) -> Response {
    crate::api::ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        format!("The vault can't be read, so obid answers nothing until it's fixed: {why}"),
    )
    .into_response()
}

// ---------------------------------------------------------------------------------------------
// `obid vault`

/// What `obid vault --config <path> …` does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    List,
    Add(String),
    Remove(String),
}

pub const USAGE: &str = "usage: obid vault --config /path/to/config.json list | add NAME (the value on stdin) | remove NAME";

impl Action {
    /// What follows `vault --config <path>`. A value is never an argument: `add NAME VALUE` is
    /// refused (other processes see arguments).
    pub fn parse(args: &[String]) -> Result<Action, String> {
        match args {
            [list] if list == "list" => Ok(Action::List),
            [add, name] if add == "add" => Ok(Action::Add(name.clone())),
            [remove, name] if remove == "remove" => Ok(Action::Remove(name.clone())),
            _ => Err(USAGE.into()),
        }
    }
}

/// Runs `action` on the vault in `home/vault` and returns the exit status (Runner/VaultCommand.swift).
/// `read` gives the value for `add`; `say` and `fail` print to stdout and stderr. Nothing printed
/// holds a value.
pub fn run(
    home: &Path,
    location: &Location,
    action: &Action,
    read: impl FnOnce() -> Option<String>,
    mut say: impl FnMut(&str),
    mut fail: impl FnMut(&str),
) -> u8 {
    let vault = Vault::new(location.store(home), Arc::new(Secrets::default()));
    let done = match action {
        Action::List => vault.names().map(|names| names.iter().for_each(|n| say(n))),
        Action::Add(name) => {
            if let Some(problem) = name_problem(name) {
                fail(problem);
                return 1;
            }
            let Some(value) = read() else {
                fail("No value on stdin.");
                return 1;
            };
            vault
                .add(&value, name)
                .map(|()| say(&format!("Saved {name}.")))
        }
        Action::Remove(name) => vault.remove(name).map(|had| {
            say(&if had {
                format!("Removed {name}.")
            } else {
                format!("The vault has no secret named {name}.")
            })
        }),
    };
    match done {
        Ok(()) => 0,
        Err(why) => {
            fail(&why);
            1
        }
    }
}

/// The value from stdin: typed without echo at a terminal, else everything piped in (up to a
/// little more than the longest value, so a bigger one is refused as too big).
pub fn read_value() -> Option<String> {
    use std::io::IsTerminal;
    let stdin = std::io::stdin();
    if !stdin.is_terminal() {
        let mut bytes = Vec::new();
        stdin
            .lock()
            .take(LONGEST as u64 + 16)
            .read_to_end(&mut bytes)
            .ok()?;
        return (!bytes.is_empty()).then(|| String::from_utf8_lossy(&bytes).into_owned());
    }
    use nix::sys::termios;
    eprintln!("Value (not shown), then Return:");
    use nix::sys::signal::{SigSet, Signal};
    let saved = termios::tcgetattr(&stdin).ok()?;
    let mut quiet = saved.clone();
    quiet.local_flags.remove(termios::LocalFlags::ECHO);
    // Ctrl-C (or a hang-up or a stop) while the value is typed: echo comes back before obid ends.
    // The signals wait for a thread of their own (sigwait), which puts the terminal back.
    let mut stops = SigSet::empty();
    for signal in [
        Signal::SIGINT,
        Signal::SIGTERM,
        Signal::SIGHUP,
        Signal::SIGQUIT,
    ] {
        stops.add(signal);
    }
    stops.thread_block().ok()?;
    {
        let saved = saved.clone();
        std::thread::spawn(move || {
            if stops.wait().is_ok() {
                let _ = termios::tcsetattr(std::io::stdin(), termios::SetArg::TCSANOW, &saved);
                eprintln!();
                std::process::exit(130);
            }
        });
    }
    termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, &quiet).ok()?;
    let mut line = String::new();
    let read = std::io::BufRead::read_line(&mut stdin.lock(), &mut line);
    let _ = termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, &saved);
    eprintln!();
    read.ok()?;
    let line = line.trim_end_matches(['\n', '\r']);
    (!line.is_empty()).then(|| line.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    /// Characters every encoding treats differently: `/`, `+`, `=`, `?`, `&`, a space and a
    /// non-ASCII one (VaultTests' `secret()`).
    fn secret() -> String {
        format!(
            "tok/{}+a=b?c&d é",
            &uuid::Uuid::new_v4().simple().to_string()[..12]
        )
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Scratch {
            let path = std::env::temp_dir().join(format!("obid-vault-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&path).unwrap();
            Scratch(path)
        }

        fn vault(&self) -> (Vault, Arc<Secrets>) {
            let known = Arc::new(Secrets::default());
            (Vault::file(self.0.join("vault"), known.clone()), known)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn b64(bytes: &[u8]) -> String {
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes)
    }

    /// Every encoded copy of `value` the redaction must catch (VaultTests' `copies(of:)`).
    fn copies(value: &str) -> Vec<(&'static str, String)> {
        let unreserved = |form: bool| -> String {
            value
                .bytes()
                .map(|b| match b {
                    b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                        (b as char).to_string()
                    }
                    b' ' if form => "+".into(),
                    _ => format!("%{b:02X}"),
                })
                .collect()
        };
        let percent: String = value.bytes().map(|b| format!("%{b:02X}")).collect();
        vec![
            ("", value.to_owned()),
            ("base64", b64(value.as_bytes())),
            (
                "base64",
                base64::Engine::encode(
                    &base64::engine::general_purpose::URL_SAFE_NO_PAD,
                    value.as_bytes(),
                ),
            ),
            ("base64", b64(format!("x{value}tail").as_bytes())),
            ("base64", b64(format!("xy{value}").as_bytes())),
            ("base64", b64(format!("TOKEN={value}\n").as_bytes())),
            ("hex", hex::encode(value)),
            ("hex", hex::encode(value).to_ascii_uppercase()),
            ("URL-encoded", unreserved(false)),
            ("URL-encoded", percent.clone()),
            ("URL-encoded", percent.to_ascii_lowercase()),
            ("URL-encoded", unreserved(true)),
        ]
    }

    /// The Swift runner's Keychain items when obid runs in the Mac app's runner home; a file in
    /// `home` anywhere else, unless the configuration says.
    #[test]
    fn where_the_vault_is() {
        let user = nix::unistd::User::from_uid(nix::unistd::getuid())
            .unwrap()
            .unwrap();
        let runner_home = user.dir.join("Library/Application Support/Oby/Runner");
        let expected = if cfg!(target_os = "macos") {
            Location::Keychain {
                service: RUNNER_SERVICE.into(),
            }
        } else {
            Location::File
        };
        assert_eq!(Location::default_for(&runner_home), expected);
        assert_eq!(
            Location::default_for(Path::new("/tmp/obid-home")),
            Location::File
        );
        assert_eq!(Location::parse("file", None), Ok(Location::File));
        assert!(Location::parse("file", Some("x")).is_err());
        assert!(Location::parse("cloud", None).is_err());
        if cfg!(target_os = "macos") {
            assert_eq!(Location::parse("keychain", None), Ok(expected));
            assert_eq!(
                Location::parse("keychain", Some("com.example.test")),
                Ok(Location::Keychain {
                    service: "com.example.test".into()
                })
            );
            assert!(Location::parse("keychain", Some(" ")).is_err());
        } else {
            assert!(Location::parse("keychain", None).is_err());
        }
    }

    #[test]
    fn the_file_is_readable_only_by_obids_user() {
        let scratch = Scratch::new();
        let (vault, _) = scratch.vault();
        vault.add(&secret(), "staging-api-key").unwrap();
        let folder = std::fs::metadata(scratch.0.join("vault")).unwrap();
        let file = std::fs::metadata(scratch.0.join("vault/secrets.json")).unwrap();
        assert_eq!(folder.mode() & 0o777, 0o700);
        assert_eq!(file.mode() & 0o777, 0o600);
        // No temporary file is left behind.
        let mut left: Vec<_> = std::fs::read_dir(scratch.0.join("vault"))
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        left.sort();
        assert_eq!(left, [".lock", "secrets.json"]);
        assert_eq!(vault.names().unwrap(), ["staging-api-key"]);
    }

    #[test]
    fn a_vault_others_can_read_isnt_read() {
        let scratch = Scratch::new();
        let (vault, known) = scratch.vault();
        let value = secret();
        vault.add(&value, "staging-api-key").unwrap();
        vault.check().unwrap();
        let file = scratch.0.join("vault/secrets.json");
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        let why = vault.check().unwrap_err();
        assert!(why.contains("Others may read"), "{why}");
        assert!(!why.contains(&value), "{why}");
        assert!(vault.redact("x").is_err());
        assert!(vault.scrubbed(b"{}").is_err());
        // What was learned stays learned, for the log.
        assert_eq!(
            known.redact(&value),
            "[redacted: vault staging-api-key]",
            "{value}"
        );
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::set_permissions(
            scratch.0.join("vault"),
            std::fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        assert!(vault.check().unwrap_err().contains("run chmod 700"));
        std::fs::set_permissions(
            scratch.0.join("vault"),
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        vault.check().unwrap();
        // A link in the file's place isn't followed.
        let elsewhere = scratch.0.join("elsewhere.json");
        std::fs::rename(&file, &elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &file).unwrap();
        assert!(vault.check().unwrap_err().contains("isn't a file"));
        assert!(vault.add(&secret(), "other").is_err());
    }

    /// No vault yet is an empty vault, which everything reads; a damaged file is one that can't be
    /// read, and says what to do.
    #[test]
    fn a_missing_vault_is_empty_and_a_damaged_one_cant_be_read() {
        let scratch = Scratch::new();
        let (vault, known) = scratch.vault();
        vault.check().unwrap();
        assert_eq!(vault.redact("any text at all").unwrap(), "any text at all");
        assert_eq!(vault.scrubbed(br#"{"a":"b"}"#).unwrap(), None);
        assert!(vault.names().unwrap().is_empty());
        assert!(known.is_empty());
        assert!(!scratch.0.join("vault").exists());
        vault.add("long-enough-value", "fine").unwrap();
        std::fs::write(scratch.0.join("vault/secrets.json"), "not the vault").unwrap();
        let why = vault.check().unwrap_err();
        assert!(
            why.ends_with("isn't what obid writes: move it aside, then add the secrets again with `obid vault --config <path> add NAME`."),
            "{why}"
        );
        assert!(vault.redact("x").is_err());
    }

    #[test]
    fn names_and_values_are_checked() {
        let scratch = Scratch::new();
        let (vault, _) = scratch.vault();
        for name in ["", "-lead", "has space", "a/b", "é", &"x".repeat(65)] {
            assert!(vault.add("long-enough-value", name).is_err(), "{name:?}");
        }
        for value in ["short", "        ", "\n\n\n\n\n\n\n\n\n"] {
            assert!(vault.add(value, "fine").is_err(), "{value:?}");
        }
        // A common word or a weak pattern isn't a secret.
        for value in [
            "postgres",
            "Password123!",
            "changeme",
            "00000000",
            "12345678",
            "abababababababab",
            "letmein2024",
            "qwertyuiop",
            "abcdefgh",
        ] {
            let why = vault.add(value, "fine").unwrap_err();
            assert!(
                why.contains("common word or a simple pattern"),
                "{value}: {why}"
            );
        }
        for value in [
            "sk_9fQ2mX7pL4vR8tZ1",
            "tok/1a2b3c+a=b?c&d é",
            "correct-horse-battery-staple",
        ] {
            assert_eq!(value_problem(value), None, "{value}");
        }
        assert!(vault.add(&"v".repeat(LONGEST + 1), "fine").is_err());
        assert!(!scratch.0.join("vault").exists());
        // A paste's spaces and line breaks go; the value is what's between them.
        vault.add(" \nlong-enough-value \r\n", "fine").unwrap();
        let saved = FileStore::new(scratch.0.join("vault")).read().unwrap();
        assert_eq!(saved["fine"], "long-enough-value");
        assert!(vault.remove("fine").unwrap());
        assert!(!vault.remove("fine").unwrap());
        assert!(vault.names().unwrap().is_empty());
    }

    /// Another process (`obid vault add`) changes the file while obid runs: the next check learns
    /// it, and forgets what was removed.
    #[test]
    fn a_change_by_another_process_is_learned_and_a_removal_forgotten() {
        let scratch = Scratch::new();
        let (vault, known) = scratch.vault();
        vault.check().unwrap();
        assert!(known.is_empty());
        let other = Vault::file(scratch.0.join("vault"), Arc::new(Secrets::default()));
        let value = secret();
        other.add(&value, "staging-api-key").unwrap();
        vault.check().unwrap();
        assert_eq!(known.redact(&value), "[redacted: vault staging-api-key]");
        assert_eq!(
            vault.redact(&format!("use {value}")).unwrap(),
            "use [vault: staging-api-key]"
        );
        other.remove("staging-api-key").unwrap();
        vault.check().unwrap();
        assert_eq!(known.redact(&value), value);
        assert_eq!(vault.redact(&value).unwrap(), value);
    }

    /// VaultTests.redactionTakesOutEveryEncoding, through the JSON an answer carries.
    #[test]
    fn every_encoding_is_taken_out_of_json() {
        let scratch = Scratch::new();
        let (vault, _) = scratch.vault();
        let value = secret();
        vault.add(&value, "staging-api-key").unwrap();
        for (how, copy) in copies(&value) {
            let json = serde_json::json!({"request": format!("Use {copy} for the tests"),
                                          "list": [copy.clone()], copy.clone(): 1, "n": 3});
            let bytes = serde_json::to_vec(&json).unwrap();
            let clean = vault.scrubbed(&bytes).unwrap().expect(how);
            let text = String::from_utf8(clean).unwrap();
            assert!(!text.contains(&copy), "{how}: {text}");
            assert!(!text.contains(&value), "{how}: {text}");
            let clean: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(clean["n"], 3);
            assert!(
                clean["request"]
                    .as_str()
                    .unwrap()
                    .contains("[vault: staging-api-key]"),
                "{how}: {text}"
            );
        }
        // A clean answer goes as it was, byte for byte.
        let clean = br#"{"b":1,"a":"nothing secret here","z":[true,null]}"#;
        assert_eq!(vault.scrubbed(clean).unwrap(), None);
        // A value with a quote and a backslash, as JSON escapes them.
        vault.add("quote\"and\\back", "escaped").unwrap();
        let bytes = serde_json::to_vec(&serde_json::json!({"t": "x quote\"and\\back y"})).unwrap();
        let text = String::from_utf8(vault.scrubbed(&bytes).unwrap().unwrap()).unwrap();
        assert_eq!(text, r#"{"t":"x [vault: escaped] y"}"#);
    }

    #[test]
    fn an_event_streams_frames_are_scrubbed() {
        let scratch = Scratch::new();
        let (vault, _) = scratch.vault();
        let value = secret();
        vault.add(&value, "staging-api-key").unwrap();
        let data = serde_json::json!({"summary": format!("ran with {value}")}).to_string();
        let frame = format!("event: job\ndata: {data}\n\n");
        let clean = String::from_utf8(vault.scrubbed_events(frame.as_bytes()).unwrap()).unwrap();
        assert_eq!(
            clean,
            "event: job\ndata: {\"summary\":\"ran with [vault: staging-api-key]\"}\n\n"
        );
        assert_eq!(vault.scrubbed_events(b": ping\n\n"), None);
    }

    #[test]
    fn the_command_takes_values_on_stdin_only_and_prints_names() {
        let scratch = Scratch::new();
        let value = secret();
        let mut out = Vec::new();
        let mut err = Vec::new();
        let mut run_with = |action: Action, given: Option<String>| -> u8 {
            run(
                &scratch.0,
                &Location::File,
                &action,
                || given,
                |line| out.push(line.to_owned()),
                |line| err.push(line.to_owned()),
            )
        };
        assert_eq!(
            run_with(Action::Add("staging-api-key".into()), Some(value.clone())),
            0
        );
        assert_eq!(run_with(Action::Add("other".into()), None), 1);
        assert_eq!(run_with(Action::List, None), 0);
        assert_eq!(run_with(Action::Remove("nope".into()), None), 0);
        assert_eq!(
            out,
            [
                "Saved staging-api-key.",
                "staging-api-key",
                "The vault has no secret named nope."
            ]
        );
        assert_eq!(err, ["No value on stdin."]);
        assert!(!out.iter().chain(&err).any(|l| l.contains(&value)));
        let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            Action::parse(&args(&["add", "x"])),
            Ok(Action::Add("x".into()))
        );
        for wrong in [
            &["add", "x", "the-value-itself"][..],
            &["add"],
            &["show", "x"],
            &[],
        ] {
            assert!(Action::parse(&args(wrong)).is_err(), "{wrong:?}");
        }
    }
}
