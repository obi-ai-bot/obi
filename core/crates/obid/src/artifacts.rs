//! Artifacts (docs/conversation-harness.md, section 4; docs/runner-api.md, "obid only:
//! artifacts"): what an agent makes to be looked at, a page, a document, an image, a PDF or a
//! canvas of pages, kept with every version in `home/artifacts/<id>/<version>/` and described by
//! `home/artifacts/<id>/artifact.json`.
//!
//! [`Artifacts::publish`] is the one way in, for a job's `.obi/artifacts/` when it ends
//! (crate::jobs) and for a conversation's `oby_artifact` tool. It copies from a folder the agent
//! wrote, so nothing there is trusted: every folder and file is opened without following a link
//! (`O_NOFOLLOW`, each one inside the folder already opened), so a link anywhere, on the way or
//! inside, is refused, as is anything that isn't a plain file or folder, a file with another
//! (hard) link to it, and anything on another disk; hidden names (`.git`, `.DS_Store`) are left
//! out but counted; a version holds at most [`MAX_FILES`] entries and [`MAX_BYTES`], an artifact
//! [`MAX_VERSIONS`] versions. Then every file, read as text whatever its bytes, and every name
//! (the path, the title, each file's) go through the publish gate's secret scan (crate::scan):
//! any finding, or a scan that can't run, and nothing is kept. A refusal that would repeat a name
//! that looks like a secret says [`NAME_REFUSED`] instead.

use std::ffi::CString;
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::fs::MetadataExt;
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
/// The most versions one artifact keeps: past it, a new one is refused.
pub const MAX_VERSIONS: u32 = 50;
/// The most entries of a job's `.obi/artifacts/` published at its end: the rest are refused.
pub const MAX_JOB_ENTRIES: usize = 20;
/// The most bytes one job's artifacts hold, every version of each counted.
pub const MAX_JOB_BYTES: u64 = 500 * 1024 * 1024;
/// How a refusal for a job's artifacts holding too much begins.
pub const JOB_FULL: &str = "Not published: this job's artifacts hold";
/// What a refusal says instead, when what it would say holds what looks like a secret (a name).
pub const NAME_REFUSED: &str =
    "Not published: a name in it looks like a secret, so obid doesn't say it.";
/// The longest title.
const TITLE: usize = 100;

/// What every file obid serves from an artifact carries: its scripts run, but it loads and
/// fetches nothing past its own files (`connect-src 'none'`, no plug-in, no `<base>`, no form, no
/// frame of it in another page), and `sandbox allow-scripts` gives it an origin of its own, so it
/// can't read what obid's other pages keep on this origin (the web app's token in session
/// storage) or open windows. A CSP can't stop it navigating itself, WebRTC, DNS prefetch or a
/// meta refresh: the apps deny navigation (docs/conversation-harness.md, section 4).
pub const POLICY: &str = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' data: blob:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; connect-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox allow-scripts";

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
    /// [`MAX_JOB_BYTES`], lower in tests.
    job_bytes: u64,
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
            job_bytes: MAX_JOB_BYTES,
            lock: Mutex::new(()),
        }))
    }

    /// Publishes `what` as a new artifact, or a new version of `what.artifact`, and says its id
    /// and version, after the `artifact` event went out. When the files are the same as the
    /// artifact's latest version, that version is the answer and nothing new is kept. `Err` is
    /// one line saying why nothing was published.
    pub async fn publish(&self, what: Publish<'_>) -> Result<(String, u32), String> {
        match self.publish_unsaid(what).await {
            Ok(made) => Ok(made),
            // A refusal may name what it refused: never a name that looks like a secret.
            Err(why) => Err(self.speakable(why).await),
        }
    }

    async fn publish_unsaid(&self, what: Publish<'_>) -> Result<(String, u32), String> {
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
                // Before anything is copied or scanned.
                if artifact.versions.len() >= MAX_VERSIONS as usize {
                    return Err(full(&artifact.id));
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
        // The names it would show (the path, the title, every file's) are scanned like its files.
        let names: Vec<String> = [what.path.to_owned(), title.to_owned()]
            .into_iter()
            .chain(copied.files.iter().cloned())
            .collect();
        self.scan_names(&names).await?;
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
        if artifact.versions.len() >= MAX_VERSIONS as usize {
            return Err(full(&artifact.id));
        }
        if let Some(job) = what.job {
            let held: u64 = self
                .list(None, Some(job))
                .iter()
                .flat_map(|a| &a.versions)
                .map(|v| v.bytes)
                .sum();
            if held + copied.bytes > self.job_bytes {
                return Err(format!(
                    "{JOB_FULL} {} MB, and {} MB is the most one job's may.",
                    held / 1024 / 1024,
                    self.job_bytes / 1024 / 1024
                ));
            }
        }
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

    /// The secret scan over every file, read as text whatever it holds (bytes that aren't UTF-8
    /// become U+FFFD, so the ASCII runs a key is made of stay whole), and again without its NUL
    /// bytes when it has some (UTF-16 text): the built-in rules, the secrets obid holds and
    /// gitleaks. What a compressed stream holds (a PDF's Flate, a PNG's zTXt, gzip) isn't read.
    async fn scan(&self, staging: &Path, files: &[String]) -> Result<(), String> {
        let mut texts = Vec::new();
        for name in files {
            let bytes = std::fs::read(staging.join(name))
                .map_err(|e| format!("Not published: obid couldn't read {name} ({e})."))?;
            if bytes.contains(&0) {
                let narrow: Vec<u8> = bytes.iter().copied().filter(|b| *b != 0).collect();
                texts.push((name.clone(), String::from_utf8_lossy(&narrow).into_owned()));
            }
            texts.push((name.clone(), String::from_utf8_lossy(&bytes).into_owned()));
        }
        make_private_dir(&self.scratch)
            .map_err(|e| format!("Not published: the secret scan couldn't run ({e})."))?;
        let found = match crate::scan::scan(&texts, &self.scratch).await {
            crate::scan::Verdict::Clean => return Ok(()),
            crate::scan::Verdict::Found(found) => found,
            crate::scan::Verdict::CouldNotRun(why) => {
                return Err(format!(
                    "Not published: the secret scan couldn't run ({why})."
                ));
            }
        };
        let mut places: Vec<String> = found.iter().map(ToString::to_string).collect();
        places.dedup();
        places.truncate(5);
        Err(format!(
            "Not published: the secret scan found what looks like a secret in {}.",
            places.join(", ")
        ))
    }

    /// The built-in rules, the secrets obid holds and gitleaks on `names`, each as a line of its
    /// own: [`NAME_REFUSED`] when one looks like a secret.
    async fn scan_names(&self, names: &[String]) -> Result<(), String> {
        crate::vault::check()
            .map_err(|why| format!("Not published: the secret scan couldn't run ({why})."))?;
        // gitleaks wants a key to end where a word does: `<key>.md` and `<key>/index.html` hide
        // it. So each part between `/`s, and each piece between `.`s, is a line too.
        let mut parts: Vec<String> = Vec::new();
        for name in names {
            parts.push(name.clone());
            for part in name.split('/') {
                parts.push(part.to_owned());
                parts.extend(part.split('.').map(str::to_owned));
            }
        }
        parts.retain(|p| !p.is_empty());
        parts.sort();
        parts.dedup();
        let lines: Vec<(String, String)> = parts
            .iter()
            .map(|n| ("name".to_owned(), n.clone()))
            .collect();
        if !crate::scan::built_in(&lines).is_empty() {
            return Err(NAME_REFUSED.into());
        }
        make_private_dir(&self.scratch)
            .map_err(|e| format!("Not published: the secret scan couldn't run ({e})."))?;
        match crate::scan::gitleaks_names(&parts, &self.scratch).await {
            Ok(found) if found.is_empty() => Ok(()),
            Ok(_) => Err(NAME_REFUSED.into()),
            Err(why) => Err(format!(
                "Not published: the secret scan couldn't run ({why})."
            )),
        }
    }

    /// `line` as obid may say it, or [`NAME_REFUSED`] when it holds what looks like a secret (a
    /// name a refusal repeats); when the scan can't run, it isn't said either.
    pub async fn speakable(&self, line: String) -> String {
        match self.scan_names(std::slice::from_ref(&line)).await {
            Ok(()) => line,
            Err(why) if why == NAME_REFUSED => why,
            Err(_) => {
                "Not published: the secret scan couldn't run, so obid doesn't say why.".into()
            }
        }
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

/// Why an artifact at [`MAX_VERSIONS`] gets no more.
fn full(id: &str) -> String {
    format!(
        "Not published: artifact {id} has {MAX_VERSIONS} versions, the most obid keeps; publish it as a new one."
    )
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
    /// Every name seen in its folders, hidden ones too.
    entries: usize,
    /// The disk its folder is on.
    dev: u64,
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
    still_there(&at, last, &metadata(&entry)?, &shown)?;
    let mut copied = Copied {
        files: Vec::new(),
        bytes: 0,
        folder: false,
        entries: 0,
        dev: metadata(&at)?.dev(),
    };
    make_private_dir(to).map_err(|e| format!("obid couldn't make its copy ({e})."))?;
    let meta = metadata(&entry)?;
    plain(&meta, &shown, copied.dev)?;
    if meta.is_dir() {
        copied.folder = true;
        copy_folder(entry, &shown, to, "", 0, &mut copied)?;
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

/// A file or folder the copy may take: on the same disk as its folder, and a file with no other
/// link to it (a hard link may be to a file outside the folder, which a link check can't see).
fn plain(meta: &std::fs::Metadata, shown: &str, dev: u64) -> Result<(), String> {
    if meta.dev() != dev {
        return Err(format!(
            "{shown} is on another disk: obid publishes only what is in its folder."
        ));
    }
    if meta.is_file() && meta.nlink() > 1 {
        return Err(format!(
            "{shown} has another link to it (a hard link): obid publishes only files of their own."
        ));
    }
    Ok(())
}

/// Whether `name` in `dir` is still the entry opened as `meta`.
fn still_there(
    dir: &impl std::os::fd::AsFd,
    name: &str,
    meta: &std::fs::Metadata,
    shown: &str,
) -> Result<(), String> {
    let now = nix::sys::stat::fstatat(dir, name, nix::fcntl::AtFlags::AT_SYMLINK_NOFOLLOW)
        .map_err(|e| format!("{shown} can't be read ({e})."))?;
    if now.st_dev as u64 != meta.dev() || now.st_ino as u64 != meta.ino() {
        return Err(format!(
            "{shown} changed while obid copied it: try again once nothing writes there."
        ));
    }
    if meta.is_file() && (meta.nlink() != 1 || now.st_nlink as u64 != 1) {
        return Err(format!(
            "{shown} has another link to it (a hard link): obid publishes only files of their own."
        ));
    }
    Ok(())
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
    copied: &mut Copied,
) -> Result<(), String> {
    if depth >= MAX_DEPTH {
        return Err(format!("{shown} is more than {MAX_DEPTH} folders deep."));
    }
    let mut dir = nix::dir::Dir::from_fd(dir).map_err(read_error)?;
    let mut names: Vec<CString> = Vec::new();
    for entry in dir.iter() {
        let name = entry.map_err(read_error)?.file_name().to_owned();
        if name.as_bytes() == b"." || name.as_bytes() == b".." {
            continue;
        }
        // Every name counts, hidden ones too, before any is kept or sorted.
        copied.entries += 1;
        if copied.entries > MAX_FILES {
            return Err(format!("it has more than {MAX_FILES} files."));
        }
        names.push(name);
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
        let entry = open_in(&dir, &name, &path)?;
        still_there(&dir, &name, &metadata(&entry)?, &path)?;
        let inside = format!("{prefix}{name}");
        let meta = metadata(&entry)?;
        plain(&meta, &path, copied.dev)?;
        if meta.is_dir() {
            make_private_dir(&to.join(&inside)).map_err(read_error)?;
            copy_folder(entry, &path, to, &format!("{inside}/"), depth + 1, copied)?;
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
/// `Err` when it holds more than [`MAX_FILES`] names, hidden ones too: then none is published,
/// so "the first by name" is always of them all. The read stops there.
pub fn job_entries(worktree: &Path) -> Result<Vec<String>, String> {
    let mut folder = worktree.to_path_buf();
    for part in [crate::obi_dir::OBI, "artifacts"] {
        folder.push(part);
        if !std::fs::symlink_metadata(&folder).is_ok_and(|m| m.is_dir()) {
            return Ok(Vec::new());
        }
    }
    let Ok(entries) = std::fs::read_dir(&folder) else {
        return Ok(Vec::new());
    };
    let mut names = Vec::new();
    for (read, entry) in entries.enumerate() {
        if read >= MAX_FILES {
            return Err(format!(
                "Not published: .obi/artifacts holds more than {MAX_FILES} names, so none of it is."
            ));
        }
        if let Ok(name) = entry.map(|e| e.file_name())
            && let Ok(name) = name.into_string()
            && !name.starts_with('.')
        {
            names.push(name);
        }
    }
    names.sort();
    Ok(names)
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

    /// A key in a file that isn't UTF-8 (one 0xFF byte), or in UTF-16 text, is found by the rules
    /// too, not only the secrets obid holds (#648's review, F1).
    #[tokio::test]
    async fn secrets_in_bytes_that_arent_utf8_are_found() {
        let t = Temp::new("binary-secrets");
        let key = format!("{}{}", "AKIA", "QWERTYUIOPASDFGH");
        let mut image = vec![0x89, b'P', b'N', b'G', 0xff, 0x00, b'\n'];
        image.extend_from_slice(format!("key: {key}\n").as_bytes());
        t.write("chart.png", image);
        let mut wide = vec![0xff, 0xfe];
        for unit in format!("key: {key}\n").encode_utf16() {
            wide.extend_from_slice(&unit.to_le_bytes());
        }
        t.write("wide.md", wide);
        let (store, _) = t.store();
        let room = t.room();
        for path in ["chart.png", "wide.md"] {
            let why = store.publish(what(&room, path)).await.unwrap_err();
            assert!(why.contains("AWS access key"), "{path}: {why}");
        }
        assert!(store.list(None, None).is_empty());
    }

    /// A name or a title that holds a secret is refused like a file that does, and the refusal
    /// never says the name (F2).
    #[tokio::test]
    async fn names_and_titles_are_scanned_and_never_said() {
        let t = Temp::new("names");
        let token = format!("ghp_{}", "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8");
        t.write("page/index.html", "<p>hi</p>");
        t.write(&format!("page/{token}.txt"), "plain");
        t.write("clean/index.html", "<p>hi</p>");
        t.write(&format!("{token}.md"), "# Notes");
        std::os::unix::fs::symlink("/etc/hosts", t.room().join(format!("{token}-link.md")))
            .unwrap();
        let (store, _) = t.store();
        let room = t.room();
        let link = format!("{token}-link.md");
        let file = format!("{token}.md");
        for (path, title) in [
            ("page", "Page"),
            ("clean", token.as_str()),
            (file.as_str(), "Notes"),
            (link.as_str(), "Notes"),
        ] {
            let why = store
                .publish(Publish {
                    title,
                    ..what(&room, path)
                })
                .await
                .unwrap_err();
            assert!(why.starts_with("Not published: "), "{why}");
            assert!(!why.contains(&token[4..20]), "{path}: {why}");
        }
        assert_eq!(
            store
                .speakable(format!("{token}.md: Not published: there's no {token}.md."))
                .await,
            NAME_REFUSED
        );
        assert_eq!(
            store.speakable("notes.md: fine".into()).await,
            "notes.md: fine"
        );
        assert!(store.list(None, None).is_empty());
    }

    /// At most MAX_VERSIONS versions of one artifact (F3).
    #[tokio::test]
    async fn an_artifact_has_at_most_so_many_versions() {
        let t = Temp::new("versions-cap");
        t.write("notes.md", "0");
        let (store, _) = t.store();
        let room = t.room();
        let (id, _) = store.publish(what(&room, "notes.md")).await.unwrap();
        for n in 2..=MAX_VERSIONS {
            t.write("notes.md", n.to_string());
            let again = Publish {
                artifact: Some(&id),
                ..what(&room, "notes.md")
            };
            assert_eq!(store.publish(again).await.unwrap().1, n);
        }
        t.write("notes.md", "one too many");
        let again = Publish {
            artifact: Some(&id),
            ..what(&room, "notes.md")
        };
        let why = store.publish(again).await.unwrap_err();
        assert!(why.contains(&format!("{MAX_VERSIONS} versions")), "{why}");
        assert_eq!(store.get(&id).unwrap().versions.len() as u32, MAX_VERSIONS);
    }

    /// Hidden names count toward MAX_FILES too, before anything is sorted (F3); a file with
    /// another link to it (a hard link, which may be to a file outside) is refused (F5).
    #[tokio::test]
    async fn hidden_names_count_and_hard_links_are_refused() {
        let t = Temp::new("hidden-hard");
        t.write("hidden/index.html", "x");
        for i in 0..MAX_FILES {
            t.write(&format!("hidden/.{i}"), "");
        }
        std::fs::create_dir_all(t.0.join("outside")).unwrap();
        std::fs::write(t.0.join("outside/secret.md"), "outside").unwrap();
        t.write("hard/index.html", "x");
        std::fs::hard_link(
            t.0.join("outside/secret.md"),
            t.room().join("hard/notes.md"),
        )
        .unwrap();
        std::fs::hard_link(t.0.join("outside/secret.md"), t.room().join("hard.md")).unwrap();
        let (store, _) = t.store();
        let room = t.room();
        let why = store.publish(what(&room, "hidden")).await.unwrap_err();
        assert!(why.contains("more than 2000 files"), "{why}");
        for path in ["hard", "hard.md"] {
            let why = store.publish(what(&room, path)).await.unwrap_err();
            assert!(why.contains("has another link"), "{path}: {why}");
        }
        assert!(store.list(None, None).is_empty());
    }

    /// A made-up Google API key, put together here: only gitleaks knows its shape.
    fn google_key() -> String {
        format!("{}{}", "AIza", "SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q")
    }

    /// A PDF first doesn't blind gitleaks to what follows, in its own file or the next one; and
    /// a key in a name before an extension or a slash is found (#648's re-review, N1, N2).
    #[tokio::test]
    async fn a_pdf_first_and_a_key_in_a_name_are_still_found() {
        if crate::process::resolve_bin("gitleaks").is_none() {
            return;
        }
        let t = Temp::new("gitleaks-only");
        let key = google_key();
        t.write("paper.pdf", format!("%PDF-1.4\nkey = {key}\n"));
        t.write("site/a.pdf", "%PDF-1.4\n%\u{e2}\u{e3}\n");
        t.write("site/b.md", format!("key = {key}\n"));
        t.write("site/index.html", "<p>hi</p>");
        t.write(&format!("{key}.md"), "# plain");
        t.write("nested/index.html", "<p>hi</p>");
        t.write(&format!("nested/{key}/index.html"), "<p>hi</p>");
        let (store, _) = t.store();
        let room = t.room();
        for path in ["paper.pdf", "site"] {
            let why = store.publish(what(&room, path)).await.unwrap_err();
            assert!(why.contains("gitleaks"), "{path}: {why}");
        }
        let named = format!("{key}.md");
        for path in [named.as_str(), "nested"] {
            let why = store.publish(what(&room, path)).await.unwrap_err();
            assert_eq!(why, NAME_REFUSED, "{path}");
        }
        assert_eq!(
            store.speakable(format!("{key}.md: Not published: …")).await,
            NAME_REFUSED
        );
        assert!(store.list(None, None).is_empty());
    }

    /// The entry checked after it's opened is the one its name still names, with no other link
    /// (#648's re-review, N4).
    #[test]
    fn an_entry_swapped_after_it_was_opened_is_refused() {
        let t = Temp::new("swap");
        t.write("x.md", "first");
        t.write("y.md", "second");
        let dir = open(
            &t.room(),
            OFlag::O_DIRECTORY | OFlag::O_RDONLY | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .unwrap();
        let opened = open_in(&dir, "x.md", "x.md").unwrap();
        let meta = metadata(&opened).unwrap();
        assert!(still_there(&dir, "x.md", &meta, "x.md").is_ok());
        std::fs::rename(t.room().join("y.md"), t.room().join("x.md")).unwrap();
        let why = still_there(&dir, "x.md", &meta, "x.md").unwrap_err();
        assert!(why.contains("changed while"), "{why}");
    }

    /// An artifact at its cap is refused before anything is copied; a job's artifacts hold at
    /// most so many bytes in all (#648's re-review, N5).
    #[tokio::test]
    async fn caps_come_before_the_copy_and_a_job_has_a_size() {
        let t = Temp::new("job-bytes");
        t.write("notes.md", "0");
        let (mut store, _) = t.store();
        Arc::get_mut(&mut store).unwrap().job_bytes = 10;
        let room = t.room();
        let (id, _) = store
            .publish(Publish {
                job: Some("j1"),
                conversation: None,
                ..what(&room, "notes.md")
            })
            .await
            .unwrap();
        // Filled to the cap by hand, as 50 publishes would.
        let mut artifact = store.get(&id).unwrap();
        for n in 2..=MAX_VERSIONS {
            let mut v = artifact.versions[0].clone();
            v.version = n;
            artifact.versions.push(v);
        }
        store.save(&artifact).unwrap();
        std::os::unix::fs::symlink("/etc/hosts", room.join("link.md")).unwrap();
        let again = Publish {
            job: Some("j1"),
            conversation: None,
            artifact: Some(&id),
            ..what(&room, "link.md")
        };
        let why = store.publish(again).await.unwrap_err();
        assert!(why.contains("50 versions"), "{why}");
        // j1 holds 50 bytes already (its versions), past its 10.
        t.write("more.md", "0123456789");
        let more = Publish {
            job: Some("j1"),
            conversation: None,
            ..what(&room, "more.md")
        };
        let why = store.publish(more).await.unwrap_err();
        assert!(why.starts_with(JOB_FULL), "{why}");
        // Another job has room.
        let other = Publish {
            job: Some("j2"),
            conversation: None,
            ..what(&room, "more.md")
        };
        assert!(store.publish(other).await.is_ok());
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
        assert_eq!(job_entries(&worktree), Ok(vec![]));
        std::fs::create_dir_all(worktree.join(".obi/artifacts/page")).unwrap();
        std::fs::write(worktree.join(".obi/artifacts/notes.md"), "x").unwrap();
        std::fs::write(worktree.join(".obi/artifacts/.hidden"), "x").unwrap();
        assert_eq!(
            job_entries(&worktree),
            Ok(vec!["notes.md".to_owned(), "page".to_owned()])
        );
        // `.obi/artifacts` a link out of the worktree: nothing.
        std::fs::remove_dir_all(worktree.join(".obi/artifacts")).unwrap();
        std::os::unix::fs::symlink(t.room(), worktree.join(".obi/artifacts")).unwrap();
        t.write("x.md", "x");
        assert_eq!(job_entries(&worktree), Ok(vec![]));
    }

    /// "The first 20 by name" holds: past MAX_FILES names (hidden ones too) none is published,
    /// rather than the first 20 of those read (#648's re-review, N6).
    #[test]
    fn too_many_entries_publish_none() {
        let t = Temp::new("entries-cap");
        let folder = t.0.join("worktree/.obi/artifacts");
        std::fs::create_dir_all(&folder).unwrap();
        for i in 0..MAX_FILES {
            std::fs::write(folder.join(format!(".{i}")), "").unwrap();
        }
        std::fs::write(folder.join("a.md"), "x").unwrap();
        let why = job_entries(&t.0.join("worktree")).unwrap_err();
        assert!(why.contains("more than 2000"), "{why}");
        std::fs::remove_file(folder.join(".0")).unwrap();
        assert_eq!(
            job_entries(&t.0.join("worktree")),
            Ok(vec!["a.md".to_owned()])
        );
    }
}
