//! The wire protocol `obi-plugin/0.1` (docs/ARCHITECTURE.md 5.4): JSON-RPC 2.0 over the
//! plug-in's stdin and stdout, one JSON object per line, split on `\n` only, UTF-8.
//!
//! [`Message`] is one line, either way. The params and results of each method are typed below;
//! a field they don't list makes the message invalid.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::{ContextItem, Kind, PluginError, PluginId};

/// The JSON-RPC version every message carries.
pub const JSONRPC: &str = "2.0";

/// The methods of `obi-plugin/0.1`.
pub mod method {
    /// From `obid`: [`super::InitializeParams`] → [`super::InitializeResult`], within 10 seconds.
    pub const INITIALIZE: &str = "initialize";
    /// From `obid`: [`crate::ContextRequest`] → [`super::ContextResult`], within 5 seconds.
    pub const CONTEXT_QUERY: &str = "context/query";
    /// From `obid`: [`super::Empty`] → [`super::Empty`].
    pub const PING: &str = "ping";
    /// From `obid`: [`super::Empty`] → [`super::Empty`].
    pub const SHUTDOWN: &str = "shutdown";
    /// From an `events` plug-in: [`crate::Event`] → [`super::EmitResult`].
    pub const EVENTS_EMIT: &str = "events/emit";
    /// From the plug-in, a notification: [`super::LogParams`].
    pub const LOG: &str = "log";
}

/// JSON-RPC 2.0's error codes.
pub mod code {
    pub const PARSE_ERROR: i64 = -32700;
    pub const INVALID_REQUEST: i64 = -32600;
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
    pub const INTERNAL_ERROR: i64 = -32603;
}

/// A request's id: a number or a string.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(i64),
    String(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RpcError {
    pub code: i64,
    /// The plug-in's words: data, shown as text.
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// One line of the protocol.
#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Request {
        id: RequestId,
        method: String,
        params: Value,
    },
    Notification {
        method: String,
        params: Value,
    },
    Response {
        id: RequestId,
        result: Value,
    },
    /// An error answer. `id` is null when the request it answers couldn't be read.
    Error {
        id: Option<RequestId>,
        error: RpcError,
    },
}

impl Message {
    pub fn request(id: RequestId, method: &str, params: &impl Serialize) -> Message {
        Message::Request {
            id,
            method: method.to_owned(),
            params: to_value(params),
        }
    }

    pub fn notification(method: &str, params: &impl Serialize) -> Message {
        Message::Notification {
            method: method.to_owned(),
            params: to_value(params),
        }
    }

    pub fn response(id: RequestId, result: &impl Serialize) -> Message {
        Message::Response {
            id,
            result: to_value(result),
        }
    }

    pub fn error(id: Option<RequestId>, code: i64, message: impl Into<String>) -> Message {
        Message::Error {
            id,
            error: RpcError {
                code,
                message: message.into(),
                data: None,
            },
        }
    }

    /// The message as one line, ending in `\n`. JSON escapes every control character in a
    /// string, so the line holds no other `\n`.
    pub fn encode(&self) -> String {
        let mut object = Map::new();
        object.insert("jsonrpc".into(), JSONRPC.into());
        match self {
            Message::Request { id, method, params } => {
                object.insert("id".into(), to_value(id));
                object.insert("method".into(), method.as_str().into());
                object.insert("params".into(), params.clone());
            }
            Message::Notification { method, params } => {
                object.insert("method".into(), method.as_str().into());
                object.insert("params".into(), params.clone());
            }
            Message::Response { id, result } => {
                object.insert("id".into(), to_value(id));
                object.insert("result".into(), result.clone());
            }
            Message::Error { id, error } => {
                object.insert("id".into(), to_value(id));
                object.insert("error".into(), to_value(error));
            }
        }
        let mut line = Value::Object(object).to_string();
        line.push('\n');
        line
    }

    /// Reads one line (with or without its `\n`). Anything but one JSON-RPC 2.0 object is a
    /// [`PluginError::Protocol`]: a batch, a second line, a key JSON-RPC doesn't define, a
    /// request without params.
    pub fn decode(line: &str) -> Result<Message, PluginError> {
        let fail = |reason: &str| Err(PluginError::Protocol(reason.to_owned()));
        let line = line.strip_suffix('\n').unwrap_or(line);
        if line.contains('\n') {
            return fail("more than one line");
        }
        let value: Value = serde_json::from_str(line)
            .map_err(|error| PluginError::Protocol(format!("not JSON: {error}")))?;
        let Value::Object(mut object) = value else {
            return fail("not a JSON object");
        };
        if let Some(key) = object.keys().find(|key| {
            !matches!(
                key.as_str(),
                "jsonrpc" | "id" | "method" | "params" | "result" | "error"
            )
        }) {
            return Err(PluginError::Protocol(format!("unknown key {key:?}")));
        }
        if object.remove("jsonrpc") != Some(Value::from(JSONRPC)) {
            return fail("jsonrpc is not \"2.0\"");
        }
        let id = object.remove("id");
        let method = object.remove("method");
        let params = object.remove("params");
        let result = object.remove("result");
        let error = object.remove("error");
        let request_id = |id: Value| {
            serde_json::from_value::<RequestId>(id)
                .map_err(|_| PluginError::Protocol("id is not a number or a string".into()))
        };

        match (method, result, error) {
            (Some(method), None, None) => {
                let Value::String(method) = method else {
                    return fail("method is not a string");
                };
                let Some(params) = params else {
                    return fail("params is missing");
                };
                if !params.is_object() {
                    return fail("params is not an object");
                }
                match id {
                    None => Ok(Message::Notification { method, params }),
                    Some(id) => Ok(Message::Request {
                        id: request_id(id)?,
                        method,
                        params,
                    }),
                }
            }
            (None, Some(result), None) if params.is_none() => {
                let Some(id) = id else {
                    return fail("a response without an id");
                };
                Ok(Message::Response {
                    id: request_id(id)?,
                    result,
                })
            }
            (None, None, Some(error)) if params.is_none() => {
                let id = match id {
                    None => return fail("an error without an id"),
                    Some(Value::Null) => None,
                    Some(id) => Some(request_id(id)?),
                };
                let error = serde_json::from_value(error)
                    .map_err(|error| PluginError::Protocol(format!("bad error: {error}")))?;
                Ok(Message::Error { id, error })
            }
            _ => fail("not a request, a notification, a result or an error"),
        }
    }
}

/// Reads a request's params or a response's result as `T`.
pub fn from_value<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, PluginError> {
    serde_json::from_value(value).map_err(|error| PluginError::Protocol(error.to_string()))
}

fn to_value(value: &impl Serialize) -> Value {
    // Every type this crate serializes is plain data with string keys, which can't fail.
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// `ping`'s and `shutdown`'s params and results: `{}`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Empty {}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InitializeParams {
    /// Always [`crate::PROTOCOL`].
    pub protocol: String,
    pub obid: ObidInfo,
    pub plugin: PluginInfo,
    /// The owner's settings, matching the manifest's `config` schema.
    pub config: Value,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObidInfo {
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PluginInfo {
    pub id: PluginId,
    /// `home/plugin-data/<id>/`: its working directory and `HOME`, the one place it may write.
    pub data_dir: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InitializeResult {
    /// Always [`crate::PROTOCOL`].
    pub protocol: String,
    /// The kinds it serves now: a subset of its manifest's.
    pub kinds: Vec<Kind>,
}

/// `context/query`'s result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContextResult {
    pub items: Vec<ContextItem>,
}

/// `events/emit`'s result.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmitResult {
    pub accepted: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Info,
    Warn,
    Error,
}

/// The `log` notification's params. `message` is data: it goes to `obid`'s log with the vault's
/// secrets taken out.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogParams {
    pub level: LogLevel,
    pub message: String,
}
