//! The Sphere's HTTP API as an Obi calls it (sphere-api.md): redeeming an invitation, the token
//! exchange, the directory, sending, deliveries and acknowledgements. Every answer is read as the
//! spec says; text in it (error messages, envelopes' data fields) is data.
//!
//! A `429 rate_limited` answer means nothing was recorded (sphere-api.md section 1 and 6.1, check
//! 13): the client waits as `Retry-After` says and tries the same request again, a few times, before
//! it gives up and answers the refusal.

use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::schema;

/// `grant_type` of the token exchange (identity.md 4.3).
pub const TOKEN_EXCHANGE: &str = "urn:ietf:params:oauth:grant-type:token-exchange";
/// The token type of both assertions.
pub const JWT_TOKEN_TYPE: &str = "urn:ietf:params:oauth:token-type:jwt";

/// How many times a `429` is retried before the client answers it.
const RATE_LIMIT_TRIES: u32 = 5;
/// The longest answer from a Sphere an Obi reads (an audit page of 1,000 entries is far less).
const MAX_ANSWER: usize = 16 * 1024 * 1024;
/// The longest the client waits on one `Retry-After`.
const RETRY_AFTER_MAX: Duration = Duration::from_secs(30);

/// Why a call didn't give what was asked.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ClientError {
    /// The Sphere answered an error: its HTTP status, its `code` and `message` (data, one line).
    #[error("The Sphere refused it: {code}: {message}")]
    Refused {
        status: u16,
        code: String,
        message: String,
    },
    /// No answer: the Sphere couldn't be reached, or took too long.
    #[error("The Sphere can't be reached: {0}")]
    Unreachable(String),
    /// An answer the spec doesn't allow.
    #[error("The Sphere answered something the spec doesn't allow: {0}")]
    Protocol(String),
}

impl ClientError {
    /// The spec's error code, when the Sphere answered one.
    pub fn code(&self) -> Option<&str> {
        match self {
            ClientError::Refused { code, .. } => Some(code),
            _ => None,
        }
    }
}

/// A token from the exchange.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Token {
    pub access_token: String,
    pub expires_in: i64,
    pub scope: String,
}

/// What a send answered: the message's place in the audit chain.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Sent {
    pub id: String,
    pub seq: u64,
    pub entry_hash: String,
    pub recorded_at: String,
}

/// A message waiting for the Obi. The envelope is unchecked: the receiver checks it (protocol.md
/// section 10) before it acts on it.
#[derive(Debug, Clone, PartialEq)]
pub struct Delivery {
    pub delivery_id: String,
    pub seq: u64,
    pub relayed_at: String,
    pub envelope: Value,
}

/// A client of one Sphere.
#[derive(Debug, Clone)]
pub struct Client {
    http: reqwest::Client,
    base: String,
    sphere: String,
}

/// One line of `text`, at most 300 characters: what a refusal quotes.
fn one_line(text: &str) -> String {
    let line: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(300)
        .collect();
    line.trim().to_owned()
}

impl Client {
    /// A client of the Sphere `sphere` served at `base` (like `http://127.0.0.1:8787`, no trailing
    /// `/`). It never uses a proxy from the environment, and sends nothing but what each call says.
    pub fn new(base: &str, sphere: &str) -> Result<Client, ClientError> {
        let http = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(60))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("obid/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| ClientError::Unreachable(e.to_string()))?;
        Ok(Client {
            http,
            base: base.trim_end_matches('/').to_owned(),
            sphere: sphere.to_owned(),
        })
    }

    pub fn base(&self) -> &str {
        &self.base
    }

    pub fn sphere(&self) -> &str {
        &self.sphere
    }

    fn sphere_path(&self, rest: &str) -> String {
        format!("{}/v0.1/spheres/{}{rest}", self.base, self.sphere)
    }

    /// Sends what `build` makes, again after a `429` as `Retry-After` says; answers the status and
    /// the body as JSON (`Value::Null` when it isn't JSON).
    async fn call(
        &self,
        build: impl Fn() -> reqwest::RequestBuilder,
    ) -> Result<(u16, Value), ClientError> {
        let mut tries = 0;
        loop {
            tries += 1;
            let response = build()
                .send()
                .await
                .map_err(|e| ClientError::Unreachable(one_line(&e.to_string())))?;
            let status = response.status().as_u16();
            let retry_after = response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok());
            // Read a piece at a time, never past MAX_ANSWER: a Sphere can't fill this Obi's memory.
            let mut response = response;
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|e| ClientError::Unreachable(one_line(&e.to_string())))?
            {
                if bytes.len() + chunk.len() > MAX_ANSWER {
                    return Err(ClientError::Unreachable(
                        "the Sphere's answer is longer than an Obi reads".into(),
                    ));
                }
                bytes.extend_from_slice(&chunk);
            }
            let body: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            if status == 429 && tries < RATE_LIMIT_TRIES {
                // Nothing was recorded: the same request again, once the Sphere says.
                let wait = Duration::from_secs(retry_after.unwrap_or(1)).min(RETRY_AFTER_MAX);
                tokio::time::sleep(wait.max(Duration::from_millis(200))).await;
                continue;
            }
            return Ok((status, body));
        }
    }

    /// The refusal in an error answer (`{"error": {code, message}}`, or the token endpoint's OAuth
    /// form `{"error", "error_description"}`).
    fn refused(status: u16, body: &Value) -> ClientError {
        let (code, message) = match &body["error"] {
            Value::Object(error) => (
                error.get("code").and_then(Value::as_str).unwrap_or(""),
                error.get("message").and_then(Value::as_str).unwrap_or(""),
            ),
            Value::String(code) => (
                code.as_str(),
                body["error_description"].as_str().unwrap_or(""),
            ),
            _ => ("", ""),
        };
        let code = if code.is_empty() {
            format!("http_{status}")
        } else {
            one_line(code)
        };
        ClientError::Refused {
            status,
            code,
            message: one_line(message),
        }
    }

    fn expect(
        status: u16,
        body: Value,
        ok: &[u16],
        schema_name: &str,
    ) -> Result<Value, ClientError> {
        if !ok.contains(&status) {
            return Err(Client::refused(status, &body));
        }
        let errors = schema::errors(schema_name, &body, 3);
        if !errors.is_empty() {
            return Err(ClientError::Protocol(format!(
                "{schema_name}: {}",
                errors.join("; ")
            )));
        }
        Ok(body)
    }

    /// `GET /v0.1/health`.
    pub async fn health(&self) -> Result<Value, ClientError> {
        let url = format!("{}/v0.1/health", self.base);
        let (status, body) = self.call(|| self.http.get(&url)).await?;
        Client::expect(status, body, &[200], "wire/health.response")
    }

    /// Redeems an invitation with the owner key and the owner-signed card, and the owner's sign-in
    /// (`{"state", "code"}`) for an invitation limited to a domain (sphere-api.md section 3.1):
    /// answers the member.
    pub async fn redeem(
        &self,
        invitation_id: &str,
        secret: &str,
        owner_key: &str,
        card: &Value,
        signin: Option<&Value>,
    ) -> Result<Value, ClientError> {
        let url = self.sphere_path(&format!("/invitations/{invitation_id}/redeem"));
        let mut body = json!({"secret": secret, "owner_key": owner_key, "card": card});
        if let Some(signin) = signin {
            body["signin"] = signin.clone();
        }
        let (status, answer) = self.call(|| self.http.post(&url).json(&body)).await?;
        Client::expect(status, answer, &[201], "wire/member")
    }

    /// The token exchange (identity.md 4.3): the owner's delegation and the Obi's actor assertion.
    pub async fn token(&self, subject: &str, actor: &str) -> Result<Token, ClientError> {
        let url = format!("{}/v0.1/oauth/token", self.base);
        let form = [
            ("grant_type", TOKEN_EXCHANGE),
            ("subject_token", subject),
            ("subject_token_type", JWT_TOKEN_TYPE),
            ("actor_token", actor),
            ("actor_token_type", JWT_TOKEN_TYPE),
        ];
        let (status, body) = self.call(|| self.http.post(&url).form(&form)).await?;
        let body = Client::expect(status, body, &[200], "wire/token.response")?;
        serde_json::from_value(body).map_err(|e| ClientError::Protocol(e.to_string()))
    }

    /// Every member of the directory, active and revoked.
    pub async fn members(&self, token: &str) -> Result<Vec<Value>, ClientError> {
        let url = self.sphere_path("/members");
        let (status, body) = self.call(|| self.http.get(&url).bearer_auth(token)).await?;
        let body = Client::expect(status, body, &[200], "wire/members.response")?;
        Ok(body["members"].as_array().cloned().unwrap_or_default())
    }

    /// A page of the audit chain from `from_seq` (sphere-api.md section 7): `{sphere, entries, head}`.
    pub async fn audit(
        &self,
        token: &str,
        from_seq: u64,
        limit: u32,
    ) -> Result<Value, ClientError> {
        let url = self.sphere_path(&format!("/audit?from_seq={from_seq}&limit={limit}"));
        let (status, body) = self.call(|| self.http.get(&url).bearer_auth(token)).await?;
        Client::expect(status, body, &[200], "wire/audit.response")
    }

    /// Publishes this Obi's signed runner status in the directory (sphere-api.md 6.4).
    pub async fn put_runner(
        &self,
        token: &str,
        obi: &str,
        status: &Value,
    ) -> Result<Value, ClientError> {
        let url = self.sphere_path(&format!("/members/{obi}/runner"));
        let (code, body) = self
            .call(|| self.http.put(&url).bearer_auth(token).json(status))
            .await?;
        Client::expect(code, body, &[200], "wire/member")
    }

    /// Takes this Obi's runner status out of the directory.
    pub async fn delete_runner(&self, token: &str, obi: &str) -> Result<Value, ClientError> {
        let url = self.sphere_path(&format!("/members/{obi}/runner"));
        let (code, body) = self
            .call(|| self.http.delete(&url).bearer_auth(token))
            .await?;
        Client::expect(code, body, &[200], "wire/member")
    }

    /// `PUT /v0.1/relay/{relay}` (sphere-api.md 9.2): the phone relay is this Obi's Mac's, and
    /// answers the SHA-256 of each phone's relay token it holds, hex.
    pub async fn put_relay(&self, token: &str, relay: &str) -> Result<Vec<String>, ClientError> {
        let url = format!("{}/v0.1/relay/{relay}", self.base);
        let (status, body) = self
            .call(|| self.http.put(&url).bearer_auth(token).body(""))
            .await?;
        if !matches!(status, 200 | 201) {
            return Err(Client::refused(status, &body));
        }
        let hex = |d: &Value| {
            d.as_str()
                .filter(|h| {
                    h.len() == 64 && h.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                })
                .map(str::to_owned)
        };
        body["devices"]
            .as_array()
            .filter(|_| body["relay"] == relay)
            .and_then(|devices| devices.iter().map(hex).collect())
            .ok_or_else(|| ClientError::Protocol("a relay is {relay, devices: [hex…]}".into()))
    }

    /// `PUT /v0.1/relay/{relay}/devices/{device}`: a phone's relay token's SHA-256, hex.
    pub async fn put_relay_device(
        &self,
        token: &str,
        relay: &str,
        device: &str,
    ) -> Result<(), ClientError> {
        let url = format!("{}/v0.1/relay/{relay}/devices/{device}", self.base);
        let (status, body) = self
            .call(|| self.http.put(&url).bearer_auth(token).body(""))
            .await?;
        match status {
            200 | 201 => Ok(()),
            _ => Err(Client::refused(status, &body)),
        }
    }

    /// `DELETE /v0.1/relay/{relay}/devices/{device}`: that phone's token opens nothing from now,
    /// and its socket closes. One the relay doesn't have is gone already.
    pub async fn delete_relay_device(
        &self,
        token: &str,
        relay: &str,
        device: &str,
    ) -> Result<(), ClientError> {
        let url = format!("{}/v0.1/relay/{relay}/devices/{device}", self.base);
        let (status, body) = self
            .call(|| self.http.delete(&url).bearer_auth(token))
            .await?;
        match status {
            204 | 404 => Ok(()),
            _ => Err(Client::refused(status, &body)),
        }
    }

    /// Replaces this Obi's card with a new one its owner signed (identity.md section 3).
    pub async fn update_card(
        &self,
        token: &str,
        obi: &str,
        card: &Value,
    ) -> Result<Value, ClientError> {
        let url = self.sphere_path(&format!("/members/{obi}/card"));
        let body = json!({"card": card});
        let (code, answer) = self
            .call(|| self.http.put(&url).bearer_auth(token).json(&body))
            .await?;
        Client::expect(code, answer, &[200], "wire/member")
    }

    /// Sends a signed envelope. A retry of one already recorded answers its original place (`200`).
    pub async fn send(&self, token: &str, envelope: &Value) -> Result<Sent, ClientError> {
        let url = self.sphere_path("/messages");
        let (status, body) = self
            .call(|| self.http.post(&url).bearer_auth(token).json(envelope))
            .await?;
        let body = Client::expect(status, body, &[200, 202], "wire/send.response")?;
        serde_json::from_value(body).map_err(|e| ClientError::Protocol(e.to_string()))
    }

    /// The deliveries waiting for the Obi, oldest first; the Sphere may hold the call up to `wait`
    /// seconds (0 to 25) while there are none.
    pub async fn deliveries(
        &self,
        token: &str,
        limit: u32,
        wait: u32,
    ) -> Result<Vec<Delivery>, ClientError> {
        let url = self.sphere_path(&format!("/deliveries?limit={limit}&wait={wait}"));
        let (status, body) = self.call(|| self.http.get(&url).bearer_auth(token)).await?;
        if status != 200 {
            return Err(Client::refused(status, &body));
        }
        // Each delivery is read on its own: an envelope that isn't valid is the receiver's to judge
        // (and acknowledge), not a reason to refuse the whole answer.
        let list = body["deliveries"]
            .as_array()
            .ok_or_else(|| ClientError::Protocol("deliveries isn't a list".into()))?;
        list.iter()
            .map(|d| {
                Some(Delivery {
                    delivery_id: d["delivery_id"].as_str()?.to_owned(),
                    seq: d["seq"].as_u64()?,
                    relayed_at: d["relayed_at"].as_str()?.to_owned(),
                    envelope: d.get("envelope")?.clone(),
                })
            })
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| {
                ClientError::Protocol("a delivery without its id, seq or envelope".into())
            })
    }

    /// Acknowledges deliveries: answers how many were waiting for this Obi.
    pub async fn ack(&self, token: &str, ids: &[String]) -> Result<u64, ClientError> {
        let url = self.sphere_path("/deliveries/ack");
        let body = json!({"delivery_ids": ids});
        let (status, answer) = self
            .call(|| self.http.post(&url).bearer_auth(token).json(&body))
            .await?;
        let answer = Client::expect(status, answer, &[200], "wire/ack.response")?;
        Ok(answer["acked"].as_u64().unwrap_or(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refusals_quote_the_spec_error_or_the_oauth_one() {
        let e = Client::refused(
            403,
            &json!({"error": {"code": "invitation_invalid", "message": "no\nsuch invitation"}}),
        );
        assert_eq!(
            e.to_string(),
            "The Sphere refused it: invitation_invalid: no such invitation"
        );
        let e = Client::refused(
            400,
            &json!({"error": "invalid_grant", "error_description": "expired"}),
        );
        assert_eq!(e.code(), Some("invalid_grant"));
        let e = Client::refused(502, &Value::Null);
        assert_eq!(e.code(), Some("http_502"));
    }
}
