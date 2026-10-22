//! The guest image a shared Mac's VMs boot (#797; docs/runner-api.md, "obid only: sharing this
//! Mac"). It isn't in Oby.app (1.7 GB): obid fetches it into `home/vm` when the owner turns sharing
//! on, and only then. Which image is `obi-vm image`'s answer, the SHA-256s baked into the obi-vm
//! beside obid (core/obi-vm/image.json pins them): each file is fetched from
//! `<vmImageUrl>/<root.img's SHA-256>/<name>` and kept only when its own SHA-256 is that one, so
//! the server is trusted for nothing. `home/vm/image.json` records the image that's there; another
//! obi-vm (an update of Oby) fetches its own.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use aws_lc_rs::digest;
use serde::Serialize;
use tokio::io::AsyncWriteExt;

/// Where the images are, unless `vmImageUrl` says.
pub const DEFAULT_URL: &str = "https://downloads.oby.deskree.com/vm";
/// The three files, in the order they're fetched (the largest last).
pub const FILES: [&str; 3] = ["vmlinuz", "initrd", "root.img"];
/// The most one file may be.
const MAX_FILE: u64 = 8 * 1024 * 1024 * 1024;
/// What's kept free on the disk besides the image.
const SPARE: u64 = 5 * 1024 * 1024 * 1024;

/// Where fetching the image is, for Settings › Sharing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    /// `none` (not asked for), `fetching`, `ready` or `failed`.
    pub state: &'static str,
    pub done: u64,
    pub total: u64,
    /// Why it failed, in a sentence.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Progress {
    pub fn none() -> Progress {
        Progress {
            state: "none",
            done: 0,
            total: 0,
            error: None,
        }
    }

    pub fn failed(why: String) -> Progress {
        Progress {
            state: "failed",
            error: Some(why),
            ..Progress::none()
        }
    }
}

impl Default for Progress {
    fn default() -> Progress {
        Progress::none()
    }
}

/// The image the obi-vm at `helper` boots, as it says (`obi-vm image`): asked once per helper.
pub fn wanted(helper: &Path) -> Option<BTreeMap<String, String>> {
    type Hashes = BTreeMap<String, String>;
    static ASKED: OnceLock<Mutex<BTreeMap<PathBuf, Option<Hashes>>>> = OnceLock::new();
    let asked = ASKED.get_or_init(Default::default);
    if let Some(answer) = asked.lock().unwrap().get(helper) {
        return answer.clone();
    }
    let answer = std::process::Command::new(helper)
        .arg("image")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| serde_json::from_slice::<BTreeMap<String, String>>(&o.stdout).ok())
        .filter(|m| {
            FILES.iter().all(|f| {
                m.get(*f)
                    .is_some_and(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
            })
        });
    asked
        .lock()
        .unwrap()
        .insert(helper.to_owned(), answer.clone());
    answer
}

/// Whether `dir` holds the image `wanted` names, as recorded when it was fetched.
pub fn holds(dir: &Path, wanted: &BTreeMap<String, String>) -> bool {
    FILES.iter().all(|f| dir.join(f).is_file())
        && std::fs::read(dir.join("image.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<BTreeMap<String, String>>(&b).ok())
            .is_some_and(|kept| &kept == wanted)
}

/// Fetches the image `wanted` names into `dir`, `progress` said as it goes; the files already
/// there for it are kept.
pub async fn fetch(
    base: &str,
    dir: &Path,
    wanted: &BTreeMap<String, String>,
    progress: &Mutex<Progress>,
) -> Result<(), String> {
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let folder = format!("{}/{}", base.trim_end_matches('/'), wanted["root.img"]);
    crate::store::make_private_dir(dir).map_err(|e| format!("no folder for the image: {e}"))?;
    // How much, first: the disk must hold all of it and SPARE more.
    let mut sizes = Vec::new();
    for name in FILES {
        let head = http
            .head(format!("{folder}/{name}"))
            .send()
            .await
            .map_err(|_| "Oby couldn't reach where the guest image is.".to_owned())?;
        if !head.status().is_success() {
            return Err(format!(
                "The guest image for this Oby isn't published ({}).",
                head.status().as_u16()
            ));
        }
        // The header itself: a HEAD's body is empty, so reqwest's content_length() is 0.
        let size = head
            .headers()
            .get(reqwest::header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|n| *n > 0 && *n <= MAX_FILE)
            .ok_or("The guest image's size isn't right.")?;
        sizes.push(size);
    }
    let total: u64 = sizes.iter().sum();
    let free = nix::sys::statvfs::statvfs(dir)
        .ok()
        .map(|s| (s.blocks_available() as u64).saturating_mul(s.fragment_size()));
    if free.is_some_and(|free| free < total + SPARE) {
        return Err(
            "This Mac hasn't the free disk space for the guest image (1.7 GB, and 5 GB more)."
                .into(),
        );
    }
    *progress.lock().unwrap() = Progress {
        state: "fetching",
        done: 0,
        total,
        error: None,
    };
    // The record goes first: a half-fetched image is never taken for a whole one.
    let _ = std::fs::remove_file(dir.join("image.json"));
    for (name, size) in FILES.into_iter().zip(sizes) {
        let path = dir.join(name);
        if sha256_of(&path).as_deref() == Some(wanted[name].as_str()) {
            progress.lock().unwrap().done += size;
            continue;
        }
        let part = dir.join(format!("{name}.part"));
        let got = download(&http, &format!("{folder}/{name}"), &part, size, progress).await;
        match got {
            Ok(sha) if sha == wanted[name] => {
                std::fs::rename(&part, &path).map_err(|e| e.to_string())?;
            }
            Ok(_) => {
                let _ = std::fs::remove_file(&part);
                return Err(format!(
                    "The guest image's {name} isn't the one this Oby boots: it wasn't kept."
                ));
            }
            Err(e) => {
                let _ = std::fs::remove_file(&part);
                return Err(e);
            }
        }
    }
    let record = serde_json::to_vec_pretty(wanted).map_err(|e| e.to_string())?;
    crate::store::write_private(&dir.join("image.json"), &record).map_err(|e| e.to_string())?;
    *progress.lock().unwrap() = Progress {
        state: "ready",
        done: total,
        total,
        error: None,
    };
    Ok(())
}

/// One file into `part`, at most `size` bytes: its SHA-256.
async fn download(
    http: &reqwest::Client,
    url: &str,
    part: &Path,
    size: u64,
    progress: &Mutex<Progress>,
) -> Result<String, String> {
    let lost =
        |_| "The guest image's download broke off: turn sharing on again to retry.".to_owned();
    let mut response = http.get(url).send().await.map_err(lost)?;
    if !response.status().is_success() {
        return Err(format!(
            "The guest image couldn't be fetched ({}).",
            response.status().as_u16()
        ));
    }
    let mut file = tokio::fs::File::create(part)
        .await
        .map_err(|e| e.to_string())?;
    let mut hash = digest::Context::new(&digest::SHA256);
    let mut got = 0u64;
    while let Some(chunk) = response.chunk().await.map_err(lost)? {
        got += chunk.len() as u64;
        if got > size {
            return Err("The guest image is larger than it said.".into());
        }
        hash.update(&chunk);
        file.write_all(&chunk).await.map_err(|e| e.to_string())?;
        progress.lock().unwrap().done += chunk.len() as u64;
    }
    file.flush().await.map_err(|e| e.to_string())?;
    file.sync_all().await.map_err(|e| e.to_string())?;
    Ok(hex::encode(hash.finish().as_ref()))
}

/// A file's SHA-256, when it's there.
fn sha256_of(path: &Path) -> Option<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut hash = digest::Context::new(&digest::SHA256);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Some(hex::encode(hash.finish().as_ref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A one-request-at-a-time HTTP server for `files`: HEAD and GET, by path.
    async fn serve(files: BTreeMap<String, Vec<u8>>) -> String {
        use tokio::io::{AsyncBufReadExt, BufReader};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let files = files.clone();
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut lines = BufReader::new(read).lines();
                    let Ok(Some(first)) = lines.next_line().await else {
                        return;
                    };
                    while let Ok(Some(line)) = lines.next_line().await {
                        if line.is_empty() {
                            break;
                        }
                    }
                    let mut parts = first.split(' ');
                    let (method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
                    let reply = match files.get(path) {
                        Some(body) => {
                            let mut r = format!(
                                "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                                body.len()
                            )
                            .into_bytes();
                            if method == "GET" {
                                r.extend_from_slice(body);
                            }
                            r
                        }
                        None => b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_vec(),
                    };
                    let _ = write.write_all(&reply).await;
                    let _ = write.shutdown().await;
                });
            }
        });
        format!("http://{addr}")
    }

    fn sha(bytes: &[u8]) -> String {
        hex::encode(digest::digest(&digest::SHA256, bytes).as_ref())
    }

    #[tokio::test]
    async fn the_image_is_fetched_only_as_obi_vm_names_it() {
        let bodies: BTreeMap<&str, Vec<u8>> = [
            ("vmlinuz", b"kernel".to_vec()),
            ("initrd", b"initrd".to_vec()),
            ("root.img", vec![7u8; 300_000]),
        ]
        .into();
        let wanted: BTreeMap<String, String> = bodies
            .iter()
            .map(|(k, v)| (k.to_string(), sha(v)))
            .collect();
        let folder = format!("/vm/{}", wanted["root.img"]);
        let mut served: BTreeMap<String, Vec<u8>> = bodies
            .iter()
            .map(|(k, v)| (format!("{folder}/{k}"), v.clone()))
            .collect();
        let base = serve(served.clone()).await;
        let dir = std::env::temp_dir().join(format!("obid-vm-image-{}", uuid::Uuid::new_v4()));
        let progress = Mutex::new(Progress::none());
        fetch(&format!("{base}/vm"), &dir, &wanted, &progress)
            .await
            .unwrap();
        assert!(holds(&dir, &wanted));
        let done = progress.lock().unwrap().clone();
        assert_eq!(
            (done.state, done.done, done.total),
            ("ready", 300_012, 300_012)
        );
        assert_eq!(
            std::fs::read(dir.join("root.img")).unwrap(),
            bodies["root.img"]
        );

        // A server that serves another root: nothing of it is kept, and the image isn't held.
        let other = tempdir_sibling(&dir);
        served.insert(format!("{folder}/root.img"), vec![8u8; 300_000]);
        let bad = serve(served).await;
        let progress = Mutex::new(Progress::none());
        let refused = fetch(&format!("{bad}/vm"), &other, &wanted, &progress).await;
        assert!(
            refused
                .unwrap_err()
                .contains("isn't the one this Oby boots")
        );
        assert!(!holds(&other, &wanted));
        assert!(!other.join("root.img").exists() && !other.join("root.img.part").exists());

        // Not published at all.
        let missing = serve(BTreeMap::new()).await;
        let refused = fetch(&format!("{missing}/vm"), &other, &wanted, &progress).await;
        assert!(refused.unwrap_err().contains("isn't published (404)"));
        let _ = std::fs::remove_dir_all(dir);
        let _ = std::fs::remove_dir_all(other);
    }

    fn tempdir_sibling(dir: &Path) -> PathBuf {
        dir.with_file_name(format!("obid-vm-image-{}", uuid::Uuid::new_v4()))
    }
}
