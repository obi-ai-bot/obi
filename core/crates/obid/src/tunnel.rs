//! The Cloudflare Tunnel that lets a paired phone reach this Mac from anywhere (#896;
//! docs/runner-api.md, "obid only: the tunnel"; docs/remote-access.md). The Mac app signs in and
//! gets the tunnel's run token from the control plane, then hands it to obid, which keeps it in its
//! vault and runs the app's bundled `cloudflared` as its own child: the tunnel lives as long as
//! obid does, not the window app.
//!
//! The token is never in an argument or the environment: cloudflared reads it from
//! `home/tunnel/token` (0600, in a 0700 folder every job's box hides), with an environment of only
//! `PATH` and `HOME`. Its log is read for two things only: "Registered tunnel connection" (it's
//! connected) and `ERR` lines (logged and shown by obid with every secret it holds taken out).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, BufReader};
use tokio::sync::{Notify, watch};

/// The tunnel's run token, in obid's vault.
pub const TOKEN: &str = "oby.remote.tunnel";
/// The longest wait before starting a cloudflared that stopped again.
const BACKOFF_MAX: Duration = Duration::from_secs(60);

/// How the tunnel is: `off`, `starting`, `connected` or `failed`, with a line saying why.
#[derive(Clone, Debug, PartialEq)]
struct Shown {
    state: &'static str,
    detail: Option<String>,
}

pub struct Tunnel {
    folder: PathBuf,
    binary: Option<PathBuf>,
    vault: Arc<crate::vault::Vault>,
    events: crate::events::Events,
    shown: Mutex<Shown>,
    /// The token was put or deleted: the runner starts again from the vault.
    changed: Notify,
}

impl Tunnel {
    /// The tunnel for obid's `home`, run by [`Tunnel::spawn`].
    pub fn open(
        home: &Path,
        vault: Arc<crate::vault::Vault>,
        events: crate::events::Events,
    ) -> Arc<Tunnel> {
        Arc::new(Tunnel {
            folder: home.join("tunnel"),
            binary: binary(),
            vault,
            events,
            shown: Mutex::new(Shown {
                state: "off",
                detail: None,
            }),
            changed: Notify::new(),
        })
    }

    /// `GET /v1/status`'s `tunnel`.
    pub fn json(&self) -> Value {
        let shown = self.shown.lock().unwrap_or_else(|e| e.into_inner()).clone();
        json!({"state": shown.state, "detail": shown.detail})
    }

    fn show(&self, state: &'static str, detail: Option<String>) {
        let next = Shown { state, detail };
        let mut shown = self.shown.lock().unwrap_or_else(|e| e.into_inner());
        if *shown != next {
            *shown = next;
            drop(shown);
            self.events.send("tunnel", self.json());
        }
    }

    /// `PUT /v1/obid/tunnel`: keeps `token` in the vault and (re)starts cloudflared.
    pub fn put(&self, token: &str) -> Result<(), (u16, String)> {
        if self.binary.is_none() {
            return Err((
                409,
                "This obid has no cloudflared: remote access comes with the Mac app.".into(),
            ));
        }
        let token = token.trim();
        let base64ish = |c: char| c.is_ascii_alphanumeric() || "+/=_-".contains(c);
        if token.is_empty() || token.len() > 4096 || !token.chars().all(base64ish) {
            return Err((422, "The tunnel's token is one line of base64.".into()));
        }
        self.vault
            .add(token, TOKEN)
            .map_err(|why| (503, format!("obid couldn't keep the tunnel's token: {why}")))?;
        self.changed.notify_one();
        Ok(())
    }

    /// `DELETE /v1/obid/tunnel`: stops cloudflared and forgets the token.
    pub fn delete(&self) -> Result<(), (u16, String)> {
        self.vault.remove(TOKEN).map_err(|why| {
            (
                503,
                format!("obid couldn't forget the tunnel's token: {why}"),
            )
        })?;
        let _ = std::fs::remove_file(self.folder.join("token"));
        self.changed.notify_one();
        Ok(())
    }

    /// Runs cloudflared whenever the vault holds a token, until obid stops.
    pub fn spawn(self: &Arc<Self>, stopping: watch::Receiver<bool>) {
        let tunnel = self.clone();
        tokio::spawn(async move { tunnel.run(stopping).await });
    }

    async fn run(self: Arc<Self>, mut stopping: watch::Receiver<bool>) {
        stop_left_over(&self.folder);
        let mut backoff = Duration::from_secs(1);
        loop {
            if *stopping.borrow() {
                return;
            }
            let token = match self.vault.value(TOKEN) {
                Ok(Some(token)) => token,
                Ok(None) => {
                    self.show("off", None);
                    let _ = std::fs::remove_file(self.folder.join("token"));
                    tokio::select! {
                        () = self.changed.notified() => continue,
                        _ = stopping.changed() => return,
                    }
                }
                Err(why) => {
                    self.show(
                        "failed",
                        Some(format!("obid can't read the tunnel's token: {why}")),
                    );
                    tokio::select! {
                        () = self.changed.notified() => continue,
                        () = tokio::time::sleep(BACKOFF_MAX) => continue,
                        _ = stopping.changed() => return,
                    }
                }
            };
            let Some(binary) = self.binary.clone() else {
                self.show("failed", Some("This obid has no cloudflared.".into()));
                tokio::select! {
                    () = self.changed.notified() => continue,
                    _ = stopping.changed() => return,
                }
            };
            self.show("starting", None);
            let ended = match self.start(&binary, &token) {
                Ok(child) => {
                    let (ended, connected) = self.watch(child, &mut stopping).await;
                    if connected {
                        backoff = Duration::from_secs(1);
                    }
                    ended
                }
                Err(why) => Ended::Failed(why),
            };
            match ended {
                Ended::Stopping => return,
                Ended::Changed => continue,
                Ended::Failed(why) => {
                    tracing::warn!("cloudflared stopped: {why}");
                    self.show("failed", Some(why));
                    tokio::select! {
                        () = tokio::time::sleep(backoff) => {}
                        () = self.changed.notified() => {}
                        _ = stopping.changed() => return,
                    }
                    backoff = (backoff * 2).min(BACKOFF_MAX);
                }
            }
        }
    }

    /// Writes the token file and starts cloudflared on it.
    fn start(&self, binary: &Path, token: &str) -> Result<tokio::process::Child, String> {
        use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.folder)
            .map_err(|e| format!("obid couldn't make its tunnel folder: {e}"))?;
        let _ = std::fs::set_permissions(&self.folder, std::fs::Permissions::from_mode(0o700));
        let file = self.folder.join("token");
        crate::store::write_private(&file, token.as_bytes())
            .map_err(|e| format!("obid couldn't write the tunnel's token file: {e}"))?;
        let child = tokio::process::Command::new(binary)
            .args(["tunnel", "--no-autoupdate", "run", "--token-file"])
            .arg(&file)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &self.folder)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("obid couldn't start cloudflared: {e}"))?;
        if let Some(pid) = child.id() {
            let _ = std::fs::write(self.folder.join("pid"), pid.to_string());
        }
        Ok(child)
    }

    /// Follows cloudflared until it ends, the token changes or obid stops; whether it connected.
    async fn watch(
        &self,
        mut child: tokio::process::Child,
        stopping: &mut watch::Receiver<bool>,
    ) -> (Ended, bool) {
        let mut lines = child.stderr.take().map(|e| BufReader::new(e).lines());
        let mut connected = false;
        let mut last_error: Option<String> = None;
        loop {
            tokio::select! {
                line = async {
                    match lines.as_mut() {
                        Some(lines) => lines.next_line().await.ok().flatten(),
                        None => std::future::pending().await,
                    }
                } => match line {
                    Some(line) => {
                        if line.contains("Registered tunnel connection") {
                            connected = true;
                            self.show("connected", None);
                        } else if line.contains(" ERR ") {
                            // Every secret obid holds (the token too) out, before it's logged or shown.
                            let line = crate::secrets::known().redact(&line);
                            tracing::warn!("cloudflared: {line}");
                            last_error = Some(line);
                        }
                    }
                    None => lines = None,
                },
                status = child.wait() => {
                    let _ = std::fs::remove_file(self.folder.join("pid"));
                    let why = last_error.unwrap_or_else(|| match status {
                        Ok(status) => format!("cloudflared exited ({status})."),
                        Err(e) => format!("cloudflared couldn't be waited on: {e}"),
                    });
                    return (Ended::Failed(why), connected);
                }
                () = self.changed.notified() => {
                    end(&mut child, &self.folder).await;
                    return (Ended::Changed, connected);
                }
                _ = stopping.changed() => {
                    end(&mut child, &self.folder).await;
                    return (Ended::Stopping, connected);
                }
            }
        }
    }
}

enum Ended {
    Stopping,
    Changed,
    Failed(String),
}

/// Asks cloudflared to stop, then kills it after 5 seconds.
async fn end(child: &mut tokio::process::Child, folder: &Path) {
    if let Some(pid) = child.id() {
        let _ = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(pid as i32),
            nix::sys::signal::Signal::SIGTERM,
        );
    }
    if tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .is_err()
    {
        let _ = child.kill().await;
    }
    let _ = std::fs::remove_file(folder.join("pid"));
}

/// A cloudflared an obid that was killed left running: stopped, so two never serve one tunnel.
fn stop_left_over(folder: &Path) {
    let Some(pid) = std::fs::read_to_string(folder.join("pid"))
        .ok()
        .and_then(|p| p.trim().parse::<i32>().ok())
    else {
        return;
    };
    let named = std::process::Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .output()
        .ok()
        .is_some_and(|out| String::from_utf8_lossy(&out.stdout).contains("cloudflared"));
    if named {
        let _ = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(pid),
            nix::sys::signal::Signal::SIGTERM,
        );
    }
    let _ = std::fs::remove_file(folder.join("pid"));
}

/// The app's own cloudflared, `Contents/MacOS/cloudflared` beside obid's `Contents/Helpers/obid`,
/// or what tests set in `OBID_CLOUDFLARED`; none for an obid anywhere else.
fn binary() -> Option<PathBuf> {
    if let Some(given) = std::env::var_os("OBID_CLOUDFLARED") {
        return Some(PathBuf::from(given)).filter(|p| p.is_file());
    }
    let exe = std::env::current_exe().ok()?;
    let contents = exe.parent()?.parent()?;
    (contents.file_name()? == "Contents")
        .then(|| contents.join("MacOS/cloudflared"))
        .filter(|p| p.is_file())
}
