//! The processes obid starts for a job (an agent, the repository's check): each in a session (and
//! so a process group) of its own, its environment made from scratch, and ended with everything it
//! started.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use nix::sys::signal::killpg;
use nix::unistd::Pid;

/// What a job's worker is told while its agent or check runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    /// Carry on.
    Run,
    /// The owner stopped the job: end everything now.
    Stop,
    /// obid is stopping: end everything now and leave the job as it is, for the next start.
    Shutdown,
}

/// From SIGTERM to SIGKILL when a job is stopped: Stop all promises every agent ends within 2 seconds.
pub const STOPPING: Duration = Duration::from_millis(400);

/// The variables a sandboxed process may keep from obid's own environment: the locale, the
/// terminal, who it runs as, and how to reach the network through a proxy. Nothing else: no token,
/// no login, no Claude Code or Anthropic variable (AGENTS.md, "Spawning claude").
const KEPT: &[&str] = &[
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LC_MESSAGES",
    "TERM",
    "USER",
    "LOGNAME",
    "SHELL",
    "TZ",
    "HTTPS_PROXY",
    "https_proxy",
    "HTTP_PROXY",
    "http_proxy",
    "NO_PROXY",
    "no_proxy",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
];

/// Names that never reach an agent or a check, however they got into a list.
pub fn is_forbidden(name: &str) -> bool {
    name == "CLAUDECODE"
        || name.starts_with("CLAUDE_CODE_")
        || name.starts_with("ANTHROPIC_")
        || name == "GH_TOKEN"
        || name == "GITHUB_TOKEN"
        || name == crate::token::ENV
        || name.starts_with("OBY_GITHUB_APP")
}

/// The [`KEPT`] variables `get` has (obid's own environment): what every process obid starts
/// keeps of it, a job's and the brain's alike.
pub fn kept(get: impl Fn(&str) -> Option<OsString>) -> Vec<(OsString, OsString)> {
    KEPT.iter()
        .filter_map(|name| Some(((*name).into(), get(name)?)))
        .collect()
}

/// The environment of a process in the job sandbox: `PATH`, `HOME` and `TMPDIR` (the job's
/// temporary folder), an empty GitHub CLI configuration, git that never prompts, xcrun's cache in
/// the temporary folder, the kept variables above, then `extra` (an account's `CLAUDE_CONFIG_DIR`).
pub fn sandbox_env(
    path: &OsStr,
    temp: &Path,
    extra: &[(&str, OsString)],
) -> Vec<(OsString, OsString)> {
    let mut env = kept(|name| std::env::var_os(name));
    env.push(("PATH".into(), path.to_os_string()));
    env.push(("HOME".into(), temp.as_os_str().to_os_string()));
    env.push(("TMPDIR".into(), temp.as_os_str().to_os_string()));
    env.push((
        "GH_CONFIG_DIR".into(),
        temp.join(".config/gh-none").into_os_string(),
    ));
    env.push(("GIT_TERMINAL_PROMPT".into(), "0".into()));
    // macOS's /usr/bin/git is xcrun's shim: its cache goes here, not in /var/folders, which the
    // sandbox doesn't let a job write.
    env.push(("xcrun_db".into(), temp.join("xcrun_db").into_os_string()));
    for (name, value) in extra {
        env.push(((*name).into(), value.clone()));
    }
    // obid's own CLAUDE_CODE_TMPDIR (a Claude Code run's, below) is the one CLAUDE_CODE_* let in.
    env.retain(|(name, _)| name == CLAUDE_TMPDIR || !is_forbidden(&name.to_string_lossy()));
    env
}

/// What a Claude Code launch adds to [`sandbox_env`]'s `extra`: Claude Code makes its Bash folder in
/// /tmp/claude-<uid> unless told, which the sandbox doesn't let a job write (a field test,
/// 2026-10-17: every Bash command failed with EPERM), so it's the run's own temporary folder.
pub const CLAUDE_TMPDIR: &str = "CLAUDE_CODE_TMPDIR";

/// The `PATH` processes get: obid's own, then what the login shell adds (AGENTS.md, "PATH"), so a
/// tool installed for the person is found even when obid was started with a short `PATH`.
pub fn tools_path() -> OsString {
    static PATH: OnceLock<OsString> = OnceLock::new();
    PATH.get_or_init(|| {
        let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).collect())
            .unwrap_or_default();
        for dir in login_shell_path() {
            if !dirs.contains(&dir) {
                dirs.push(dir);
            }
        }
        if dirs.is_empty() {
            dirs = ["/usr/local/bin", "/usr/bin", "/bin"]
                .map(PathBuf::from)
                .to_vec();
        }
        std::env::join_paths(dirs).unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".into())
    })
    .clone()
}

/// The login shell's `PATH`: the shell from the password database (it can differ from `$SHELL`),
/// run as `<shell> -l -c /usr/bin/env`. Empty when it can't be read within 5 seconds.
fn login_shell_path() -> Vec<PathBuf> {
    let Ok(Some(user)) = nix::unistd::User::from_uid(nix::unistd::getuid()) else {
        return Vec::new();
    };
    let shell = user.shell;
    if !shell.is_absolute() {
        return Vec::new();
    }
    use std::os::unix::process::CommandExt;
    let child = std::process::Command::new(&shell)
        .args(["-l", "-c", "/usr/bin/env"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .spawn();
    let Ok(mut child) = child else {
        return Vec::new();
    };
    let give_up_at = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < give_up_at => {
                std::thread::sleep(Duration::from_millis(20))
            }
            _ => {
                let _ = killpg(
                    Pid::from_raw(child.id() as i32),
                    nix::sys::signal::Signal::SIGKILL,
                );
                let _ = child.wait();
                return Vec::new();
            }
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = std::io::Read::read_to_string(&mut stdout, &mut out);
    }
    out.lines()
        .find_map(|line| line.strip_prefix("PATH="))
        .map(|path| {
            std::env::split_paths(path)
                .filter(|p| p.is_absolute())
                .collect()
        })
        .unwrap_or_default()
}

/// `bin` as a path: itself when it names one, else found on [`tools_path`].
pub fn resolve_bin(bin: &str) -> Option<PathBuf> {
    if bin.contains('/') {
        let path = PathBuf::from(bin);
        return crate::sandbox::is_executable(&path).then_some(path);
    }
    std::env::split_paths(&tools_path())
        .map(|dir| dir.join(bin))
        .find(|candidate| crate::sandbox::is_executable(candidate))
}

/// Runs `argv` in a session of its own, in place of this process: `setsid`, then `exec`. What
/// `obid __session -- <argv>` does ([`crate::sandbox::SESSION`]), so that a sandboxed process has
/// no controlling terminal, and its process group (its id) holds everything it starts. Returns only
/// when it couldn't: then nothing ran.
pub fn exec_in_own_session(argv: &[OsString]) -> std::io::Error {
    use std::os::unix::process::CommandExt;
    let Some((program, args)) = argv.split_first() else {
        return std::io::Error::other("nothing to run");
    };
    if let Err(errno) = nix::unistd::setsid() {
        return std::io::Error::other(format!("can't start a session of its own: {errno}"));
    }
    std::process::Command::new(program).args(args).exec()
}

/// Sends `signal` to the process group `pgid`; a group that's gone is fine.
pub fn signal_group(pgid: u32, signal: nix::sys::signal::Signal) {
    if pgid > 1 {
        let _ = killpg(Pid::from_raw(pgid as i32), signal);
    }
}

/// SIGTERM to the group now, SIGKILL `grace` later: everything it started ends.
pub async fn end_group(pgid: u32, grace: Duration) {
    signal_group(pgid, nix::sys::signal::Signal::SIGTERM);
    tokio::time::sleep(grace).await;
    signal_group(pgid, nix::sys::signal::Signal::SIGKILL);
}

/// "exit status 1", or "killed by signal 9".
pub fn describe(status: std::process::ExitStatus) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return format!("killed by signal {signal}");
        }
    }
    match status.code() {
        Some(code) => format!("exit status {code}"),
        None => "ended".into(),
    }
}

#[cfg(test)]
mod claude_tmpdir_tests {
    use super::*;

    /// Claude Code's Bash folder is the run's own temporary folder when its launch says so; no
    /// other CLAUDE_CODE_* gets in.
    #[test]
    fn claude_code_makes_its_bash_folder_in_the_jobs_temp() {
        let temp = Path::new("/tmp/job-temp");
        let env = sandbox_env(
            OsStr::new("/usr/bin"),
            temp,
            &[
                (CLAUDE_TMPDIR, temp.into()),
                ("CLAUDE_CODE_OTHER", "x".into()),
            ],
        );
        let names: Vec<_> = env
            .iter()
            .map(|(k, _)| k.to_string_lossy().into_owned())
            .collect();
        assert!(names.contains(&CLAUDE_TMPDIR.to_owned()), "{names:?}");
        assert!(
            !names.contains(&"CLAUDE_CODE_OTHER".to_owned()),
            "{names:?}"
        );
        assert!(
            sandbox_env(OsStr::new("/usr/bin"), temp, &[])
                .iter()
                .all(|(k, _)| k != CLAUDE_TMPDIR)
        );
    }
    /// macOS's /usr/bin/git is xcrun's shim, whose cache goes in the user's /var/folders, which the
    /// sandbox doesn't let a job write: every git call printed "couldn't create cache file". Its
    /// cache is in the job's temporary folder instead.
    #[test]
    fn xcrun_keeps_its_cache_in_the_jobs_temp() {
        let temp = Path::new("/tmp/job-temp");
        let env = sandbox_env(OsStr::new("/usr/bin"), temp, &[]);
        assert!(
            env.iter()
                .any(|(k, v)| k == "xcrun_db" && Path::new(v) == temp.join("xcrun_db")),
            "{env:?}"
        );
    }
}
