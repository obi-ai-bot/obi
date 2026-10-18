//! Artifacts (docs/conversation-harness.md, section 4; docs/runner-api.md, "obid only:
//! artifacts"): what an agent makes to be looked at, a page, a document, an image, a PDF or a
//! canvas of pages, kept with every version in `home/artifacts/<id>/<version>/` and described by
//! `home/artifacts/<id>/artifact.json`.
//!
//! [`Artifacts::publish`] is the one way in, for a job's `.obi/artifacts/` when it ends
//! (crate::jobs) and for a conversation's `oby_artifact` tool. It copies from a folder the agent
//! wrote, so nothing there is trusted: every folder and file is opened without following a link
//! (`O_NOFOLLOW`, each one inside the folder already opened), so a link anywhere, on the way or
//! inside, is refused, as is anything that isn't a plain file or folder; hidden names (`.git`,
//! `.DS_Store`) are left out; a version holds at most [`MAX_FILES`] entries and [`MAX_BYTES`]. Then
//! every file goes through the publish gate's secret scan (crate::scan): any finding, or a scan
//! that can't run, and nothing is kept.

use std::ffi::CString;
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use axum::body::Bytes;
use axum::extract::{Path as UrlPath, Query, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use nix::fcntl::{OFlag, open, openat};
use nix::sys::stat::Mode;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::api::{ApiError, Shared};
use crate::events::Events;
use crate::store::{make_private_dir, write_private};

/// The most one version holds, in bytes.
pub const MAX_BYTES: u64 = 50 * 1024 * 1024;
/// The most files and folders one version holds.
pub const MAX_FILES: usize = 2000;
/// How deep folders in one version go.
const MAX_DEPTH: usize = 32;
/// The longest title.
const TITLE: usize = 100;

/// What every file obid serves from an artifact carries: its scripts run, but it reaches nothing
/// past its own files (`connect-src 'none'`, no frame of it in another page), and `sandbox
/// allow-scripts` gives it an origin of its own, so it can't read what obid's other pages keep
/// on this origin (the web app's token in session storage), open windows or send forms.
pub const POLICY: &str = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' data: blob:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; connect-src 'none'; frame-ancestors 'none'; sandbox allow-scripts";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A folder with an `index.html` (a single `.html` file becomes one).
    Html,
    Markdown,
    Image,
    Pdf,
    /// A folder with a `canvas.json`: a list of frames `{title, file, x, y, w, h}`, each an HTML
    /// file of the folder.
    Canvas,
}

impl Kind {
    pub fn parse(text: &str) -> Option<Kind> {
        serde_json::from_value(json!(text)).ok()
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Html => "html",
            Kind::Markdown => "markdown",
            Kind::Image => "image",
            Kind::Pdf => "pdf",
            Kind::Canvas => "canvas",
        }
    }
}

/// One artifact, as `artifact.json` keeps it and the API shows it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Artifact {
    pub id: String,
    pub title: String,
    pub kind: Kind,
    pub conversation: Option<String>,
    pub job: Option<String>,
    pub created: String,
    /// Oldest first.
    pub versions: Vec<Version>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Version {
    pub version: u32,
    pub created: String,
    /// Its files, paths relative to the version's folder, sorted.
    pub files: Vec<String>,
    pub bytes: u64,
}

impl Artifact {
    fn latest(&self) -> u32 {
        self.versions.last().map_or(0, |v| v.version)
    }
}

/// What to publish: `path`, relative to `root`, a file or a folder. `root` is a folder obid
/// chose (a conversation's room, a job's worktree); `path` may come from the agent, and is
/// refused when absolute or holding `..`.
pub struct Publish<'a> {
    pub root: &'a Path,
    pub path: &'a str,
    pub title: &'a str,
    /// None: from the shape (a folder with `index.html` or `canvas.json`, a file's extension).
    pub kind: Option<Kind>,
    pub conversation: Option<&'a str>,
    pub job: Option<&'a str>,
    /// A new version of this artifact, which must be of the same conversation and job.
    pub artifact: Option<&'a str>,
}

/// Every artifact obid keeps.
pub struct Artifacts {
    dir: PathBuf,
    scratch: PathBuf,
    events: Events,
    /// Each change to an `artifact.json`, one at a time. ponytail: one lock for all; per artifact
    /// if publishing ever queues.
    lock: Mutex<()>,
}

impl Artifacts {
    /// `home/artifacts` (0700), made if missing, with what a publish cut short left behind gone.
    pub fn open(home: &Path, events: Events) -> std::io::Result<Arc<Artifacts>> {
        let dir = home.join("artifacts");
        make_private_dir(&dir)?;
        for entry in std::fs::read_dir(&dir)?.flatten() {
            if entry.file_name().to_string_lossy().starts_with(".staging-") {
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
        Ok(Arc::new(Artifacts {
            dir,
            scratch: home.join("tmp"),
            events,
            lock: Mutex::new(()),
        }))
    }

    /// Publishes `what` as a new artifact, or a new version of `what.artifact`, and says its id
    /// and version, after the `artifact` event went out. When the files are the same as the
    /// artifact's latest version, that version is the answer and nothing new is kept. `Err` is
    /// one line saying why nothing was published.
    pub async fn publish(&self, what: Publish<'_>) -> Result<(String, u32), String> {
        let title = clean_title(what.title)
            .ok_or("Not published: the title is one line of 1 to 100 characters.")?;
        let before = match what.artifact {
            Some(id) => {
                let artifact = self
                    .get(id)
                    .ok_or(format!("Not published: there's no artifact {}.", shown(id)))?;
                if artifact.conversation.as_deref() != what.conversation
                    || artifact.job.as_deref() != what.job
                {
                    return Err(format!(
                        "Not published: artifact {id} was made somewhere else, so only there can it get a new version."
                    ));
                }
                Some(artifact)
            }
            None => None,
        };
        let staging = self
            .dir
            .join(format!(".staging-{}", uuid::Uuid::new_v4().simple()));
        let copied = {
            let (root, path, staging) = (
                what.root.to_path_buf(),
                what.path.to_owned(),
                staging.clone(),
            );
            tokio::task::spawn_blocking(move || copy(&root, &path, &staging))
                .await
                .map_err(|e| format!("Not published: the copy stopped ({e})."))?
        };
        let result = self.finish(&what, &title, before, &staging, copied).await;
        let _ = std::fs::remove_dir_all(&staging);
        result
    }

    async fn finish(
        &self,
        what: &Publish<'_>,
        title: &str,
        before: Option<Artifact>,
        staging: &Path,
        copied: Result<Copied, String>,
    ) -> Result<(String, u32), String> {
        let copied = copied.map_err(|why| format!("Not published: {why}"))?;
        let kind = check_kind(
            &copied,
            staging,
            what.kind.or(before.as_ref().map(|a| a.kind)),
        )
        .map_err(|why| format!("Not published: {why}"))?;
        if let Some(before) = &before {
            if before.kind != kind {
                return Err(format!(
                    "Not published: artifact {} is {}, and this is {}.",
                    before.id,
                    before.kind.as_str(),
                    kind.as_str()
                ));
            }
            let latest = self.version_path(&before.id, before.latest());
            if same_files(&latest, staging, &copied.files, before.versions.last()) {
                return Ok((before.id.clone(), before.latest()));
            }
        }
        self.scan(staging, &copied.files).await?;
        let _held = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let now = obi_protocol::time::format(obi_protocol::time::now());
        let mut artifact = match &before {
            // Read again under the lock: a rename may have come meanwhile.
            Some(before) => self
                .get(&before.id)
                .ok_or("Not published: the artifact was deleted meanwhile.")?,
            None => Artifact {
                id: uuid::Uuid::new_v4().to_string().to_lowercase(),
                title: title.to_owned(),
                kind,
                conversation: what.conversation.map(str::to_owned),
                job: what.job.map(str::to_owned),
                created: now.clone(),
                versions: Vec::new(),
            },
        };
        let version = artifact.latest() + 1;
        let folder = self.dir.join(&artifact.id);
        make_private_dir(&folder)
            .and_then(|()| std::fs::rename(staging, folder.join(version.to_string())))
            .map_err(|e| format!("Not published: obid couldn't keep it ({e})."))?;
        artifact.versions.push(Version {
            version,
            created: now,
            files: copied.files,
            bytes: copied.bytes,
        });
        self.save(&artifact)
            .map_err(|e| format!("Not published: obid couldn't keep it ({e})."))?;
        self.events.send(
            "artifact",
            json!({"id": artifact.id, "version": version, "title": artifact.title,
                   "kind": artifact.kind, "conversation": artifact.conversation, "job": artifact.job}),
        );
        Ok((artifact.id, version))
    }

    /// The secret scan over every file: the text ones whole (the built-in rules, the secrets obid
    /// holds, gitleaks), the others for the secrets obid holds.
    async fn scan(&self, staging: &Path, files: &[String]) -> Result<(), String> {
        let mut texts = Vec::new();
        let mut found = Vec::new();
        for name in files {
            let bytes = std::fs::read(staging.join(name))
                .map_err(|e| format!("Not published: obid couldn't read {name} ({e})."))?;
            match String::from_utf8(bytes) {
                Ok(text) => texts.push((name.clone(), text)),
                Err(e) => found.extend(crate::scan::known_secrets_in_file(
                    &String::from_utf8_lossy(e.as_bytes()),
                    name,
                )),
            }
        }
        make_private_dir(&self.scratch)
            .map_err(|e| format!("Not published: the secret scan couldn't run ({e})."))?;
        match crate::scan::scan(&texts, &self.scratch).await {
            crate::scan::Verdict::Clean => {}
            crate::scan::Verdict::Found(more) => found.extend(more),
            crate::scan::Verdict::CouldNotRun(why) => {
                return Err(format!(
                    "Not published: the secret scan couldn't run ({why})."
                ));
            }
        }
        if found.is_empty() {
            return Ok(());
        }
        let places: Vec<String> = found.iter().take(5).map(ToString::to_string).collect();
        Err(format!(
            "Not published: the secret scan found what looks like a secret in {}.",
            places.join(", ")
        ))
    }

    fn version_path(&self, id: &str, version: u32) -> PathBuf {
        self.dir.join(id).join(version.to_string())
    }

    fn save(&self, artifact: &Artifact) -> std::io::Result<()> {
        let text = serde_json::to_vec_pretty(artifact).map_err(std::io::Error::other)?;
        write_private(&self.dir.join(&artifact.id).join("artifact.json"), &text)
    }

    /// The artifact `id`, or none.
    pub fn get(&self, id: &str) -> Option<Artifact> {
        if !is_id(id) {
            return None;
        }
        let bytes = std::fs::read(self.dir.join(id).join("artifact.json")).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// Every artifact, newest first; only a conversation's or a job's when they're given.
    pub fn list(&self, conversation: Option<&str>, job: Option<&str>) -> Vec<Artifact> {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let mut all: Vec<Artifact> = entries
            .flatten()
            .filter_map(|e| self.get(&e.file_name().to_string_lossy()))
            .filter(|a| conversation.is_none_or(|c| a.conversation.as_deref() == Some(c)))
            .filter(|a| job.is_none_or(|j| a.job.as_deref() == Some(j)))
            .collect();
        all.sort_by(|a, b| b.created.cmp(&a.created).then_with(|| b.id.cmp(&a.id)));
        all
    }

    /// Renames it: the artifact, or none when there's no such one.
    pub fn rename(&self, id: &str, title: &str) -> std::io::Result<Option<Artifact>> {
        let _held = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let Some(mut artifact) = self.get(id) else {
            return Ok(None);
        };
        artifact.title = title.to_owned();
        self.save(&artifact)?;
        Ok(Some(artifact))
    }

    /// Deletes it with every version: whether it was there.
    pub fn delete(&self, id: &str) -> std::io::Result<bool> {
        let _held = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        if self.get(id).is_none() {
            return Ok(false);
        }
        std::fs::remove_dir_all(self.dir.join(id))?;
        self.events
            .send("artifact", json!({"id": id, "deleted": true}));
        Ok(true)
    }

    /// The file `path` of version `version` of `id`, read: its path and bytes.
    fn file(&self, id: &str, version: &str, path: &str) -> Option<(PathBuf, Vec<u8>)> {
        let version: u32 = version.parse().ok()?;
        let artifact = self.get(id)?;
        let kept = artifact.versions.iter().find(|v| v.version == version)?;
        // Only what the version lists: nothing else that may be in its folder, and never `..`.
        if !kept.files.iter().any(|f| f == path) {
            return None;
        }
        let file = crate::web::inside(&self.version_path(id, version), path)?;
        let bytes = std::fs::read(&file).ok()?;
        Some((file, bytes))
    }
}

/// A lower-case UUID, as obid makes them: never `..` or a path.
fn is_id(id: &str) -> bool {
    id.len() == 36 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

/// An id as said back: only when it is one.
fn shown(id: &str) -> &str {
    if is_id(id) { id } else { "by that id" }
}

/// The title trimmed, when it is one line of 1 to 100 characters.
pub fn clean_title(title: &str) -> Option<String> {
    let title = title.trim();
    let fine = !title.is_empty()
        && title.chars().count() <= TITLE
        && !title
            .chars()
            .any(|c| c.is_control() || c == '\u{2028}' || c == '\u{2029}');
    fine.then(|| title.to_owned())
}

/// What a copy made: its files, sorted, how many bytes, and whether it was a folder.
#[derive(Debug)]
struct Copied {
    files: Vec<String>,
    bytes: u64,
    folder: bool,
}

/// The kind the copy is, when it is `wanted` too (or nothing was wanted).
fn check_kind(copied: &Copied, staging: &Path, wanted: Option<Kind>) -> Result<Kind, String> {
    let has = |name: &str| copied.files.iter().any(|f| f == name);
    let kind = if copied.folder {
        if has("canvas.json") {
            Kind::Canvas
        } else if has("index.html") {
            Kind::Html
        } else {
            return Err(
                "a folder is an html artifact with an index.html, or a canvas with a canvas.json."
                    .into(),
            );
        }
    } else {
        let name = copied.files.first().map_or("", String::as_str);
        match extension(name).as_str() {
            "html" => Kind::Html,
            "md" | "markdown" => Kind::Markdown,
            "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" => Kind::Image,
            "pdf" => Kind::Pdf,
            _ => {
                return Err(format!(
                    "{name} isn't a page (.html), a document (.md), an image (.png, .jpg, .gif, .webp, .svg) or a PDF."
                ));
            }
        }
    };
    if let Some(wanted) = wanted.filter(|w| *w != kind) {
        return Err(format!(
            "it was asked for as {}, and it is {}.",
            wanted.as_str(),
            kind.as_str()
        ));
    }
    if kind == Kind::Canvas {
        check_canvas(copied, staging)?;
    }
    Ok(kind)
}

fn extension(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

#[derive(Deserialize)]
struct Frame {
    #[allow(dead_code)]
    title: String,
    file: String,
    #[allow(dead_code)]
    x: f64,
    #[allow(dead_code)]
    y: f64,
    #[allow(dead_code)]
    w: f64,
    #[allow(dead_code)]
    h: f64,
}

/// A canvas's `canvas.json` is a list of frames, each an HTML file of its own.
fn check_canvas(copied: &Copied, staging: &Path) -> Result<(), String> {
    let text = std::fs::read(staging.join("canvas.json")).map_err(read_error)?;
    let frames: Vec<Frame> = serde_json::from_slice(&text).map_err(|_| {
        "canvas.json is a list of frames, each {\"title\", \"file\", \"x\", \"y\", \"w\", \"h\"}."
            .to_owned()
    })?;
    if frames.is_empty() {
        return Err("canvas.json has no frame.".into());
    }
    match frames
        .iter()
        .find(|f| extension(&f.file) != "html" || !copied.files.contains(&f.file))
    {
        Some(frame) => Err(format!(
            "canvas.json's frame {:?} isn't an HTML file of the canvas.",
            frame.file
        )),
        None => Ok(()),
    }
}

/// Whether the files in `staging` are those of `latest` (`kept`), byte for byte.
fn same_files(latest: &Path, staging: &Path, files: &[String], kept: Option<&Version>) -> bool {
    kept.is_some_and(|kept| kept.files == files)
        && files.iter().all(|f| {
            matches!((std::fs::read(latest.join(f)), std::fs::read(staging.join(f))), (Ok(a), Ok(b)) if a == b)
        })
}

/// Copies `root/path` into `to` (a new folder), never following a link; see the module's
/// documentation.
fn copy(root: &Path, path: &str, to: &Path) -> Result<Copied, String> {
    let parts: Vec<&str> = path.split('/').collect();
    if parts
        .iter()
        .any(|p| p.is_empty() || *p == "." || *p == ".." || p.contains(['\\', '\0']))
    {
        return Err(format!(
            "{path:?} isn't a path inside its folder (no `..`, nothing absolute)."
        ));
    }
    let mut at = open(
        root,
        OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_RDONLY | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|e| format!("its folder can't be opened ({e})."))?;
    let (last, on_the_way) = parts.split_last().expect("split gives a part");
    let mut shown = String::new();
    for part in on_the_way {
        shown.push_str(part);
        at = open_in(&at, part, &shown)?;
        if !is_dir(&at)? {
            return Err(format!("{shown} isn't a folder."));
        }
        shown.push('/');
    }
    shown.push_str(last);
    let entry = open_in(&at, last, &shown)?;
    let mut copied = Copied {
        files: Vec::new(),
        bytes: 0,
        folder: false,
    };
    let mut entries = 0;
    make_private_dir(to).map_err(|e| format!("obid couldn't make its copy ({e})."))?;
    let meta = metadata(&entry)?;
    if meta.is_dir() {
        copied.folder = true;
        copy_folder(entry, &shown, to, "", 0, &mut entries, &mut copied)?;
    } else if meta.is_file() {
        // A single page is its folder's index.html.
        let name = if extension(last) == "html" || extension(last) == "htm" {
            "index.html"
        } else {
            last
        };
        copy_file(entry, &to.join(name), &mut copied)?;
        copied.files.push(name.to_owned());
    } else {
        return Err(format!("{shown} isn't a file or a folder."));
    }
    copied.files.sort();
    Ok(copied)
}

fn read_error(e: impl std::fmt::Display) -> String {
    format!("obid couldn't read it ({e}).")
}

fn metadata(fd: &OwnedFd) -> Result<std::fs::Metadata, String> {
    let file = std::fs::File::from(fd.try_clone().map_err(read_error)?);
    file.metadata().map_err(read_error)
}

fn is_dir(fd: &OwnedFd) -> Result<bool, String> {
    Ok(metadata(fd)?.is_dir())
}

/// `name` in the folder `at`, opened without following a link (`shown` is its path, for why).
fn open_in(at: &impl std::os::fd::AsFd, name: &str, shown: &str) -> Result<OwnedFd, String> {
    // Non-blocking, so a named pipe opens (and is refused as what it is) instead of waiting.
    openat(
        at,
        name,
        OFlag::O_NOFOLLOW | OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NONBLOCK,
        Mode::empty(),
    )
    .map_err(|e| match e {
        nix::errno::Errno::ELOOP => {
            format!("{shown} is a link: obid publishes only plain files and folders.")
        }
        nix::errno::Errno::ENOENT => format!("there's no {shown}."),
        e => format!("{shown} can't be opened ({e})."),
    })
}

/// The folder `dir` (`shown`) into `to`/`prefix`, each entry opened inside it: at most
/// [`MAX_FILES`] entries, [`MAX_DEPTH`] deep.
fn copy_folder(
    dir: OwnedFd,
    shown: &str,
    to: &Path,
    prefix: &str,
    depth: usize,
    entries: &mut usize,
    copied: &mut Copied,
) -> Result<(), String> {
    if depth >= MAX_DEPTH {
        return Err(format!("{shown} is more than {MAX_DEPTH} folders deep."));
    }
    let mut dir = nix::dir::Dir::from_fd(dir).map_err(read_error)?;
    let mut names: Vec<CString> = Vec::new();
    for entry in dir.iter() {
        let name = entry.map_err(read_error)?.file_name().to_owned();
        if name.as_bytes() != b"." && name.as_bytes() != b".." {
            names.push(name);
        }
    }
    names.sort();
    for name in names {
        let Ok(name) = name.into_string() else {
            return Err(format!("{shown} holds a name that isn't text."));
        };
        // Hidden names (.git, .DS_Store) are left out.
        if name.starts_with('.') {
            continue;
        }
        let path = format!("{shown}/{name}");
        if name.contains(['\\', ':']) {
            return Err(format!("{path}: a name can't hold `\\` or `:`."));
        }
        *entries += 1;
        if *entries > MAX_FILES {
            return Err(format!("it has more than {MAX_FILES} files."));
        }
        let entry = open_in(&dir, &name, &path)?;
        let inside = format!("{prefix}{name}");
        let meta = metadata(&entry)?;
        if meta.is_dir() {
            make_private_dir(&to.join(&inside)).map_err(read_error)?;
            copy_folder(
                entry,
                &path,
                to,
                &format!("{inside}/"),
                depth + 1,
                entries,
                copied,
            )?;
        } else if meta.is_file() {
            copy_file(entry, &to.join(&inside), copied)?;
            copied.files.push(inside);
        } else {
            return Err(format!("{path} isn't a file or a folder."));
        }
    }
    Ok(())
}

/// The open file `from` to the new file `to` (0600), counted against [`MAX_BYTES`].
fn copy_file(from: OwnedFd, to: &Path, copied: &mut Copied) -> Result<(), String> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut out = options
        .open(to)
        .map_err(|e| format!("obid couldn't make its copy ({e})."))?;
    let left = MAX_BYTES - copied.bytes;
    let mut from = std::fs::File::from(from).take(left + 1);
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let n = match from.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(read_error(e)),
        };
        copied.bytes += n as u64;
        if copied.bytes > MAX_BYTES {
            return Err(format!("it is more than {} MB.", MAX_BYTES / 1024 / 1024));
        }
        out.write_all(&buffer[..n])
            .map_err(|e| format!("obid couldn't make its copy ({e})."))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// The API

#[derive(Deserialize)]
pub struct Filter {
    conversation: Option<String>,
    job: Option<String>,
}

/// `GET /v1/artifacts?conversation=&job=`
pub async fn list(State(shared): State<Arc<Shared>>, Query(filter): Query<Filter>) -> Response {
    let all = shared
        .artifacts
        .list(filter.conversation.as_deref(), filter.job.as_deref());
    axum::Json(json!(all)).into_response()
}

fn no_artifact() -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, "There's no such artifact.")
}

/// `GET /v1/artifacts/{id}`
pub async fn get(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    let artifact = shared.artifacts.get(&id).ok_or_else(no_artifact)?;
    Ok(axum::Json(artifact).into_response())
}

/// `GET /v1/artifacts/{id}/{version}/{*path}`: one of its files, with [`POLICY`].
pub async fn file(
    State(shared): State<Arc<Shared>>,
    UrlPath((id, version, path)): UrlPath<(String, String, String)>,
) -> Result<Response, ApiError> {
    let (file, bytes) = shared
        .artifacts
        .file(&id, &version, &path)
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "There's no such file."))?;
    let mut response = (StatusCode::OK, bytes).into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(crate::web::type_of(&file)),
    );
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(POLICY),
    );
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    Ok(response)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rename {
    title: String,
}

/// `PATCH /v1/artifacts/{id}` with `{"title": "…"}`.
pub async fn update(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    let Rename { title } = serde_json::from_slice(&body)
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "The body is {\"title\": \"…\"}."))?;
    let title = clean_title(&title).ok_or_else(|| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "title is one line of 1 to 100 characters.",
        )
    })?;
    match shared.artifacts.rename(&id, &title) {
        Ok(Some(artifact)) => Ok(axum::Json(artifact).into_response()),
        Ok(None) => Err(no_artifact()),
        Err(e) => Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("obid couldn't rename it: {e}"),
        )),
    }
}

/// `DELETE /v1/artifacts/{id}`: it goes, with every version.
pub async fn remove(
    State(shared): State<Arc<Shared>>,
    UrlPath(id): UrlPath<String>,
) -> Result<Response, ApiError> {
    match shared.artifacts.delete(&id) {
        Ok(true) => Ok(StatusCode::NO_CONTENT.into_response()),
        Ok(false) => Err(no_artifact()),
        Err(e) => Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("obid couldn't delete it: {e}"),
        )),
    }
}

/// What a job's `.obi/artifacts/` holds: one artifact per entry, hidden names left out, sorted.
/// Nothing when `.obi` or `.obi/artifacts` isn't a real folder.
pub fn job_entries(worktree: &Path) -> Vec<String> {
    let mut folder = worktree.to_path_buf();
    for part in [crate::obi_dir::OBI, "artifacts"] {
        folder.push(part);
        if !std::fs::symlink_metadata(&folder).is_ok_and(|m| m.is_dir()) {
            return Vec::new();
        }
    }
    let Ok(entries) = std::fs::read_dir(&folder) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| !n.starts_with('.'))
        .collect();
    names.sort();
    names
}

/// The title an entry of `.obi/artifacts/` gets: its name without its extension.
pub fn title_of(entry: &str) -> String {
    let stem = Path::new(entry)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(entry);
    let title: String = stem
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(TITLE)
        .collect();
    clean_title(&title).unwrap_or_else(|| "Artifact".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Temp(PathBuf);

    impl Temp {
        fn new(name: &str) -> Temp {
            let path =
                std::env::temp_dir().join(format!("obid-artifacts-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(path.join("room")).unwrap();
            Temp(path.canonicalize().unwrap())
        }
        fn room(&self) -> PathBuf {
            self.0.join("room")
        }
        fn write(&self, path: &str, bytes: impl AsRef<[u8]>) {
            let path = self.room().join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, bytes).unwrap();
        }
        fn store(
            &self,
        ) -> (
            Arc<Artifacts>,
            tokio::sync::broadcast::Receiver<crate::events::Event>,
        ) {
            let events = Events::new();
            let receiver = events.subscribe();
            (
                Artifacts::open(&self.0.join("home"), events).unwrap(),
                receiver,
            )
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn what<'a>(root: &'a Path, path: &'a str) -> Publish<'a> {
        Publish {
            root,
            path,
            title: "Landing page",
            kind: None,
            conversation: Some("c1"),
            job: None,
            artifact: None,
        }
    }

    /// A folder with an index.html is an html artifact: version 1, kept with its files and an
    /// `artifact.json`, and an `artifact` event. The same files again are still version 1; other
    /// files are version 2, both kept.
    #[tokio::test]
    async fn a_publish_keeps_every_version_and_says_so() {
        let t = Temp::new("versions");
        t.write("page/index.html", "<h1>One</h1>");
        t.write("page/css/style.css", "h1 { color: red }");
        t.write("page/.DS_Store", "hidden");
        let (store, mut events) = t.store();
        let room = t.room();
        let (id, version) = store.publish(what(&room, "page")).await.unwrap();
        assert_eq!(version, 1);
        let artifact = store.get(&id).unwrap();
        assert_eq!(artifact.kind, Kind::Html);
        assert_eq!(artifact.title, "Landing page");
        assert_eq!(artifact.conversation.as_deref(), Some("c1"));
        assert_eq!(artifact.versions[0].files, ["css/style.css", "index.html"]);
        assert_eq!(artifact.versions[0].bytes, 29);
        let kept = t.0.join("home/artifacts").join(&id);
        assert!(kept.join("artifact.json").is_file());
        assert_eq!(
            std::fs::read_to_string(kept.join("1/index.html")).unwrap(),
            "<h1>One</h1>"
        );
        assert!(!kept.join("1/.DS_Store").exists());
        let event = events.try_recv().unwrap();
        assert_eq!(event.name, "artifact");
        assert_eq!(
            event.data,
            json!({"id": id, "version": 1, "title": "Landing page", "kind": "html", "conversation": "c1", "job": null})
        );

        let again = Publish {
            artifact: Some(&id),
            ..what(&room, "page")
        };
        assert_eq!(store.publish(again).await.unwrap(), (id.clone(), 1));
        assert!(events.try_recv().is_err(), "nothing new, no event");
        t.write("page/index.html", "<h1>Two</h1>");
        let again = Publish {
            artifact: Some(&id),
            ..what(&room, "page")
        };
        assert_eq!(store.publish(again).await.unwrap(), (id.clone(), 2));
        assert_eq!(store.get(&id).unwrap().versions.len(), 2);
        assert_eq!(
            store.file(&id, "1", "index.html").unwrap().1,
            b"<h1>One</h1>"
        );
        assert_eq!(
            store.file(&id, "2", "index.html").unwrap().1,
            b"<h1>Two</h1>"
        );
        assert!(store.file(&id, "3", "index.html").is_none());
        assert!(store.file(&id, "1", "../artifact.json").is_none());
        assert!(store.file(&id, "1", ".DS_Store").is_none());
        // Another conversation's artifact gets no version from here.
        let elsewhere = Publish {
            artifact: Some(&id),
            conversation: Some("c2"),
            ..what(&room, "page")
        };
        assert!(store.publish(elsewhere).await.is_err());
        // Listed, renamed, deleted.
        assert_eq!(store.list(Some("c1"), None).len(), 1);
        assert!(store.list(Some("c2"), None).is_empty());
        assert_eq!(
            store.rename(&id, "Renamed").unwrap().unwrap().title,
            "Renamed"
        );
        assert!(store.delete(&id).unwrap());
        assert!(!kept.exists());
        assert!(!store.delete(&id).unwrap());
        assert!(store.get("..").is_none());
    }

    /// The kind comes from the shape; one asked for must be it; a canvas's frames must be its own
    /// HTML files.
    #[tokio::test]
    async fn the_kind_is_the_shape() {
        let t = Temp::new("kinds");
        t.write("notes.md", "# Notes");
        t.write("chart.png", [0x89, b'P', b'N', b'G', 0xff, 0x00]);
        t.write("paper.pdf", "%PDF-1.4");
        t.write("one.html", "<p>one</p>");
        t.write("notes.txt", "plain");
        t.write("empty/readme.md", "no index");
        t.write(
            "board/canvas.json",
            r#"[{"title": "A", "file": "a.html", "x": 0, "y": 0, "w": 390, "h": 844}]"#,
        );
        t.write("board/a.html", "<p>a</p>");
        t.write(
            "broken/canvas.json",
            r#"[{"title": "B", "file": "b.html", "x": 0, "y": 0, "w": 1, "h": 1}]"#,
        );
        t.write("broken/index.html", "x");
        t.write("notalist/canvas.json", r#"{"frames": []}"#);
        let (store, _) = t.store();
        let room = t.room();
        let kind = async |path: &str, wanted: Option<Kind>| {
            let published = store
                .publish(Publish {
                    kind: wanted,
                    ..what(&room, path)
                })
                .await;
            published.map(|(id, _)| store.get(&id).unwrap())
        };
        assert_eq!(kind("notes.md", None).await.unwrap().kind, Kind::Markdown);
        assert_eq!(kind("chart.png", None).await.unwrap().kind, Kind::Image);
        assert_eq!(kind("paper.pdf", None).await.unwrap().kind, Kind::Pdf);
        let one = kind("one.html", None).await.unwrap();
        assert_eq!(
            (one.kind, &one.versions[0].files[..]),
            (Kind::Html, &["index.html".to_owned()][..])
        );
        let board = kind("board", Some(Kind::Canvas)).await.unwrap();
        assert_eq!(board.versions[0].files, ["a.html", "canvas.json"]);
        for (path, wanted, why) in [
            ("notes.txt", None, "isn't a page"),
            ("empty", None, "index.html"),
            ("notes.md", Some(Kind::Html), "asked for as html"),
            ("broken", None, "b.html"),
            ("notalist", None, "canvas.json"),
            ("missing.md", None, "missing.md"),
        ] {
            let why_not = kind(path, wanted).await.unwrap_err();
            assert!(
                why_not.starts_with("Not published: ") && why_not.contains(why),
                "{path}: {why_not}"
            );
        }
        assert_eq!(store.list(None, None).len(), 5);
        assert!(
            std::fs::read_dir(t.0.join("home/artifacts"))
                .unwrap()
                .flatten()
                .all(|e| !e.file_name().to_string_lossy().starts_with('.'))
        );
    }

    /// Links, wherever they are, `..`, absolute paths and what isn't a plain file are refused, and
    /// nothing outside the root is read or kept.
    #[tokio::test]
    async fn links_and_paths_out_are_refused() {
        let t = Temp::new("links");
        std::fs::create_dir_all(t.0.join("outside")).unwrap();
        std::fs::write(t.0.join("outside/index.html"), "<p>outside</p>").unwrap();
        std::fs::write(t.0.join("outside/secret.md"), "outside").unwrap();
        t.write("page/index.html", "<p>in</p>");
        std::os::unix::fs::symlink(t.0.join("outside/secret.md"), t.room().join("page/leak.md"))
            .unwrap();
        std::os::unix::fs::symlink(t.0.join("outside"), t.room().join("away")).unwrap();
        std::os::unix::fs::symlink(t.0.join("outside/secret.md"), t.room().join("link.md"))
            .unwrap();
        t.write("inner/index.html", "<p>in</p>");
        std::os::unix::fs::symlink(t.0.join("outside"), t.room().join("inner/sub")).unwrap();
        nix::unistd::mkfifo(&t.room().join("pipe.md"), Mode::from_bits_truncate(0o600)).unwrap();
        let (store, _) = t.store();
        let room = t.room();
        for (path, why) in [
            ("page", "page/leak.md is a link"),
            ("away", "away is a link"),
            ("away/index.html", "away is a link"),
            ("link.md", "link.md is a link"),
            ("inner", "inner/sub is a link"),
            ("pipe.md", "pipe.md isn't a file or a folder"),
            ("../outside", "no `..`"),
            ("page/../../outside", "no `..`"),
            ("/etc", "no `..`"),
            ("", "no `..`"),
        ] {
            let why_not = store.publish(what(&room, path)).await.unwrap_err();
            assert!(why_not.contains(why), "{path}: {why_not}");
        }
        assert!(store.list(None, None).is_empty());
    }

    /// At most MAX_FILES entries and MAX_BYTES a version.
    #[tokio::test]
    async fn a_version_has_a_size() {
        let t = Temp::new("caps");
        t.write("big/index.html", "x");
        std::fs::File::create(t.room().join("big/video.bin"))
            .unwrap()
            .set_len(MAX_BYTES)
            .unwrap();
        for i in 0..MAX_FILES {
            t.write(&format!("many/{i}.txt"), "");
        }
        t.write("many/index.html", "x");
        let (store, _) = t.store();
        let room = t.room();
        let why = store.publish(what(&room, "big")).await.unwrap_err();
        assert!(why.contains("more than 50 MB"), "{why}");
        let why = store.publish(what(&room, "many")).await.unwrap_err();
        assert!(why.contains("more than 2000 files"), "{why}");
        assert!(store.list(None, None).is_empty());
    }

    /// A secret the scan's rules find, or one obid holds (even in a file that isn't text), and
    /// nothing is kept.
    #[tokio::test]
    async fn secrets_are_never_published() {
        let t = Temp::new("secrets");
        // Put together here, so this file holds no key a scanner flags.
        t.write("page/index.html", "<p>hello</p>");
        t.write(
            "page/config.js",
            format!("const key = \"{}{}\";", "AKIA", "QWERTYUIOPASDFGH"),
        );
        let held = "artifact-test-held-secret-6f1c2e";
        crate::secrets::known().learn("vault ARTIFACT_TEST", held);
        let mut image = vec![0x89, b'P', b'N', b'G', 0xff, 0xfe];
        image.extend_from_slice(held.as_bytes());
        t.write("chart.png", image);
        let (store, _) = t.store();
        let room = t.room();
        let why = store.publish(what(&room, "page")).await.unwrap_err();
        assert!(why.contains("config.js line 1 (AWS access key)"), "{why}");
        let why = store.publish(what(&room, "chart.png")).await.unwrap_err();
        assert!(why.contains("vault secret"), "{why}");
        assert!(!why.contains(held));
        crate::secrets::known().forget("vault ARTIFACT_TEST");
        assert!(store.list(None, None).is_empty());
    }

    #[test]
    fn titles_and_entries() {
        assert_eq!(title_of("landing-page"), "landing-page");
        assert_eq!(title_of("Q3 report.md"), "Q3 report");
        assert_eq!(title_of("a\nb.md"), "a b");
        assert_eq!(clean_title("  x  ").as_deref(), Some("x"));
        assert!(clean_title("").is_none());
        assert!(clean_title("a\u{2028}b").is_none());
        assert!(clean_title(&"x".repeat(101)).is_none());
        let t = Temp::new("entries");
        let worktree = t.0.join("worktree");
        assert!(job_entries(&worktree).is_empty());
        std::fs::create_dir_all(worktree.join(".obi/artifacts/page")).unwrap();
        std::fs::write(worktree.join(".obi/artifacts/notes.md"), "x").unwrap();
        std::fs::write(worktree.join(".obi/artifacts/.hidden"), "x").unwrap();
        assert_eq!(job_entries(&worktree), ["notes.md", "page"]);
        // `.obi/artifacts` a link out of the worktree: nothing.
        std::fs::remove_dir_all(worktree.join(".obi/artifacts")).unwrap();
        std::os::unix::fs::symlink(t.room(), worktree.join(".obi/artifacts")).unwrap();
        t.write("x.md", "x");
        assert!(job_entries(&worktree).is_empty());
    }
}
