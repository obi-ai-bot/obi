//! The secrets obid holds, and how they are taken out of text before it is written to the log
//! (docs/ARCHITECTURE.md 5.4, decision D6): every value in each form it could be written in,
//! plain, base64 (standard or URL-safe, at any offset in a longer run), hex and URL-encoded, as
//! Engine/Vault.swift's `Leaks` finds them.
//!
//! obid has no vault yet (#457). The secrets it holds today are its API token (`home/api-token`),
//! its Obi key, and the Sphere's delegation and access token; [`known`] holds them once obid has
//! read or been given them. When the vault is ported, its values join the same set, so the log
//! layer (`crate::logs`) takes them out too.

use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock, RwLock};

use base64::Engine as _;
use regex::Regex;

/// The shortest value taken out: a shorter one would match ordinary text everywhere (the vault's
/// own shortest secret, Engine/Vault.swift's `Vault.shortest`).
pub const SHORTEST: usize = 8;

/// The secrets of this obid, shared by everything that writes the log.
pub fn known() -> Arc<Secrets> {
    static KNOWN: OnceLock<Arc<Secrets>> = OnceLock::new();
    KNOWN.get_or_init(|| Arc::new(Secrets::default())).clone()
}

/// Secret values by name, and what they look like in every form [`Secrets::redact`] takes out.
#[derive(Default)]
pub struct Secrets {
    inner: RwLock<Learned>,
}

#[derive(Default)]
struct Learned {
    /// Each name's value, in the forms it is kept in (the Obi key: its hex text and its bytes).
    values: BTreeMap<String, Vec<Vec<u8>>>,
    needles: Vec<Needle>,
}

/// One form of one value.
#[derive(Debug, Clone)]
struct Needle {
    name: String,
    text: String,
    /// Hex and URL-encoding read the same in either case: matched without regard to it.
    any_case: bool,
    /// A base64 form: what is taken out is the whole base64 run that holds it, so no character
    /// of the run around it (which encodes part of the value too) is left.
    run: bool,
}

impl Secrets {
    /// Learns `value` as `name`, in place of what `name` held before. A value shorter than
    /// [`SHORTEST`] bytes is not learned (and the one held before under `name` is forgotten).
    pub fn learn(&self, name: &str, value: impl AsRef<[u8]>) {
        self.learn_forms(name, &[value.as_ref()]);
    }

    /// Learns one secret kept in several forms as `name`, each taken out in all its encodings:
    /// the Obi key is both its hex text (`keys/obi.key`) and the 32 bytes that text spells. Forms
    /// shorter than [`SHORTEST`] bytes are left out; with none left, `name` is forgotten.
    pub fn learn_forms(&self, name: &str, forms: &[&[u8]]) {
        let forms: Vec<Vec<u8>> = forms
            .iter()
            .filter(|form| form.len() >= SHORTEST)
            .map(|form| form.to_vec())
            .collect();
        let mut inner = self.inner.write().unwrap_or_else(|e| e.into_inner());
        if forms.is_empty() {
            inner.values.remove(name);
        } else {
            inner.values.insert(name.to_owned(), forms);
        }
        inner.needles = needles_of(&inner.values);
    }

    /// Forgets the value held as `name`.
    pub fn forget(&self, name: &str) {
        let mut inner = self.inner.write().unwrap_or_else(|e| e.into_inner());
        inner.values.remove(name);
        inner.needles = needles_of(&inner.values);
    }

    pub fn is_empty(&self) -> bool {
        self.inner
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .values
            .is_empty()
    }

    /// `text` with every secret it holds, in any of its forms, replaced by `[redacted: <name>]`:
    /// each copy of a value, plain or encoded, first; then any base64, hex or URL-encoded run
    /// that decodes to text holding one.
    pub fn redact(&self, text: &str) -> String {
        let inner = self.inner.read().unwrap_or_else(|e| e.into_inner());
        if inner.needles.is_empty() {
            return text.to_owned();
        }
        let mut text = text.to_owned();
        for needle in &inner.needles {
            text = replace(&text, needle);
        }
        // What is left: runs that decode to a value (hex inside base64, a value partly
        // URL-encoded, base64 cut where the needles' offsets don't reach).
        for run in runs() {
            text = run
                .replace_all(&text, |found: &regex::Captures<'_>| {
                    let whole = &found[0];
                    let names = hits(&inner.needles, whole);
                    if names.is_empty() {
                        whole.to_owned()
                    } else {
                        marker(&names)
                    }
                })
                .into_owned();
        }
        text
    }
}

fn marker(names: &[String]) -> String {
    format!("[redacted: {}]", names.join(", "))
}

/// A character a base64 run (standard or URL-safe) is made of, padding aside.
fn is_base64_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'-' | b'_')
}

/// `text` with every copy of `needle` replaced by its marker; for a base64 form, the whole run
/// of base64 characters (and its padding) around each copy.
fn replace(text: &str, needle: &Needle) -> String {
    let marker = marker(std::slice::from_ref(&needle.name));
    // ASCII lower case keeps every byte where it was, so positions found in the lower-cased
    // copy are the same in `text`.
    let (haystack, wanted) = if needle.any_case {
        (text.to_ascii_lowercase(), needle.text.to_ascii_lowercase())
    } else {
        (text.to_owned(), needle.text.clone())
    };
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while let Some(found) = haystack[at..].find(&wanted) {
        let mut start = at + found;
        let mut end = start + wanted.len();
        if needle.run {
            while start > at && is_base64_char(bytes[start - 1]) {
                start -= 1;
            }
            while end < bytes.len() && is_base64_char(bytes[end]) {
                end += 1;
            }
            while end < bytes.len() && bytes[end] == b'=' {
                end += 1;
            }
        }
        out.push_str(&text[at..start]);
        out.push_str(&marker);
        at = end;
    }
    out.push_str(&text[at..]);
    out
}

/// The names of the values `run` decodes to text holding (in any form), each once.
fn hits(needles: &[Needle], run: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for decoded in decodings(run) {
        let lower = decoded.to_ascii_lowercase();
        for needle in needles {
            let found = if needle.any_case {
                lower.contains(&needle.text.to_ascii_lowercase())
            } else {
                decoded.contains(&needle.text)
            };
            if found && !names.contains(&needle.name) {
                names.push(needle.name.clone());
            }
        }
    }
    names
}

/// What `run` decodes to, as text: URL-decoded, base64 (standard or URL-safe), hex.
fn decodings(run: &str) -> Vec<String> {
    let mut out = Vec::new();
    if run.contains('%') {
        let plain = percent_decode(run);
        if plain != run {
            out.push(plain);
        }
    }
    let trimmed = run.trim_end_matches('=');
    for engine in [
        &base64::engine::general_purpose::STANDARD_NO_PAD,
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
    ] {
        // A run cut anywhere: try it as it is, and without its last one or two characters.
        for cut in 0..3 {
            let Some(end) = trimmed.len().checked_sub(cut) else {
                break;
            };
            if let Ok(bytes) = engine.decode(&trimmed[..end]) {
                out.push(String::from_utf8_lossy(&bytes).into_owned());
                break;
            }
        }
    }
    if run.len().is_multiple_of(2)
        && let Ok(bytes) = hex::decode(run)
    {
        out.push(String::from_utf8_lossy(&bytes).into_owned());
    }
    out
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(byte) = text
                .get(i + 1..i + 3)
                .and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Runs of text an encoded value could hide in: URL-encoded, base64, hex.
fn runs() -> &'static [Regex] {
    static RUNS: OnceLock<Vec<Regex>> = OnceLock::new();
    RUNS.get_or_init(|| {
        [
            r#"[^\s"'<>]*%[0-9A-Fa-f]{2}[^\s"'<>]*"#,
            r"[A-Za-z0-9+/_-]{16,}={0,2}",
            r"[0-9A-Fa-f]{16,}",
        ]
        .iter()
        .map(|pattern| Regex::new(pattern).expect("a run pattern compiles"))
        .collect()
    })
}

/// Every form of every value, longest first, so a value goes before the parts that would match
/// inside it.
fn needles_of(values: &BTreeMap<String, Vec<Vec<u8>>>) -> Vec<Needle> {
    let mut needles: Vec<Needle> = values
        .iter()
        .flat_map(|(name, forms)| forms.iter().flat_map(|form| needles_for(name, form)))
        .collect();
    needles.sort_by_key(|needle| std::cmp::Reverse(needle.text.len()));
    needles
}

fn needles_for(name: &str, bytes: &[u8]) -> Vec<Needle> {
    let needle = |text: String, any_case: bool| Needle {
        name: name.to_owned(),
        text,
        any_case,
        run: false,
    };
    let mut needles = Vec::new();
    if let Ok(value) = std::str::from_utf8(bytes) {
        // A value that is hex text (a key file's) reads the same in either case.
        let hex_text = value.bytes().all(|b| b.is_ascii_hexdigit());
        needles.push(needle(value.to_owned(), hex_text));
        // A key or certificate over several lines: each long line on its own, the value with
        // Windows line ends, and the value as one line of a log writes its line breaks (`\n`).
        if value.contains('\n') {
            for line in value.lines() {
                if line.len() >= SHORTEST && line != value {
                    needles.push(needle(line.to_owned(), false));
                }
            }
            if !value.contains("\r\n") {
                needles.push(needle(value.replace('\n', "\r\n"), false));
            }
            needles.push(needle(
                value.replace('\r', "\\r").replace('\n', "\\n"),
                false,
            ));
        }
        // URL-encoded, with the unreserved characters as they are, and as a form sends spaces.
        let encoded = percent_encode(value, false);
        if encoded != value {
            needles.push(needle(encoded, true));
        }
        if value.contains(' ') {
            needles.push(needle(percent_encode(value, true), true));
        }
    }
    for run in base64_runs(bytes) {
        let safe = run.replace('+', "-").replace('/', "_");
        if safe != run {
            needles.push(Needle {
                run: true,
                ..needle(safe, false)
            });
        }
        needles.push(Needle {
            run: true,
            ..needle(run, false)
        });
    }
    needles.push(needle(hex::encode(bytes), true));
    needles.push(needle(
        bytes.iter().map(|b| format!("%{b:02X}")).collect(),
        true,
    ));
    needles
}

/// `value` URL-encoded: every byte but `A-Z a-z 0-9 - . _ ~` as `%XX`, and with `form`, spaces
/// as `+`.
fn percent_encode(value: &str, form: bool) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            b' ' if form => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// The base64 characters only the value decides, whatever comes before it in a longer encoded
/// run: one per offset (0, 1 or 2 bytes in), so a value in the middle of a longer string is
/// found too (Engine/Vault.swift, `Leaks.base64`).
fn base64_runs(bytes: &[u8]) -> Vec<String> {
    (0..3)
        .filter_map(|offset| {
            let mut padded = vec![0u8; offset];
            padded.extend_from_slice(bytes);
            let encoded = base64::engine::general_purpose::STANDARD.encode(&padded);
            // Character i holds bits 6i to 6i+6; the value's are 8·offset to 8·(offset+count).
            let first = (8 * offset).div_ceil(6);
            let end = (8 * (offset + bytes.len())) / 6;
            (end >= first + 4).then(|| encoded[first..end].to_owned())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "s3cr3t-T0ken_value+with/odd chars";

    fn secrets() -> Secrets {
        let secrets = Secrets::default();
        secrets.learn("api-token", TOKEN);
        secrets
    }

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn every_form_is_taken_out() {
        let secrets = secrets();
        let forms = [
            TOKEN.to_owned(),
            b64(TOKEN.as_bytes()),
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(TOKEN),
            // In the middle of a longer base64 run, at each offset.
            b64(format!("x{TOKEN}y").as_bytes()),
            b64(format!("xy{TOKEN}z").as_bytes()),
            b64(format!("{{\"token\":\"{TOKEN}\"}}").as_bytes()),
            hex::encode(TOKEN),
            hex::encode(TOKEN).to_ascii_uppercase(),
            percent_encode(TOKEN, false),
            percent_encode(TOKEN, false).to_ascii_lowercase(),
            percent_encode(TOKEN, true),
            TOKEN.bytes().map(|b| format!("%{b:02x}")).collect(),
            // Hex inside base64.
            b64(hex::encode(TOKEN).as_bytes()),
        ];
        for form in forms {
            let line = format!("plugin=x the value is <{form}> and more");
            let redacted = secrets.redact(&line);
            assert!(
                redacted.contains("[redacted: api-token]"),
                "{form}: {redacted}"
            );
            assert!(!redacted.contains(&form), "{form}: {redacted}");
            assert!(!redacted.contains(TOKEN), "{redacted}");
            assert!(
                redacted.starts_with("plugin=x the value is <"),
                "{redacted}"
            );
        }
    }

    /// No character of the base64 run that holds a value is left: each encodes part of it.
    #[test]
    fn the_whole_base64_run_goes() {
        let secrets = secrets();
        for text in [
            b64(TOKEN.as_bytes()),
            b64(format!("token={TOKEN}").as_bytes()),
            b64(format!("xy{TOKEN}").as_bytes()),
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!("a{TOKEN}bc")),
        ] {
            assert_eq!(
                secrets.redact(&format!("LEAK {text} end")),
                "LEAK [redacted: api-token] end",
                "{text}"
            );
        }
    }

    /// The Obi key, kept as hex text and as its 32 bytes: every common encoding of either.
    #[test]
    fn a_key_is_taken_out_in_every_common_encoding() {
        let secrets = Secrets::default();
        let seed: Vec<u8> = (0u8..32)
            .map(|b| b.wrapping_mul(37).wrapping_add(11))
            .collect();
        let hex_text = hex::encode(&seed);
        secrets.learn_forms("obi-key", &[hex_text.as_bytes(), &seed]);
        let engines = [
            base64::engine::general_purpose::STANDARD,
            base64::engine::general_purpose::STANDARD_NO_PAD,
            base64::engine::general_purpose::URL_SAFE,
            base64::engine::general_purpose::URL_SAFE_NO_PAD,
        ];
        let mut forms = vec![hex_text.clone(), hex_text.to_ascii_uppercase()];
        for engine in engines {
            forms.push(engine.encode(&seed));
            forms.push(engine.encode(hex_text.as_bytes()));
        }
        for form in forms {
            let redacted = secrets.redact(&format!("key: {form} end"));
            assert_eq!(redacted, "key: [redacted: obi-key] end", "{form}");
        }
    }

    #[test]
    fn other_text_is_left_as_it_is() {
        let secrets = secrets();
        let line = "ready: 3 items, aGVsbG8gd29ybGQgaGVsbG8= deadbeefdeadbeefdeadbeef 50%25 done";
        assert_eq!(secrets.redact(line), line);
        assert_eq!(Secrets::default().redact(TOKEN), TOKEN);
    }

    #[test]
    fn short_values_are_not_learned_and_names_are_replaced() {
        let secrets = Secrets::default();
        secrets.learn("short", "abc");
        assert!(secrets.is_empty());
        secrets.learn("t", "first-value-1234");
        secrets.learn("t", "second-value-5678");
        assert_eq!(secrets.redact("first-value-1234"), "first-value-1234");
        assert_eq!(secrets.redact("second-value-5678"), "[redacted: t]");
        secrets.forget("t");
        assert_eq!(secrets.redact("second-value-5678"), "second-value-5678");
    }

    #[test]
    fn a_value_over_lines_is_taken_out_as_a_log_writes_it() {
        let secrets = Secrets::default();
        let key = "-----BEGIN KEY-----\nAAAAB3NzaC1yc2EAAAADAQABAAABAQ\n-----END KEY-----";
        secrets.learn("key", key);
        let escaped = key.replace('\n', "\\n");
        assert_eq!(
            secrets.redact(&format!("x {escaped} y")),
            "x [redacted: key] y"
        );
        assert!(
            !secrets
                .redact("line: AAAAB3NzaC1yc2EAAAADAQABAAABAQ")
                .contains("AAAAB3NzaC1yc2EAAAADAQABAAABAQ")
        );
    }
}
