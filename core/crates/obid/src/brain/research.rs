//! The chat looks things up (Engine/ResearchTools.swift, #374): a fixed set of read-only lookups
//! the brain may ask for, up to 4 at once. obid runs each with a fixed command line (git on its
//! own clone at one resolved commit, its own `gh` login, `curl` pinned to a public address);
//! model text never becomes a command, an option or a shell program. Results are quoted in the
//! brain's next `work.md`, never in a prompt, with caps on each and on the turn.

use std::collections::HashMap;
use std::future::Future;
use std::net::IpAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

use super::plan::{Lookup, LookupTool, is_branch_name};
use super::read::clamp;

/// The most lookups one turn runs.
pub const MOST: usize = 12;
/// The most the turn's lookups put in the quoted file, in bytes.
pub const SIZE: usize = 48 * 1024;
/// How long one lookup's command may take.
const TIMEOUT: Duration = Duration::from_secs(10);

/// How a lookup went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    Empty,
    Refused,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Empty => "empty",
            Status::Refused => "refused",
            Status::Failed => "failed",
        }
    }
}

/// A bounded, read-only result of one lookup.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub status: Status,
    pub title: String,
    pub text: String,
}

impl Found {
    fn new(status: Status, title: impl Into<String>, text: impl Into<String>) -> Found {
        Found {
            status,
            title: title.into(),
            text: text.into(),
        }
    }
}

/// What a web request answered.
pub struct Response {
    pub status: u16,
    pub mime: String,
    pub location: Option<String>,
    pub body: Vec<u8>,
}

/// A web request to a URL, pinned to an address.
pub type Fetch = Arc<
    dyn Fn(String, String) -> Pin<Box<dyn Future<Output = Result<Response, String>> + Send>>
        + Send
        + Sync,
>;
/// A host's addresses.
pub type Resolve =
    Arc<dyn Fn(String) -> Pin<Box<dyn Future<Output = Option<Vec<String>>> + Send>> + Send + Sync>;

/// The lookups of one turn: obid's clones (each fetched once per turn), its `gh`, and the web.
pub struct Tools {
    /// obid's jobs, for its clones; none in unit tests of the web.
    pub jobs: Option<Arc<crate::jobs::Jobs>>,
    clones: Mutex<HashMap<String, PathBuf>>,
    fetch: Fetch,
    resolve: Resolve,
}

impl Tools {
    pub fn new(jobs: Arc<crate::jobs::Jobs>) -> Tools {
        Tools {
            jobs: Some(jobs),
            clones: Mutex::new(HashMap::new()),
            fetch: Arc::new(|url, address| Box::pin(curl(url, address))),
            resolve: Arc::new(|host| Box::pin(resolve(host))),
        }
    }

    /// Runs one lookup.
    pub async fn run(&self, lookup: &Lookup) -> Found {
        let label = format!(
            "{}{}",
            lookup.tool.as_str(),
            lookup
                .repo
                .as_ref()
                .map_or(String::new(), |r| format!(" {r}"))
        );
        if lookup.tool == LookupTool::FetchUrl {
            return fetch_url(
                lookup.url.as_deref().unwrap_or(""),
                &self.resolve,
                &self.fetch,
            )
            .await;
        }
        match self.code(lookup, &label).await {
            Ok(found) => found,
            Err(why) => Found::new(Status::Failed, label, why),
        }
    }

    async fn clone(&self, repo: &str) -> Result<(PathBuf, String), String> {
        let jobs = self.jobs.as_ref().ok_or("obid's clones aren't here")?;
        let base = jobs
            .default_branch(repo)
            .ok_or_else(|| format!("{repo} isn't a known repository"))?;
        let known = self
            .clones
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(repo)
            .cloned();
        let clone = match known {
            Some(clone) => clone,
            None => {
                let clone = jobs.research_clone(repo).await?;
                self.clones
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(repo.to_owned(), clone.clone());
                clone
            }
        };
        Ok((clone, base))
    }

    async fn code(&self, lookup: &Lookup, label: &str) -> Result<Found, String> {
        if let Some(reference) = &lookup.reference
            && !(is_branch_name(reference)
                || ((7..=40).contains(&reference.len())
                    && reference.bytes().all(|b| b.is_ascii_hexdigit())))
        {
            return Ok(Found::new(Status::Refused, label, "refused unsafe ref"));
        }
        if let Some(path) = &lookup.path
            && (path.is_empty()
                || path.chars().count() > 300
                || path.starts_with('/')
                || path.starts_with('-')
                || path.split('/').any(|p| p == ".."))
        {
            return Ok(Found::new(Status::Refused, label, "refused unsafe path"));
        }
        let Some(repo) = lookup.repo.as_deref() else {
            return Ok(Found::new(Status::Refused, label, "repo is required"));
        };
        if matches!(lookup.tool, LookupTool::ViewIssue | LookupTool::ViewPr) {
            return github(repo, lookup).await;
        }
        let (clone, base) = self.clone(repo).await?;
        let clone_dir = clone.to_string_lossy().into_owned();
        let reference = lookup
            .reference
            .clone()
            .unwrap_or_else(|| format!("origin/{base}"));
        let resolved = git(
            &clone_dir,
            &["rev-parse", "--verify", &format!("{reference}^{{commit}}")],
        )
        .await?;
        let sha = String::from_utf8_lossy(&resolved.out).trim().to_owned();
        if sha.len() != 40 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("git returned an invalid commit id".into());
        }
        let short = &sha[..7];
        let target = match (&lookup.tool, &lookup.query, &lookup.path, lookup.number) {
            (LookupTool::SearchCode, Some(query), _, _) => format!(" {query:?}"),
            (_, _, Some(path), _) => format!(" {path}"),
            (_, _, _, Some(number)) => format!(" #{number}"),
            _ => String::new(),
        };
        let title = format!(
            "{} {repo}@{reference}{target} (sha {short})",
            lookup.tool.as_str()
        );
        let with_path = |mut args: Vec<String>| {
            if let Some(path) = &lookup.path {
                args.push(path.clone());
            }
            args
        };
        let output = match lookup.tool {
            LookupTool::SearchCode => {
                let args = with_path(vec![
                    "grep".into(),
                    "-n".into(),
                    "-I".into(),
                    "-F".into(),
                    "--max-count=5".into(),
                    "-e".into(),
                    lookup.query.clone().unwrap_or_default(),
                    sha.clone(),
                    "--".into(),
                ]);
                let result = git_owned(&clone_dir, &args, &[0, 1]).await?;
                String::from_utf8_lossy(&result.out)
                    .lines()
                    .filter(|l| !l.is_empty())
                    .take(50)
                    .map(|hit| {
                        let bits: Vec<&str> = hit.splitn(4, ':').collect();
                        match bits.as_slice() {
                            [_, path, number, text] if number.parse::<u64>().is_ok() => {
                                let text: String = text.chars().take(200).collect();
                                format!(
                                    "{path}:{number}: {text}\nhttps://github.com/{repo}/blob/{sha}/{path}#L{number}"
                                )
                            }
                            _ => hit.to_owned(),
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n")
            }
            LookupTool::ListFiles => {
                let args = with_path(vec![
                    "ls-tree".into(),
                    "-r".into(),
                    "--name-only".into(),
                    sha.clone(),
                    "--".into(),
                ]);
                let result = git_owned(&clone_dir, &args, &[0]).await?;
                let files: Vec<String> = String::from_utf8_lossy(&result.out)
                    .lines()
                    .filter(|l| !l.is_empty())
                    .map(str::to_owned)
                    .collect();
                let mut text = files
                    .iter()
                    .take(300)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("\n");
                if files.len() > 300 {
                    text.push_str(&format!("\n…(cut: {} more files)", files.len() - 300));
                }
                text
            }
            LookupTool::ReadFile => {
                let path = lookup.path.clone().unwrap_or_default();
                let result = git_owned(&clone_dir, &["show".into(), format!("{sha}:{path}")], &[0])
                    .await
                    .map_err(|_| format!("not in the repository at {short}"))?;
                let all: Vec<String> = String::from_utf8_lossy(&result.out)
                    .split('\n')
                    .map(str::to_owned)
                    .collect();
                let start = lookup.start_line.unwrap_or(1).max(1) as usize;
                let end = lookup
                    .end_line
                    .map_or(start + 399, |e| e.max(0) as usize)
                    .min(all.len());
                let lines: Vec<String> = (start..=end)
                    .filter(|_| start <= end)
                    .map(|n| format!("{n}: {}", all[n - 1]))
                    .collect();
                format!(
                    "https://github.com/{repo}/blob/{sha}/{path}#L{start}-L{end}\n\n{}",
                    lines.join("\n")
                )
            }
            LookupTool::GitLog => {
                let args = with_path(vec![
                    "log".into(),
                    "--format=%h %ad %s".into(),
                    "--date=short".into(),
                    "-n".into(),
                    "20".into(),
                    sha.clone(),
                    "--".into(),
                ]);
                let result = git_owned(&clone_dir, &args, &[0]).await?;
                String::from_utf8_lossy(&result.out).into_owned()
            }
            _ => return Ok(Found::new(Status::Refused, label, "invalid tool")),
        };
        let cap = if lookup.tool == LookupTool::ReadFile {
            24 * 1024
        } else {
            16 * 1024
        };
        let empty = output.trim().is_empty();
        Ok(Found::new(
            if empty { Status::Empty } else { Status::Ok },
            title,
            clamp(if empty { "(no results)" } else { &output }, cap),
        ))
    }
}

/// What a command printed.
struct Ran {
    out: Vec<u8>,
}

async fn git(clone: &str, args: &[&str]) -> Result<Ran, String> {
    let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    git_owned(clone, &args, &[0]).await
}

/// git with `args` on `clone`, at most [`TIMEOUT`], with no hook, no fsmonitor and no prompt;
/// an error unless it exits with one of `ok`.
async fn git_owned(clone: &str, args: &[String], ok: &[i32]) -> Result<Ran, String> {
    let mut command = tokio::process::Command::new("git");
    command
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "credential.interactive=never",
            "-C",
            clone,
        ])
        .args(args)
        .env_clear()
        .env("PATH", crate::process::tools_path())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_REPLACE_OBJECTS", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = match tokio::time::timeout(TIMEOUT, command.output()).await {
        Ok(output) => output.map_err(|e| format!("git couldn't run: {e}"))?,
        Err(_) => return Err("lookup timed out after 10 seconds".into()),
    };
    match output.status.code() {
        Some(code) if ok.contains(&code) => Ok(Ran { out: output.stdout }),
        code => Err(String::from_utf8_lossy(&output.stderr)
            .lines()
            .last()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("command exited {}", code.unwrap_or(-1)))),
    }
}

/// An issue or a pull request, with obid's own `gh` login: its title, state, body, labels,
/// files and the first comments, each capped.
async fn github(repo: &str, lookup: &Lookup) -> Result<Found, String> {
    let number = lookup.number.unwrap_or(0);
    let (kind, fields) = if lookup.tool == LookupTool::ViewIssue {
        ("issue", "title,body,state,labels,url,author,comments")
    } else {
        (
            "pr",
            "title,body,state,labels,url,author,comments,files,baseRefName,headRefName",
        )
    };
    let gh = crate::process::resolve_bin("gh").ok_or("gh isn't available")?;
    let mut command = tokio::process::Command::new(gh);
    command
        .args([
            kind,
            "view",
            &number.to_string(),
            "-R",
            repo,
            "--json",
            fields,
        ])
        .env("GH_PAGER", "cat")
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(TIMEOUT, command.output())
        .await
        .map_err(|_| "lookup timed out after 10 seconds".to_owned())?
        .map_err(|e| format!("gh couldn't run: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr)
            .lines()
            .last()
            .map(str::to_owned)
            .unwrap_or_else(|| "gh failed".into()));
    }
    let object: Value =
        serde_json::from_slice(&output.stdout).map_err(|_| "GitHub returned unreadable JSON")?;
    let path = if kind == "issue" { "issues" } else { "pull" };
    let mut lines = vec![
        format!("https://github.com/{repo}/{path}/{number}"),
        format!(
            "Title: {}",
            object["title"].as_str().unwrap_or("(no title)")
        ),
        format!("State: {}", object["state"].as_str().unwrap_or("unknown")),
        String::new(),
        clamp(object["body"].as_str().unwrap_or(""), 6 * 1024),
    ];
    if let Some(labels) = object["labels"].as_array() {
        let names: Vec<&str> = labels.iter().filter_map(|l| l["name"].as_str()).collect();
        lines.extend([String::new(), format!("Labels: {}", names.join(", "))]);
    }
    if let (Some(base), Some(head)) = (
        object["baseRefName"].as_str(),
        object["headRefName"].as_str(),
    ) {
        lines.push(format!("Branches: {head} → {base}"));
    }
    if let Some(files) = object["files"].as_array() {
        lines.extend([String::new(), "Files:".into()]);
        lines.extend(
            files
                .iter()
                .take(50)
                .filter_map(|f| f["path"].as_str())
                .map(|p| format!("- {p}")),
        );
    }
    if let Some(comments) = object["comments"].as_array().filter(|c| !c.is_empty()) {
        lines.extend([String::new(), "Comments:".into()]);
        for comment in comments.iter().take(10) {
            lines.push(format!(
                "- @{}: {}",
                comment["author"]["login"].as_str().unwrap_or("unknown"),
                clamp(comment["body"].as_str().unwrap_or(""), 1024)
            ));
        }
        if comments.len() > 10 {
            lines.push(format!("…(cut: {} more comments)", comments.len() - 10));
        }
    }
    let title = format!("{} {repo} #{number}", lookup.tool.as_str());
    Ok(Found::new(
        Status::Ok,
        title,
        clamp(&lines.join("\n"), 16 * 1024),
    ))
}

/// A URL's host, when it's `https`, has no user or password, and names a public-looking host.
fn https_host(url: &str) -> Option<(String, u16)> {
    let (scheme, rest) = url.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next()?;
    if authority.contains('@') || url.chars().any(char::is_whitespace) {
        return None;
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if !host.contains(']') || host.ends_with(']') => {
            (host, port.parse().ok()?)
        }
        _ => (authority, 443),
    };
    let host = host.to_lowercase();
    if !host.contains('.')
        || host.ends_with(".local")
        || host.ends_with(".internal")
        || host.ends_with(".ts.net")
        || host == "localhost"
        || host.trim_matches(['[', ']']).parse::<IpAddr>().is_ok()
    {
        return None;
    }
    Some((host, port))
}

/// Whether an address is private, loopback, link-local, carrier-grade NAT (Tailscale) or unique
/// local.
pub fn is_private(address: &str) -> bool {
    match address.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => {
            let [a, b, ..] = v4.octets();
            a == 0
                || a == 10
                || a == 127
                || (a == 172 && (16..=31).contains(&b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
                || (a == 100 && (64..=127).contains(&b))
        }
        Ok(IpAddr::V6(v6)) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_private(&v4.to_string());
            }
            let first = v6.segments()[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || (first & 0xfe00) == 0xfc00
                || (first & 0xffc0) == 0xfe80
        }
        Err(_) => true,
    }
}

/// The public address to connect to for `url`, or none: every address its host resolves to
/// must be public, and the first is pinned, so the connection can't resolve the host again.
async fn public_address(url: &str, resolve: &Resolve) -> Option<String> {
    let (host, _) = https_host(url)?;
    let addresses = resolve(host).await?;
    if addresses.is_empty() || addresses.iter().any(|a| is_private(a)) {
        return None;
    }
    addresses.into_iter().next()
}

/// Whether `url` is a public HTTPS URL, resolved now.
pub async fn is_public_url(url: &str) -> bool {
    let resolve: Resolve = Arc::new(|host| Box::pin(resolve(host)));
    public_address(url, &resolve).await.is_some()
}

async fn resolve(host: String) -> Option<Vec<String>> {
    let found = tokio::net::lookup_host((host.as_str(), 443)).await.ok()?;
    Some(found.map(|a| a.ip().to_string()).collect())
}

/// A web page, public HTTPS only, every redirect resolved and checked again, at most 1 MB, text
/// only, and at most 16 KB of it.
pub async fn fetch_url(url: &str, resolve: &Resolve, fetch: &Fetch) -> Found {
    let refused = |host: &str| {
        Found::new(
            Status::Refused,
            format!("fetch_url {host}"),
            "refused: private address or URL is not public HTTPS",
        )
    };
    let mut current = url.to_owned();
    for redirects in 0..=3 {
        let host = https_host(&current).map(|(h, _)| h).unwrap_or_default();
        let Some(address) = public_address(&current, resolve).await else {
            return refused(&host);
        };
        let response = match fetch(current.clone(), address).await {
            Ok(response) => response,
            Err(why) => return Found::new(Status::Failed, format!("fetch_url {host}"), why),
        };
        if (300..400).contains(&response.status) {
            let next = response.location.as_deref().and_then(|location| {
                if location.starts_with("https://") || location.starts_with("http://") {
                    Some(location.to_owned())
                } else if location.starts_with('/') {
                    // The same authority, its port kept.
                    let authority = current
                        .split_once("://")
                        .map_or("", |(_, rest)| rest)
                        .split(['/', '?', '#'])
                        .next()
                        .unwrap_or("");
                    Some(format!("https://{authority}{location}"))
                } else {
                    None
                }
            });
            match next {
                Some(next) if redirects < 3 => {
                    current = next;
                    continue;
                }
                _ => {
                    return Found::new(
                        Status::Refused,
                        format!("fetch_url {host}"),
                        "refused: invalid or excessive redirect",
                    );
                }
            }
        }
        if !(200..300).contains(&response.status) {
            return Found::new(
                Status::Failed,
                format!("fetch_url {host}"),
                "HTTP request failed",
            );
        }
        if response.body.len() > 1024 * 1024 {
            return Found::new(
                Status::Failed,
                format!("fetch_url {host}"),
                "response exceeded 1 MB",
            );
        }
        let mime = response
            .mime
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_lowercase();
        if !(mime.starts_with("text/") || mime == "application/json" || mime == "application/xml") {
            return Found::new(
                Status::Refused,
                format!("fetch_url {host}"),
                format!("refused content type {mime}"),
            );
        }
        let mut text = String::from_utf8_lossy(&response.body).into_owned();
        if mime == "text/html" {
            text = strip_html(&text);
        }
        let status = if text.trim().is_empty() {
            Status::Empty
        } else {
            Status::Ok
        };
        return Found::new(status, format!("fetch_url {host}"), clamp(&text, 16 * 1024));
    }
    Found::new(Status::Refused, "fetch_url", "refused: excessive redirects")
}

/// A page's words: no scripts, no styles, no tags.
fn strip_html(html: &str) -> String {
    static PATTERNS: std::sync::OnceLock<[regex::Regex; 3]> = std::sync::OnceLock::new();
    let [script, style, tag] = PATTERNS.get_or_init(|| {
        [
            regex::Regex::new(r"(?is)<script\b[^>]*>.*?</script\s*>").expect("a pattern"),
            regex::Regex::new(r"(?is)<style\b[^>]*>.*?</style\s*>").expect("a pattern"),
            regex::Regex::new(r"(?s)<[^>]*>").expect("a pattern"),
        ]
    });
    let text = script.replace_all(html, " ");
    let text = style.replace_all(&text, " ");
    tag.replace_all(&text, " ")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
}

/// `curl` with a fixed command line, connecting only to `address`, no redirects followed, at
/// most 1 MB and 10 seconds.
async fn curl(url: String, address: String) -> Result<Response, String> {
    let (host, port) = https_host(&url).ok_or("web URL has no host")?;
    let pinned = if address.contains(':') {
        format!("[{address}]")
    } else {
        address
    };
    let marker = format!("OBID-META-{}", uuid::Uuid::new_v4().simple());
    let mut command = tokio::process::Command::new("/usr/bin/curl");
    command
        .args([
            "--disable",
            "--silent",
            "--show-error",
            "--noproxy",
            "*",
            "--max-time",
            "10",
            "--max-filesize",
            "1048576",
            "--max-redirs",
            "0",
            "--resolve",
            &format!("{host}:{port}:{pinned}"),
            "--header",
            "Accept: text/*, application/json, application/xml",
            "--dump-header",
            "-",
            "--output",
            "-",
            "--write-out",
            &format!("\n{marker}:%{{http_code}}\\t%{{content_type}}\\n"),
            &url,
        ])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(12), command.output())
        .await
        .map_err(|_| "web request timed out after 10 seconds".to_owned())?
        .map_err(|e| format!("curl couldn't run: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr)
            .lines()
            .last()
            .map(str::to_owned)
            .unwrap_or_else(|| "web request failed".into()));
    }
    if output.stdout.len() > 1024 * 1024 + 64 * 1024 {
        return Err("response exceeded 1 MB".into());
    }
    let needle = format!("\n{marker}:").into_bytes();
    let at = output
        .stdout
        .windows(needle.len())
        .rposition(|w| w == needle.as_slice())
        .ok_or("web request returned no HTTP metadata")?;
    let meta = String::from_utf8_lossy(&output.stdout[at + needle.len()..]).into_owned();
    let meta = meta.lines().next().unwrap_or("");
    let (code, mime) = meta
        .split_once('\t')
        .ok_or("web request returned bad HTTP metadata")?;
    let status: u16 = code
        .parse()
        .map_err(|_| "web request returned bad HTTP metadata")?;
    let response = &output.stdout[..at];
    let split = response
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("web request returned no headers")?;
    let headers = String::from_utf8_lossy(&response[..split]).into_owned();
    let location = headers
        .split("\r\n")
        .find(|h| h.to_lowercase().starts_with("location:"))
        .map(|h| h["location:".len()..].trim().to_owned());
    Ok(Response {
        status,
        mime: mime.to_owned(),
        location,
        body: response[split + 4..].to_vec(),
    })
}

/// The lookups of a turn and what they found, quoted for the brain between steps.
#[derive(Default)]
pub struct Log {
    pub entries: Vec<(String, Lookup, Found)>,
    pub notes: Vec<String>,
}

fn key(lookup: &Lookup) -> String {
    serde_json::to_string(lookup).unwrap_or_default()
}

impl Log {
    /// Runs the lookups not run yet this turn, side by side, up to [`MOST`] in the turn. A web
    /// address that isn't in the user's words (`said`) or an earlier lookup's result this turn is
    /// refused whole, before anything resolves or fetches it: its path or host could carry what
    /// another lookup read out to the web (#546, review on #552).
    pub async fn run(&mut self, lookups: &[Lookup], tools: &Tools, said: &str) {
        let mut checked: Vec<Lookup> = vec![];
        for lookup in lookups {
            let unseen = lookup.tool == LookupTool::FetchUrl
                && lookup
                    .url
                    .as_deref()
                    .is_some_and(|url| !self.seen(url, said));
            if !unseen {
                checked.push(lookup.clone());
                continue;
            }
            let key = key(lookup);
            if self.entries.iter().any(|(k, ..)| *k == key) {
                continue;
            }
            self.notes.push(
                "fetch_url was refused: Oby reads only a web address that's in the user's words or an earlier lookup's result this turn.".into(),
            );
            self.entries.push((
                key,
                lookup.clone(),
                Found::new(
                    Status::Refused,
                    "Web page",
                    "refused: the address isn't in the user's words or an earlier lookup's result this turn",
                ),
            ));
        }
        let lookups = checked;
        let mut fresh: Vec<(String, &Lookup)> = vec![];
        for lookup in &lookups {
            let key = key(lookup);
            if self.entries.iter().any(|(k, ..)| *k == key) || fresh.iter().any(|(k, _)| *k == key)
            {
                self.notes.push(format!(
                    "{} is already in work.md; read it there.",
                    lookup.tool.as_str()
                ));
            } else if self.entries.len() + fresh.len() >= MOST {
                self.notes.push(format!(
                    "Oby reads at most {MOST} lookups in one turn. It did not run {}; answer from work.md or say what remains.",
                    lookup.tool.as_str()
                ));
            } else {
                fresh.push((key, lookup));
            }
        }
        let found =
            futures_util::future::join_all(fresh.iter().map(|(_, lookup)| tools.run(lookup))).await;
        for ((key, lookup), found) in fresh.into_iter().zip(found) {
            // Why a lookup failed can be a tool's own words: quoted with the result, never here.
            let outcome = if matches!(found.status, Status::Failed | Status::Refused) {
                " (why is quoted in work.md)"
            } else {
                ""
            };
            // The address the brain chose is never echoed here: it's in work.md, quoted.
            self.notes.push(format!(
                "{}{} returned status {}{outcome}; its result is quoted in work.md.",
                lookup.tool.as_str(),
                lookup
                    .repo
                    .as_deref()
                    .map(|repo| format!(" {repo}"))
                    .unwrap_or_default(),
                found.status.as_str()
            ));
            self.entries.push((key, lookup.clone(), found));
        }
    }

    /// The quoted file with what was found added, the whole under [`SIZE`].
    /// The quoted file with what was found added, each lookup in a fence of the turn's `nonce`
    /// ([`super::briefing::fence`]), the whole under [`SIZE`]: each block is cut to fit before
    /// it's fenced, so no cut leaves a block open.
    pub fn quoted(&self, file: Option<String>, nonce: &str) -> Option<String> {
        if self.entries.is_empty() {
            return file;
        }
        let file = file.map_or(String::new(), |f| f + "\n");
        let header = format!(
            "# Researched on request, quoted\n\n{}\n\n",
            super::briefing::fence_rule(nonce, "repositories, GitHub and the web")
        );
        // The fence's own lines, and the blank line between blocks.
        let fence = super::briefing::fence(nonce, "").len() + 2;
        let mut remaining = SIZE.saturating_sub(file.len() + header.len() + 1);
        let mut sections = vec![];
        for (index, (_, _, found)) in self.entries.iter().enumerate() {
            let room = remaining.saturating_sub(fence);
            if room < 64 {
                break;
            }
            let section = format!(
                "## Lookup {}: {}\n\nstatus: {}\n\n{}",
                index + 1,
                found.title,
                found.status.as_str(),
                found.text
            );
            let fenced = super::briefing::fence(nonce, &clamp(&section, room));
            remaining = remaining.saturating_sub(fenced.len() + 2);
            sections.push(fenced);
        }
        let combined = format!("{file}{header}{}\n", sections.join("\n\n"));
        // Only a file already past the cap gets cut here.
        Some(clamp(&combined, SIZE))
    }

    /// Whether `url` is in the user's words or an earlier lookup's result this turn.
    fn seen(&self, url: &str, said: &str) -> bool {
        said.contains(url)
            || self
                .entries
                .iter()
                .any(|(_, _, found)| found.text.contains(url))
    }

    /// The request for the brain's next step, with what the lookups did.
    pub fn continued(&self, request: &str) -> String {
        if self.notes.is_empty() {
            request.to_owned()
        } else {
            format!("{request}\n\n({})", self.notes.join(" "))
        }
    }
}

/// What a research step's event says (`Desk.researchStepText`).
pub fn step_text(lookup: &Lookup) -> String {
    let repo = lookup.repo.as_deref();
    match lookup.tool {
        LookupTool::SearchCode => format!(
            "Searching {} for “{}”",
            repo.unwrap_or("code"),
            lookup.query.as_deref().unwrap_or("")
        ),
        LookupTool::ListFiles => format!("Listing files in {}", repo.unwrap_or("repository")),
        LookupTool::ReadFile => format!("Reading {}", lookup.path.as_deref().unwrap_or("file")),
        LookupTool::GitLog => format!(
            "Reading history for {}",
            lookup.path.as_deref().or(repo).unwrap_or("repository")
        ),
        LookupTool::ViewIssue => format!("Reading issue #{}", lookup.number.unwrap_or(0)),
        LookupTool::ViewPr => format!("Reading pull request #{}", lookup.number.unwrap_or(0)),
        LookupTool::FetchUrl => format!("Reading {}", lookup.url.as_deref().unwrap_or("web page")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resolver(answers: &'static [(&'static str, &'static [&'static str])]) -> Resolve {
        Arc::new(move |host: String| {
            let found = answers
                .iter()
                .find(|(h, _)| *h == host)
                .map(|(_, a)| a.iter().map(|s| (*s).to_owned()).collect());
            Box::pin(async move { found })
        })
    }

    /// ResearchToolsTests.isPublicURLRefusesPrivateAndTailnetHosts
    #[tokio::test]
    async fn public_urls_refuse_private_and_tailnet_hosts() {
        let resolve = resolver(&[
            ("100.100.1.1.nip.io", &["100.100.1.1"]),
            ("example.com", &["93.184.215.14"]),
        ]);
        for url in [
            "https://localhost",
            "https://foo",
            "https://10.0.0.1",
            "https://x.ts.net",
            "https://100.100.1.1.nip.io",
            "https://user:pw@example.com",
            "http://example.com",
        ] {
            assert!(public_address(url, &resolve).await.is_none(), "{url}");
        }
        assert_eq!(
            public_address("https://example.com/a", &resolve).await,
            Some("93.184.215.14".into())
        );
        for private in [
            "10.1.2.3",
            "172.20.0.1",
            "192.168.1.1",
            "169.254.1.1",
            "100.64.0.1",
            "::1",
            "fd00::1",
            "fe80::1",
            "::ffff:127.0.0.1",
        ] {
            assert!(is_private(private), "{private}");
        }
        assert!(!is_private("8.8.8.8") && !is_private("2606:4700::1111"));
    }

    /// ResearchToolsTests.webRedirectsResolveAgainAndPassThePinnedAddress
    #[tokio::test]
    async fn web_redirects_resolve_again_and_pass_the_pinned_address() {
        let asked: Arc<Mutex<Vec<(String, String)>>> = Arc::default();
        let seen = asked.clone();
        let fetch: Fetch = Arc::new(move |url, address| {
            seen.lock().unwrap().push((url, address));
            Box::pin(async {
                Ok(Response {
                    status: 302,
                    mime: "text/plain".into(),
                    location: Some("https://internal.example/private".into()),
                    body: vec![],
                })
            })
        });
        let resolve = resolver(&[
            ("public.example", &["8.8.8.8"]),
            ("internal.example", &["127.0.0.1"]),
        ]);
        let found = fetch_url("https://public.example/", &resolve, &fetch).await;
        assert_eq!(found.status, Status::Refused);
        assert!(found.text.contains("private address"));
        assert_eq!(
            *asked.lock().unwrap(),
            [("https://public.example/".to_owned(), "8.8.8.8".to_owned())]
        );
    }

    #[tokio::test]
    async fn pages_are_text_and_their_words_only() {
        let fetch: Fetch = Arc::new(|_, _| {
            Box::pin(async {
                Ok(Response {
                    status: 200,
                    mime: "text/html; charset=utf-8".into(),
                    location: None,
                    body: b"<html><script>steal()</script><p>Hello &amp; welcome</p></html>"
                        .to_vec(),
                })
            })
        });
        let resolve = resolver(&[("docs.example", &["8.8.4.4"])]);
        let found = fetch_url("https://docs.example/", &resolve, &fetch).await;
        assert_eq!(found.status, Status::Ok);
        assert!(found.text.contains("Hello & welcome") && !found.text.contains("steal"));
        let binary: Fetch = Arc::new(|_, _| {
            Box::pin(async {
                Ok(Response {
                    status: 200,
                    mime: "image/png".into(),
                    location: None,
                    body: vec![1, 2],
                })
            })
        });
        assert_eq!(
            fetch_url("https://docs.example/", &resolve, &binary)
                .await
                .status,
            Status::Refused
        );
    }

    /// ResearchToolsTests.combinedResearchAndEarlierQuotesStayUnderTheTurnCap
    #[test]
    fn combined_research_and_earlier_quotes_stay_under_the_turn_cap() {
        let lookup = Lookup {
            tool: LookupTool::ListFiles,
            repo: Some("deskree-inc/oby".into()),
            reference: None,
            query: None,
            path: None,
            start_line: None,
            end_line: None,
            number: None,
            url: None,
        };
        let log = Log {
            entries: vec![(
                key(&lookup),
                lookup,
                Found::new(Status::Ok, "list_files", "x\n".repeat(10_000)),
            )],
            notes: vec![],
        };
        let combined = log.quoted(Some("x".repeat(47 * 1024)), "n0nce").unwrap();
        assert!(combined.len() <= SIZE);
        assert!(Log::default().quoted(None, "n0nce").is_none());
        // What fits is fenced whole: the cut never leaves a block open.
        assert_eq!(
            combined.lines().filter(|l| *l == "<<<quoted-n0nce").count(),
            combined.lines().filter(|l| *l == "quoted-n0nce>>>").count()
        );
    }

    fn web(url: &str) -> Lookup {
        Lookup {
            tool: LookupTool::FetchUrl,
            repo: None,
            reference: None,
            query: None,
            path: None,
            start_line: None,
            end_line: None,
            number: None,
            url: Some(url.into()),
        }
    }

    /// Tools with no clones, whose web answers `body` and notes every address asked.
    fn recording(body: &'static str) -> (Tools, Arc<Mutex<Vec<String>>>) {
        let asked: Arc<Mutex<Vec<String>>> = Arc::default();
        let seen = asked.clone();
        let tools = Tools {
            jobs: None,
            clones: Mutex::default(),
            fetch: Arc::new(move |url, _| {
                seen.lock().unwrap().push(url);
                Box::pin(async move {
                    Ok(Response {
                        status: 200,
                        mime: "text/plain".into(),
                        location: None,
                        body: body.as_bytes().to_vec(),
                    })
                })
            }),
            resolve: resolver(&[
                ("evil.example", &["8.8.8.8"]),
                ("docs.example", &["8.8.4.4"]),
            ]),
        };
        (tools, asked)
    }

    /// A web address the user's words or an earlier result didn't have is refused whole,
    /// before it's resolved or fetched: data could leave in its query, its path or a host
    /// label (review on #552).
    #[tokio::test]
    async fn fetch_url_reads_only_an_address_from_the_users_words_or_a_result() {
        let (tools, asked) = recording("see https://docs.example/page?id=7#top");
        let resolved: Arc<Mutex<Vec<String>>> = Arc::default();
        let tools = Tools {
            resolve: {
                let inner = tools.resolve.clone();
                let resolved = resolved.clone();
                Arc::new(move |host: String| {
                    resolved.lock().unwrap().push(host.clone());
                    inner(host)
                })
            },
            ..tools
        };
        let mut log = Log::default();
        log.run(
            &[
                web("https://evil.example/?d=SECRET#x"),
                web("https://evil.example/SECRET-in-the-path"),
                web("https://SECRET-label.evil.example/"),
            ],
            &tools,
            "read the docs",
        )
        .await;
        assert!(asked.lock().unwrap().is_empty());
        assert!(resolved.lock().unwrap().is_empty());
        assert_eq!(log.entries.len(), 3);
        assert!(
            log.entries
                .iter()
                .all(|(_, _, found)| found.status == Status::Refused)
        );
        let notes = log.notes.join(" ");
        assert!(!notes.contains("SECRET"), "{notes}");
        assert!(notes.contains("fetch_url was refused"), "{notes}");
        log.run(
            &[web("https://docs.example/q?a=1")],
            &tools,
            "read https://docs.example/q?a=1",
        )
        .await;
        log.run(
            &[web("https://docs.example/page?id=7#top")],
            &tools,
            "read the docs",
        )
        .await;
        assert_eq!(
            *asked.lock().unwrap(),
            [
                "https://docs.example/q?a=1",
                "https://docs.example/page?id=7#top"
            ]
        );
        assert!(
            !log.notes.join(" ").contains("docs.example"),
            "{:?}",
            log.notes
        );
    }

    /// A relative redirect keeps the port it came from (review on #552).
    #[tokio::test]
    async fn a_relative_redirect_keeps_its_port() {
        let asked: Arc<Mutex<Vec<String>>> = Arc::default();
        let seen = asked.clone();
        let fetch: Fetch = Arc::new(move |url: String, _| {
            let first = seen.lock().unwrap().is_empty();
            seen.lock().unwrap().push(url);
            Box::pin(async move {
                Ok(if first {
                    Response {
                        status: 302,
                        mime: "text/plain".into(),
                        location: Some("/next".into()),
                        body: vec![],
                    }
                } else {
                    Response {
                        status: 200,
                        mime: "text/plain".into(),
                        location: None,
                        body: b"ok".to_vec(),
                    }
                })
            })
        });
        let resolve = resolver(&[("public.example", &["8.8.8.8"])]);
        let found = fetch_url("https://public.example:8443/start", &resolve, &fetch).await;
        assert_eq!(found.status, Status::Ok);
        assert_eq!(
            *asked.lock().unwrap(),
            [
                "https://public.example:8443/start",
                "https://public.example:8443/next"
            ]
        );
    }
}
