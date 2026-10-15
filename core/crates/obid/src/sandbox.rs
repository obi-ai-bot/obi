//! The job sandbox (docs/runner-api.md, "obid only: Obi-to-Obi review jobs", "The job sandbox"):
//! what an agent and the repository's check run in. Bubblewrap on Linux, a Seatbelt profile run
//! with `sandbox-exec` on macOS. For the process and everything it starts:
//!
//! - **Writes** go only to the job's worktree, the worktree's own git directory
//!   (`<common dir>/worktrees/<name>`), the job's temporary folder (its `HOME` and `TMPDIR`) and,
//!   for an agent, its account folder. A job that commits also writes the clone's objects, refs and
//!   logs; a review job never does.
//! - **Reads, from obid's home and the person's home**: the worktree, the clone's git common
//!   directory (read-only), the job's own folders, and the tools it runs. Nothing else: not the
//!   database, `keys/`, `api-token`, other clones or other worktrees.
//! - **Network**: none for the check; an agent keeps the network any agent has (its model's API).
//!
//! When the sandbox can't be made on this machine, nothing runs: [`Sandbox::detect`] says why, and
//! the job fails saying so.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The tool that makes the sandbox on this machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Sandbox {
    /// `bwrap`, at this path.
    Bubblewrap(PathBuf),
    /// `/usr/bin/sandbox-exec`.
    Seatbelt(PathBuf),
}

/// What one sandboxed process may touch.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Spec {
    /// The job's worktree: read and written, the working directory.
    pub worktree: PathBuf,
    /// The worktree's own git directory (`<common>/worktrees/<name>`): written.
    pub git_admin: Option<PathBuf>,
    /// The clone's git common directory: read only, unless `commits`.
    pub git_common: Option<PathBuf>,
    /// The job commits: the common directory's `objects`, `refs` and `logs` are written too.
    pub commits: bool,
    /// The job's temporary folder: its `HOME` and `TMPDIR`, read and written.
    pub temp: PathBuf,
    /// The agent's account: its folder (`configDir`), or the files of the tool's own login. Read
    /// and written. Never for the check.
    pub accounts: Vec<PathBuf>,
    /// Files or folders read but never written inside what is hidden: the tools on `PATH` that live
    /// in a hidden folder, the agent's own binary.
    pub read_only: Vec<PathBuf>,
    /// Folders nothing in the sandbox may read or write, but for what the fields above name:
    /// obid's home and the person's home.
    pub hidden: Vec<PathBuf>,
    /// Whether it may reach the network at all.
    pub network: bool,
}

impl Sandbox {
    /// The sandbox this machine can make, or why it can't.
    pub fn detect() -> Result<Sandbox, String> {
        if cfg!(target_os = "macos") {
            let path = PathBuf::from("/usr/bin/sandbox-exec");
            if path.exists() {
                return Ok(Sandbox::Seatbelt(path));
            }
            return Err(
                "/usr/bin/sandbox-exec isn't on this Mac, so obid can't make the job sandbox."
                    .into(),
            );
        }
        if cfg!(target_os = "linux") {
            let Some(bwrap) = find_on_path("bwrap") else {
                return Err(
                    "bubblewrap (bwrap) isn't installed, so obid can't make the job sandbox."
                        .into(),
                );
            };
            // A trial run: user namespaces can be off (or refused by AppArmor) on this machine.
            let tried = std::process::Command::new(&bwrap)
                .args([
                    "--unshare-pid",
                    "--ro-bind",
                    "/",
                    "/",
                    "--dev",
                    "/dev",
                    "--proc",
                    "/proc",
                    "--",
                    "true",
                ])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped())
                .output();
            return match tried {
                Ok(output) if output.status.success() => Ok(Sandbox::Bubblewrap(bwrap)),
                Ok(output) => Err(format!(
                    "bubblewrap can't make a sandbox on this machine: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                )),
                Err(e) => Err(format!("bubblewrap can't run: {e}")),
            };
        }
        Err("obid makes the job sandbox only on Linux and macOS.".into())
    }

    /// The command line that runs `argv` inside the sandbox `spec` describes: the program, then its
    /// arguments. The caller sets the working directory to `spec.worktree` and the environment.
    pub fn wrap(&self, spec: &Spec, argv: &[OsString]) -> Vec<OsString> {
        let spec = spec.canonical();
        match self {
            Sandbox::Bubblewrap(bwrap) => {
                let mut out: Vec<OsString> = vec![bwrap.clone().into()];
                out.extend(bubblewrap_args(&spec));
                out.push("--".into());
                out.extend(argv.iter().cloned());
                out
            }
            Sandbox::Seatbelt(sandbox_exec) => {
                let mut out: Vec<OsString> = vec![sandbox_exec.clone().into(), "-p".into()];
                out.push(seatbelt_profile(&spec).into());
                out.extend(argv.iter().cloned());
                out
            }
        }
    }
}

impl Spec {
    /// Every path as the kernel sees it (macOS's `/tmp` and `/var` are behind symbolic links, and a
    /// Seatbelt profile matches real paths). A path that doesn't exist is kept as given.
    fn canonical(&self) -> Spec {
        let real = |p: &PathBuf| p.canonicalize().unwrap_or_else(|_| p.clone());
        let mut read_only: Vec<PathBuf> = Vec::new();
        for path in &self.read_only {
            // The path as named, where it leads, and every symbolic link on the way there: exec
            // and lookups go through the name, and a Seatbelt profile matches what each link is.
            let mut candidates = vec![path.clone(), real(path)];
            candidates.extend(symlinks_on_the_way(path));
            for candidate in candidates {
                if !read_only.contains(&candidate) {
                    read_only.push(candidate);
                }
            }
        }
        let mut hidden: Vec<PathBuf> = Vec::new();
        for path in &self.hidden {
            for candidate in [path.clone(), real(path)] {
                if !hidden.contains(&candidate)
                    && candidate.is_absolute()
                    && candidate != Path::new("/")
                {
                    hidden.push(candidate);
                }
            }
        }
        // Outermost first, so an inner one is made inside the outer one's empty folder.
        hidden.sort_by_key(|p| p.components().count());
        Spec {
            worktree: real(&self.worktree),
            git_admin: self.git_admin.as_ref().map(real),
            git_common: self.git_common.as_ref().map(real),
            commits: self.commits,
            temp: real(&self.temp),
            accounts: self.accounts.iter().map(real).collect(),
            read_only,
            hidden,
            network: self.network,
        }
    }

    /// The folders written.
    fn writable(&self) -> Vec<PathBuf> {
        let mut out = vec![self.worktree.clone()];
        out.extend(self.git_admin.clone());
        out.push(self.temp.clone());
        out.extend(self.accounts.iter().cloned());
        if self.commits
            && let Some(common) = &self.git_common
        {
            out.extend(["objects", "refs", "logs"].map(|d| common.join(d)));
        }
        out
    }

    /// Everything read inside a hidden folder.
    fn readable(&self) -> Vec<PathBuf> {
        let mut out = self.writable();
        out.extend(self.git_common.clone());
        out.extend(self.read_only.iter().cloned());
        out
    }
}

/// bubblewrap's arguments, in the order they apply: the whole system read-only, a private `/tmp`
/// and `/dev`, every hidden folder replaced by an empty one, then the job's own paths bound back
/// (read-only or writable), and finally the empty folders made read-only.
fn bubblewrap_args(spec: &Spec) -> Vec<OsString> {
    let mut args: Vec<OsString> = Vec::new();
    let mut push = |items: &[&std::ffi::OsStr]| args.extend(items.iter().map(|s| s.to_os_string()));
    push(&[
        "--unshare-pid".as_ref(),
        "--unshare-ipc".as_ref(),
        "--unshare-uts".as_ref(),
    ]);
    if !spec.network {
        push(&["--unshare-net".as_ref()]);
    }
    push(&["--ro-bind".as_ref(), "/".as_ref(), "/".as_ref()]);
    push(&[
        "--dev".as_ref(),
        "/dev".as_ref(),
        "--proc".as_ref(),
        "/proc".as_ref(),
    ]);
    // /tmp is empty and, at the end, read-only: TMPDIR is the job's own folder.
    push(&["--tmpfs".as_ref(), "/tmp".as_ref()]);
    for hidden in &spec.hidden {
        push(&["--tmpfs".as_ref(), hidden.as_os_str()]);
    }
    for path in &spec.read_only {
        if path.exists() {
            push(&["--ro-bind".as_ref(), path.as_os_str(), path.as_os_str()]);
        }
    }
    if let Some(common) = &spec.git_common {
        push(&["--ro-bind".as_ref(), common.as_os_str(), common.as_os_str()]);
    }
    let worktree = spec.worktree.as_os_str();
    push(&["--bind".as_ref(), worktree, worktree]);
    // The pointer that says where the worktree's git data is stays as obid wrote it.
    let pointer = spec.worktree.join(".git");
    if pointer.is_file() {
        push(&[
            "--ro-bind".as_ref(),
            pointer.as_os_str(),
            pointer.as_os_str(),
        ]);
    }
    if let Some(admin) = &spec.git_admin {
        push(&["--bind".as_ref(), admin.as_os_str(), admin.as_os_str()]);
        // Where git finds the common directory, and the way back to the worktree, stay too.
        for file in ["commondir", "gitdir"] {
            let file = admin.join(file);
            if file.is_file() {
                push(&["--ro-bind".as_ref(), file.as_os_str(), file.as_os_str()]);
            }
        }
    }
    if spec.commits
        && let Some(common) = &spec.git_common
    {
        for dir in ["objects", "refs", "logs"] {
            let dir = common.join(dir);
            if dir.is_dir() {
                push(&["--bind".as_ref(), dir.as_os_str(), dir.as_os_str()]);
            }
        }
    }
    push(&[
        "--bind".as_ref(),
        spec.temp.as_os_str(),
        spec.temp.as_os_str(),
    ]);
    for account in &spec.accounts {
        push(&[
            "--bind-try".as_ref(),
            account.as_os_str(),
            account.as_os_str(),
        ]);
    }
    push(&["--remount-ro".as_ref(), "/tmp".as_ref()]);
    for hidden in &spec.hidden {
        push(&["--remount-ro".as_ref(), hidden.as_os_str()]);
    }
    push(&["--chdir".as_ref(), worktree]);
    args
}

/// A Seatbelt profile: everything allowed but what follows (later rules win). No writes but the
/// job's own; no reads in a hidden folder but the job's own and the tools', with the folders above
/// them visible by name only (their metadata, so paths resolve), never listed; no network for the
/// check.
fn seatbelt_profile(spec: &Spec) -> String {
    let mut profile =
        String::from("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*");
    for path in spec.writable() {
        profile.push_str(&format!(" (subpath {})", sbpl_string(&path)));
    }
    // What a process writes to that isn't a file: its terminal and the null device.
    profile.push_str(
        " (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/\"))\n",
    );
    // The pointers that say where the worktree's git data is, and the way back, stay as obid wrote
    // them (bubblewrap binds them read-only).
    profile.push_str(&format!(
        "(deny file-write* (literal {})",
        sbpl_string(&spec.worktree.join(".git"))
    ));
    if let Some(admin) = &spec.git_admin {
        for file in ["commondir", "gitdir"] {
            profile.push_str(&format!(" (literal {})", sbpl_string(&admin.join(file))));
        }
    }
    profile.push_str(")\n");
    if !spec.hidden.is_empty() {
        profile.push_str("(deny file-read*");
        for hidden in &spec.hidden {
            profile.push_str(&format!(" (subpath {})", sbpl_string(hidden)));
        }
        profile.push_str(")\n");
        let readable = spec.readable();
        let mut ancestors: Vec<PathBuf> = Vec::new();
        for path in &readable {
            for ancestor in path.ancestors().skip(1) {
                if spec.hidden.iter().any(|h| ancestor.starts_with(h))
                    && !ancestors.iter().any(|a| a == ancestor)
                {
                    ancestors.push(ancestor.to_path_buf());
                }
            }
        }
        if !ancestors.is_empty() {
            profile.push_str("(allow file-read-metadata");
            for ancestor in &ancestors {
                profile.push_str(&format!(" (literal {})", sbpl_string(ancestor)));
            }
            profile.push_str(")\n");
        }
        profile.push_str("(allow file-read*");
        for path in &readable {
            profile.push_str(&format!(" (subpath {})", sbpl_string(path)));
        }
        profile.push_str(")\n");
    }
    if !spec.network {
        profile.push_str("(deny network*)\n");
    }
    profile
}

/// A path as an SBPL string literal.
fn sbpl_string(path: &Path) -> String {
    let text = path.to_string_lossy();
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// Every symbolic link a lookup of `path` goes through, as the links themselves (not where they
/// lead), at most 40 of them.
pub fn symlinks_on_the_way(path: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut queue: std::collections::VecDeque<std::ffi::OsString> = path
        .components()
        .filter_map(|c| match c {
            std::path::Component::Normal(name) => Some(name.to_os_string()),
            std::path::Component::ParentDir => Some("..".into()),
            _ => None,
        })
        .collect();
    let mut current = PathBuf::from("/");
    while let Some(part) = queue.pop_front() {
        if part == ".." {
            current.pop();
            continue;
        }
        let next = current.join(&part);
        match std::fs::symlink_metadata(&next) {
            Ok(meta) if meta.file_type().is_symlink() && found.len() < 40 => {
                let Ok(target) = std::fs::read_link(&next) else {
                    current = next;
                    continue;
                };
                found.push(next);
                if target.is_absolute() {
                    current = PathBuf::from("/");
                }
                let parts: Vec<std::ffi::OsString> = target
                    .components()
                    .filter_map(|c| match c {
                        std::path::Component::Normal(name) => Some(name.to_os_string()),
                        std::path::Component::ParentDir => Some("..".into()),
                        _ => None,
                    })
                    .collect();
                for part in parts.into_iter().rev() {
                    queue.push_front(part);
                }
            }
            _ => current = next,
        }
    }
    found
}

/// `name` found on obid's own `PATH`, or `None`.
pub fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable(candidate))
}

/// A regular file someone may execute.
pub fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The folders of the tools on `path` that a sandbox hiding `hidden` must still let a process
/// read: each `PATH` entry inside a hidden folder (and, for one named `bin`, the `lib` and
/// `libexec` beside it), never a hidden folder itself or one above it, and nothing inside `never`
/// (obid's home).
pub fn tool_roots(path: &std::ffi::OsStr, hidden: &[PathBuf], never: &[PathBuf]) -> Vec<PathBuf> {
    let never: Vec<PathBuf> = never
        .iter()
        .flat_map(|h| [h.clone(), h.canonicalize().unwrap_or_else(|_| h.clone())])
        .collect();
    let mut roots = Vec::new();
    let hidden: Vec<PathBuf> = hidden
        .iter()
        .flat_map(|h| [h.clone(), h.canonicalize().unwrap_or_else(|_| h.clone())])
        .collect();
    for dir in std::env::split_paths(path) {
        if !dir.is_absolute() {
            continue;
        }
        for dir in [dir.clone(), dir.canonicalize().unwrap_or(dir)] {
            let inside = |p: &Path| hidden.iter().any(|h| p.starts_with(h) && p != h);
            // A hidden folder, or one that holds one, would show what is hidden.
            if !inside(&dir)
                || hidden.iter().any(|h| h.starts_with(&dir))
                || never.iter().any(|n| dir.starts_with(n))
            {
                continue;
            }
            let mut found = vec![dir.clone()];
            // A `bin` of an installation brings the libraries beside it, not the rest of what is
            // there: `~/.local/bin` must not show all of `~/.local`.
            if let Some(parent) = dir.parent()
                && dir.file_name().is_some_and(|n| n == "bin")
                && inside(parent)
            {
                found.extend(
                    ["lib", "libexec"]
                        .map(|d| parent.join(d))
                        .into_iter()
                        .filter(|d| d.is_dir()),
                );
            }
            for root in found {
                if !roots.contains(&root) {
                    roots.push(root);
                }
            }
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_in_a_hidden_home_come_back_with_their_libraries_only() {
        let root = std::env::temp_dir().join(format!("obid-tool-roots-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let home = root.join("home/w");
        for dir in [
            ".local/share/fnm/v22/bin",
            ".local/share/fnm/v22/lib",
            ".local/bin",
            ".local/lib",
            "bin",
            "obid/x",
        ] {
            std::fs::create_dir_all(home.join(dir)).unwrap();
        }
        let path = std::env::join_paths([
            PathBuf::from("/usr/bin"),
            home.join(".local/share/fnm/v22/bin"),
            home.join(".local/bin"),
            home.join("bin"),
            home.clone(),
            root.join("home"),
            PathBuf::from("relative"),
            home.join("obid/x"),
        ])
        .unwrap();
        let roots = tool_roots(
            &path,
            &[home.clone(), home.join("obid")],
            &[home.join("obid")],
        );
        let _ = std::fs::remove_dir_all(&root);
        let real = |p: &str| home.canonicalize().unwrap_or_else(|_| home.clone()).join(p);
        let roots: Vec<PathBuf> = roots
            .into_iter()
            .filter(|r| {
                r.starts_with(home.canonicalize().unwrap_or_else(|_| home.clone()))
                    || r.starts_with(&home)
            })
            .collect();
        for expected in [
            ".local/share/fnm/v22/bin",
            ".local/share/fnm/v22/lib",
            ".local/bin",
            ".local/lib",
            "bin",
        ] {
            assert!(
                roots.contains(&home.join(expected)) || roots.contains(&real(expected)),
                "{expected}: {roots:?}"
            );
        }
        for never in [".local", ".local/share", "obid/x", ""] {
            assert!(
                !roots.contains(&home.join(never)) && !roots.contains(&real(never)),
                "{never}: {roots:?}"
            );
        }
    }

    #[test]
    fn symlinks_on_the_way_are_found() {
        let root = std::env::temp_dir().join(format!("obid-symlinks-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("share/v22/bin")).unwrap();
        std::fs::create_dir_all(root.join("state")).unwrap();
        std::os::unix::fs::symlink("../share/v22", root.join("state/default")).unwrap();
        std::os::unix::fs::symlink(root.join("state/default"), root.join("state/shell")).unwrap();
        let root_real = root.canonicalize().unwrap();
        let found: Vec<PathBuf> = symlinks_on_the_way(&root_real.join("state/shell/bin"))
            .into_iter()
            // macOS's /var, on the way to the temporary folder the absolute link names, too.
            .filter(|p| p.starts_with(&root_real))
            .collect();
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(
            found,
            vec![
                root_real.join("state/shell"),
                root_real.join("state/default")
            ]
        );
    }

    #[test]
    fn seatbelt_profile_names_only_the_jobs_paths() {
        let spec = Spec {
            worktree: "/h/worktrees/j1".into(),
            git_admin: Some("/h/clones/o/n/.git/worktrees/j1".into()),
            git_common: Some("/h/clones/o/n/.git".into()),
            temp: "/h/tmp/j1".into(),
            hidden: vec!["/h".into(), "/Users/w".into()],
            ..Spec::default()
        };
        let profile = seatbelt_profile(&spec);
        assert!(profile.contains("(allow file-write* (subpath \"/h/worktrees/j1\") (subpath \"/h/clones/o/n/.git/worktrees/j1\") (subpath \"/h/tmp/j1\")"));
        assert!(profile.contains("(deny file-read* (subpath \"/h\") (subpath \"/Users/w\"))"));
        assert!(profile.contains("(literal \"/h/worktrees\")"));
        assert!(!profile.contains("(subpath \"/h/clones/o/n/.git/objects\")"));
        assert!(profile.ends_with("(deny network*)\n"));
        assert_eq!(sbpl_string(Path::new("/a \"b\\")), "\"/a \\\"b\\\\\"");
    }

    #[test]
    fn bubblewrap_hides_then_binds_back() {
        let spec = Spec {
            worktree: "/h/worktrees/j1".into(),
            temp: "/h/tmp/j1".into(),
            hidden: vec!["/h".into()],
            network: false,
            ..Spec::default()
        };
        let args: Vec<String> = bubblewrap_args(&spec)
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let at = |s: &str| args.iter().position(|a| a == s).unwrap();
        assert!(args.contains(&"--unshare-net".to_owned()));
        assert!(at("--tmpfs") < at("--bind"));
        assert_eq!(
            args[args.len() - 2..],
            ["--chdir".to_owned(), "/h/worktrees/j1".to_owned()]
        );
    }
}
