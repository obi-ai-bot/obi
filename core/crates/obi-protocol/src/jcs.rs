//! RFC 8785, the JSON Canonicalization Scheme: what every signature and hash in the protocol is
//! computed over (spec/protocol.md, "Signing").
//!
//! Object members are sorted by their keys' UTF-16 code units; strings are written as ECMAScript's
//! `JSON.stringify` writes them (only `"`, `\`, and the control characters below U+0020 escaped,
//! those as `\b \t \n \f \r` or `\u00xx` in lower-case hex); numbers as ECMAScript writes them, so
//! `-0` is `0` and `1.0` is `1`. The protocol itself only has integers.

use serde_json::Value;

/// Why a value has no canonical form.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum JcsError {
    #[error("JCS: non-finite number")]
    NonFinite,
}

/// The canonical text of `value`.
pub fn canonicalize(value: &Value) -> Result<String, JcsError> {
    let mut out = String::new();
    write(value, &mut out)?;
    Ok(out)
}

/// The canonical form as UTF-8 bytes: what is signed and hashed.
pub fn canonical_bytes(value: &Value) -> Result<Vec<u8>, JcsError> {
    canonicalize(value).map(String::into_bytes)
}

fn write(value: &Value, out: &mut String) -> Result<(), JcsError> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => write_number(number, out)?,
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write(item, out)?;
            }
            out.push(']');
        }
        Value::Object(members) => {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write(&members[key], out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn write_number(number: &serde_json::Number, out: &mut String) -> Result<(), JcsError> {
    if let Some(n) = number.as_i64() {
        out.push_str(&n.to_string());
    } else if let Some(n) = number.as_u64() {
        out.push_str(&n.to_string());
    } else {
        let n = number.as_f64().ok_or(JcsError::NonFinite)?;
        if !n.is_finite() {
            return Err(JcsError::NonFinite);
        }
        if n == 0.0 {
            // Negative zero too: ECMAScript writes both as 0.
            out.push('0');
        } else {
            let mut buffer = ryu_js::Buffer::new();
            out.push_str(buffer.format_finite(n));
        }
    }
    Ok(())
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{0C}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers_as_ecmascript_writes_them() {
        let value: Value =
            serde_json::from_str("[-0, 0.0, 1.0, 1e21, 1.5, -2, 18446744073709551615]").unwrap();
        assert_eq!(
            canonicalize(&value).unwrap(),
            "[0,0,1,1e+21,1.5,-2,18446744073709551615]"
        );
    }

    #[test]
    fn keys_sorted_by_utf16_code_units() {
        // U+1F600 is D83D DE00 in UTF-16, which sorts before U+FB33 (as RFC 8785 3.2.3 shows),
        // although its code point is higher.
        let value = json!({"\u{fb33}": 1, "\u{1f600}": 2});
        assert_eq!(
            canonicalize(&value).unwrap(),
            "{\"\u{1f600}\":2,\"\u{fb33}\":1}"
        );
    }

    #[test]
    fn escapes() {
        let value = json!("\"\\\u{7}\u{1f}\n\t \u{e9}\u{2028}\u{7f}");
        assert_eq!(
            canonicalize(&value).unwrap(),
            "\"\\\"\\\\\\u0007\\u001f\\n\\t \u{e9}\u{2028}\u{7f}\""
        );
    }
}
