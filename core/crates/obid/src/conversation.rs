//! The one conversation shared by the apps and plan requests (`GET /v1/conversation`).

use crate::api::{ApiError, Shared};
use crate::events::Events;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const KEPT: usize = 500;
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Turn {
    pub id: String,
    pub who: String,
    pub text: String,
    pub at: String,
    #[serde(default)]
    pub jobs: Vec<String>,
}
pub struct Conversation {
    path: PathBuf,
    turns: Mutex<Vec<Turn>>,
    events: Events,
}
impl Conversation {
    pub fn open(home: &Path, events: Events) -> Conversation {
        let path = home.join("conversation.json");
        let turns = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<Turn>>(&b).ok())
            .unwrap_or_default();
        let turns = turns
            .into_iter()
            .rev()
            .take(KEPT)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        Conversation {
            path,
            turns: Mutex::new(turns),
            events,
        }
    }
    pub fn append(&self, who: &str, text: String, jobs: Vec<String>) -> std::io::Result<Turn> {
        let turn = Turn {
            id: uuid::Uuid::new_v4().to_string().to_lowercase(),
            who: who.into(),
            text,
            at: obi_protocol::time::format(obi_protocol::time::now()),
            jobs,
        };
        let mut turns = self.turns.lock().unwrap_or_else(|e| e.into_inner());
        turns.push(turn.clone());
        if turns.len() > KEPT {
            let excess = turns.len() - KEPT;
            turns.drain(..excess);
        }
        crate::store::write_private(
            &self.path,
            &serde_json::to_vec(&*turns).map_err(std::io::Error::other)?,
        )?;
        self.events
            .send("turn", serde_json::to_value(&turn).unwrap_or_default());
        Ok(turn)
    }
    fn page(&self, before: Option<&str>, limit: usize) -> Result<Vec<Turn>, ()> {
        let turns = self.turns.lock().unwrap_or_else(|e| e.into_inner());
        let end = match before {
            None => turns.len(),
            Some(id) => turns.iter().position(|t| t.id == id).ok_or(())?,
        };
        Ok(turns[end.saturating_sub(limit)..end].to_vec())
    }
    pub fn all(&self) -> Vec<Turn> {
        self.turns.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}
#[derive(Deserialize)]
pub struct Page {
    before: Option<String>,
    limit: Option<String>,
}
pub async fn get(
    State(shared): State<std::sync::Arc<Shared>>,
    Query(query): Query<Page>,
) -> Result<Response, ApiError> {
    let limit = match query.limit.as_deref() {
        None => 50,
        Some(raw) => raw
            .parse::<usize>()
            .map_err(|_| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "limit is a number."))?,
    };
    if limit == 0 {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "limit is 1 to 500.",
        ));
    }
    match shared
        .conversation
        .page(query.before.as_deref(), limit.min(500))
    {
        Ok(turns) => Ok((StatusCode::OK, axum::Json(json!(turns))).into_response()),
        Err(()) => Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "That conversation turn isn't in the thread.",
        )),
    }
}
