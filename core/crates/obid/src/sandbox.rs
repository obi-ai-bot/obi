//! The job sandbox (docs/runner-api.md, "obid only: Obi-to-Obi review jobs", "The job sandbox"):
//! what an agent and the repository's check run in. Bubblewrap on Linux, a Seatbelt profile run
//! with `sandbox-exec` on macOS. For the process and everything it starts:
//!
//! - **Writes** go only to the job's worktree, the worktree's own git directory
//!   (`<common dir>/worktrees/<name>`), the job's temporary folder (its `HOME` and `TMPDIR`) and,
//!   for an agent, its account folder. Nothing of the clone's common directory, not even for a job
//!   that commits: its new objects go to an object folder of its own inside the worktree's git
//!   directory ([`Spec::git_env`]), its `HEAD` is detached there, and obid takes the commits into
//!   the clone and moves the job's branch itself, outside the sandbox (`git::keep_commits`). So no
//!   job can touch another job's branch, `refs/remotes/origin/*` or the objects the clone has.
//! - **Reads, from obid's home and the person's home**: the worktree, the clone's git common
//!   directory (read-only), the job's own folders, and the tools it runs. Nothing else: not the
//!   database, `keys/`, `api-token`, other clones or other worktrees.
//! - **Network**: none for the check. An agent has its own network namespace, with slirp4netns so
//!   it still reaches its model's API, and the host's abstract Unix sockets are not in it.
//!
//! - **No terminal, no one to ask**: the process leads a session of its own, so it has no
//!   controlling terminal (none to push keystrokes into with `TIOCSTI` when obid was started from a
//!   shell); on macOS it can't have LaunchServices open an app, send Apple events, submit a launchd
//!   job, post input events through the window server, or connect to a Unix socket but the DNS
//!   resolver's and its own: each of those would run something outside the sandbox for it.
//! - **On macOS, no preferences, pasteboard or keychain**: cfprefsd would read and write the
//!   person's preferences for it, whatever its file rules (so a job has no preferences at all), the
//!   pasteboard server would read and write the person's pasteboard, and secd would read and write
//!   the data protection keychain for it. None of them answers it. A file-based keychain (the
//!   person's login keychain) is a file in the person's hidden home, so it can't read it either.
//!
//! When the sandbox can't be made on this machine, nothing runs: [`Sandbox::detect`] says why, and
//! the job fails saying so. On macOS an obid that itself runs inside a job sandbox (a job running
//! obid's tests) can't make another, since Seatbelt doesn't nest: what it starts stays in the job's
//! sandbox it inherits ([`Tool::Enclosing`]), never in none.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The job sandbox on this machine: the tool that makes it, and the program that starts what it
/// runs in a session of its own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sandbox {
    tool: Tool,
    /// obid's own executable: `obid __session -- <program> <arguments>` calls `setsid` and runs
    /// the program ([`SESSION`]).
    session: PathBuf,
}

/// The tool that makes the sandbox.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Tool {
    /// `bwrap`, at this path.
    Bubblewrap(PathBuf),
    /// `/usr/bin/sandbox-exec`.
    Seatbelt(PathBuf),
    /// macOS, when obid itself runs inside a job sandbox (a job running obid's tests): Seatbelt
    /// can't nest, so what obid starts stays in the sandbox it was started in, which every
    /// process inherits and none can leave ([`inside_a_job_sandbox`]).
    Enclosing,
}

/// Whether this process is inside obid's own job sandbox. Asked only once `sandbox-exec` was
/// refused, which happens only inside a sandbox; inside any other (an App Sandbox, a sandboxed
/// launcher) obid makes none and runs nothing. The job profile's fingerprint, each part probed
/// without a side effect (libsandbox's `sandbox_check` would need `unsafe`, which this workspace
/// forbids): the person's home (from the password database, not `HOME`) can't be listed; a Unix
/// socket that isn't the resolver's can't be connected to (syslog's: connected, nothing sent); and
/// the pasteboard server can't be reached (`pbpaste` of the ruler pasteboard, its output
/// discarded).
fn inside_a_job_sandbox() -> bool {
    let denied = |e: std::io::Error| e.kind() == std::io::ErrorKind::PermissionDenied;
    let Ok(Some(user)) = nix::unistd::User::from_uid(nix::unistd::getuid()) else {
        return false;
    };
    let home_hidden = user.dir.is_absolute()
        && user.dir != Path::new("/")
        && std::fs::read_dir(&user.dir).is_err_and(denied);
    let sockets_denied = std::os::unix::net::UnixDatagram::unbound()
        .and_then(|socket| socket.connect("/var/run/syslog"))
        .is_err_and(denied);
    let pasteboard_denied = std::process::Command::new("/usr/bin/pbpaste")
        .args(["-pboard", "ruler"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| !status.success());
    home_hidden && sockets_denied && pasteboard_denied
}

/// obid's argument that runs the rest of its command line in a session of its own:
/// `obid __session -- <program> <arguments>` ([`crate::process::exec_in_own_session`]). Not a
/// command for people: obid starts every sandboxed process through it, because a session of its
/// own has no controlling terminal, and starting one needs `setsid` between `fork` and `exec`,
/// which obid's safe Rust can't do in place.
pub const SESSION: &str = "__session";

/// Runs inside the network namespace: waits until the launcher has started slirp4netns, then
/// replaces itself with the job's program.
const NET_WAIT: &str = r#"
while [ ! -f "$1" ]; do sleep 0.05; done
shift
exec "$@"
"#;

/// Runs outside the sandbox, as the process obid starts. `bwrap` is already in its own network
/// namespace; slirp4netns joins that namespace, so the host's abstract Unix sockets are not in
/// it and the guest still reaches the host (10.0.2.2) and the rest of the network.
const NET_LAUNCH: &str = r#"
ready=$1
loopback=$2
shift 2
rm -f "$ready" "$ready.log"
# An explicit stdin redirect: a background command otherwise gets /dev/null, and the
# program inside the sandbox would see its stdin close. bash would also hand the
# program SHLVL and _, which are not part of the sandbox environment.
env -u SHLVL -u _ "$@" <&0 &
bpid=$!
child=
i=0
while [ -z "$child" ] && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  for status in /proc/[0-9]*/status; do
    pid=${status#/proc/}
    pid=${pid%/status}
    ppid=$(sed -n 's/^PPid:[^0-9]*//p' "$status" 2>/dev/null) || continue
    if [ "$ppid" = "$bpid" ]; then
      child=$pid
      break
    fi
  done
  [ -n "$child" ] && break
  sleep 0.05
done
if [ -z "$child" ]; then
  echo "obid: the sandbox never started" >&2
  kill "$bpid" 2>/dev/null
  wait "$bpid" 2>/dev/null
  exit 1
fi
# A conversation's shell command never reaches this machine's own services (obid's API).
host_loopback=
if [ "$loopback" = no ]; then host_loopback=--disable-host-loopback; fi
slirp4netns --configure --mtu=65520 $host_loopback --userns-path="/proc/$child/ns/user" "$child" tap0 >"$ready.log" 2>&1 &
slirp=$!
i=0
while [ "$i" -lt 50 ]; do
  i=$((i + 1))
  grep -q "sent tapfd" "$ready.log" 2>/dev/null && break
  sleep 0.05
done
if ! grep -q "sent tapfd" "$ready.log" 2>/dev/null; then
  echo "obid: slirp4netns didn't give the sandbox a network" >&2
  cat "$ready.log" >&2
  kill "$slirp" "$bpid" 2>/dev/null
  wait "$bpid" 2>/dev/null
  exit 1
fi
touch "$ready"
wait "$bpid"
status=$?
kill "$slirp" 2>/dev/null
wait "$slirp" 2>/dev/null
exit "$status"
"#;

/// What one sandboxed process may touch.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Spec {
    /// The job's worktree: read and written, the working directory.
    pub worktree: PathBuf,
    /// The worktree's own git directory (`<common>/worktrees/<name>`): written.
    pub git_admin: Option<PathBuf>,
    /// The clone's git common directory: read only, always.
    pub git_common: Option<PathBuf>,
    /// The job commits: git writes its new objects to `<git_admin>/objects`, with the clone's
    /// read as alternates ([`Spec::git_env`]).
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
    /// Folders inside the worktree that stay read-only: a conversation's checkouts of the
    /// repositories in its room (`room/repos`). Each must exist before the process starts.
    pub frozen: Vec<PathBuf>,
}

impl Sandbox {
    /// The sandbox this machine can make, or why it can't. `obid` is obid's own executable (what
    /// starts every sandboxed process in a session of its own: [`SESSION`]).
    pub fn detect(obid: &Path) -> Result<Sandbox, String> {
        if !is_executable(obid) {
            return Err(format!(
                "obid can't find its own executable ({}), which starts every sandboxed process.",
                obid.display()
            ));
        }
        let session = obid.to_path_buf();
        if cfg!(target_os = "macos") {
            let path = PathBuf::from("/usr/bin/sandbox-exec");
            if !path.exists() {
                return Err(
                    "/usr/bin/sandbox-exec isn't on this Mac, so obid can't make the job sandbox."
                        .into(),
                );
            }
            // A trial run, as on Linux. Seatbelt doesn't nest: inside a sandbox (a job's, running
            // obid's own tests) `sandbox_apply` is refused for any profile.
            let tried = std::process::Command::new(&path)
                .args([
                    "-p",
                    "(version 1)(allow default)(deny file-write* (literal \"/obid-trial\"))",
                    "/usr/bin/true",
                ])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped())
                .output();
            return match tried {
                Ok(output) if output.status.success() => Ok(Sandbox {
                    tool: Tool::Seatbelt(path),
                    session,
                }),
                Ok(output)
                    if String::from_utf8_lossy(&output.stderr).contains("sandbox_apply")
                        && inside_a_job_sandbox() =>
                {
                    Ok(Sandbox {
                        tool: Tool::Enclosing,
                        session,
                    })
                }
                Ok(output) => Err(format!(
                    "sandbox-exec can't make a sandbox on this Mac: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                )),
                Err(e) => Err(format!("sandbox-exec can't run: {e}")),
            };
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
                Ok(output) if output.status.success() => Ok(Sandbox {
                    tool: Tool::Bubblewrap(bwrap),
                    session,
                }),
                Ok(output) => Err(format!(
                    "bubblewrap can't make a sandbox on this machine: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                )),
                Err(e) => Err(format!("bubblewrap can't run: {e}")),
            };
        }
        Err("obid makes the job sandbox only on Linux and macOS.".into())
    }

    /// Whether what obid starts stays in the job sandbox obid itself runs in ([`Tool::Enclosing`]).
    pub fn encloses(&self) -> bool {
        self.tool == Tool::Enclosing
    }

    /// The command line that runs `argv` inside the sandbox `spec` describes: the program, then its
    /// arguments. The caller sets the working directory to `spec.worktree` and the environment, and
    /// starts it as it is, in obid's own process group: the first program (obid, [`SESSION`]) makes
    /// a session of its own, whose process group's id is the started process's id, so signalling
    /// that group reaches everything it starts.
    pub fn wrap(&self, spec: &Spec, argv: &[OsString]) -> Vec<OsString> {
        self.wrap_reading(spec, argv, false, true)
    }

    /// [`Sandbox::wrap`], for a process that reads nothing of the machine's but the system's
    /// software ([`SYSTEM_READS_MACOS`], [`SYSTEM_READS_LINUX`]) and what `spec` names: no
    /// world-readable folder of anyone's (`/Users/Shared`, `/Volumes`, `/private/var/folders`,
    /// `/mnt`, `/srv`), whether or not it is hidden. On macOS every path's metadata stays
    /// readable (paths resolve), never its contents.
    pub fn wrap_reading_only_its_own(&self, spec: &Spec, argv: &[OsString]) -> Vec<OsString> {
        self.wrap_reading(spec, argv, true, true)
    }

    /// [`Sandbox::wrap_reading_only_its_own`], for a conversation's shell command: given the
    /// network, it still never reaches this machine's own loopback, where obid's API and its MCP
    /// endpoints listen (Seatbelt denies `localhost`; slirp4netns runs with
    /// `--disable-host-loopback`).
    pub fn wrap_command(&self, spec: &Spec, argv: &[OsString]) -> Vec<OsString> {
        self.wrap_reading(spec, argv, true, false)
    }

    fn wrap_reading(
        &self,
        spec: &Spec,
        argv: &[OsString],
        confined: bool,
        loopback: bool,
    ) -> Vec<OsString> {
        let spec = spec.canonical();
        let mut out: Vec<OsString> = vec![self.session.clone().into(), SESSION.into(), "--".into()];
        match &self.tool {
            Tool::Bubblewrap(bwrap) => {
                let mut bwrap_argv = vec![bwrap.clone().into_os_string()];
                let resolver = spec.network.then(Resolver::for_this_machine).flatten();
                bwrap_argv.extend(bubblewrap_args_reading(&spec, confined, resolver.as_ref()));
                bwrap_argv.push("--".into());
                if spec.network {
                    let ready = spec.temp.join(".obid-net-ready");
                    let _ = std::fs::remove_file(&ready);
                    bwrap_argv.extend([
                        "/bin/sh".into(),
                        "-c".into(),
                        NET_WAIT.into(),
                        "net-wait".into(),
                        ready.clone().into(),
                    ]);
                    // bash, not dash: a background command keeps the program's stdin only
                    // when the redirect is explicit, and dash drops it anyway.
                    out.extend([
                        "/bin/bash".into(),
                        "-c".into(),
                        NET_LAUNCH.into(),
                        "net-launch".into(),
                        ready.into(),
                        if loopback { "yes" } else { "no" }.into(),
                    ]);
                    out.extend(bwrap_argv);
                } else {
                    out.extend(bwrap_argv);
                }
            }
            Tool::Seatbelt(sandbox_exec) => {
                out.push(sandbox_exec.clone().into());
                out.push("-p".into());
                out.push(seatbelt_profile_reading(&spec, confined, loopback).into());
                // The watcher is the session leader. When the job's program exits, or obid
                // signals the group, it kills every process in the sandbox, including one
                // that called setsid and left the group. kill -1 is safe only because the
                // profile lets a process signal only its own sandbox, and only after the
                // watcher has checked that a hidden path is really hidden.
                out.push("/bin/sh".into());
                out.push("-c".into());
                out.push(WATCHER.into());
                out.push("watcher".into());
                out.push(
                    spec.hidden
                        .first()
                        .cloned()
                        .unwrap_or_else(|| PathBuf::from("/"))
                        .into(),
                );
            }
            Tool::Enclosing => {
                // The same watcher, but it never reaps: `/` is readable, and `kill -1` would
                // reach everything in the enclosing job sandbox, the job's own agent included.
                // A process that called setsid ends with that job instead.
                out.extend([
                    "/bin/sh".into(),
                    "-c".into(),
                    WATCHER.into(),
                    "watcher".into(),
                    "/".into(),
                ]);
            }
        }
        out.extend(argv.iter().cloned());
        out
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
        // An account's folder is writable, so a job on the same account could put a link in its
        // place: it's named by its parent's real path and its own name, never where such a link
        // leads, and left out when it isn't a real folder now (#643's security review).
        let account = |p: &PathBuf| -> Option<PathBuf> {
            let at = real(&p.parent()?.to_path_buf()).join(p.file_name()?);
            std::fs::symlink_metadata(&at)
                .is_ok_and(|m| m.is_dir())
                .then_some(at)
        };
        Spec {
            worktree: real(&self.worktree),
            git_admin: self.git_admin.as_ref().map(real),
            git_common: self.git_common.as_ref().map(real),
            commits: self.commits,
            temp: real(&self.temp),
            accounts: self.accounts.iter().filter_map(account).collect(),
            read_only,
            hidden,
            network: self.network,
            frozen: self.frozen.iter().map(real).collect(),
        }
    }

    /// The job's own object folder, where its commits' objects go: `<git_admin>/objects`. `None`
    /// for a job that doesn't commit.
    pub fn own_objects(&self) -> Option<PathBuf> {
        self.git_admin
            .as_ref()
            .filter(|_| self.commits)
            .map(|admin| admin.join("objects"))
    }

    /// The environment git needs inside the sandbox for a job that commits: its new objects in the
    /// job's own object folder, the clone's read as alternates. Empty for one that doesn't commit
    /// (it can't: nothing it could write objects to).
    pub fn git_env(&self) -> Vec<(&'static str, OsString)> {
        match (self.own_objects(), &self.git_common) {
            (Some(own), Some(common)) => vec![
                ("GIT_OBJECT_DIRECTORY", own.into_os_string()),
                (
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                    common.join("objects").into_os_string(),
                ),
            ],
            _ => Vec::new(),
        }
    }

    /// The folders written.
    fn writable(&self) -> Vec<PathBuf> {
        let mut out = vec![self.worktree.clone()];
        out.extend(self.git_admin.clone());
        out.push(self.temp.clone());
        out.extend(self.accounts.iter().cloned());
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
#[cfg(test)]
fn bubblewrap_args(spec: &Spec) -> Vec<OsString> {
    bubblewrap_args_reading(spec, false, None)
}

/// What a confined process reads of the system on Linux ([`Sandbox::wrap_reading_only_its_own`]):
/// its software and its settings, each bound read-only when it exists (a symbolic link, as on a
/// merged `/usr`, made again as the same link).
pub const SYSTEM_READS_LINUX: [&str; 10] = [
    "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt", "/nix",
];

/// What a confined process reads of the system on macOS: the system's own folders, the
/// dynamic linker's caches, the system's settings, the time zones, the shell `/bin/sh` picks,
/// devices.
pub const SYSTEM_READS_MACOS: [&str; 11] = [
    "/System",
    "/usr",
    "/bin",
    "/sbin",
    "/Library/Apple",
    "/private/etc",
    "/private/var/db/timezone",
    "/private/var/db/dyld",
    "/private/var/select",
    "/private/var/run/resolv.conf",
    "/dev",
];

fn bubblewrap_args_reading(
    spec: &Spec,
    confined: bool,
    resolver: Option<&Resolver>,
) -> Vec<OsString> {
    let mut args: Vec<OsString> = Vec::new();
    let mut push = |items: &[&std::ffi::OsStr]| args.extend(items.iter().map(|s| s.to_os_string()));
    // A session of its own inside too (no controlling terminal, whatever started bwrap), and
    // everything inside ends when bwrap does: its process group is obid's to signal, but what runs
    // inside is in another session.
    push(&[
        "--unshare-pid".as_ref(),
        "--unshare-ipc".as_ref(),
        "--unshare-uts".as_ref(),
        "--new-session".as_ref(),
        "--die-with-parent".as_ref(),
    ]);
    // Always a network namespace of its own. With no network, nothing is set up in it. With
    // network, the launcher outside starts slirp4netns in it, so the host's abstract Unix
    // sockets stay unreachable and the model's API does not. bubblewrap 0.11 leaves the
    // sandbox with no capabilities, so slirp can enter that namespace only when the user is
    // uid 0 inside it (`--userns-path`); files it creates are still the user's outside.
    push(&["--unshare-net".as_ref()]);
    if spec.network {
        push(&[
            "--uid".as_ref(),
            "0".as_ref(),
            "--gid".as_ref(),
            "0".as_ref(),
        ]);
    }
    if confined {
        // Nothing of `/` but the system's software and what the spec names (bound below).
        for path in SYSTEM_READS_LINUX.iter().map(Path::new) {
            match std::fs::read_link(path) {
                Ok(target) => push(&["--symlink".as_ref(), target.as_os_str(), path.as_os_str()]),
                Err(_) if path.is_dir() => {
                    push(&["--ro-bind".as_ref(), path.as_os_str(), path.as_os_str()])
                }
                Err(_) => {}
            }
        }
    } else {
        push(&["--ro-bind".as_ref(), "/".as_ref(), "/".as_ref()]);
    }
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
    // What runs commands or holds logins for this user without a file to read: the user's own
    // runtime folder (its session bus, its keyring) and Docker's socket.
    let runtime = PathBuf::from(format!("/run/user/{}", nix::unistd::getuid()));
    if runtime.is_dir() {
        push(&["--tmpfs".as_ref(), runtime.as_os_str()]);
    }
    // `/var/run` is a symlink to `/run`. Binding over the symlink path makes bwrap
    // exit before the agent starts (`Can't create file at /var/run/docker.sock`).
    for socket in docker_sockets_to_mask() {
        push(&[
            "--ro-bind".as_ref(),
            "/dev/null".as_ref(),
            socket.as_os_str(),
        ]);
    }
    if spec.network
        && let Some(resolver) = resolver
    {
        push(&[
            "--ro-bind".as_ref(),
            resolver.file.as_os_str(),
            resolver.over.as_os_str(),
        ]);
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
    // What stays read-only inside the worktree is bound over it again, read-only: a mount point,
    // so it can't be renamed or removed either.
    for frozen in &spec.frozen {
        push(&["--ro-bind".as_ref(), frozen.as_os_str(), frozen.as_os_str()]);
    }
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
/// them visible by name only (their metadata, so paths resolve), never listed; nothing that has
/// another process run or write something for it; no network for the check.
#[cfg(test)]
fn seatbelt_profile(spec: &Spec) -> String {
    seatbelt_profile_reading(spec, false, true)
}

/// [`seatbelt_profile`]; `confined`, it reads no file's contents but the system's
/// ([`SYSTEM_READS_MACOS`]) and the spec's own, before the hidden folders' rules (which still
/// apply on top).
fn seatbelt_profile_reading(spec: &Spec, confined: bool, loopback: bool) -> String {
    let mut profile =
        String::from("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*");
    for path in spec.writable() {
        profile.push_str(&format!(" (subpath {})", sbpl_string(&path)));
    }
    // What a process writes to that isn't a file: the null device, its own descriptors. Not a
    // terminal: it has none (it leads a session of its own), and the person's are theirs.
    profile.push_str(
        " (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/\"))\n",
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
    // What stays read-only inside the worktree, itself included (it can't be removed or renamed).
    for frozen in &spec.frozen {
        profile.push_str(&format!(" (subpath {})", sbpl_string(frozen)));
    }
    profile.push_str(")\n");
    if confined {
        profile.push_str(
            "(deny file-read*)\n(allow file-read-metadata)\n(allow file-read* (literal \"/\")",
        );
        for path in SYSTEM_READS_MACOS {
            profile.push_str(&format!(" (subpath {})", sbpl_text(path)));
        }
        for path in spec.readable() {
            profile.push_str(&format!(" (subpath {})", sbpl_string(&path)));
        }
        // Claude Code opens its own folder in `/tmp` (`/tmp/claude-<uid>`) whatever `TMPDIR` says,
        // and stops when it can't: the folder itself, never what is in it (other sessions').
        profile.push_str(&format!(
            " (literal {})",
            sbpl_text(&format!("/private/tmp/claude-{}", nix::unistd::getuid()))
        ));
        profile.push_str(")\n");
    }
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
    // Others who would run something, or write, for the job, outside its sandbox: LaunchServices
    // opening an app (one the job wrote, say), Apple events (Terminal's `do script`, Finder),
    // launchd jobs (`launchctl submit`), input events posted through the window server into the
    // person's terminal.
    profile.push_str(
        "(deny lsopen)\n(deny appleevent-send)\n(deny job-creation)\n(deny hid-control)\n",
    );
    // And those who read or write for the job what its file rules keep from it: cfprefsd, which
    // reads and writes the person's preferences for whoever asks, whatever the asker's `HOME` or
    // file rules (so a job has no preferences at all: CoreFoundation's writes fail, its reads find
    // only what the job may read as files); the pasteboard; secd, which reads and writes the data
    // protection keychain for whoever asks, and SecurityAgent ([`KEYCHAIN`]). The file-based
    // keychains' securityd and trustd stay: the system's root certificates come through them.
    profile.push_str("(deny user-preference-read user-preference-write)\n");
    profile.push_str("(deny mach-lookup");
    for service in WINDOW_SERVER
        .iter()
        .chain(PREFERENCES.iter())
        .chain(PASTEBOARD.iter())
        .chain(KEYCHAIN.iter())
    {
        profile.push_str(&format!(" (global-name {})", sbpl_text(service)));
    }
    profile.push_str(")\n");
    // And whatever listens on a Unix socket: a terminal multiplexer's server, a login agent,
    // Docker's daemon, an editor's command socket. A socket is reached by connecting, not by
    // reading, so the file rules above don't hold it back. None but the DNS resolver's (an agent
    // names its model's API by host name) and the job's own, in its own folders.
    profile.push_str("(deny network-outbound (remote unix-socket))\n");
    profile.push_str("(allow network-outbound");
    for socket in RESOLVER_SOCKETS {
        profile.push_str(&format!(
            " (remote unix-socket (path-literal {}))",
            sbpl_text(socket)
        ));
    }
    for path in spec.writable() {
        profile.push_str(&format!(
            " (remote unix-socket (subpath {}))",
            sbpl_string(&path)
        ));
    }
    profile.push_str(")\n");
    if !spec.network {
        profile.push_str("(deny network*)\n");
    } else if !loopback {
        profile.push_str("(deny network-outbound (remote ip \"localhost:*\"))\n");
    }
    // A process signals only others in this sandbox. The watcher's `kill -1` then reaches a
    // descendant that called setsid, and nothing of the person's outside the sandbox.
    profile.push_str("(deny signal)\n(allow signal (target same-sandbox))\n");
    profile
}

/// The first process inside a macOS job sandbox. It runs the job's program and, when that
/// exits or this process is signalled, kills every process in the sandbox.
const WATCHER: &str = r#"probe=$1; shift
reap() {
  # Not sandboxed: the probe is readable, and `kill -1` would reach the person's processes.
  # Inside the sandbox a signal is allowed only to this sandbox, so `kill -1` is exactly
  # what the job started, including a process that called setsid. It kills this process too.
  /bin/ls "$probe" >/dev/null 2>&1 && return
  kill -KILL -1 2>/dev/null
}
trap 'reap; exit 143' TERM
exec 3<&0
"$@" <&3 3<&- &
child=$!
exec 0</dev/null 1>/dev/null 2>&1 3<&-
wait "$child"
status=$?
# `reap` kills this process too. The exit code is recorded first so a check that
# passed is not reported as killed.
echo "$status" > "$TMPDIR/.obid-status"
reap
exit "$status"
"#;

/// The DNS forwarder slirp4netns gives the network namespace (`--configure`): it asks the host's
/// own resolver. The host's `/etc/resolv.conf` can't serve inside: on Ubuntu it names
/// systemd-resolved's stub, 127.0.0.53, which inside is the namespace's own loopback, and in the
/// confined form it is a link into `/run`, which isn't there.
pub const SLIRP_DNS: &str = "10.0.2.3";

/// What a sandbox with the network reads as `/etc/resolv.conf`: obid's own file, which names only
/// [`SLIRP_DNS`] (the host's `search` and `options` lines aren't carried over), bound read-only over
/// the one file the host's `/etc/resolv.conf` leads to, so nothing else of where that lives
/// (`/run`) is shown.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Resolver {
    /// obid's file: in a folder only obid's user can open, which no sandbox shows (the user's
    /// runtime folder and `/tmp` are empty inside), never in a folder a job writes, where it could
    /// leave a link for obid to write through or for bubblewrap to bind.
    file: PathBuf,
    /// Where the host's `/etc/resolv.conf` leads.
    over: PathBuf,
}

impl Resolver {
    /// This machine's. None when the host's `/etc/resolv.conf` leads to no file (bubblewrap could
    /// make none there, and the host has no resolver to ask either) or obid can't keep a file of
    /// its own safely: then the sandbox has no resolver, as before.
    fn for_this_machine() -> Option<Resolver> {
        let over = resolver_target(Path::new("/etc/resolv.conf"))?;
        let uid = nix::unistd::getuid().as_raw();
        let runtime = PathBuf::from(format!("/run/user/{uid}"));
        let base = if private_folder(&runtime, uid) {
            runtime
        } else {
            std::env::temp_dir()
        };
        match write_resolver(&base.join(format!("obid-resolver-{uid}")), uid) {
            Ok(file) => Some(Resolver { file, over }),
            Err(why) => {
                tracing::warn!("sandbox: no resolver for the sandbox's network ({why})");
                None
            }
        }
    }
}

/// The file `/etc/resolv.conf` leads to on this machine, if it is one.
fn resolver_target(path: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok().filter(|p| p.is_file())
}

/// Writes obid's resolver file in `folder`, which is made for `uid` alone (0700) when it isn't
/// there, and must be a real folder that only `uid` can open, so nobody else can leave a link in
/// it. The file is replaced with a rename, never written through whatever is at its path.
fn write_resolver(folder: &Path, uid: u32) -> Result<PathBuf, String> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    use std::sync::atomic::{AtomicU64, Ordering};

    match std::fs::DirBuilder::new().mode(0o700).create(folder) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(format!("can't make {}: {e}", folder.display())),
    }
    if !private_folder(folder, uid) {
        return Err(format!(
            "{} isn't a folder only obid's user can open",
            folder.display()
        ));
    }
    let file = folder.join("resolv.conf");
    let text = format!("nameserver {SLIRP_DNS}\n");
    let current = std::fs::symlink_metadata(&file)
        .ok()
        .filter(|m| m.is_file())
        .and_then(|_| std::fs::read_to_string(&file).ok());
    if current.as_deref() == Some(text.as_str()) {
        return Ok(file);
    }
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let staged = folder.join(format!(
        ".resolv.conf.{}.{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .open(&staged)
        .and_then(|mut out| out.write_all(text.as_bytes()))
        .and_then(|()| std::fs::rename(&staged, &file));
    if let Err(e) = written {
        let _ = std::fs::remove_file(&staged);
        return Err(format!("can't write {}: {e}", file.display()));
    }
    Ok(file)
}

/// Whether `path` is a folder (not a link to one) of `uid`'s that nobody else can open.
fn private_folder(path: &Path, uid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(path)
        .is_ok_and(|m| m.is_dir() && m.uid() == uid && m.mode() & 0o077 == 0)
}

/// Where Docker's socket is.
const DOCKER_SOCKETS: [&str; 2] = ["/run/docker.sock", "/var/run/docker.sock"];

/// Socket paths bubblewrap can mask with `--ro-bind /dev/null`. A symlink path is replaced by
/// the file it names: binding over `/var/run/docker.sock` when `/var/run` points at `/run`
/// makes bwrap exit (`Can't create file at /var/run/docker.sock`).
fn docker_sockets_to_mask() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for socket in DOCKER_SOCKETS {
        let Some(target) = maskable_socket(Path::new(socket)) else {
            continue;
        };
        if !out.contains(&target) {
            out.push(target);
        }
    }
    out
}

/// The real file `path` names, when its parent is a directory and not itself a symlink.
fn maskable_socket(path: &Path) -> Option<PathBuf> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    let target = if meta.file_type().is_symlink() {
        std::fs::canonicalize(path).ok()?
    } else if path.exists() {
        path.to_path_buf()
    } else {
        return None;
    };
    let parent = target.parent()?;
    let parent_meta = std::fs::symlink_metadata(parent).ok()?;
    if !parent_meta.file_type().is_dir() || parent_meta.file_type().is_symlink() {
        return None;
    }
    Some(target)
}

/// The DNS resolver's socket on macOS (mDNSResponder): every host name lookup goes through it.
const RESOLVER_SOCKETS: [&str; 2] = ["/private/var/run/mDNSResponder", "/var/run/mDNSResponder"];

/// The window server's services on macOS, which post input events (keystrokes into the person's
/// terminal) for whoever asks with the right to.
const WINDOW_SERVER: [&str; 2] = ["com.apple.windowserver.active", "com.apple.windowserver"];

/// cfprefsd on macOS, the system's and the person's: it reads and writes preferences for whoever
/// asks, in the person's `~/Library/Preferences`, whatever the asker's file rules say.
const PREFERENCES: [&str; 2] = ["com.apple.cfprefsd.daemon", "com.apple.cfprefsd.agent"];

/// The pasteboard server on macOS (the general, find, font and ruler pasteboards), and the one that
/// hands the pasteboard to other devices (Universal Clipboard).
const PASTEBOARD: [&str; 2] = [
    "com.apple.pasteboard.1",
    "com.apple.coreservices.uauseractivitypasteboardclient.xpc",
];

/// The keychain's services on macOS that would hand a job secrets its file rules don't: secd, which
/// reads and writes the data protection keychain (and iCloud Keychain) for whoever asks; the system
/// keychain's securityd; SecurityAgent, which would ask the person for a keychain's password for
/// it. Not `com.apple.SecurityServer`, the file-based keychains' securityd: a client reads those
/// keychains' files itself (the person's login keychain is in their home, which is hidden), and
/// without it Node can't read the system's root certificates and crashes
/// (`node::crypto::ReadMacOSKeychainCertificates`), so a Node agent using them (Cursor's
/// `cursor-agent`) couldn't start.
const KEYCHAIN: [&str; 11] = [
    "com.apple.securityd.xpc",
    "com.apple.securityd.general",
    "com.apple.securityd.ckks",
    "com.apple.securityd.sos",
    "com.apple.securityd.aps",
    "com.apple.security.octagon",
    "com.apple.security.kcsharing",
    "com.apple.security.escrow-update",
    "com.apple.securityd.systemkeychain",
    "com.apple.security.agent",
    "com.apple.security.KeychainStasher",
];

/// The keychain's services a job keeps on macOS: the file-based keychains' securityd (see
/// [`KEYCHAIN`]) and trustd, which checks a server's certificate.
#[cfg(test)]
const KEYCHAIN_KEPT: [&str; 2] = ["com.apple.SecurityServer", "com.apple.trustd.agent"];

/// A path as an SBPL string literal.
fn sbpl_string(path: &Path) -> String {
    sbpl_text(&path.to_string_lossy())
}

/// Text as an SBPL string literal.
fn sbpl_text(text: &str) -> String {
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

/// What a confined run ([`Sandbox::wrap_reading_only_its_own`]) reads of the software on `path`
/// outside the hidden folders (`/opt/homebrew/bin`, `/usr/local/bin`): each folder, and the
/// install prefix around a `bin` or `sbin` (its libraries, a symbolic link's target in it), never
/// `/` itself nor a folder that holds a hidden one.
pub fn path_software(path: &std::ffi::OsStr, hidden: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in std::env::split_paths(path) {
        if !entry.is_absolute() || hidden.iter().any(|h| entry.starts_with(h)) {
            continue;
        }
        let prefix = entry
            .file_name()
            .filter(|n| *n == "bin" || *n == "sbin")
            .and_then(|_| entry.parent())
            .filter(|p| p.components().count() > 1 && !hidden.iter().any(|h| h.starts_with(p)));
        // Not the whole install prefix (it can hold a user's own data), only the folders a tool
        // runs from: its binaries, libraries and shared files (N8).
        if let Some(prefix) = prefix {
            for sub in [
                "bin", "sbin", "lib", "lib64", "libexec", "share", "etc", "opt", "Cellar",
            ] {
                let dir = prefix.join(sub);
                if dir.is_dir() {
                    out.push(dir);
                }
            }
        }
        out.push(entry);
    }
    out
}

/// The folder an agent's binary is installed in, when the sandbox hides it and the binary needs
/// what is beside it: where `bin` leads (through its symbolic links), that file's folder. Cursor's
/// `~/.local/bin/cursor-agent` leads to `~/.local/share/cursor-agent/versions/<v>/cursor-agent`,
/// which runs the `index.js` and `node` beside it. `None` when that folder isn't hidden, is or holds
/// a hidden folder (a binary straight in the home shows nothing more), or is inside `never`.
pub fn install_root(bin: &Path, hidden: &[PathBuf], never: &[PathBuf]) -> Option<PathBuf> {
    let both = |paths: &[PathBuf]| -> Vec<PathBuf> {
        paths
            .iter()
            .flat_map(|p| [p.clone(), p.canonicalize().unwrap_or_else(|_| p.clone())])
            .collect()
    };
    let (hidden, never) = (both(hidden), both(never));
    let root = bin.canonicalize().ok()?.parent()?.to_path_buf();
    let inside = hidden.iter().any(|h| root.starts_with(h) && &root != h);
    if !inside
        || hidden.iter().any(|h| h.starts_with(&root))
        || never
            .iter()
            .any(|n| root.starts_with(n) || n.starts_with(&root))
    {
        return None;
    }
    Some(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_software_brings_a_tools_folders_not_the_whole_prefix() {
        let root = std::env::temp_dir().join(format!("obid-pathsw-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let prefix = root.join("brew");
        for dir in ["bin", "lib", "libexec", "share", "etc", "projects", "db"] {
            std::fs::create_dir_all(prefix.join(dir)).unwrap();
        }
        let path = std::env::join_paths([prefix.join("bin")]).unwrap();
        let got = path_software(&path, &[]);
        // The tool's own folders, not the whole prefix nor a user-data folder beside them (N8).
        for keep in ["bin", "lib", "libexec", "share", "etc"] {
            assert!(got.contains(&prefix.join(keep)), "{keep}: {got:?}");
        }
        assert!(!got.contains(&prefix), "the prefix itself: {got:?}");
        assert!(!got.contains(&prefix.join("projects")), "{got:?}");
        assert!(!got.contains(&prefix.join("db")), "{got:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_agent_installed_in_a_hidden_home_brings_its_own_folder_only() {
        let root = std::env::temp_dir().join(format!("obid-install-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let home = root.join("home/w");
        let version = home.join(".local/share/cursor-agent/versions/1");
        std::fs::create_dir_all(&version).unwrap();
        std::fs::create_dir_all(home.join(".local/bin")).unwrap();
        std::fs::write(version.join("cursor-agent"), "").unwrap();
        std::os::unix::fs::symlink(
            version.join("cursor-agent"),
            home.join(".local/bin/cursor-agent"),
        )
        .unwrap();
        std::fs::write(home.join("tool"), "").unwrap();
        std::fs::create_dir_all(root.join("obid/bin")).unwrap();
        std::fs::write(root.join("obid/bin/agent"), "").unwrap();
        std::fs::create_dir_all(root.join("usr/bin")).unwrap();
        std::fs::write(root.join("usr/bin/agent"), "").unwrap();
        let hidden = [home.clone(), root.join("obid")];
        let never = [root.join("obid")];
        let real = |p: PathBuf| p.canonicalize().unwrap();
        assert_eq!(
            install_root(&home.join(".local/bin/cursor-agent"), &hidden, &never),
            Some(real(version.clone()))
        );
        assert_eq!(install_root(&home.join("tool"), &hidden, &never), None);
        assert_eq!(
            install_root(&root.join("obid/bin/agent"), &hidden, &never),
            None
        );
        assert_eq!(
            install_root(&root.join("usr/bin/agent"), &hidden, &never),
            None
        );
        assert_eq!(install_root(&home.join("missing"), &hidden, &never), None);
        let _ = std::fs::remove_dir_all(&root);
    }

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

    /// An account folder is named by its parent's real path and its own name, and one that's a
    /// link now (a job on the same account put it there) is left out, never followed (#643's
    /// re-review).
    #[test]
    fn an_account_folder_that_became_a_link_is_left_out() {
        let root = std::env::temp_dir().join(format!("obid-canon-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("accounts/real")).unwrap();
        std::fs::create_dir_all(root.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(root.join("elsewhere"), root.join("accounts/planted")).unwrap();
        let spec = Spec {
            accounts: vec![root.join("accounts/real"), root.join("accounts/planted")],
            ..Spec::default()
        }
        .canonical();
        let real = root.canonicalize().unwrap();
        assert_eq!(spec.accounts, vec![real.join("accounts/real")]);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A folder frozen inside the worktree (a conversation's `room/repos`) stays read-only: denied
    /// after the worktree's writes on macOS, bound read-only over it on Linux.
    #[test]
    fn a_frozen_folder_inside_the_worktree_stays_read_only() {
        let spec = Spec {
            worktree: "/h/conversations/c/room".into(),
            temp: "/h/conversations/c/home".into(),
            frozen: vec!["/h/conversations/c/room/repos".into()],
            hidden: vec!["/h".into()],
            ..Spec::default()
        };
        let profile = seatbelt_profile(&spec);
        let allow = profile
            .find("(allow file-write* (subpath \"/h/conversations/c/room\")")
            .unwrap();
        let deny = profile
            .find("(subpath \"/h/conversations/c/room/repos\"))\n")
            .unwrap();
        assert!(allow < deny, "{profile}");
        assert!(
            profile[..deny].rfind("(deny file-write*").unwrap() > allow,
            "{profile}"
        );
        let args: Vec<String> = bubblewrap_args(&spec)
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let bind = args
            .windows(3)
            .position(|w| {
                w == [
                    "--bind",
                    "/h/conversations/c/room",
                    "/h/conversations/c/room",
                ]
            })
            .unwrap();
        let frozen = args
            .windows(3)
            .position(|w| {
                w == [
                    "--ro-bind",
                    "/h/conversations/c/room/repos",
                    "/h/conversations/c/room/repos",
                ]
            })
            .unwrap();
        assert!(bind < frozen, "{args:?}");
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
        assert!(profile.contains("(deny network*)\n"));
        assert!(profile.contains("(deny signal)\n(allow signal (target same-sandbox))\n"));
        for rule in [
            "(deny lsopen)",
            "(deny appleevent-send)",
            "(deny job-creation)",
            "(deny mach-lookup (global-name \"com.apple.windowserver.active\")",
            "(deny user-preference-read user-preference-write)",
            "(global-name \"com.apple.cfprefsd.agent\")",
            "(global-name \"com.apple.pasteboard.1\")",
            "(global-name \"com.apple.securityd.xpc\")",
            "(global-name \"com.apple.security.agent\")",
            "(deny network-outbound (remote unix-socket))",
            "(remote unix-socket (path-literal \"/private/var/run/mDNSResponder\"))",
            "(remote unix-socket (subpath \"/h/tmp/j1\"))",
        ] {
            assert!(profile.contains(rule), "{rule}\n{profile}");
        }
        assert!(!profile.contains("/dev/tty"), "{profile}");
        for kept in KEYCHAIN_KEPT {
            assert!(!profile.contains(kept), "{kept}\n{profile}");
        }
        assert_eq!(sbpl_string(Path::new("/a \"b\\")), "\"/a \\\"b\\\\\"");
    }

    /// Confined, it reads no file's contents but the system's software and the spec's own: a
    /// rule that denies every read comes before them, and the hidden folders' rules still follow.
    #[test]
    fn a_confined_profile_reads_only_the_system_and_its_own() {
        let spec = Spec {
            worktree: "/h/answers/x/question".into(),
            temp: "/h/answers/x/tmp".into(),
            accounts: vec!["/h/accounts/a".into()],
            read_only: vec!["/opt/homebrew/bin".into()],
            hidden: vec!["/h".into()],
            ..Spec::default()
        };
        let plain = seatbelt_profile(&spec);
        assert!(!plain.contains("(deny file-read*)\n"), "{plain}");
        let profile = seatbelt_profile_reading(&spec, true, true);
        let deny_all = profile
            .find("(deny file-read*)\n(allow file-read-metadata)\n")
            .unwrap();
        let hidden = profile.find("(deny file-read* (subpath \"/h\"))").unwrap();
        assert!(deny_all < hidden, "{profile}");
        for allowed in [
            "(subpath \"/System\")",
            "(subpath \"/usr\")",
            "(subpath \"/private/etc\")",
            "(subpath \"/h/answers/x/question\")",
            "(subpath \"/h/accounts/a\")",
            "(subpath \"/opt/homebrew/bin\")",
        ] {
            assert!(
                profile[deny_all..hidden].contains(allowed),
                "{allowed}\n{profile}"
            );
        }
        for never in [
            "(subpath \"/Users\")",
            "(subpath \"/Volumes\")",
            "(subpath \"/private/var/folders\")",
            "(subpath \"/private/tmp\")",
        ] {
            assert!(!profile.contains(never), "{never}\n{profile}");
        }
        // bubblewrap binds the system's software, never `/`.
        let args: Vec<String> = bubblewrap_args_reading(&spec, true, None)
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(
            !args.windows(3).any(|w| w == ["--ro-bind", "/", "/"]),
            "{args:?}"
        );
        let plain: Vec<String> = bubblewrap_args(&spec)
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(plain.windows(3).any(|w| w == ["--ro-bind", "/", "/"]));
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
        let with_network = Spec {
            network: true,
            ..spec.clone()
        };
        let with_network: Vec<String> = bubblewrap_args(&with_network)
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(with_network.contains(&"--unshare-net".to_owned()));
        assert!(args.contains(&"--new-session".to_owned()));
        assert!(args.contains(&"--die-with-parent".to_owned()));
        assert!(at("--tmpfs") < at("--bind"));
        assert_eq!(
            args[args.len() - 2..],
            ["--chdir".to_owned(), "/h/worktrees/j1".to_owned()]
        );
    }

    /// With the network, both forms bind obid's resolver file over where the host's leads, and
    /// nothing else of `/run`. Without it, neither does, even with a resolver at hand.
    #[test]
    fn a_sandbox_with_the_network_binds_obids_resolver() {
        let spec = Spec {
            worktree: "/h/answers/x/question".into(),
            temp: "/h/answers/x/tmp".into(),
            hidden: vec!["/h".into()],
            network: true,
            ..Spec::default()
        };
        let resolver = Resolver {
            file: "/r/obid-resolver-1/resolv.conf".into(),
            over: "/run/systemd/resolve/stub-resolv.conf".into(),
        };
        let bind = [
            "--ro-bind",
            "/r/obid-resolver-1/resolv.conf",
            "/run/systemd/resolve/stub-resolv.conf",
        ];
        for confined in [false, true] {
            let args: Vec<String> = bubblewrap_args_reading(&spec, confined, Some(&resolver))
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            assert!(args.windows(3).any(|w| w == bind), "{args:?}");
            for never in ["/run", "/run/systemd", "/run/systemd/resolve"] {
                assert!(!args.iter().any(|a| a == never), "{never}\n{args:?}");
            }
            let offline = Spec {
                network: false,
                ..spec.clone()
            };
            let args: Vec<String> = bubblewrap_args_reading(&offline, confined, Some(&resolver))
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            assert!(
                !args.iter().any(|a| a.contains("obid-resolver")),
                "{args:?}"
            );
        }
    }

    /// A folder of the test's own, removed when it ends.
    fn scratch(name: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("obid-resolver-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root.canonicalize().unwrap()
    }

    /// The host's `/etc/resolv.conf` is followed to the file it leads to; a link to nothing gives
    /// nothing to bind over.
    #[test]
    fn the_resolver_is_bound_over_the_file_the_hosts_leads_to() {
        let root = scratch("target");
        let stub = root.join("run/stub-resolv.conf");
        std::fs::create_dir_all(stub.parent().unwrap()).unwrap();
        std::fs::write(&stub, "nameserver 127.0.0.53\n").unwrap();
        std::fs::create_dir_all(root.join("etc")).unwrap();
        let link = root.join("etc/resolv.conf");
        std::os::unix::fs::symlink("../run/stub-resolv.conf", &link).unwrap();
        assert_eq!(resolver_target(&link), Some(stub.clone()));
        std::fs::remove_file(&stub).unwrap();
        assert_eq!(resolver_target(&link), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// obid's resolver file is never written through a link at its path, and its folder must be
    /// a real one only obid's user can open.
    #[test]
    fn obids_resolver_file_is_never_written_through_a_link() {
        use std::os::unix::fs::PermissionsExt;
        let uid = nix::unistd::getuid().as_raw();
        let root = scratch("write");
        let victim = root.join("victim");
        std::fs::write(&victim, "the owner's file").unwrap();
        let folder = root.join("obid-resolver");
        std::fs::create_dir(&folder).unwrap();
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(&victim, folder.join("resolv.conf")).unwrap();
        let file = write_resolver(&folder, uid).unwrap();
        assert_eq!(
            std::fs::read_to_string(&victim).unwrap(),
            "the owner's file"
        );
        assert!(std::fs::symlink_metadata(&file).unwrap().is_file());
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            format!("nameserver {SLIRP_DNS}\n")
        );
        // Others can open it: refused.
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(write_resolver(&folder, uid).is_err());
        // A link to a folder: refused, and nothing is written in the folder it points at.
        let elsewhere = root.join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        std::fs::set_permissions(&elsewhere, std::fs::Permissions::from_mode(0o700)).unwrap();
        let linked = root.join("linked");
        std::os::unix::fs::symlink(&elsewhere, &linked).unwrap();
        assert!(write_resolver(&linked, uid).is_err());
        assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_symlink_socket_path_is_masked_at_its_target() {
        let root = std::env::temp_dir().join(format!("obid-sock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let run = root.join("run");
        let var_run = root.join("var/run");
        std::fs::create_dir_all(&run).unwrap();
        std::fs::create_dir_all(root.join("var")).unwrap();
        let real = run.join("docker.sock");
        std::fs::write(&real, "").unwrap();
        std::os::unix::fs::symlink(&run, &var_run).unwrap();
        let via = var_run.join("docker.sock");
        assert!(
            maskable_socket(&via).is_none(),
            "a path under a symlink is not bindable"
        );
        assert_eq!(maskable_socket(&real).unwrap(), real);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A conversation's shell command with the network never reaches this machine's loopback,
    /// where obid listens: Seatbelt denies localhost, slirp4netns runs without the host's loopback.
    /// An agent's box keeps it (its MCP server is there) (#774's review, 4).
    #[test]
    fn a_shell_command_never_reaches_this_machines_loopback() {
        let spec = Spec {
            worktree: "/w".into(),
            temp: "/t".into(),
            network: true,
            ..Spec::default()
        };
        let deny = "(deny network-outbound (remote ip \"localhost:*\"))";
        assert!(seatbelt_profile_reading(&spec, true, false).contains(deny));
        assert!(!seatbelt_profile_reading(&spec, true, true).contains(deny));
        let offline = Spec {
            network: false,
            ..spec.clone()
        };
        assert!(seatbelt_profile_reading(&offline, true, false).contains("(deny network*)"));
        let bwrap = Sandbox {
            tool: Tool::Bubblewrap("/usr/bin/bwrap".into()),
            session: "/obid".into(),
        };
        let given = |argv: Vec<OsString>| {
            let at = argv.iter().position(|a| a == "net-launch").unwrap();
            argv[at + 2].clone()
        };
        assert_eq!(given(bwrap.wrap_command(&spec, &["true".into()])), "no");
        assert_eq!(
            given(bwrap.wrap_reading_only_its_own(&spec, &["true".into()])),
            "yes"
        );
        assert!(NET_LAUNCH.contains("--disable-host-loopback"));
    }
}
