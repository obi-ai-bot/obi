//! Oby's conversations (#493): many threads, each with its own turns, shared by every device and
//! plan request (`GET /v1/conversations`, `GET /v1/conversation`, `PATCH` and `DELETE
//! /v1/conversations/{id}`). Each is one private file, `home/conversations/<id>.json`, written
//! whole. The single thread obid kept before (`home/conversation.json`) becomes the first one.

use crate::api::{ApiError, Shared};
use crate::events::Events;
use axum::body::Bytes;
use axum::extract::{Path as UrlPath, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The turns kept per conversation, the oldest pruned.
const KEPT: usize = 500;
/// The longest title a rename may set.
const TITLE: usize = 100;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Turn {
    pub id: String,
    pub who: String,
    pub text: String,
    pub at: String,
    #[serde(default)]
    pub jobs: Vec<String>,
    /// The conversation it's in. Turns kept before #493 have none until they're migrated.
    #[serde(default)]
    pub conversation: String,
}

/// One conversation as obid keeps it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Thread {
    id: String,
    title: String,
    pinned: bool,
    created: String,
    /// Raised on every turn, so the latest conversation is known to more than the second
    /// (`at` and `created` are whole seconds).
    sequence: u64,
    turns: Vec<Turn>,
}

impl Thread {
    fn last_activity(&self) -> &str {
        self.turns.last().map_or(&self.created, |t| &t.at)
    }

    /// As `GET /v1/conversations` lists it and the `conversation` event sends it.
    fn summary(&self) -> Value {
        json!({
            "id": self.id,
            "title": self.title,
            "pinned": self.pinned,
            "created": self.created,
            "lastActivity": self.last_activity(),
        })
    }
}

/// Which conversation a plan request joins.
pub enum Target {
    /// The latest, as every app did before #493; a new one when there's none yet.
    Latest,
    /// A new one, titled from the user's words.
    New,
    Id(String),
}

#[derive(Debug)]
pub enum Error {
    /// No conversation has that id: deleted, or never there.
    NoConversation,
    /// The turn isn't in the conversation (pruned since).
    NoTurn,
    /// It couldn't be written.
    Io(std::io::Error),
}

impl From<Error> for ApiError {
    fn from(error: Error) -> ApiError {
        match error {
            Error::NoConversation => ApiError::new(
                StatusCode::NOT_FOUND,
                "There's no conversation with that id.",
            ),
            Error::NoTurn => ApiError::new(
                StatusCode::NOT_FOUND,
                "That conversation turn isn't in the thread.",
            ),
            Error::Io(_) => ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "The conversation couldn't be kept.",
            ),
        }
    }
}

pub struct Conversations {
    dir: PathBuf,
    threads: Mutex<Vec<Thread>>,
    events: Events,
}

impl Conversations {
    /// The conversations in `home/conversations`, after moving the single thread of obid before
    /// #493 (`home/conversation.json`) into the first of them.
    pub fn open(home: &Path, events: Events) -> Conversations {
        let dir = home.join("conversations");
        if let Err(e) = crate::store::make_private_dir(&dir) {
            tracing::warn!("can't make {}: {e}", dir.display());
        }
        let threads = crate::store::load_dir::<Thread>(&dir)
            .into_iter()
            .filter(|t| {
                let named = is_id(&t.id) && dir.join(format!("{}.json", t.id)).is_file();
                if !named {
                    tracing::warn!(
                        "{} holds a conversation not named after its id",
                        dir.display()
                    );
                }
                named
            })
            .collect();
        let conversations = Conversations {
            dir,
            threads: Mutex::new(threads),
            events,
        };
        conversations.migrate(&home.join("conversation.json"));
        conversations
    }

    /// The thread obid kept before #493 becomes a conversation, with all its turns, and its file
    /// goes. The conversation is named after the thread's first turn, so a move cut short (the
    /// conversation written, the old file still there) isn't made twice.
    fn migrate(&self, old: &Path) {
        let Ok(bytes) = std::fs::read(old) else {
            return;
        };
        let Ok(mut turns) = serde_json::from_slice::<Vec<Turn>>(&bytes) else {
            tracing::warn!("{} isn't a conversation; left as it is", old.display());
            return;
        };
        if let Some(first) = turns.first() {
            let id = if is_id(&first.id) {
                first.id.clone()
            } else {
                new_id()
            };
            let mut threads = self.lock();
            if !threads.iter().any(|t| t.id == id) {
                let excess = turns.len().saturating_sub(KEPT);
                turns.drain(..excess);
                for turn in &mut turns {
                    turn.conversation = id.clone();
                }
                let thread = Thread {
                    title: turns
                        .iter()
                        .find(|t| t.who == "user")
                        .map_or_else(|| "Conversation with Oby".into(), |t| titled(&t.text)),
                    created: turns[0].at.clone(),
                    sequence: next_sequence(&threads),
                    pinned: false,
                    id,
                    turns,
                };
                if let Err(e) = self.write(&thread) {
                    tracing::warn!("can't move {} into a conversation: {e}", old.display());
                    return;
                }
                tracing::info!(
                    "the conversation in {} is now conversation {}",
                    old.display(),
                    thread.id
                );
                threads.push(thread);
            }
        }
        if let Err(e) = std::fs::remove_file(old) {
            tracing::warn!("can't remove {}: {e}", old.display());
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Thread>> {
        self.threads.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn write(&self, thread: &Thread) -> std::io::Result<()> {
        crate::store::write_private(
            &self.dir.join(format!("{}.json", thread.id)),
            &serde_json::to_vec(thread).map_err(std::io::Error::other)?,
        )
    }

    /// The user's words join `target` (made first when it's new): its id, and its turns before
    /// them, oldest first.
    pub fn begin(&self, target: Target, said: String) -> Result<(String, Vec<Turn>), Error> {
        let mut threads = self.lock();
        let found = match target {
            Target::Id(id) => Some(
                threads
                    .iter()
                    .position(|t| t.id == id)
                    .ok_or(Error::NoConversation)?,
            ),
            Target::Latest => latest(&threads),
            Target::New => None,
        };
        let index = found.unwrap_or_else(|| {
            threads.push(Thread {
                id: new_id(),
                title: titled(&said),
                pinned: false,
                created: obi_protocol::time::format(obi_protocol::time::now()),
                sequence: 0,
                turns: vec![],
            });
            threads.len() - 1
        });
        let before = threads[index].turns.clone();
        let turn = match self.add(&mut threads, index, "user", said, vec![]) {
            Ok(turn) => turn,
            Err(e) => {
                if found.is_none() {
                    threads.remove(index);
                }
                return Err(e);
            }
        };
        // A new conversation is announced before its first turn.
        if found.is_none() {
            self.events.send("conversation", threads[index].summary());
        }
        self.events
            .send("turn", serde_json::to_value(&turn).unwrap_or_default());
        Ok((threads[index].id.clone(), before))
    }

    /// Adds a turn to the conversation `id`.
    pub fn append(
        &self,
        id: &str,
        who: &str,
        text: String,
        jobs: Vec<String>,
    ) -> Result<Turn, Error> {
        let mut threads = self.lock();
        let index = threads
            .iter()
            .position(|t| t.id == id)
            .ok_or(Error::NoConversation)?;
        let turn = self.add(&mut threads, index, who, text, jobs)?;
        self.events
            .send("turn", serde_json::to_value(&turn).unwrap_or_default());
        Ok(turn)
    }

    /// The turn, kept and written; its event is the caller's.
    fn add(
        &self,
        threads: &mut [Thread],
        index: usize,
        who: &str,
        text: String,
        jobs: Vec<String>,
    ) -> Result<Turn, Error> {
        let sequence = next_sequence(threads);
        let thread = &mut threads[index];
        let turn = Turn {
            id: new_id(),
            who: who.into(),
            text,
            at: obi_protocol::time::format(obi_protocol::time::now()),
            jobs,
            conversation: thread.id.clone(),
        };
        thread.turns.push(turn.clone());
        let excess = thread.turns.len().saturating_sub(KEPT);
        thread.turns.drain(..excess);
        thread.sequence = sequence;
        self.write(thread).map_err(Error::Io)?;
        Ok(turn)
    }

    /// Up to `limit` turns, oldest first, ending before the turn `before` (or at the latest):
    /// of the conversation `id`, else of the one holding `before`, else of the latest.
    fn page(
        &self,
        id: Option<&str>,
        before: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Turn>, Error> {
        let threads = self.lock();
        let thread = match (id, before) {
            (Some(id), _) => threads
                .iter()
                .find(|t| t.id == id)
                .ok_or(Error::NoConversation)?,
            (None, Some(turn)) => threads
                .iter()
                .find(|t| t.turns.iter().any(|t| t.id == turn))
                .ok_or(Error::NoTurn)?,
            (None, None) => match latest(&threads) {
                Some(index) => &threads[index],
                None => return Ok(vec![]),
            },
        };
        let end = match before {
            None => thread.turns.len(),
            Some(id) => thread
                .turns
                .iter()
                .position(|t| t.id == id)
                .ok_or(Error::NoTurn)?,
        };
        Ok(thread.turns[end.saturating_sub(limit)..end].to_vec())
    }

    /// Up to `limit` conversations after the one `after` (or from the first): the pinned ones,
    /// then the rest, each newest first.
    fn list(&self, after: Option<&str>, limit: usize) -> Result<Vec<Value>, Error> {
        let threads = self.lock();
        let mut order: Vec<&Thread> = threads.iter().collect();
        order.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then(b.sequence.cmp(&a.sequence))
                .then_with(|| a.id.cmp(&b.id))
        });
        let start = match after {
            None => 0,
            Some(id) => {
                order
                    .iter()
                    .position(|t| t.id == id)
                    .ok_or(Error::NoConversation)?
                    + 1
            }
        };
        Ok(order
            .iter()
            .skip(start)
            .take(limit)
            .map(|t| t.summary())
            .collect())
    }

    /// Renames or pins the conversation `id`.
    fn change(
        &self,
        id: &str,
        title: Option<String>,
        pinned: Option<bool>,
    ) -> Result<Value, Error> {
        let mut threads = self.lock();
        let thread = threads
            .iter_mut()
            .find(|t| t.id == id)
            .ok_or(Error::NoConversation)?;
        let kept = thread.clone();
        if let Some(title) = title {
            thread.title = title;
        }
        if let Some(pinned) = pinned {
            thread.pinned = pinned;
        }
        if let Err(e) = self.write(thread) {
            *thread = kept;
            return Err(Error::Io(e));
        }
        let summary = thread.summary();
        self.events.send("conversation", summary.clone());
        Ok(summary)
    }

    /// Forgets the conversation `id` and its turns. The jobs it started stay, with its id.
    fn delete(&self, id: &str) -> Result<(), Error> {
        let mut threads = self.lock();
        let index = threads
            .iter()
            .position(|t| t.id == id)
            .ok_or(Error::NoConversation)?;
        match std::fs::remove_file(self.dir.join(format!("{id}.json"))) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::Io(e)),
        }
        threads.remove(index);
        self.events
            .send("conversation", json!({"id": id, "deleted": true}));
        Ok(())
    }
}

/// The conversation with the latest turn.
fn latest(threads: &[Thread]) -> Option<usize> {
    (0..threads.len()).max_by_key(|&i| threads[i].sequence)
}

fn next_sequence(threads: &[Thread]) -> u64 {
    threads.iter().map(|t| t.sequence).max().unwrap_or(0) + 1
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_lowercase()
}

/// An id obid made (a lower-case UUID), so a file name of its own.
fn is_id(id: &str) -> bool {
    id.len() == 36
        && id
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f' | b'-'))
}

/// A conversation's title from the user's first words, as Sangam's design names them
/// (design/app/src/renderer/src/chats.ts, `titled`): the first line, at most 48 characters
/// (45 and `…` when longer), its first letter upper-case.
pub fn titled(text: &str) -> String {
    let line = text.trim().lines().next().unwrap_or("").trim();
    let short = if line.chars().count() > 48 {
        format!("{}…", line.chars().take(45).collect::<String>().trim_end())
    } else {
        line.to_owned()
    };
    let mut chars = short.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => "New conversation".into(),
    }
}

fn limit(raw: Option<&str>) -> Result<usize, ApiError> {
    let limit = match raw {
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
    Ok(limit.min(500))
}

#[derive(Deserialize)]
pub struct Page {
    id: Option<String>,
    before: Option<String>,
    limit: Option<String>,
}

/// `GET /v1/conversation?id=&before=&limit=`: one page of a conversation's turns, oldest first.
pub async fn get(
    State(shared): State<std::sync::Arc<Shared>>,
    Query(query): Query<Page>,
) -> Result<Response, ApiError> {
    let limit = limit(query.limit.as_deref())?;
    let turns = shared
        .conversations
        .page(query.id.as_deref(), query.before.as_deref(), limit)?;
    Ok((StatusCode::OK, axum::Json(json!(turns))).into_response())
}

#[derive(Deserialize)]
pub struct ListPage {
    after: Option<String>,
    limit: Option<String>,
}

/// `GET /v1/conversations?after=&limit=`: the conversations, pinned first, then newest first.
pub async fn list(
    State(shared): State<std::sync::Arc<Shared>>,
    Query(query): Query<ListPage>,
) -> Result<Response, ApiError> {
    let limit = limit(query.limit.as_deref())?;
    let list = shared.conversations.list(query.after.as_deref(), limit)?;
    Ok((StatusCode::OK, axum::Json(json!(list))).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Change {
    title: Option<String>,
    pinned: Option<bool>,
}

/// `PATCH /v1/conversations/{id}`: a new title, pinned or not.
pub async fn update(
    State(shared): State<std::sync::Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let change: Change = serde_json::from_slice(&body).map_err(|_| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "The body is {\"title\": …, \"pinned\": …}.",
        )
    })?;
    if change.title.is_none() && change.pinned.is_none() {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send a title, pinned, or both.",
        ));
    }
    let title = change.title.map(|t| t.trim().to_owned());
    if title
        .as_ref()
        .is_some_and(|t| t.is_empty() || t.chars().count() > TITLE || t.contains('\n'))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "title is one line of 1 to 100 characters.",
        ));
    }
    let summary = shared.conversations.change(&id, title, change.pinned)?;
    Ok((StatusCode::OK, axum::Json(summary)).into_response())
}

/// `DELETE /v1/conversations/{id}`: the conversation goes; the jobs it started stay.
pub async fn remove(
    State(shared): State<std::sync::Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    shared.conversations.delete(&id)?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

#[cfg(test)]
mod tests {
    use super::titled;

    #[test]
    fn titles_are_the_first_line_as_the_design_cuts_it() {
        assert_eq!(
            titled("  review oby PR #33\nand the vault one"),
            "Review oby PR #33"
        );
        assert_eq!(
            titled("why did oberon’s build go from 4 to 11 minutes since the update?"),
            "Why did oberon’s build go from 4 to 11 minute…"
        );
        assert_eq!(
            titled("x".repeat(48).as_str()),
            "X".to_owned() + &"x".repeat(47)
        );
        assert_eq!(titled("éclair"), "Éclair");
        assert_eq!(titled(" \n "), "New conversation");
    }
}
