//! The owner's settings for a plug-in must match its manifest's `config`, a JSON Schema
//! (docs/ARCHITECTURE.md 5.2). The host checks the part of JSON Schema a plug-in's settings
//! need, and refuses a schema that uses anything else, rather than letting settings through
//! that it couldn't check.
//!
//! Checked: `type` (one name or a list), `enum`, `const`, `properties`, `required`,
//! `additionalProperties` (a boolean or a schema), `minProperties`, `maxProperties`, `items`
//! (one schema), `minItems`, `maxItems`, `uniqueItems`, `minLength`, `maxLength` (in Unicode
//! code points, as JSON Schema counts them), `minimum`, `maximum`, `exclusiveMinimum` and
//! `exclusiveMaximum` (numbers). Boolean schemas (`true`, `false`) too. Annotations are allowed
//! and change nothing: `$schema`, `$id`, `$comment`, `title`, `description`, `default`,
//! `examples`, `format`, `readOnly`, `writeOnly`, `deprecated`.

use serde_json::{Map, Value};

/// How deep a schema or a value may nest before the host stops reading it.
const MAX_DEPTH: usize = 32;

const CHECKED: [&str; 19] = [
    "type",
    "enum",
    "const",
    "properties",
    "required",
    "additionalProperties",
    "minProperties",
    "maxProperties",
    "items",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "$schema",
];

const ANNOTATIONS: [&str; 10] = [
    "$id",
    "$comment",
    "title",
    "description",
    "default",
    "examples",
    "format",
    "readOnly",
    "writeOnly",
    "deprecated",
];

const TYPES: [&str; 7] = [
    "object", "array", "string", "number", "integer", "boolean", "null",
];

/// Whether the host can check settings against `schema`: every keyword is one it knows, with a
/// value of the right shape. The reason names the first one it can't.
pub(crate) fn supported(schema: &Value) -> Result<(), String> {
    supported_at(schema, "config", 0)
}

fn supported_at(schema: &Value, at: &str, depth: usize) -> Result<(), String> {
    if depth > MAX_DEPTH {
        return Err(format!("{at} nests deeper than {MAX_DEPTH}"));
    }
    let object = match schema {
        Value::Bool(_) => return Ok(()),
        Value::Object(object) => object,
        _ => return Err(format!("{at} is not a schema (an object or a boolean)")),
    };
    for (key, value) in object {
        let here = format!("{at}.{key}");
        let shape_ok = match key.as_str() {
            "type" => match value {
                Value::String(name) => TYPES.contains(&name.as_str()),
                Value::Array(names) => {
                    !names.is_empty()
                        && names
                            .iter()
                            .all(|n| n.as_str().is_some_and(|n| TYPES.contains(&n)))
                }
                _ => false,
            },
            "enum" => value.as_array().is_some_and(|values| !values.is_empty()),
            "const" => true,
            "properties" => {
                let Some(properties) = value.as_object() else {
                    return Err(format!("{here} is not an object"));
                };
                for (name, property) in properties {
                    supported_at(property, &format!("{here}.{name}"), depth + 1)?;
                }
                true
            }
            "required" => value
                .as_array()
                .is_some_and(|names| names.iter().all(Value::is_string)),
            "additionalProperties" | "items" => {
                supported_at(value, &here, depth + 1)?;
                true
            }
            "minProperties" | "maxProperties" | "minItems" | "maxItems" | "minLength"
            | "maxLength" => value.as_u64().is_some(),
            "uniqueItems" => value.is_boolean(),
            "minimum" | "maximum" | "exclusiveMinimum" | "exclusiveMaximum" => value.is_number(),
            "$schema" => value.is_string(),
            key if ANNOTATIONS.contains(&key) => true,
            _ => {
                return Err(format!(
                    "{here} is a JSON Schema keyword the host doesn't check (it checks {})",
                    CHECKED.join(", ")
                ));
            }
        };
        if !shape_ok {
            return Err(format!("{here} has a value of the wrong shape"));
        }
    }
    Ok(())
}

/// Whether `value` matches `schema`, which [`supported`] accepted. The reason names the first
/// place it doesn't, by its path in the settings (`config.repos[2]`), never by quoting it.
pub(crate) fn validate(schema: &Value, value: &Value) -> Result<(), String> {
    validate_at(schema, value, "config", 0)
}

fn validate_at(schema: &Value, value: &Value, at: &str, depth: usize) -> Result<(), String> {
    if depth > MAX_DEPTH {
        return Err(format!("{at} nests deeper than {MAX_DEPTH}"));
    }
    let schema = match schema {
        Value::Bool(true) => return Ok(()),
        Value::Bool(false) => return Err(format!("{at} is not allowed")),
        Value::Object(schema) => schema,
        _ => return Err(format!("{at}: the schema is not an object or a boolean")),
    };
    let fail = |reason: &str| Err(format!("{at} {reason}"));

    if let Some(types) = schema.get("type") {
        let names: Vec<&str> = match types {
            Value::String(name) => vec![name.as_str()],
            Value::Array(names) => names.iter().filter_map(Value::as_str).collect(),
            _ => Vec::new(),
        };
        if !names.iter().any(|name| is_type(value, name)) {
            return fail(&format!("is not {}", names.join(" or ")));
        }
    }
    if let Some(values) = schema.get("enum").and_then(Value::as_array)
        && !values.iter().any(|allowed| equal(allowed, value))
    {
        return fail("is not one of the values the schema lists");
    }
    if let Some(allowed) = schema.get("const")
        && !equal(allowed, value)
    {
        return fail("is not the value the schema requires");
    }

    match value {
        Value::Object(object) => validate_object(schema, object, at, depth)?,
        Value::Array(items) => {
            let count = items.len() as u64;
            if let Some(min) = number(schema, "minItems").filter(|min| count < *min) {
                return fail(&format!("has fewer than {min} items"));
            }
            if let Some(max) = number(schema, "maxItems").filter(|max| count > *max) {
                return fail(&format!("has more than {max} items"));
            }
            if schema.get("uniqueItems") == Some(&Value::Bool(true)) {
                for (i, item) in items.iter().enumerate() {
                    if items[..i].iter().any(|earlier| equal(earlier, item)) {
                        return fail("has an item twice");
                    }
                }
            }
            if let Some(item_schema) = schema.get("items") {
                for (i, item) in items.iter().enumerate() {
                    validate_at(item_schema, item, &format!("{at}[{i}]"), depth + 1)?;
                }
            }
        }
        Value::String(text) => {
            let length = text.chars().count() as u64;
            if let Some(min) = number(schema, "minLength").filter(|min| length < *min) {
                return fail(&format!("is shorter than {min} characters"));
            }
            if let Some(max) = number(schema, "maxLength").filter(|max| length > *max) {
                return fail(&format!("is longer than {max} characters"));
            }
        }
        Value::Number(n) => {
            let n = n.as_f64().unwrap_or(f64::NAN);
            let bound = |key: &str| schema.get(key).and_then(Value::as_f64);
            if bound("minimum").is_some_and(|min| n < min) {
                return fail("is below the minimum");
            }
            if bound("maximum").is_some_and(|max| n > max) {
                return fail("is above the maximum");
            }
            if bound("exclusiveMinimum").is_some_and(|min| n <= min) {
                return fail("is not above the exclusive minimum");
            }
            if bound("exclusiveMaximum").is_some_and(|max| n >= max) {
                return fail("is not below the exclusive maximum");
            }
        }
        Value::Bool(_) | Value::Null => {}
    }
    Ok(())
}

fn validate_object(
    schema: &Map<String, Value>,
    object: &Map<String, Value>,
    at: &str,
    depth: usize,
) -> Result<(), String> {
    let count = object.len() as u64;
    if let Some(min) = number(schema, "minProperties").filter(|min| count < *min) {
        return Err(format!("{at} has fewer than {min} properties"));
    }
    if let Some(max) = number(schema, "maxProperties").filter(|max| count > *max) {
        return Err(format!("{at} has more than {max} properties"));
    }
    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for name in required.iter().filter_map(Value::as_str) {
            if !object.contains_key(name) {
                return Err(format!("{at} has no {name:?}, which the schema requires"));
            }
        }
    }
    let properties = schema.get("properties").and_then(Value::as_object);
    for (name, value) in object {
        let here = format!("{at}.{name}");
        match properties.and_then(|properties| properties.get(name)) {
            Some(property) => validate_at(property, value, &here, depth + 1)?,
            None => {
                if let Some(additional) = schema.get("additionalProperties") {
                    if additional == &Value::Bool(false) {
                        return Err(format!("{at} has {name:?}, which the schema doesn't list"));
                    }
                    validate_at(additional, value, &here, depth + 1)?;
                }
            }
        }
    }
    Ok(())
}

fn number(schema: &Map<String, Value>, key: &str) -> Option<u64> {
    schema.get(key).and_then(Value::as_u64)
}

fn is_type(value: &Value, name: &str) -> bool {
    match name {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "number" => value.is_number(),
        "integer" => match value {
            Value::Number(n) => {
                n.is_i64() || n.is_u64() || n.as_f64().is_some_and(|f| f.fract() == 0.0)
            }
            _ => false,
        },
        "boolean" => value.is_boolean(),
        "null" => value.is_null(),
        _ => false,
    }
}

/// JSON Schema's equality: numbers by value (`1` equals `1.0`), objects by their members.
fn equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| equal(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(key, value)| y.get(key).is_some_and(|other| equal(value, other)))
        }
        _ => a == b,
    }
}

#[cfg(test)]
mod tests {
    use super::{supported, validate};
    use serde_json::json;

    #[test]
    fn the_empty_object_schema_takes_only_an_empty_object() {
        let schema = json!({"type": "object", "additionalProperties": false, "properties": {}});
        supported(&schema).unwrap();
        validate(&schema, &json!({})).unwrap();
        assert!(validate(&schema, &json!({"url": "https://x"})).is_err());
        assert!(validate(&schema, &json!([])).is_err());
        assert!(validate(&schema, &json!(null)).is_err());
    }

    #[test]
    fn properties_required_and_their_types() {
        let schema = json!({
            "type": "object",
            "required": ["mode"],
            "additionalProperties": false,
            "properties": {
                "mode": {"enum": ["a", "b"]},
                "count": {"type": "integer", "minimum": 0, "maximum": 30},
                "name": {"type": "string", "minLength": 1, "maxLength": 3},
                "paths": {"type": "array", "items": {"type": "string"}, "maxItems": 2, "uniqueItems": true},
                "extra": {"type": "object"},
                "flag": {"type": ["boolean", "null"]}
            }
        });
        supported(&schema).unwrap();
        validate(&schema, &json!({"mode": "a"})).unwrap();
        validate(
            &schema,
            &json!({"mode": "b", "count": 3, "name": "été", "paths": ["x", "y"], "extra": {"any": [1]}, "flag": null}),
        )
        .unwrap();
        validate(&schema, &json!({"mode": "a", "count": 2.0})).unwrap();
        for bad in [
            json!({}),
            json!({"mode": "c"}),
            json!({"mode": "a", "count": -1}),
            json!({"mode": "a", "count": 31}),
            json!({"mode": "a", "count": 1.5}),
            json!({"mode": "a", "name": ""}),
            json!({"mode": "a", "name": "four"}),
            json!({"mode": "a", "paths": ["x", "x"]}),
            json!({"mode": "a", "paths": ["x", "y", "z"]}),
            json!({"mode": "a", "paths": [1]}),
            json!({"mode": "a", "flag": "yes"}),
            json!({"mode": "a", "other": 1}),
        ] {
            assert!(validate(&schema, &bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_reason_names_the_place_not_the_value() {
        let schema = json!({"type": "object", "properties": {"token": {"type": "integer"}}});
        let reason = validate(&schema, &json!({"token": "ghp_secretvalue"})).unwrap_err();
        assert!(reason.contains("config.token"), "{reason}");
        assert!(!reason.contains("ghp_secretvalue"), "{reason}");
    }

    #[test]
    fn keywords_it_cannot_check_are_refused() {
        for schema in [
            json!({"type": "object", "properties": {"x": {"type": "string", "pattern": "^a"}}}),
            json!({"oneOf": [{"type": "string"}]}),
            json!({"$ref": "#/definitions/x"}),
            json!({"type": "object", "patternProperties": {}}),
            json!({"type": "array", "items": [{"type": "string"}]}),
            json!({"type": "strings"}),
            json!({"enum": []}),
            json!({"minLength": -1}),
            json!(3),
        ] {
            assert!(supported(&schema).is_err(), "{schema}");
        }
        for schema in [
            json!(true),
            json!({"$schema": "https://json-schema.org/draft/2020-12/schema", "title": "x", "description": "y", "default": {}, "type": "object"}),
            json!({"type": "object", "additionalProperties": {"type": "string", "format": "uri"}}),
        ] {
            supported(&schema).unwrap();
        }
    }

    #[test]
    fn deep_nesting_is_refused() {
        let mut schema = json!({"type": "object"});
        for _ in 0..40 {
            schema = json!({"type": "object", "properties": {"x": schema}});
        }
        assert!(supported(&schema).is_err());
    }
}
