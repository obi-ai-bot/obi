//! The guest image a shared Mac's VMs boot (#797; docs/runner-api.md, "obid only: sharing this
//! Mac"). It isn't in Oby.app: obid fetches it into `home/vm` when the owner turns sharing on, and
//! only then. Which image is `obi-vm image`'s answer, what's baked into the obi-vm beside obid
//! (core/obi-vm/image.json pins it): each file's SHA-256 and size, and its zstd-compressed copy's
//! SHA-256. Each file comes compressed from `<vmImageUrl>/<root.img's SHA-256>/<name>.zst`, is kept
//! only when the download's SHA-256 is the pinned one, and is unpacked to a file of its own that's
//! moved into place only when its SHA-256 and size are too: the server is trusted for nothing.
//! `home/vm/image.json` records the image that's there; another obi-vm (an update of Oby) fetches
//! its own.

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
/// The most one file, compressed or not, may be.
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
            let sha = |k: String| {
                m.get(&k)
                    .is_some_and(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
            };
            FILES
                .iter()
                .all(|f| sha(f.to_string()) && sha(format!("{f}.zst")) && size_of(m, f).is_some())
        });
    asked
        .lock()
        .unwrap()
        .insert(helper.to_owned(), answer.clone());
    answer
}

/// A file's size as `wanted` pins it.
fn size_of(wanted: &BTreeMap<String, String>, name: &str) -> Option<u64> {
    wanted
        .get(&format!("{name}.bytes"))?
        .parse()
        .ok()
        .filter(|n| *n > 0 && *n <= MAX_FILE)
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
    // How much, first: the disk must hold all of it, compressed and not, and SPARE more.
    let mut sizes = Vec::new();
    for name in FILES {
        let head = http
            .head(format!("{folder}/{name}.zst"))
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
    let unpacked: u64 = FILES
        .iter()
        .map(|f| size_of(wanted, f).unwrap_or(MAX_FILE))
        .sum();
    let free = nix::sys::statvfs::statvfs(dir)
        .ok()
        .map(|s| (s.blocks_available() as u64).saturating_mul(s.fragment_size()));
    if free.is_some_and(|free| free < unpacked + total + SPARE) {
        return Err(format!(
            "This Mac hasn't the free disk space for the guest image ({} MB, and 5 GB more).",
            (unpacked + total).div_ceil(1 << 20)
        ));
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
        let part = dir.join(format!("{name}.zst.part"));
        let got = download(
            &http,
            &format!("{folder}/{name}.zst"),
            &part,
            size,
            progress,
        )
        .await;
        match got {
            Ok(sha) if sha == wanted[&format!("{name}.zst")] => {}
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
        // Unpacked to a file of its own, and moved into place only when it's the pinned one.
        let unpack = dir.join(format!("{name}.unpack"));
        let most = size_of(wanted, name).unwrap_or(0);
        let (from, to) = (part.clone(), unpack.clone());
        let unpacked = tokio::task::spawn_blocking(move || unzstd(&from, &to, most))
            .await
            .map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(&part);
        match unpacked {
            Ok((sha, bytes)) if sha == wanted[name] && bytes == most => {
                std::fs::rename(&unpack, &path).map_err(|e| e.to_string())?;
            }
            Ok(_) => {
                let _ = std::fs::remove_file(&unpack);
                return Err(format!(
                    "The guest image's {name} doesn't unpack to the one this Oby boots: it wasn't kept."
                ));
            }
            Err(e) => {
                let _ = std::fs::remove_file(&unpack);
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

/// Unpacks the zstd file `from` (one frame or more) into `to`, at most `most` bytes: its SHA-256
/// and size.
fn unzstd(from: &Path, to: &Path, most: u64) -> Result<(String, u64), String> {
    use std::io::{BufRead, Read, Write};
    let broken = |_| "The guest image didn't unpack: turn sharing on again to retry.".to_owned();
    let mut source = std::io::BufReader::new(std::fs::File::open(from).map_err(|e| e.to_string())?);
    let mut out = std::fs::File::create(to).map_err(|e| e.to_string())?;
    let mut hash = digest::Context::new(&digest::SHA256);
    let mut got = 0u64;
    let mut buf = vec![0u8; 1 << 20];
    while !source.fill_buf().map_err(|e| e.to_string())?.is_empty() {
        let mut frame = ruzstd::decoding::StreamingDecoder::new(&mut source).map_err(|_| {
            "The guest image didn't unpack: turn sharing on again to retry.".to_owned()
        })?;
        loop {
            let n = frame.read(&mut buf).map_err(broken)?;
            if n == 0 {
                break;
            }
            got += n as u64;
            if got > most {
                return Err("The guest image unpacks to more than it should.".into());
            }
            hash.update(&buf[..n]);
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        }
    }
    out.sync_all().map_err(|e| e.to_string())?;
    Ok((hex::encode(hash.finish().as_ref()), got))
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

    fn zst(bytes: &[u8]) -> Vec<u8> {
        ruzstd::encoding::compress_to_vec(bytes, ruzstd::encoding::CompressionLevel::Fastest)
    }

    /// What `obi-vm image` says for these files: each one's SHA-256 and size, and its .zst's.
    fn pin(bodies: &BTreeMap<&str, Vec<u8>>) -> BTreeMap<String, String> {
        let mut wanted = BTreeMap::new();
        for (name, body) in bodies {
            wanted.insert(name.to_string(), sha(body));
            wanted.insert(format!("{name}.zst"), sha(&zst(body)));
            wanted.insert(format!("{name}.bytes"), body.len().to_string());
        }
        wanted
    }

    #[tokio::test]
    async fn the_image_is_fetched_only_as_obi_vm_names_it() {
        let bodies: BTreeMap<&str, Vec<u8>> = [
            ("vmlinuz", b"kernel".to_vec()),
            ("initrd", b"initrd".to_vec()),
            ("root.img", vec![7u8; 300_000]),
        ]
        .into();
        let wanted = pin(&bodies);
        let folder = format!("/vm/{}", wanted["root.img"]);
        let served: BTreeMap<String, Vec<u8>> = bodies
            .iter()
            .map(|(k, v)| (format!("{folder}/{k}.zst"), zst(v)))
            .collect();
        let compressed: u64 = served.values().map(|v| v.len() as u64).sum();
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
            ("ready", compressed, compressed)
        );
        assert_eq!(
            std::fs::read(dir.join("root.img")).unwrap(),
            bodies["root.img"]
        );
        let left: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .filter(|n| n.ends_with(".part") || n.ends_with(".unpack") || n.ends_with(".zst"))
            .collect();
        assert!(left.is_empty(), "{left:?}");

        // A corrupted download: its SHA-256 isn't the pinned .zst's, and nothing of it is kept.
        let other = tempdir_sibling(&dir);
        let mut corrupted = served.clone();
        let mut root = corrupted[&format!("{folder}/root.img.zst")].clone();
        let at = root.len() / 2;
        root[at] ^= 0xff;
        corrupted.insert(format!("{folder}/root.img.zst"), root);
        let bad = serve(corrupted).await;
        let progress = Mutex::new(Progress::none());
        let refused = fetch(&format!("{bad}/vm"), &other, &wanted, &progress).await;
        assert!(
            refused
                .unwrap_err()
                .contains("isn't the one this Oby boots")
        );
        assert!(!holds(&other, &wanted));
        assert!(!other.join("root.img").exists() && !other.join("root.img.zst.part").exists());

        // A good .zst of other bytes, pinned as the .zst but not as what it unpacks to.
        let mut lying = wanted.clone();
        let other_root = vec![8u8; 300_000];
        lying.insert("root.img.zst".into(), sha(&zst(&other_root)));
        let mut swapped = served.clone();
        swapped.insert(format!("{folder}/root.img.zst"), zst(&other_root));
        let liar = serve(swapped).await;
        let refused = fetch(&format!("{liar}/vm"), &other, &lying, &progress).await;
        assert!(
            refused
                .unwrap_err()
                .contains("doesn't unpack to the one this Oby boots")
        );
        assert!(!other.join("root.img").exists() && !other.join("root.img.unpack").exists());

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
