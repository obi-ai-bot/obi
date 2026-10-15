//! The sandbox every plug-in process runs in (docs/ARCHITECTURE.md 5.3): bubblewrap on Linux,
//! a Seatbelt profile run with `sandbox-exec` on macOS. For the plug-in's process and
//! everything it starts:
//!
//! - writes go only to `home/plugin-data/<id>/` (its working directory, `HOME`, and `TMPDIR`
//!   under `tmp/`);
//! - of `obid`'s `home` it reads only its own folder `home/plugins/<id>/` (read-only) and its
//!   data folder; nothing else of `home`, not the person's real `HOME`, and not the machine's
//!   temporary folders (where `obid`'s `TMPDIR`, and so its jobs' temporary folders, are);
//! - it reads the system's files and the tools it runs, read-only;
//! - its environment is only `PATH`, `HOME`, `LANG` and `TMPDIR`;
//! - it has the network.
//!
//! "Everything it starts" includes what it could ask a service outside the sandbox to start
//! for it, which would run unconfined. So the sandbox also cuts the plug-in off from the
//! machine's local services, and keeps only what name lookups, TLS and logging need:
//!
//! - on macOS it can't open apps or documents through LaunchServices (`open`), send Apple
//!   Events, look up any Mach service but the few in [`MACH_SERVICES`] (not launchd's job
//!   submission, LaunchServices or any app's service), connect to a Unix socket outside its
//!   data folder (Docker's, an SSH agent's) or signal a process outside its sandbox;
//! - on macOS it has no preferences, no pasteboard and no keychain ([`MACH_DENIED`]): `cfprefsd`
//!   would read and write the person's preferences for it whatever its file rules (it serves
//!   the account, not the asker's `HOME`), so `cfprefsd` is denied and so are
//!   `user-preference-read` and `user-preference-write`, and CoreFoundation's own reads of
//!   preference files find nothing, because `/Users` (every account's home, the person's
//!   `~/Library/Preferences` among them) is hidden like the person's `HOME`; the pasteboard
//!   server is denied; so are the keychain's `securityd`, `secd` and SecurityAgent, so it can't
//!   read even the system's own file keychains through `security` (certificate checks go
//!   through `trustd`, which it keeps);
//! - on Linux `/tmp`, `/var/tmp` and `/run` (with `/var/run`) are empty folders of its own, so
//!   the D-Bus buses, the user's systemd, X11's sockets, an SSH agent's socket and Docker's
//!   socket aren't there; only the folder the name resolver's `resolv.conf` lives in (and
//!   `systemd-resolved`'s) is bound back in, read-only. Its processes are in their own PID
//!   and IPC namespaces, which end with its first process, so nothing it started outlives it,
//!   whatever left its process group or session. Unix sockets in the abstract namespace belong to the network
//!   namespace, which the plug-in shares with the machine because it has the network: a
//!   service listening on one (an X server, an old D-Bus) is still reachable.
//!
//! On macOS the temporary folders `/private/tmp`, `/private/var/tmp` and `/private/var/folders`
//! (which holds every user's `TMPDIR` and caches) can't be read. Of the folders above its own
//! two (`/`, the person's `HOME`, `obid`'s home, `home/plugin-data`, ...) a plug-in may read
//! only the folder itself (`stat`), not what it holds: tools like `git` check every folder of
//! the path they work in. Tools started through `xcrun` (Apple's `git`, `python3`) may read
//! the user's `xcrun` cache (`<TMPDIR>/xcrun_db`, which names where developer tools are; without
//! it each of them takes seconds to start) but not write it, so they print that they
//! "couldn't create cache file" when it lacks a tool, and work without it.
//!
//! What no sandbox here stops, on macOS: any process of the same user that isn't one of
//! Apple's own can have its full arguments and environment read by another (the
//! `KERN_PROCARGS2` sysctl), and Seatbelt has no rule against it (`sysctl-read` and
//! `process-info*` denials don't reach it). So a plug-in can read `obid`'s environment and the
//! environment of whatever else the person runs. `obid` must keep secrets out of its own
//! environment and out of the environment of the long-running processes it starts. On Linux the
//! plug-in's own PID namespace hides every other process.
//!
//! On macOS, which has no PID namespace, the first process in the sandbox is a watcher
//! ([`WATCHER`]) that kills every process in the sandbox when the plug-in exits or the host
//! tells it to stop: also what called `setsid` and was handed to launchd. A plug-in that kills
//! its own watcher first can still leave processes that left its process group running; the
//! host then ends the process group and logs it.
//!
//! When the sandbox can't be made on the machine, the plug-in isn't started.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::process::Command;

/// The PATH a plug-in gets when `obid` has none.
const DEFAULT_PATH: &str = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// The Seatbelt profile. Later rules win over earlier ones: everything is allowed, then every
/// write is denied but to the data folder (and `/dev/null`, which programs write to as a
/// matter of course), then every read under `obid`'s home, under the person's real `HOME`,
/// under `/Users` and of the machine's temporary folders ([`MACOS_TEMP`]) is denied, then
/// reads of the
/// plug-in's own folder and its data folder are allowed again, and the metadata (not the
/// contents) of the folders above those two (`ANCESTOR_<n>`, `ancestors` of them), and the
/// `xcrun` cache ([`XCRUN_CACHE`]).
/// Then what would let it start a process outside the sandbox, or use a local service in the
/// person's name, is denied: LaunchServices, Apple Events, every Mach service but
/// [`MACH_SERVICES`] (and [`MACH_DENIED`] by name, whatever that list says), preferences,
/// Unix sockets outside its data folder (but the name resolver's and the system log's), and
/// signals to processes outside its sandbox.
/// The paths come in as parameters (`-D`), so nothing in a path is read as profile syntax.
fn seatbelt_profile(ancestors: usize) -> String {
    let services: String = MACH_SERVICES
        .iter()
        .map(|name| format!("\n  (global-name \"{name}\")"))
        .collect();
    let denied: String = MACH_DENIED
        .iter()
        .map(|name| format!("\n  (global-name \"{name}\")"))
        .collect();
    let temp: String = MACOS_TEMP
        .iter()
        .map(|path| format!(" (subpath \"{path}\")"))
        .collect();
    // With no folder to name, no rule at all: an `allow` without a filter allows everywhere.
    let ancestors: String = if ancestors == 0 {
        String::new()
    } else {
        let folders: String = (0..ancestors)
            .map(|n| format!("\n  (literal (param \"ANCESTOR_{n}\"))"))
            .collect();
        format!("(allow file-read-metadata{folders})\n")
    };
    format!(
        r#"(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath (param "DATA")) (literal "/dev/null") (literal "/dev/zero") (regex #"^/dev/fd/"))
(deny file-read* (subpath (param "OBID_HOME")) (subpath (param "REAL_HOME")) (subpath "/Users"){temp})
(allow file-read* (subpath (param "PLUGIN")) (subpath (param "DATA")) (regex #"{XCRUN_CACHE}"))
{ancestors}(deny lsopen)
(deny appleevent-send)
(deny mach-lookup)
(allow mach-lookup{services})
(deny mach-lookup{denied})
(deny user-preference-read user-preference-write)
(deny network-outbound (remote unix-socket))
(allow network-outbound
  (remote unix-socket (subpath (param "DATA")))
  (remote unix-socket (path-literal "/private/var/run/mDNSResponder"))
  (remote unix-socket (path-literal "/private/var/run/syslog")))
(deny signal)
(allow signal (target same-sandbox))
"#
    )
}

/// The Mach services a plug-in may look up on macOS: users and groups, notifications, logging,
/// name lookups and the network's configuration, and certificate trust. Not launchd's job
/// submission, LaunchServices, Apple Events, preferences, the pasteboard, the keychain or any
/// app's.
const MACH_SERVICES: &[&str] = &[
    "com.apple.system.opendirectoryd.libinfo",
    "com.apple.system.opendirectoryd.membership",
    "com.apple.system.notification_center",
    "com.apple.system.logger",
    "com.apple.logd",
    "com.apple.diagnosticd",
    "com.apple.mDNSResponder",
    "com.apple.dnssd.service",
    "com.apple.SystemConfiguration.configd",
    "com.apple.SystemConfiguration.DNSConfiguration",
    "com.apple.networkd",
    "com.apple.symptomsd",
    "com.apple.trustd",
    "com.apple.trustd.agent",
    "com.apple.ocspd",
];

/// The first process in a plug-in's Seatbelt sandbox on macOS, run by `/bin/sh` with `obid`'s
/// home, the plug-in's program and its arguments. It starts the plug-in (with its stdin; its
/// stdout and stderr are the plug-in's; its environment only the four variables, none of the
/// shell's own like `PWD` or `SHLVL`), and when the plug-in exits, or the host sends it
/// `SIGTERM`, it kills every process in the sandbox with `kill -KILL -1`: the profile lets a
/// process signal only processes in its own sandbox, so that reaches exactly what the plug-in
/// started, also what left its process group or session (`setsid`) and was handed to launchd,
/// and nothing else. macOS has no PID namespace and no other way to find those from outside
/// without calling into the system's C API, which this crate doesn't do.
///
/// Before it kills, it checks that it really is sandboxed: it must not be able to list `obid`'s
/// home, which the profile hides. Outside a sandbox `kill -KILL -1` would end every process of
/// the person's.
///
/// What it can't stop: the plug-in's processes may signal it too (they are in its sandbox), so
/// a plug-in that kills its watcher first can leave processes it started outside its process
/// group running. The host then ends the process group and logs that the watcher was killed.
const WATCHER: &str = r#"home=$1; shift
reap() {
  if ! /bin/ls "$home" >/dev/null 2>&1; then kill -KILL -1 2>/dev/null; fi
}
trap 'reap; exit 143' TERM
exec 3<&0
/usr/bin/env -i PATH="$PATH" HOME="$HOME" LANG="$LANG" TMPDIR="$TMPDIR" "$@" <&3 3<&- &
plugin=$!
exec 0</dev/null 1>/dev/null 2>&1 3<&-
wait "$plugin"
status=$?
reap
exit "$status"
"#;

/// Mach services denied by name too, after [`MACH_SERVICES`], so that adding a service there
/// can't let one of these back in: cfprefsd (the system's and the person's), which reads and
/// writes the person's preferences for whoever asks, whatever the asker's `HOME` or file rules;
/// the pasteboard server and the one that hands the pasteboard to other devices; the keychain's
/// securityd (file-based keychains), secd (the data protection keychain and iCloud Keychain)
/// and SecurityAgent, which would ask the person for a keychain's password.
const MACH_DENIED: &[&str] = &[
    "com.apple.cfprefsd.daemon",
    "com.apple.cfprefsd.agent",
    "com.apple.pasteboard.1",
    "com.apple.coreservices.uauseractivitypasteboardclient.xpc",
    "com.apple.SecurityServer",
    "com.apple.securityd.xpc",
    "com.apple.securityd.general",
    "com.apple.securityd.systemkeychain",
    "com.apple.security.agent",
    "com.apple.security.KeychainStasher",
];

/// The machine's temporary folders on macOS (their real paths: `/tmp` and `/var` are links into
/// `/private`), which a plug-in can't read: other programs' temporary files, and under
/// `/private/var/folders` each user's `TMPDIR` (`obid`'s and its jobs') and caches.
const MACOS_TEMP: &[&str] = &["/private/tmp", "/private/var/tmp", "/private/var/folders"];

/// The user's `xcrun` cache in their `TMPDIR`, which a plug-in may read (not write): the
/// paths of the developer tools `xcrun` starts (Apple's `git`, `python3`, `clang`).
const XCRUN_CACHE: &str = "^/private/var/folders/[^/]+/[^/]+/T/xcrun_db$";

/// The folders on Linux that hold the machine's local services' sockets (D-Bus, the user's
/// systemd, X11, SSH agents, Docker) and other programs' temporary files. Each is an empty
/// folder in the sandbox. `/var/run` is one only where it isn't a link to `/run`.
const LINUX_HIDDEN: &[&str] = &["/tmp", "/var/tmp", "/run", "/var/run"];

/// Folders under `/run` bound back in, read-only, where they exist: `systemd-resolved`'s, which
/// `/etc/resolv.conf` often links into and `nss-resolve` asks.
const LINUX_RUN_KEPT: &[&str] = &["/run/systemd/resolve"];

/// A sandbox this machine can make.
#[derive(Clone, Debug)]
pub(crate) enum Sandbox {
    /// macOS: `sandbox-exec -p <profile>`.
    Seatbelt { program: PathBuf },
    /// Linux: `bwrap`.
    Bubblewrap { program: PathBuf },
}

/// What to start, and the folders the sandbox is made of. Every path is absolute and resolved
/// (no symbolic links), because Seatbelt matches the real path.
#[derive(Clone, Debug)]
pub(crate) struct Launch {
    pub obid_home: PathBuf,
    /// The person's real `HOME`, hidden from the plug-in; `None` when it is unknown or `/`.
    pub real_home: Option<PathBuf>,
    pub plugin_dir: PathBuf,
    pub data_dir: PathBuf,
    pub tmp_dir: PathBuf,
    /// Inside `plugin_dir`.
    pub program: PathBuf,
    pub args: Vec<String>,
}

impl Sandbox {
    /// Finds the sandbox tool for this operating system (`program` when given, for tests) and
    /// checks that it can make a sandbox here. The reason says why it can't.
    pub(crate) async fn detect(program: Option<&Path>) -> Result<Sandbox, String> {
        if cfg!(target_os = "macos") {
            let program = program
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("/usr/bin/sandbox-exec"));
            if !program.is_file() {
                return Err(format!("{} is not on this Mac", program.display()));
            }
            let mut probe = Command::new(&program);
            probe.args(["-p", "(version 1)(allow default)", "/usr/bin/true"]);
            probe_runs(probe, &program).await?;
            Ok(Sandbox::Seatbelt { program })
        } else if cfg!(target_os = "linux") {
            let program = match program {
                Some(program) => program.to_path_buf(),
                None => find_on_path("bwrap").ok_or_else(|| {
                    "bubblewrap (bwrap) is not installed or not on PATH".to_owned()
                })?,
            };
            if !program.is_file() {
                return Err(format!("{} is not on this machine", program.display()));
            }
            let mut probe = Command::new(&program);
            probe.args([
                "--die-with-parent",
                "--unshare-pid",
                "--new-session",
                "--ro-bind",
                "/",
                "/",
                "--dev",
                "/dev",
                "--proc",
                "/proc",
                "--",
                "true",
            ]);
            probe_runs(probe, &program).await?;
            Ok(Sandbox::Bubblewrap { program })
        } else {
            Err("plug-ins run only on Linux (bubblewrap) and macOS (Seatbelt)".to_owned())
        }
    }

    /// Whether the process the host starts is the sandbox's watcher ([`WATCHER`], on macOS),
    /// which ends everything in the sandbox when it gets `SIGTERM` or the plug-in exits. With
    /// bubblewrap the sandbox's own PID namespace ends with its first process
    /// (`--die-with-parent`), whatever left its process group or session.
    pub(crate) fn has_watcher(&self) -> bool {
        matches!(self, Sandbox::Seatbelt { .. })
    }

    /// The command that starts `launch` in this sandbox, with only `PATH`, `HOME`, `LANG` and
    /// `TMPDIR` in its environment and its own process group.
    pub(crate) fn command(&self, launch: &Launch) -> Command {
        let mut command = match self {
            Sandbox::Seatbelt { program } => {
                let mut command = Command::new(program);
                let define = |key: &str, path: &Path| {
                    let mut pair = OsString::from(format!("{key}="));
                    pair.push(path.as_os_str());
                    pair
                };
                // When the person's HOME is unknown, the rule names the data folder again,
                // which changes nothing.
                let real_home = launch.real_home.as_deref().unwrap_or(&launch.data_dir);
                let ancestors = ancestors(&[&launch.data_dir, &launch.plugin_dir]);
                for (n, ancestor) in ancestors.iter().enumerate() {
                    command
                        .arg("-D")
                        .arg(define(&format!("ANCESTOR_{n}"), ancestor));
                }
                command
                    .arg("-D")
                    .arg(define("DATA", &launch.data_dir))
                    .arg("-D")
                    .arg(define("PLUGIN", &launch.plugin_dir))
                    .arg("-D")
                    .arg(define("OBID_HOME", &launch.obid_home))
                    .arg("-D")
                    .arg(define("REAL_HOME", real_home))
                    .arg("-p")
                    .arg(seatbelt_profile(ancestors.len()))
                    .args(["/bin/sh", "-c", WATCHER, "obi-plugin-watcher"])
                    .arg(&launch.obid_home)
                    .arg(&launch.program)
                    .args(&launch.args);
                command.current_dir(&launch.data_dir);
                command
            }
            Sandbox::Bubblewrap { program } => {
                let mut command = Command::new(program);
                command.args([
                    "--die-with-parent",
                    "--unshare-pid",
                    "--unshare-ipc",
                    "--new-session",
                    "--ro-bind",
                    "/",
                    "/",
                    "--dev",
                    "/dev",
                    "--proc",
                    "/proc",
                ]);
                // Hide the machine's service and temporary folders, the person's HOME and
                // obid's home behind empty folders, the outer one first, then bind back in
                // the resolver's folders and the two folders the plug-in may see.
                let mut hidden: Vec<PathBuf> = LINUX_HIDDEN
                    .iter()
                    .map(PathBuf::from)
                    .filter(|path| std::fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir()))
                    .collect();
                hidden.push(launch.obid_home.clone());
                if let Some(real_home) = &launch.real_home {
                    hidden.push(real_home.clone());
                }
                hidden.sort_by_key(|path| path.components().count());
                hidden.dedup();
                for path in &hidden {
                    command.arg("--tmpfs").arg(path);
                }
                for kept in resolver_folders() {
                    // Not when it is inside a folder the plug-in mustn't read.
                    if kept.starts_with(&launch.obid_home)
                        || launch
                            .real_home
                            .as_ref()
                            .is_some_and(|real_home| kept.starts_with(real_home))
                    {
                        continue;
                    }
                    command.arg("--ro-bind-try").arg(&kept).arg(&kept);
                }
                command
                    .arg("--ro-bind")
                    .arg(&launch.plugin_dir)
                    .arg(&launch.plugin_dir)
                    .arg("--bind")
                    .arg(&launch.data_dir)
                    .arg(&launch.data_dir)
                    .arg("--chdir")
                    .arg(&launch.data_dir);
                // The empty folders are read-only once everything is bound into them, so the
                // data folder stays the only place a write goes (each remount is of that
                // folder alone: what is bound inside it keeps its own mode).
                for path in &hidden {
                    command.arg("--remount-ro").arg(path);
                }
                command
                    // bubblewrap sets PWD after its --chdir; `env -u PWD` takes it out again,
                    // so the plug-in's environment is the four variables only.
                    .args(["--", "env", "-u", "PWD", "--"])
                    .arg(&launch.program)
                    .args(&launch.args);
                command.current_dir("/");
                command
            }
        };
        let path = std::env::var_os("PATH")
            .filter(|path| !path.is_empty())
            .unwrap_or_else(|| DEFAULT_PATH.into());
        let lang = std::env::var_os("LANG")
            .filter(|lang| !lang.is_empty())
            .unwrap_or_else(|| "C.UTF-8".into());
        command
            .env_clear()
            .env("PATH", path)
            .env("HOME", &launch.data_dir)
            .env("LANG", lang)
            .env("TMPDIR", &launch.tmp_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .kill_on_drop(true);
        command
    }
}

/// Every folder above `folders` (not the folders themselves), once each.
fn ancestors(folders: &[&Path]) -> Vec<PathBuf> {
    let mut above: Vec<PathBuf> = folders
        .iter()
        .flat_map(|folder| folder.ancestors().skip(1))
        .map(Path::to_path_buf)
        .collect();
    above.sort();
    above.dedup();
    above
}

/// The folders under a hidden one that name lookups need: [`LINUX_RUN_KEPT`], and the folder
/// `/etc/resolv.conf` really is in when that is under `/run` (`systemd-resolved`'s, resolvconf's
/// or NetworkManager's).
fn resolver_folders() -> Vec<PathBuf> {
    let mut kept: Vec<PathBuf> = LINUX_RUN_KEPT
        .iter()
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .collect();
    if let Some(folder) = std::fs::canonicalize("/etc/resolv.conf")
        .ok()
        .and_then(|file| file.parent().map(Path::to_path_buf))
        .filter(|folder| folder.starts_with("/run") && folder != Path::new("/run"))
    {
        if !kept.iter().any(|path| folder.starts_with(path)) {
            kept.push(folder);
        }
    }
    kept
}

/// Runs the sandbox tool once on `true` and fails with what it said when that doesn't work.
async fn probe_runs(mut probe: Command, program: &Path) -> Result<(), String> {
    probe
        .env_clear()
        .env("PATH", DEFAULT_PATH)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = tokio::time::timeout(std::time::Duration::from_secs(10), probe.output())
        .await
        .map_err(|_| format!("{} didn't finish a test run", program.display()))?
        .map_err(|error| format!("{} can't run: {error}", program.display()))?;
    if output.status.success() {
        Ok(())
    } else {
        let said = String::from_utf8_lossy(&output.stderr);
        let said: String = said.trim().chars().take(300).collect();
        Err(format!(
            "{} can't make a sandbox here ({}): {said}",
            program.display(),
            output.status
        ))
    }
}

/// The first executable `name` on `obid`'s PATH.
fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

/// Ends the process group `pgid` (the plug-in's first process and whatever it started that
/// stayed in its group), with `kill -KILL -- -<pgid>` run by `/bin/sh`.
pub(crate) async fn kill_group(pgid: u32) {
    if pgid > 1 {
        signal(&format!("-{pgid}"), "KILL").await;
    }
}

/// Sends `SIGTERM` to the watcher `pid` ([`WATCHER`]), which then ends everything in its
/// sandbox.
pub(crate) async fn tell_watcher(pid: u32) {
    if pid > 1 {
        signal(&pid.to_string(), "TERM").await;
    }
}

/// `kill -<signal> -- <target>`, run by `/bin/sh`.
async fn signal(target: &str, signal: &str) {
    let mut kill = Command::new("/bin/sh");
    kill.args([
        "-c",
        "kill -\"$1\" -- \"$2\" 2>/dev/null",
        "sh",
        signal,
        target,
    ])
    .env_clear()
    .env("PATH", DEFAULT_PATH)
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(Stdio::null())
    .kill_on_drop(true);
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), kill.status()).await;
}
