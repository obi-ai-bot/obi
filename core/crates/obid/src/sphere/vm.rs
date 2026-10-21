//! A teammate's job's VM on this Mac (#797; docs/research/sphere-sharing.md section 8): obid runs
//! `obi-vm` (core/obi-vm), which holds the Virtualization.framework VM, and talks to it over its
//! stdin and stdout. The VM has no network device and no shared folder: its only link is vsock to
//! two Unix sockets obid serves, the job's (7000) and the model API's (7001). Its disk is a sparse
//! file the guest encrypts with a key obid hands it once and never writes down, removed after.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;

/// The guest's vsock ports (core/obi-vm/image/obi-guest).
pub const CONTROL_PORT: u32 = 7000;
pub const MODEL_PORT: u32 = 7001;
/// The job disk's key, which the guest's PID 1 reads once, as root, before anything else runs.
pub const KEY_PORT: u32 = 7002;

/// A box's size (protocol.md 5.10): vCPUs, memory and disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Size {
    pub cpus: u32,
    pub memory_mib: u64,
    pub disk_gib: u64,
}

impl Size {
    /// `small` (the default the owner accepted) or `large`.
    pub fn named(name: &str) -> Option<Size> {
        match name {
            "small" => Some(Size {
                cpus: 4,
                memory_mib: 8 * 1024,
                disk_gib: 30,
            }),
            "large" => Some(Size {
                cpus: 6,
                memory_mib: 12 * 1024,
                disk_gib: 60,
            }),
            _ => None,
        }
    }
}

/// The image every guest VM boots: the kernel, its initrd and the read-only root
/// (core/obi-vm/image/build.sh).
#[derive(Debug, Clone)]
pub struct Image {
    pub dir: PathBuf,
}

impl Image {
    pub fn kernel(&self) -> PathBuf {
        self.dir.join("vmlinuz")
    }
    pub fn initrd(&self) -> PathBuf {
        self.dir.join("initrd")
    }
    pub fn root(&self) -> PathBuf {
        self.dir.join("root.img")
    }
    /// Whether all three are there.
    pub fn present(&self) -> bool {
        [self.kernel(), self.initrd(), self.root()]
            .iter()
            .all(|p| p.is_file())
    }
}

/// Whether the owner is at the Mac, as `obi-vm signals` reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signals {
    pub idle_seconds: u64,
    pub on_ac: bool,
    pub low_power: bool,
    /// `nominal`, `fair`, `serious` or `critical`.
    pub thermal: String,
}

impl Signals {
    /// Whether the Mac may run a guest job now, apart from idleness: on power, not in Low Power
    /// Mode, and cooler than `serious`.
    pub fn fit(&self) -> bool {
        self.on_ac && !self.low_power && matches!(self.thermal.as_str(), "nominal" | "fair")
    }
}

/// Reads the signals once.
pub async fn signals(helper: &Path) -> Result<Signals, String> {
    let out = Command::new(helper)
        .arg("signals")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
        .map_err(|e| format!("obi-vm didn't run: {e}"))?;
    let v: Value = serde_json::from_slice(&out.stdout)
        .map_err(|_| "obi-vm's signals weren't JSON".to_owned())?;
    Ok(Signals {
        idle_seconds: v["idleSeconds"].as_u64().unwrap_or(0),
        on_ac: v["onAC"].as_bool().unwrap_or(false),
        low_power: v["lowPower"].as_bool().unwrap_or(true),
        thermal: v["thermal"].as_str().unwrap_or("critical").to_owned(),
    })
}

/// One running VM.
pub struct Vm {
    child: Child,
    stdin: ChildStdin,
    events: mpsc::Receiver<Value>,
    disk: PathBuf,
}

/// Where one VM's files are: its disk and console log in obid's home, and the two sockets obid
/// serves in a short folder of their own (a socket's path is at most 104 bytes).
#[derive(Debug, Clone)]
pub struct Place {
    pub dir: PathBuf,
    pub sockets: PathBuf,
}

/// This obid home's folder for its jobs' sockets, at a short path:
/// `/private/tmp/obi-guests-<uid>/<8 hex of the home>`. A user folder there that isn't this
/// user's, or isn't 0700, or is a link, is refused.
pub fn sockets_base(home: &Path) -> Result<PathBuf, String> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    let uid = nix::unistd::getuid().as_raw();
    let user = PathBuf::from(format!("/private/tmp/obi-guests-{uid}"));
    let _ = std::fs::DirBuilder::new().mode(0o700).create(&user);
    let meta = std::fs::symlink_metadata(&user)
        .map_err(|e| format!("no folder for the job's sockets: {e}"))?;
    if !meta.is_dir() || meta.uid() != uid || meta.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "{} isn't a private folder of this user's, so no job runs",
            user.display()
        ));
    }
    let digest = aws_lc_rs::digest::digest(
        &aws_lc_rs::digest::SHA256,
        home.as_os_str().as_encoded_bytes(),
    );
    Ok(user.join(hex::encode(&digest.as_ref()[..4])))
}

/// A folder only this user may open, for one job's sockets, under [`sockets_base`].
pub fn socket_dir(home: &Path, name: &str) -> Result<PathBuf, String> {
    use std::os::unix::fs::DirBuilderExt;
    let base = sockets_base(home)?;
    let _ = std::fs::DirBuilder::new().mode(0o700).create(&base);
    let dir = base.join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&dir)
        .map_err(|e| format!("no folder for the job's sockets: {e}"))?;
    Ok(dir)
}

impl Place {
    pub fn disk(&self) -> PathBuf {
        self.dir.join("disk.img")
    }
    pub fn console(&self) -> PathBuf {
        self.dir.join("console.log")
    }
    pub fn control(&self) -> PathBuf {
        self.sockets.join("c.sock")
    }
    pub fn model(&self) -> PathBuf {
        self.sockets.join("m.sock")
    }
    pub fn key(&self) -> PathBuf {
        self.sockets.join("k.sock")
    }
}

impl Vm {
    /// Makes the job's disk (sparse, `size.disk_gib`) and starts the VM, which obi-vm itself stops
    /// past `max_seconds` whatever obid does. Its three sockets must be served already.
    pub async fn start(
        helper: &Path,
        image: &Image,
        place: &Place,
        size: Size,
        max_seconds: u64,
    ) -> Result<Vm, String> {
        let disk = place.disk();
        let file = std::fs::File::create(&disk)
            .map_err(|e| format!("the job's disk couldn't be made: {e}"))?;
        file.set_len(size.disk_gib * 1024 * 1024 * 1024)
            .map_err(|e| format!("the job's disk couldn't be sized: {e}"))?;
        drop(file);
        let mut child = Command::new(helper)
            .arg("run")
            .arg("--kernel")
            .arg(image.kernel())
            .arg("--initrd")
            .arg(image.initrd())
            .arg("--root")
            .arg(image.root())
            .arg("--disk")
            .arg(&disk)
            .arg("--console")
            .arg(place.console())
            .arg("--cpus")
            .arg(size.cpus.to_string())
            .arg("--memory-mib")
            .arg(size.memory_mib.to_string())
            .arg("--vsock")
            .arg(format!("{CONTROL_PORT}={}", place.control().display()))
            .arg("--vsock")
            .arg(format!("{MODEL_PORT}={}", place.model().display()))
            .arg("--vsock")
            .arg(format!("{KEY_PORT}={}", place.key().display()))
            .arg("--max-seconds")
            .arg(max_seconds.to_string())
            // Nothing of obid's environment, but where programs are (a test's stand-in needs it).
            .env_clear()
            .envs(std::env::var_os("PATH").map(|p| ("PATH", p)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("obi-vm didn't start: {e}"))?;
        let stdin = child.stdin.take().ok_or("obi-vm has no stdin")?;
        let stdout = child.stdout.take().ok_or("obi-vm has no stdout")?;
        let (tx, events) = mpsc::channel(16);
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(event) = serde_json::from_str::<Value>(&line)
                    && tx.send(event).await.is_err()
                {
                    break;
                }
            }
        });
        let mut vm = Vm {
            child,
            stdin,
            events,
            disk,
        };
        // A VM that hasn't started in 5 minutes won't (obi-vm is killed as `vm` drops).
        let first = tokio::time::timeout(std::time::Duration::from_secs(300), vm.next())
            .await
            .map_err(|_| "the VM didn't start within 5 minutes".to_owned())?;
        match first {
            Some(e) if e["event"] == "running" => Ok(vm),
            Some(e) => Err(format!(
                "the VM didn't start: {}",
                e["error"].as_str().unwrap_or("it stopped")
            )),
            None => Err("the VM didn't start".into()),
        }
    }

    /// The next event: `paused`, `resumed`, `background`, `stopped`, `error`; None once obi-vm
    /// is gone.
    pub async fn next(&mut self) -> Option<Value> {
        self.events.recv().await
    }

    /// `pause`, `resume`, `background`, `foreground` or `stop`.
    pub async fn command(&mut self, command: &str) -> bool {
        self.stdin
            .write_all(format!("{command}\n").as_bytes())
            .await
            .is_ok()
            && self.stdin.flush().await.is_ok()
    }

    /// Stops the VM at once and removes its disk: whatever the guest wrote there was encrypted
    /// with a key that is gone with it.
    pub async fn stop(mut self) {
        let _ = self.command("stop").await;
        let wait = tokio::time::timeout(std::time::Duration::from_secs(5), self.child.wait()).await;
        if wait.is_err() {
            let _ = self.child.kill().await;
        }
        let _ = std::fs::remove_file(&self.disk);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_are_the_owners_choices() {
        assert_eq!(
            Size::named("small"),
            Some(Size {
                cpus: 4,
                memory_mib: 8192,
                disk_gib: 30
            })
        );
        assert_eq!(Size::named("large").map(|s| s.cpus), Some(6));
        assert_eq!(Size::named("huge"), None);
    }

    #[test]
    fn a_mac_is_fit_on_power_cool_and_not_saving_power() {
        let s = Signals {
            idle_seconds: 900,
            on_ac: true,
            low_power: false,
            thermal: "nominal".into(),
        };
        assert!(s.fit());
        assert!(
            !Signals {
                on_ac: false,
                ..s.clone()
            }
            .fit()
        );
        assert!(
            !Signals {
                low_power: true,
                ..s.clone()
            }
            .fit()
        );
        assert!(
            !Signals {
                thermal: "serious".into(),
                ..s
            }
            .fit()
        );
    }
}
