//! One running plug-in's `obi-plugin/0.1` connection: JSON-RPC 2.0 over its stdin and stdout,
//! one JSON object per line, split on `\n` only (docs/ARCHITECTURE.md 5.4). Its stderr goes to
//! the log, at most 64 KB a minute.
//!
//! Everything the plug-in writes is data. Its requests are answered only for the kinds it
//! serves (`events/emit` for `events`), and an event reaches `obid` only after
//! [`obi_plugin_api::Event::check`] and the repeat check.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use obi_plugin_api::rpc::{self, Message, RequestId, code, method};
use obi_plugin_api::{Event, EventKind, Kind, PROTOCOL, PluginError, PluginEvent, PluginId};
use serde_json::Value;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStderr, ChildStdin, ChildStdout};
use tokio::sync::{mpsc, oneshot, watch};

use crate::lock;

/// The longest line the host reads from a plug-in. A longer one ends the connection.
pub(crate) const MAX_LINE_BYTES: usize = 1 << 20;
/// What a plug-in's stderr and `log` messages may put in the log each minute.
pub(crate) const LOG_BYTES_PER_MINUTE: usize = 64 * 1024;
/// The longest `log` message or stderr line the host logs; the rest is cut.
const MAX_LOG_LINE_BYTES: usize = 4 * 1024;
/// How many event ids the host remembers per plug-in to ignore a repeat.
pub(crate) const REMEMBERED_EVENT_IDS: usize = 4_096;
/// Lines waiting to be written to the plug-in's stdin.
const WRITE_BUFFER: usize = 64;

/// The JSON-RPC error a plug-in gets when `obid` isn't taking events as fast as it sends them:
/// nothing was accepted, and it may send the event again.
pub(crate) const BUSY: i64 = -32000;

/// What the plug-in may do, and where its events go: shared by every connection the plug-in
/// has over its restarts.
#[derive(Debug)]
pub(crate) struct Peer {
    pub id: PluginId,
    /// The kinds its manifest lists: what its `initialize` answer may say it serves.
    pub kinds: Vec<Kind>,
    /// The manifest's `events.kinds`; empty for a plug-in that isn't an `events` plug-in.
    pub event_kinds: Vec<EventKind>,
    /// The ids of the events accepted lately, oldest first.
    pub seen: Mutex<Seen>,
    pub log: Mutex<LogBudget>,
}

impl Peer {
    pub(crate) fn new(id: PluginId, kinds: Vec<Kind>, event_kinds: Vec<EventKind>) -> Peer {
        Peer {
            id,
            kinds,
            event_kinds,
            seen: Mutex::new(Seen::default()),
            log: Mutex::new(LogBudget::default()),
        }
    }
}

/// The last [`REMEMBERED_EVENT_IDS`] event ids accepted from one plug-in.
#[derive(Debug, Default)]
pub(crate) struct Seen {
    order: VecDeque<String>,
    ids: HashSet<String>,
}

impl Seen {
    fn contains(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    fn insert(&mut self, id: String) {
        if self.ids.insert(id.clone()) {
            self.order.push_back(id);
            while self.order.len() > REMEMBERED_EVENT_IDS {
                if let Some(oldest) = self.order.pop_front() {
                    self.ids.remove(&oldest);
                }
            }
        }
    }
}

/// How much of the current minute's [`LOG_BYTES_PER_MINUTE`] a plug-in has used.
#[derive(Debug)]
pub(crate) struct LogBudget {
    minute: Instant,
    used: usize,
    dropped: usize,
}

impl Default for LogBudget {
    fn default() -> LogBudget {
        LogBudget {
            minute: Instant::now(),
            used: 0,
            dropped: 0,
        }
    }
}

impl LogBudget {
    /// Whether `bytes` more fit in this minute. When a new minute starts, how many lines the
    /// last one dropped comes back once, to be logged.
    pub(crate) fn take(&mut self, bytes: usize, now: Instant) -> (bool, Option<usize>) {
        let mut dropped_before = None;
        if now.duration_since(self.minute) >= Duration::from_secs(60) {
            if self.dropped > 0 {
                dropped_before = Some(self.dropped);
            }
            self.minute = now;
            self.used = 0;
            self.dropped = 0;
        }
        if self.used + bytes > LOG_BYTES_PER_MINUTE {
            self.dropped += 1;
            (false, dropped_before)
        } else {
            self.used += bytes;
            (true, dropped_before)
        }
    }
}

type Pending = HashMap<i64, oneshot::Sender<Result<Value, PluginError>>>;

/// A running plug-in's connection.
#[derive(Debug)]
pub(crate) struct Conn {
    /// Dropped to close its stdin: shared with the reader, which answers the plug-in's requests.
    writer: Arc<Mutex<Option<mpsc::Sender<String>>>>,
    pending: Arc<Mutex<Pending>>,
    next_id: AtomicI64,
    /// The kinds it serves now, from its `initialize` answer: until then, none.
    served: Arc<Mutex<Vec<Kind>>>,
    /// The id of the `initialize` request, so the reader marks the kinds served as it reads
    /// the answer, before any request the plug-in sends after it.
    initialize_id: Arc<Mutex<Option<i64>>>,
    /// Ends the reading tasks when the host is done with the plug-in, even if a process it
    /// started still holds its pipes open.
    cancel: watch::Sender<bool>,
}

impl Conn {
    /// Starts reading and writing the plug-in's pipes. Accepted events go to `events` while it
    /// is open.
    pub(crate) fn start(
        peer: Arc<Peer>,
        stdin: ChildStdin,
        stdout: ChildStdout,
        stderr: ChildStderr,
        events: Option<mpsc::Sender<PluginEvent>>,
    ) -> Arc<Conn> {
        let (write_tx, write_rx) = mpsc::channel(WRITE_BUFFER);
        let (cancel, cancelled) = watch::channel(false);
        let conn = Arc::new(Conn {
            writer: Arc::new(Mutex::new(Some(write_tx))),
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: AtomicI64::new(1),
            served: Arc::new(Mutex::new(Vec::new())),
            initialize_id: Arc::new(Mutex::new(None)),
            cancel,
        });
        tokio::spawn(write_lines(stdin, write_rx));
        tokio::spawn(read_stdout(
            Reader {
                peer: peer.clone(),
                pending: conn.pending.clone(),
                served: conn.served.clone(),
                initialize_id: conn.initialize_id.clone(),
                answers: conn.writer.clone(),
                events,
            },
            BufReader::new(stdout),
            cancelled.clone(),
        ));
        tokio::spawn(read_stderr(peer, BufReader::new(stderr), cancelled));
        conn
    }

    /// Sends `method` and waits at most `limit` for its answer.
    pub(crate) async fn request(
        &self,
        method: &str,
        params: &impl serde::Serialize,
        limit: Duration,
    ) -> Result<Value, PluginError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (answer_tx, answer_rx) = oneshot::channel();
        lock(&self.pending).insert(id, answer_tx);
        if method == method::INITIALIZE {
            *lock(&self.initialize_id) = Some(id);
        }
        let line = Message::request(RequestId::Number(id), method, params).encode();
        let writer = lock(&self.writer).clone();
        let sent = match writer {
            Some(writer) => writer.send(line).await.is_ok(),
            None => false,
        };
        if !sent {
            lock(&self.pending).remove(&id);
            return Err(PluginError::Stopped);
        }
        match tokio::time::timeout(limit, answer_rx).await {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Err(PluginError::Stopped),
            Err(_) => {
                lock(&self.pending).remove(&id);
                Err(PluginError::Timeout {
                    method: method.to_owned(),
                    seconds: limit.as_secs().max(1),
                })
            }
        }
    }

    /// The kinds it serves, from its `initialize` answer.
    pub(crate) fn set_served(&self, kinds: Vec<Kind>) {
        *lock(&self.served) = kinds;
    }

    pub(crate) fn serves(&self, kind: Kind) -> bool {
        lock(&self.served).contains(&kind)
    }

    /// Closes its stdin once what was sent before is written.
    pub(crate) fn close_stdin(&self) {
        lock(&self.writer).take();
    }

    /// Stops reading its pipes and fails every request still waiting.
    pub(crate) fn cancel(&self) {
        self.close_stdin();
        let _ = self.cancel.send(true);
        fail_pending(&self.pending);
    }
}

fn fail_pending(pending: &Mutex<Pending>) {
    for (_, answer) in lock(pending).drain() {
        let _ = answer.send(Err(PluginError::Stopped));
    }
}

async fn write_lines(mut stdin: ChildStdin, mut lines: mpsc::Receiver<String>) {
    while let Some(line) = lines.recv().await {
        if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
            break;
        }
    }
    // Dropping stdin closes it.
}

/// What the stdout reader needs.
struct Reader {
    peer: Arc<Peer>,
    pending: Arc<Mutex<Pending>>,
    served: Arc<Mutex<Vec<Kind>>>,
    initialize_id: Arc<Mutex<Option<i64>>>,
    /// Where answers to the plug-in's own requests are written, while its stdin is open.
    answers: Arc<Mutex<Option<mpsc::Sender<String>>>>,
    events: Option<mpsc::Sender<PluginEvent>>,
}

async fn read_stdout(
    reader: Reader,
    mut stdout: BufReader<ChildStdout>,
    mut cancelled: watch::Receiver<bool>,
) {
    loop {
        let line = tokio::select! {
            line = read_line(&mut stdout, MAX_LINE_BYTES) => line,
            _ = cancelled.wait_for(|cancelled| *cancelled) => break,
        };
        let line = match line {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(reason) => {
                log_line(&reader.peer, Level::Warn, &format!("stdout: {reason}"));
                break;
            }
        };
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let message = std::str::from_utf8(&line)
            .map_err(|_| PluginError::Protocol("a line that is not UTF-8".into()))
            .and_then(Message::decode);
        match message {
            Ok(message) => reader.handle(message).await,
            Err(error) => log_line(
                &reader.peer,
                Level::Warn,
                &format!("stdout: a line that isn't obi-plugin/0.1 ({error})"),
            ),
        }
    }
    fail_pending(&reader.pending);
}

impl Reader {
    async fn handle(&self, message: Message) {
        match message {
            Message::Response {
                id: RequestId::Number(id),
                result,
            } => {
                if *lock(&self.initialize_id) == Some(id) {
                    let kinds = rpc::from_value::<rpc::InitializeResult>(result.clone())
                        .and_then(|result| initialize_kinds(&self.peer.kinds, result));
                    if let Ok(kinds) = kinds {
                        *lock(&self.served) = kinds;
                    }
                }
                if let Some(answer) = lock(&self.pending).remove(&id) {
                    let _ = answer.send(Ok(result));
                }
            }
            Message::Error {
                id: Some(RequestId::Number(id)),
                error,
            } => {
                if let Some(answer) = lock(&self.pending).remove(&id) {
                    let _ = answer.send(Err(PluginError::Rpc {
                        code: error.code,
                        message: error.message,
                    }));
                }
            }
            Message::Response { .. } | Message::Error { .. } => {}
            Message::Notification { method, params } => {
                if method == method::LOG {
                    match rpc::from_value::<rpc::LogParams>(params) {
                        Ok(log) => {
                            let level = match log.level {
                                rpc::LogLevel::Info => Level::Info,
                                rpc::LogLevel::Warn => Level::Warn,
                                rpc::LogLevel::Error => Level::Error,
                            };
                            log_line(&self.peer, level, &log.message);
                        }
                        Err(error) => {
                            log_line(&self.peer, Level::Warn, &format!("a bad log: {error}"))
                        }
                    }
                }
            }
            Message::Request { id, method, params } => {
                let answer = match self.answer(&method, params) {
                    Ok(result) => Message::response(id, &result),
                    Err((code, message)) => Message::error(Some(id), code, message),
                };
                let writer = lock(&self.answers).clone();
                if let Some(writer) = writer {
                    let _ = writer.send(answer.encode()).await;
                }
            }
        }
    }

    /// The answer to one of the plug-in's requests.
    fn answer(&self, name: &str, params: Value) -> Result<Value, (i64, String)> {
        if name != method::EVENTS_EMIT {
            return Err((
                code::METHOD_NOT_FOUND,
                format!("obid takes no {name:?} from a plug-in"),
            ));
        }
        if !lock(&self.served).contains(&Kind::Events) {
            return Err((
                code::METHOD_NOT_FOUND,
                "events/emit is only for a plug-in that serves events".into(),
            ));
        }
        let event: Event =
            rpc::from_value(params).map_err(|error| (code::INVALID_PARAMS, error.to_string()))?;
        event
            .check(&self.peer.event_kinds)
            .map_err(|error| (code::INVALID_PARAMS, error.to_string()))?;

        let accepted = serde_json::json!({"accepted": true});
        let mut seen = lock(&self.peer.seen);
        if seen.contains(&event.id) {
            return Ok(accepted);
        }
        let Some(events) = &self.events else {
            return Err((BUSY, "obid has stopped taking events".into()));
        };
        let id = event.id.clone();
        match events.try_send(PluginEvent {
            plugin: self.peer.id.clone(),
            event,
        }) {
            Ok(()) => {
                seen.insert(id);
                Ok(accepted)
            }
            Err(mpsc::error::TrySendError::Full(_)) => Err((
                BUSY,
                "obid has too many events waiting; nothing was accepted, send it again later"
                    .into(),
            )),
            Err(mpsc::error::TrySendError::Closed(_)) => {
                Err((BUSY, "obid has stopped taking events".into()))
            }
        }
    }
}

/// The kinds an `initialize` answer says it serves, when that answer is `obi-plugin/0.1` and
/// they are among `manifest_kinds`.
pub(crate) fn initialize_kinds(
    manifest_kinds: &[Kind],
    result: rpc::InitializeResult,
) -> Result<Vec<Kind>, PluginError> {
    if result.protocol != PROTOCOL {
        return Err(PluginError::Protocol(format!(
            "it speaks {:?}, not {PROTOCOL:?}",
            result.protocol
        )));
    }
    if let Some(kind) = result
        .kinds
        .iter()
        .find(|kind| !manifest_kinds.contains(kind))
    {
        return Err(PluginError::Protocol(format!(
            "it says it serves {kind:?}, which its manifest doesn't list"
        )));
    }
    let mut kinds = result.kinds;
    kinds.sort();
    kinds.dedup();
    Ok(kinds)
}

async fn read_stderr(
    peer: Arc<Peer>,
    mut stderr: BufReader<ChildStderr>,
    mut cancelled: watch::Receiver<bool>,
) {
    loop {
        let line = tokio::select! {
            line = read_line(&mut stderr, MAX_LOG_LINE_BYTES) => line,
            _ = cancelled.wait_for(|cancelled| *cancelled) => break,
        };
        match line {
            Ok(Some(line)) => log_line(&peer, Level::Info, &String::from_utf8_lossy(&line)),
            Ok(None) => break,
            // A line too long: log what it holds, cut, and go on with the next one.
            Err(_) => log_line(
                &peer,
                Level::Info,
                "(a stderr line longer than 4 KB, left out)",
            ),
        }
    }
}

#[derive(Clone, Copy)]
enum Level {
    Info,
    Warn,
    Error,
}

/// Logs one line a plug-in wrote, within its [`LOG_BYTES_PER_MINUTE`]. The plug-in's words are
/// data: logged under the target `obi_plugin` with its id, never acted on.
fn log_line(peer: &Peer, level: Level, line: &str) {
    let mut text: String = line.trim_end().to_owned();
    if text.len() > MAX_LOG_LINE_BYTES {
        let mut end = MAX_LOG_LINE_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    let (fits, dropped) = lock(&peer.log).take(text.len().max(1), Instant::now());
    if let Some(dropped) = dropped {
        tracing::warn!(target: "obi_plugin", plugin = %peer.id, "{dropped} line(s) left out of the log: over 64 KB in a minute");
    }
    if !fits {
        return;
    }
    let id = &peer.id;
    match level {
        Level::Info => tracing::info!(target: "obi_plugin", plugin = %id, "{text}"),
        Level::Warn => tracing::warn!(target: "obi_plugin", plugin = %id, "{text}"),
        Level::Error => tracing::error!(target: "obi_plugin", plugin = %id, "{text}"),
    }
}

/// Reads one line ending in `\n` (or the last one, at the end), without the `\n`: `Ok(None)` at
/// the end. A line longer than `max` is an error, and what is left of it is skipped.
async fn read_line<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    max: usize,
) -> Result<Option<Vec<u8>>, String> {
    let mut line = Vec::new();
    let mut too_long = false;
    loop {
        let buffer = reader.fill_buf().await.map_err(|error| error.to_string())?;
        if buffer.is_empty() {
            return match (line.is_empty(), too_long) {
                (_, true) => Err(format!("a line longer than {max} bytes")),
                (true, false) => Ok(None),
                (false, false) => Ok(Some(line)),
            };
        }
        let (chunk, found) = match buffer.iter().position(|&b| b == b'\n') {
            Some(at) => (&buffer[..at], Some(at)),
            None => (buffer, None),
        };
        if !too_long {
            if line.len() + chunk.len() > max {
                too_long = true;
                line.clear();
            } else {
                line.extend_from_slice(chunk);
            }
        }
        let used = found.map_or(buffer.len(), |at| at + 1);
        reader.consume(used);
        if found.is_some() {
            return if too_long {
                Err(format!("a line longer than {max} bytes"))
            } else {
                Ok(Some(line))
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{LOG_BYTES_PER_MINUTE, LogBudget, REMEMBERED_EVENT_IDS, Seen, read_line};
    use std::time::{Duration, Instant};

    #[tokio::test]
    async fn lines_split_on_newline_only() {
        let text = "{\"a\":\"x\u{2028}y\"}\r\n\nlast";
        let mut reader = tokio::io::BufReader::new(text.as_bytes());
        assert_eq!(
            read_line(&mut reader, 100).await.unwrap().unwrap(),
            "{\"a\":\"x\u{2028}y\"}\r".as_bytes()
        );
        assert_eq!(read_line(&mut reader, 100).await.unwrap().unwrap(), b"");
        assert_eq!(read_line(&mut reader, 100).await.unwrap().unwrap(), b"last");
        assert_eq!(read_line(&mut reader, 100).await.unwrap(), None);
    }

    #[tokio::test]
    async fn a_line_too_long_is_refused_and_skipped() {
        let text = format!("{}\nnext\n", "x".repeat(50));
        let mut reader = tokio::io::BufReader::with_capacity(8, text.as_bytes());
        assert!(read_line(&mut reader, 10).await.is_err());
        assert_eq!(read_line(&mut reader, 10).await.unwrap().unwrap(), b"next");
    }

    #[test]
    fn the_log_takes_64_kb_a_minute() {
        let start = Instant::now();
        let mut budget = LogBudget {
            minute: start,
            used: 0,
            dropped: 0,
        };
        assert_eq!(budget.take(LOG_BYTES_PER_MINUTE - 10, start), (true, None));
        assert_eq!(budget.take(10, start), (true, None));
        assert_eq!(budget.take(1, start), (false, None));
        assert_eq!(budget.take(1, start), (false, None));
        let later = start + Duration::from_secs(61);
        assert_eq!(budget.take(100, later), (true, Some(2)));
        assert_eq!(budget.take(100, later), (true, None));
    }

    #[test]
    fn seen_ids_are_bounded() {
        let mut seen = Seen::default();
        for i in 0..REMEMBERED_EVENT_IDS + 10 {
            seen.insert(format!("e{i}"));
        }
        seen.insert("e20".into());
        assert!(!seen.contains("e0"));
        assert!(!seen.contains("e9"));
        assert!(seen.contains("e10"));
        assert!(seen.contains(&format!("e{}", REMEMBERED_EVENT_IDS + 9)));
        assert_eq!(seen.ids.len(), REMEMBERED_EVENT_IDS);
        assert_eq!(seen.order.len(), REMEMBERED_EVENT_IDS);
    }
}
