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
/// The conversations kept: past it, starting one forgets the oldest that isn't pinned.
pub const CONVERSATIONS: usize = 200;
/// The longest title a rename may set.
const TITLE: usize = 100;
/// The longest search a list takes, in characters (#593).
pub const QUERY: usize = 200;
/// The turns a search returns per conversation, the latest first.
pub const HITS: usize = 3;
/// The most of a found turn's text a search returns, in characters.
pub const EXCERPT: usize = 500;
/// Where the thread of obid before #493 is kept once it's a conversation, for a rollback.
const PRE_493: &str = "conversation.json.pre-493";

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
    /// True on the turn that tells its conversation how a job it started ended (#351). Its first
    /// line is obid's own words; the second, when there is one, is the first line of the job's
    /// summary, which its agent may have written: the brain's briefing reads only the first.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ended: bool,
    /// The artifacts Oby made in this turn, `{id, version}` each (docs/conversation-harness.md,
    /// section 4). Left out when it made none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<Value>,
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
    /// (`at` and `created` are whole seconds). Each is one more than the highest kept, so no
    /// two conversations share one.
    sequence: u64,
    turns: Vec<Turn>,
}

impl Thread {
    fn last_activity(&self) -> &str {
        self.turns.last().map_or(&self.created, |t| &t.at)
    }

    /// Where it stands in the list: pinned first, then the latest turn first.
    fn key(&self) -> Cursor {
        Cursor {
            pinned: self.pinned,
            sequence: self.sequence,
        }
    }

    /// As `GET /v1/conversations` lists it and the `conversation` event sends it.
    fn summary(&self) -> Value {
        json!({
            "id": self.id,
            "title": self.title,
            "pinned": self.pinned,
            "created": self.created,
            "lastActivity": self.last_activity(),
            "cursor": self.key().to_string(),
        })
    }
}

/// A conversation a search found (#593): what the list says of it, and the turns that hold the
/// words, the latest first, each with its place in the conversation from 1.
#[derive(Debug, Clone)]
pub struct Found {
    pub id: String,
    pub title: String,
    pub summary: Value,
    /// How many turns it keeps.
    pub turns: usize,
    pub hits: Vec<(usize, Turn)>,
}

/// A conversation's place in the list, as `after` takes it: `1-42` (pinned, sequence 42) or
/// `0-42`. Ordered as the list is, first to last.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pinned: bool,
    sequence: u64,
}

impl Cursor {
    fn parse(text: &str) -> Option<Cursor> {
        let (pinned, sequence) = text.split_once('-')?;
        Some(Cursor {
            pinned: match pinned {
                "1" => true,
                "0" => false,
                _ => return None,
            },
            sequence: sequence.parse().ok()?,
        })
    }

    /// True when a conversation at `self` is listed after one at `other`.
    fn after(self, other: Cursor) -> bool {
        (self.pinned, self.sequence) < (other.pinned, other.sequence)
    }
}

impl std::fmt::Display for Cursor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}-{}", u8::from(self.pinned), self.sequence)
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

/// Where a plan request's words went.
pub struct Begun {
    pub conversation: String,
    /// The user's turn: what the turn's step events name (#546).
    pub turn: String,
    /// Its turns before them, oldest first.
    pub before: Vec<Turn>,
    /// True when the words started it.
    pub started: bool,
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
    /// #493 (`home/conversation.json`) into the first of them, and forgetting the oldest past
    /// [`CONVERSATIONS`].
    pub fn open(home: &Path, events: Events) -> Conversations {
        let dir = home.join("conversations");
        if let Err(e) = crate::store::make_private_dir(&dir) {
            tracing::warn!("can't make {}: {e}", dir.display());
        }
        let threads: Vec<Thread> = crate::store::load_dir::<Thread>(&dir)
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
        conversations.migrate(home);
        conversations.prune(&mut conversations.lock());
        conversations
    }

    /// The thread obid kept before #493 (`home/conversation.json`) becomes a conversation, with
    /// all its turns, and its file is kept as `home/conversation.json.pre-493`. The conversation
    /// is named after the thread's first turn when obid made that id, so a move cut short (the
    /// conversation written, the old file still there) isn't made twice.
    fn migrate(&self, home: &Path) {
        let old = home.join("conversation.json");
        let Ok(bytes) = std::fs::read(&old) else {
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
                // The conversation's name in its folder must be on disk before the old file goes.
                if let Err(e) = self.write(&thread).and_then(|()| sync_dir(&self.dir)) {
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
        if let Err(e) = std::fs::rename(&old, home.join(PRE_493)) {
            tracing::warn!("can't move {} aside: {e}", old.display());
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

    /// The user's words join `target` (made first when it's new).
    pub fn begin(&self, target: Target, said: String) -> Result<Begun, Error> {
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
        let turn = match self.add(&mut threads, index, "user", said, vec![], false, vec![]) {
            Ok(turn) => turn.id,
            Err(e) => {
                if found.is_none() {
                    threads.remove(index);
                }
                return Err(e);
            }
        };
        let conversation = threads[index].id.clone();
        if found.is_none() {
            self.prune(&mut threads);
        }
        Ok(Begun {
            conversation,
            turn,
            before,
            started: found.is_none(),
        })
    }

    /// The conversation with the latest turn, if there is one.
    pub fn latest_id(&self) -> Option<String> {
        let threads = self.lock();
        latest(&threads).map(|index| threads[index].id.clone())
    }

    /// Adds a turn to the conversation `id`.
    pub fn append(
        &self,
        id: &str,
        who: &str,
        text: String,
        jobs: Vec<String>,
    ) -> Result<Turn, Error> {
        self.append_as(id, who, text, jobs, false, vec![])
    }

    /// Oby's turn in the conversation `id`, with the artifacts it made (`{id, version}` each).
    pub fn append_made(
        &self,
        id: &str,
        text: String,
        jobs: Vec<String>,
        artifacts: Vec<Value>,
    ) -> Result<Turn, Error> {
        self.append_as(id, "oby", text, jobs, false, artifacts)
    }

    /// Oby's turn telling the conversation `id` how the job `job` ended ([`job_report`], #351).
    pub fn job_ended(&self, id: &str, text: String, job: String) -> Result<Turn, Error> {
        self.append_as(id, "oby", text, vec![job], true, vec![])
    }

    fn append_as(
        &self,
        id: &str,
        who: &str,
        text: String,
        jobs: Vec<String>,
        ended: bool,
        artifacts: Vec<Value>,
    ) -> Result<Turn, Error> {
        let mut threads = self.lock();
        let index = threads
            .iter()
            .position(|t| t.id == id)
            .ok_or(Error::NoConversation)?;
        self.add(&mut threads, index, who, text, jobs, ended, artifacts)
    }

    /// The turn, kept, written and announced: the conversation as it is now, then the turn.
    #[allow(clippy::too_many_arguments)]
    fn add(
        &self,
        threads: &mut [Thread],
        index: usize,
        who: &str,
        text: String,
        jobs: Vec<String>,
        ended: bool,
        artifacts: Vec<Value>,
    ) -> Result<Turn, Error> {
        let sequence = next_sequence(threads);
        let thread = &mut threads[index];
        let kept = thread.clone();
        let turn = Turn {
            id: new_id(),
            who: who.into(),
            text,
            at: obi_protocol::time::format(obi_protocol::time::now()),
            jobs,
            conversation: thread.id.clone(),
            ended,
            artifacts,
        };
        thread.turns.push(turn.clone());
        let excess = thread.turns.len().saturating_sub(KEPT);
        thread.turns.drain(..excess);
        thread.sequence = sequence;
        if let Err(error) = self.write(thread) {
            *thread = kept;
            return Err(Error::Io(error));
        }
        self.events.send("conversation", thread.summary());
        self.events
            .send("turn", serde_json::to_value(&turn).unwrap_or_default());
        Ok(turn)
    }

    /// Past [`CONVERSATIONS`], forgets the oldest that are neither pinned nor the latest.
    fn prune(&self, threads: &mut Vec<Thread>) {
        while threads.len() > CONVERSATIONS {
            let newest = threads.iter().map(|t| t.sequence).max().unwrap_or(0);
            let Some(oldest) = threads
                .iter()
                .enumerate()
                .filter(|(_, t)| !t.pinned && t.sequence != newest)
                .min_by_key(|(_, t)| t.sequence)
                .map(|(i, _)| i)
            else {
                return;
            };
            if let Err(e) = self.forget(threads, oldest) {
                tracing::warn!("can't forget an old conversation: {e:?}");
                return;
            }
        }
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

    /// Up to `limit` conversations listed after `after` (or from the first): the pinned ones,
    /// then the rest, each newest first. A cursor is a place, not a conversation, so one that
    /// moved since is skipped or listed again, never anything else.
    fn list(&self, after: Option<Cursor>, limit: usize) -> Vec<Value> {
        let threads = self.lock();
        ordered(&threads, after)
            .iter()
            .take(limit)
            .map(|t| t.summary())
            .collect()
    }

    /// Up to `limit` conversations, in the list's order after `after`, whose title or one of
    /// whose turns holds every one of `words` (any case): a plain text match, no model (#593).
    /// Each comes with up to [`HITS`] of its turns that hold them, the latest first; none when
    /// only the title does. `except` is left out: the conversation asking. Deleted conversations
    /// are gone from the list, so they're never found.
    pub fn search(
        &self,
        words: &[String],
        except: Option<&str>,
        after: Option<Cursor>,
        limit: usize,
    ) -> Vec<Found> {
        if words.is_empty() {
            return vec![];
        }
        let holds = |text: &str| {
            let text = text.to_lowercase();
            words.iter().all(|w| text.contains(w.as_str()))
        };
        let threads = self.lock();
        ordered(&threads, after)
            .into_iter()
            .filter(|t| except != Some(t.id.as_str()))
            .filter_map(|t| {
                let hits: Vec<(usize, Turn)> = t
                    .turns
                    .iter()
                    .enumerate()
                    .rev()
                    .filter(|(_, turn)| holds(&turn.text))
                    .take(HITS)
                    .map(|(index, turn)| (index + 1, turn.clone()))
                    .collect();
                (!hits.is_empty() || holds(&t.title)).then(|| Found {
                    id: t.id.clone(),
                    title: t.title.clone(),
                    summary: t.summary(),
                    turns: t.turns.len(),
                    hits,
                })
            })
            .take(limit)
            .collect()
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
    pub fn delete(&self, id: &str) -> Result<(), Error> {
        let mut threads = self.lock();
        let index = threads
            .iter()
            .position(|t| t.id == id)
            .ok_or(Error::NoConversation)?;
        self.forget(&mut threads, index)
    }

    fn forget(&self, threads: &mut Vec<Thread>, index: usize) -> Result<(), Error> {
        let id = threads[index].id.clone();
        match std::fs::remove_file(self.dir.join(format!("{id}.json"))) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::Io(e)),
        }
        threads.remove(index);
        // Its agent session's room, checkouts and login go with it (crate::brain::harness).
        let _ = std::fs::remove_dir_all(self.dir.join(&id));
        self.events
            .send("conversation", json!({"id": id, "deleted": true}));
        Ok(())
    }
}

/// What Oby tells a conversation when a job its plan started ends (#351), from the job as its
/// `job` event sends it: the conversation and the turn's text, or none for a job no conversation
/// started, one that was dismissed, or one that hasn't ended. The first line is obid's own words:
/// the job's title, how it ended, its pull request or why it wasn't published. The first line of
/// its summary, which its agent may have written, follows on a line of its own. Every secret obid
/// holds is taken out.
pub fn job_report(job: &Value) -> Option<(String, String)> {
    let conversation = job["conversation"].as_str()?;
    if !job["dismissed"].is_null() {
        return None;
    }
    let first_line = |key: &str| {
        job[key]
            .as_str()?
            .lines()
            .find(|l| !l.trim().is_empty())
            .map(|l| crate::brain::briefing::line(l, 300))
    };
    let title = crate::brain::briefing::line(job["title"].as_str().unwrap_or("A job"), 80);
    let said = match job["status"].as_str()? {
        "done" => match (job["published"].as_str(), first_line("publishError")) {
            (Some(url), _) => format!("{title} is done: {url}"),
            (None, Some(why)) => format!("{title} is done, but it wasn't published: {why}"),
            (None, None) => format!("{title} is done."),
        },
        "failed" => format!("{title} failed."),
        "stopped" => format!("{title} was stopped."),
        "interrupted" => format!("{title} was interrupted."),
        _ => return None,
    };
    let text = match first_line("summary") {
        Some(summary) => format!("{said}\n{summary}"),
        None => said,
    };
    Some((
        conversation.to_owned(),
        crate::secrets::known().redact(&text),
    ))
}

/// Follows obid's job events (#351): when a job a conversation's plan started goes from queued or
/// running to an end, that conversation gets one Oby turn saying how ([`job_report`]), with the
/// job's card. What had ended when obid started says nothing, and neither does a dismissed job or
/// one that no conversation started.
pub fn report_job_ends(shared: std::sync::Arc<Shared>) {
    let mut bus = shared.events.subscribe();
    let mut stopping = shared.stopping.clone();
    let mut active: std::collections::HashMap<String, bool> = shared
        .jobs
        .list(usize::MAX)
        .iter()
        .map(|j| (j.id.clone(), j.status.is_active()))
        .collect();
    tokio::spawn(async move {
        loop {
            let event = tokio::select! {
                got = bus.recv() => match got {
                    Ok(event) => event,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                },
                _ = stopping.changed() => return,
            };
            let Some(id) = event.data["id"].as_str().filter(|_| event.name == "job") else {
                continue;
            };
            let now = matches!(event.data["status"].as_str(), Some("queued" | "running"));
            if active.insert(id.to_owned(), now) != Some(true) || now {
                continue;
            }
            let Some((conversation, text)) = job_report(&event.data) else {
                continue;
            };
            if let Err(e) = shared
                .conversations
                .job_ended(&conversation, text, id.to_owned())
            {
                tracing::info!("job {id} ended; conversation {conversation} wasn't told: {e:?}");
            }
        }
    });
}

/// The conversations as the list orders them, after `after` (or from the first): the pinned
/// ones, then the rest, each newest first.
fn ordered(threads: &[Thread], after: Option<Cursor>) -> Vec<&Thread> {
    let mut order: Vec<&Thread> = threads
        .iter()
        .filter(|t| after.is_none_or(|cursor| t.key().after(cursor)))
        .collect();
    order.sort_by(|a, b| {
        (b.pinned, b.sequence)
            .cmp(&(a.pinned, a.sequence))
            .then_with(|| a.id.cmp(&b.id))
    });
    order
}

/// The words a search looks for: `q` split on spaces, lower-case, each without the punctuation
/// around it ("target?" is "target"; "off-limits" stays whole).
pub fn search_words(q: &str) -> Vec<String> {
    q.split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect()
}

/// At most [`EXCERPT`] characters of `text` around the first of `words` it holds, `…` where
/// it's cut.
pub fn excerpt(text: &str, words: &[String]) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= EXCERPT {
        return text.to_owned();
    }
    let lower = text.to_lowercase();
    // Where the first word is, in characters (lower-casing can change byte lengths).
    let at = words
        .iter()
        .filter_map(|w| lower.find(w.as_str()))
        .min()
        .map_or(0, |byte| lower[..byte].chars().count());
    let start = at.saturating_sub(EXCERPT / 4).min(chars.len() - EXCERPT);
    let end = start + EXCERPT;
    let mut cut: String = chars[start..end].iter().collect();
    if start > 0 {
        cut.insert(0, '…');
    }
    if end < chars.len() {
        cut.push('…');
    }
    cut
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

/// Writes the folder's own entries (the names in it) to the disk.
fn sync_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
}

/// Ends a line: what `lines()` reads, and the Unicode line and paragraph separators.
fn breaks_line(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// A conversation's title from the user's first words, as Sangam's design names them
/// (design/app/src/renderer/src/chats.ts, `titled`): the first line, at most 48 characters
/// (45 and `…` when longer), its first letter upper-case. Other control characters are spaces.
pub fn titled(text: &str) -> String {
    let line: String = text
        .trim()
        .split(breaks_line)
        .next()
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let line = line.trim();
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
    q: Option<String>,
}

/// `GET /v1/conversations?after=&limit=&q=`: the conversations, pinned first, then newest
/// first. With `q`, only those whose title or a turn holds every word of it, each with the latest
/// turn that does (`turn`, null when only the title does), its text cut to [`EXCERPT`] (#593).
pub async fn list(
    State(shared): State<std::sync::Arc<Shared>>,
    Query(query): Query<ListPage>,
) -> Result<Response, ApiError> {
    let limit = limit(query.limit.as_deref())?;
    let after = match query.after.as_deref() {
        None => None,
        Some(text) => Some(Cursor::parse(text).ok_or_else(|| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "after is the cursor of a conversation the list gave.",
            )
        })?),
    };
    let Some(q) = query.q else {
        let list = shared.conversations.list(after, limit);
        return Ok((StatusCode::OK, axum::Json(json!(list))).into_response());
    };
    let words = search_words(&q);
    if words.is_empty() || q.chars().count() > QUERY {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "q is 1 to 200 characters, with a word to find.",
        ));
    }
    let found: Vec<Value> = shared
        .conversations
        .search(&words, None, after, limit)
        .into_iter()
        .map(|found| {
            let mut item = found.summary;
            item["turn"] = found.hits.first().map_or(Value::Null, |(_, turn)| {
                json!({
                    "id": turn.id,
                    "who": turn.who,
                    "at": turn.at,
                    "text": excerpt(&turn.text, &words),
                })
            });
            item
        })
        .collect();
    Ok((StatusCode::OK, axum::Json(json!(found))).into_response())
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
            "The body is {\"title\": \"…\", \"pinned\": true or false}.",
        )
    })?;
    if change.title.is_none() && change.pinned.is_none() {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send a title, pinned, or both.",
        ));
    }
    let title = change.title.map(|t| t.trim().to_owned());
    if title.as_ref().is_some_and(|t| {
        t.is_empty()
            || t.chars().count() > TITLE
            || t.chars().any(|c| c.is_control() || breaks_line(c))
    }) {
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
    use super::{Cursor, job_report, titled};
    use serde_json::json;

    /// A job a conversation started says how it ended, in obid's words first: its title, the
    /// outcome, the pull request or why it wasn't published; its summary's first line, which its
    /// agent may have written, on a line of its own, with every secret obid holds taken out.
    #[test]
    fn a_job_that_ends_tells_its_conversation_how() {
        let secret = "s3cr3t-token-351-value";
        crate::secrets::known().learn("vault TEST_351", secret);
        let job = |status: &str| {
            json!({"id": "j1", "title": "Fix oby #351", "status": status, "conversation": "c1",
                "summary": "", "published": null, "publishError": null, "dismissed": null})
        };
        let mut failed = job("failed");
        failed["summary"] = json!(format!("\n Not logged in with {secret}\nMore below."));
        assert_eq!(
            job_report(&failed),
            Some((
                "c1".into(),
                "Fix oby #351 failed.\nNot logged in with [redacted: vault TEST_351]".into()
            ))
        );
        let mut published = job("done");
        published["published"] = json!("https://github.com/obi-ai-bot/obi/pull/700");
        published["summary"] = json!("Reports reach the chat.");
        assert_eq!(
            job_report(&published).unwrap().1,
            "Fix oby #351 is done: https://github.com/obi-ai-bot/obi/pull/700\nReports reach the chat."
        );
        let mut unpublished = job("done");
        unpublished["publishError"] = json!("Not published: the secret scan couldn't run.\nwhy");
        assert_eq!(
            job_report(&unpublished).unwrap().1,
            "Fix oby #351 is done, but it wasn't published: Not published: the secret scan couldn't run."
        );
        assert_eq!(job_report(&job("done")).unwrap().1, "Fix oby #351 is done.");
        assert_eq!(
            job_report(&job("stopped")).unwrap().1,
            "Fix oby #351 was stopped."
        );
        assert_eq!(
            job_report(&job("interrupted")).unwrap().1,
            "Fix oby #351 was interrupted."
        );
        // Nothing for a job still under way, one no conversation started, or one let go.
        assert_eq!(job_report(&job("running")), None);
        assert_eq!(job_report(&job("queued")), None);
        let mut whole = job("failed");
        whole["conversation"] = json!(null);
        assert_eq!(job_report(&whole), None);
        let mut dismissed = job("stopped");
        dismissed["dismissed"] = json!("2026-10-17T00:00:00Z");
        assert_eq!(job_report(&dismissed), None);
        crate::secrets::known().forget("vault TEST_351");
    }

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
        assert_eq!(titled("one\r\ntwo"), "One");
        assert_eq!(titled("one\u{2028}two"), "One");
        assert_eq!(titled("tab\there"), "Tab here");
    }

    #[test]
    fn failed_append_keeps_pruned_turns_sequence_and_events_unchanged() {
        let home = std::env::temp_dir().join(format!("obid-conversation-{}", uuid::Uuid::new_v4()));
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(home.clone());
        let events = crate::events::Events::new();
        let conversations = super::Conversations::open(&home, events.clone());
        let id = conversations
            .begin(super::Target::New, "first".into())
            .unwrap()
            .conversation;
        {
            let mut threads = conversations.lock();
            let thread = &mut threads[0];
            let first = thread.turns[0].clone();
            thread.turns = (0..super::KEPT)
                .map(|i| super::Turn {
                    id: i.to_string(),
                    text: format!("kept {i}"),
                    ..first.clone()
                })
                .collect();
            conversations.write(thread).unwrap();
        }
        let before = serde_json::to_value(&*conversations.lock()).unwrap();
        let mut received = events.subscribe();
        let saved = home.join("saved");
        std::fs::rename(&conversations.dir, &saved).unwrap();
        std::fs::write(&conversations.dir, b"not a directory").unwrap();
        assert!(matches!(
            conversations.append(&id, "oby", "rejected".into(), vec![]),
            Err(super::Error::Io(_))
        ));
        assert_eq!(
            serde_json::to_value(&*conversations.lock()).unwrap(),
            before
        );
        assert!(matches!(
            received.try_recv(),
            Err(tokio::sync::broadcast::error::TryRecvError::Empty)
        ));
        std::fs::remove_file(&conversations.dir).unwrap();
        std::fs::rename(&saved, &conversations.dir).unwrap();
        conversations
            .append(&id, "oby", "accepted".into(), vec![])
            .unwrap();
        let threads = conversations.lock();
        assert_eq!(threads[0].turns.len(), super::KEPT);
        assert_eq!(threads[0].turns[0].text, "kept 1");
        assert_eq!(threads[0].turns.last().unwrap().text, "accepted");
        assert!(!threads[0].turns.iter().any(|turn| turn.text == "rejected"));
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn cursors_read_back_and_order_as_the_list() {
        let pinned = Cursor::parse("1-3").unwrap();
        let older = Cursor::parse("0-7").unwrap();
        let newer = Cursor::parse("0-9").unwrap();
        assert_eq!(pinned.to_string(), "1-3");
        assert!(older.after(newer) && newer.after(pinned) && !pinned.after(older));
        for bad in ["", "2-1", "1-", "-1", "1-x", "1-2-3", "a"] {
            assert_eq!(Cursor::parse(bad), None, "{bad}");
        }
    }
}
