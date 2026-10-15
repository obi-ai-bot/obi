//! The sandbox every plug-in process runs in (docs/ARCHITECTURE.md 5.3): bubblewrap on Linux,
//! a Seatbelt profile run with `sandbox-exec` on macOS. For the plug-in's process and
//! everything it starts:
//!
//! - writes go only to `home/plugin-data/<id>/` (its working directory, `HOME`, and `TMPDIR`
//!   under `tmp/`);
//! - of `obid`'s `home` it reads only its own folder `home/plugins/<id>/` (read-only) and its
//!   data folder; nothing else of `home`, and not the person's real `HOME`;
//! - it reads the system's files and the tools it runs, read-only;
//! - its environment is only `PATH`, `HOME`, `LANG` and `TMPDIR`;
//! - it has the network.
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
/// matter of course), then every read under `obid`'s home and under the person's real `HOME`
/// is denied, then reads of the plug-in's own folder and its data folder are allowed again.
/// The paths come in as parameters (`-D`), so nothing in a path is read as profile syntax.
const SEATBELT_PROFILE: &str = r#"(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath (param "DATA")) (literal "/dev/null") (literal "/dev/zero") (regex #"^/dev/fd/"))
(deny file-read* (subpath (param "OBID_HOME")) (subpath (param "REAL_HOME")))
(allow file-read* (subpath (param "PLUGIN")) (subpath (param "DATA")))
"#;

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

    /// Whether this sandbox ends every process the plug-in started when its first process
    /// ends. bubblewrap does (`--die-with-parent` and its own PID namespace); on macOS the host
    /// ends the plug-in's process group itself.
    pub(crate) fn ends_descendants(&self) -> bool {
        matches!(self, Sandbox::Bubblewrap { .. })
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
                    .arg(SEATBELT_PROFILE)
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
                // Hide the person's HOME and obid's home behind empty folders, the outer one
                // first, then bind the two folders the plug-in may see back in.
                let mut hidden: Vec<&Path> = vec![&launch.obid_home];
                if let Some(real_home) = &launch.real_home {
                    hidden.push(real_home);
                }
                hidden.sort_by_key(|path| path.components().count());
                hidden.dedup();
                for path in hidden {
                    command.arg("--tmpfs").arg(path);
                }
                command
                    .arg("--ro-bind")
                    .arg(&launch.plugin_dir)
                    .arg(&launch.plugin_dir)
                    .arg("--bind")
                    .arg(&launch.data_dir)
                    .arg(&launch.data_dir)
                    .arg("--chdir")
                    .arg(&launch.data_dir)
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
    if pgid <= 1 {
        return;
    }
    let mut kill = Command::new("/bin/sh");
    kill.args(["-c", "kill -KILL -- \"-$1\" 2>/dev/null", "sh"])
        .arg(pgid.to_string())
        .env_clear()
        .env("PATH", DEFAULT_PATH)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), kill.status()).await;
}
