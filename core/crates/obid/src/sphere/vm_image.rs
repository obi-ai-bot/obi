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
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use aws_lc_rs::digest;
use serde::Serialize;
use tokio::io::AsyncWriteExt;

/// What `obi-vm image` answers: each file's SHA-256 and its `.zst`'s, and each one's size as
/// `<name>.bytes`.
pub type Pin = BTreeMap<String, String>;

/// Where the images are, unless `vmImageUrl` says.
pub const DEFAULT_URL: &str = "https://downloads.oby.deskree.com/vm";
/// The three files, in the order they're fetched (the largest last).
pub const FILES: [&str; 3] = ["vmlinuz", "initrd", "root.img"];
/// The most one file, compressed or not, may be.
const MAX_FILE: u64 = 8 * 1024 * 1024 * 1024;
/// What's kept free on the disk besides the image.
const SPARE: u64 = 5 * 1024 * 1024 * 1024;
/// How long connecting may take, and how long a download may go without a byte before it's given
/// up (a stalled connection never leaves sharing fetching for good).
const CONNECT: Duration = Duration::from_secs(30);
pub const STALL: Duration = Duration::from_secs(60);

/// Where fetching the image is, for Settings › Sharing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    /// `none` (not asked for), `fetching`, `ready` or `failed`.
    pub state: &'static str,
    pub done: u64,
    /// How much there is to fetch, as obi-vm pins it.
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

/// The image the obi-vm at `helper` boots, as it says (`obi-vm image`): none when it isn't there
/// or names no whole image. It runs obi-vm: call it off the async runtime.
pub fn ask(helper: &Path) -> Option<Pin> {
    std::process::Command::new(helper)
        .arg("image")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| serde_json::from_slice::<Pin>(&o.stdout).ok())
        .filter(whole)
}

/// Whether `pin` names a whole image: each file's SHA-256 and size, and its `.zst`'s.
fn whole(pin: &Pin) -> bool {
    let sha = |k: &str| {
        pin.get(k)
            .is_some_and(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
    };
    FILES.iter().all(|f| {
        let zst = format!("{f}.zst");
        sha(f) && sha(&zst) && size_of(pin, f).is_some() && size_of(pin, &zst).is_some()
    })
}

/// A file's size (`root.img`, `root.img.zst`) as `pin` says it.
fn size_of(pin: &Pin, name: &str) -> Option<u64> {
    pin.get(&format!("{name}.bytes"))?
        .parse()
        .ok()
        .filter(|n| *n > 0 && *n <= MAX_FILE)
}

/// How much fetching the image downloads, as `pin` says it.
pub fn download_size(pin: &Pin) -> u64 {
    FILES
        .iter()
        .filter_map(|f| size_of(pin, &format!("{f}.zst")))
        .sum()
}

/// Whether `dir` holds the image `pin` names, as recorded when it was fetched.
pub fn holds(dir: &Path, pin: &Pin) -> bool {
    FILES.iter().all(|f| dir.join(f).is_file())
        && std::fs::read(dir.join("image.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Pin>(&b).ok())
            .is_some_and(|kept| &kept == pin)
}

/// Takes out what a fetch that was stopped left: its downloads and unpacked files.
pub fn clear_partial(dir: &Path) {
    for name in FILES {
        let _ = std::fs::remove_file(dir.join(format!("{name}.zst.part")));
        let _ = std::fs::remove_file(dir.join(format!("{name}.unpack")));
    }
}

/// Whether `free` bytes hold `need` and SPARE more; not knowing how much is free is no.
pub fn enough_room(free: Option<u64>, need: u64) -> Result<(), String> {
    match free {
        Some(free) if free >= need + SPARE => Ok(()),
        Some(_) => Err(format!(
            "This Mac hasn't the free disk space for the guest image ({} MB, and 5 GB more).",
            need.div_ceil(1_000_000)
        )),
        None => Err("Oby couldn't tell how much disk space is free for the guest image.".into()),
    }
}

/// Fetches the image `pin` names into `dir`, `progress` said as it goes; the files already there
/// for it are kept. A download that goes `stall` without a byte is given up.
pub async fn fetch(
    base: &str,
    dir: &Path,
    pin: &Pin,
    progress: &Mutex<Progress>,
    stall: Duration,
) -> Result<(), String> {
    if !whole(pin) {
        return Err("This Oby's obi-vm names no whole guest image.".into());
    }
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(CONNECT)
        .read_timeout(stall)
        .build()
        .map_err(|e| e.to_string())?;
    let folder = format!("{}/{}", base.trim_end_matches('/'), pin["root.img"]);
    crate::store::make_private_dir(dir).map_err(|e| format!("no folder for the image: {e}"))?;
    // The disk must hold all of it, compressed and unpacked, and SPARE more: sizes from the pin.
    let total = download_size(pin);
    let unpacked: u64 = FILES.iter().filter_map(|f| size_of(pin, f)).sum();
    let free = nix::sys::statvfs::statvfs(dir)
        .ok()
        .map(|s| (s.blocks_available() as u64).saturating_mul(s.fragment_size()));
    enough_room(free, unpacked + total)?;
    *progress.lock().unwrap() = Progress {
        state: "fetching",
        done: 0,
        total,
        error: None,
    };
    // The record goes first: a half-fetched image is never taken for a whole one.
    let _ = std::fs::remove_file(dir.join("image.json"));
    for name in FILES {
        let zst = format!("{name}.zst");
        let size = size_of(pin, &zst).unwrap_or(0);
        let path = dir.join(name);
        if sha256_of(&path).as_deref() == Some(pin[name].as_str()) {
            progress.lock().unwrap().done += size;
            continue;
        }
        let part = dir.join(format!("{zst}.part"));
        let got = download(&http, &format!("{folder}/{zst}"), &part, size, progress).await;
        match got {
            Ok(sha) if sha == pin[&zst] => {}
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
        let most = size_of(pin, name).unwrap_or(0);
        let (from, to) = (part.clone(), unpack.clone());
        let unpacked = tokio::task::spawn_blocking(move || unzstd(&from, &to, most))
            .await
            .map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(&part);
        match unpacked {
            Ok((sha, bytes)) if sha == pin[name] && bytes == most => {
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
    let record = serde_json::to_vec_pretty(pin).map_err(|e| e.to_string())?;
    crate::store::write_private(&dir.join("image.json"), &record).map_err(|e| e.to_string())?;
    *progress.lock().unwrap() = Progress {
        state: "ready",
        done: total,
        total,
        error: None,
    };
    Ok(())
}

/// One file into `part`: exactly the pinned `size` bytes, whatever the server says: its SHA-256.
async fn download(
    http: &reqwest::Client,
    url: &str,
    part: &Path,
    size: u64,
    progress: &Mutex<Progress>,
) -> Result<String, String> {
    let lost = |_| "The guest image's download stopped part way.".to_owned();
    let mut response = http
        .get(url)
        .send()
        .await
        .map_err(|_| "Oby couldn't reach where the guest image is.".to_owned())?;
    match response.status().as_u16() {
        200 => {}
        404 => return Err("The guest image for this Oby isn't published (404).".into()),
        status => return Err(format!("The guest image couldn't be fetched ({status}).")),
    }
    let mut file = tokio::fs::File::create(part)
        .await
        .map_err(|e| e.to_string())?;
    let mut hash = digest::Context::new(&digest::SHA256);
    let mut got = 0u64;
    while let Some(chunk) = response.chunk().await.map_err(lost)? {
        got += chunk.len() as u64;
        if got > size {
            return Err("The guest image is larger than this Oby pins it.".into());
        }
        hash.update(&chunk);
        file.write_all(&chunk).await.map_err(|e| e.to_string())?;
        progress.lock().unwrap().done += chunk.len() as u64;
    }
    if got < size {
        return Err("The guest image's download stopped part way.".into());
    }
    file.flush().await.map_err(|e| e.to_string())?;
    file.sync_all().await.map_err(|e| e.to_string())?;
    Ok(hex::encode(hash.finish().as_ref()))
}

/// Unpacks the zstd file `from` (one frame or more) into `to`, at most `most` bytes: its SHA-256
/// and size.
fn unzstd(from: &Path, to: &Path, most: u64) -> Result<(String, u64), String> {
    use std::io::{BufRead, Read, Write};
    let broken = |_| "The guest image didn't unpack.".to_owned();
    let mut source = std::io::BufReader::new(std::fs::File::open(from).map_err(|e| e.to_string())?);
    let mut out = std::fs::File::create(to).map_err(|e| e.to_string())?;
    let mut hash = digest::Context::new(&digest::SHA256);
    let mut got = 0u64;
    let mut buf = vec![0u8; 1 << 20];
    while !source.fill_buf().map_err(|e| e.to_string())?.is_empty() {
        let mut frame = ruzstd::decoding::StreamingDecoder::new(&mut source)
            .map_err(|_| "The guest image didn't unpack.".to_owned())?;
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

    /// How the test server answers a path.
    #[derive(Clone)]
    enum Serve {
        /// The body, as it is.
        Body(Vec<u8>),
        /// Says 100 bytes more than it sends, then closes: a download cut off.
        CutOff(Vec<u8>),
        /// Sends the headers and a few bytes, then nothing.
        Stall,
    }

    /// A one-request-at-a-time HTTP server for `paths`.
    async fn serve(paths: BTreeMap<String, Serve>) -> String {
        use tokio::io::{AsyncBufReadExt, BufReader};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let paths = paths.clone();
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
                    let path = first.split(' ').nth(1).unwrap_or("").to_owned();
                    let head = |n: usize| {
                        format!(
                            "HTTP/1.1 200 OK\r\ncontent-length: {n}\r\nconnection: close\r\n\r\n"
                        )
                        .into_bytes()
                    };
                    match paths.get(&path) {
                        Some(Serve::Body(body)) => {
                            let mut r = head(body.len());
                            r.extend_from_slice(body);
                            let _ = write.write_all(&r).await;
                        }
                        Some(Serve::CutOff(body)) => {
                            let mut r = head(body.len() + 100);
                            r.extend_from_slice(body);
                            let _ = write.write_all(&r).await;
                        }
                        Some(Serve::Stall) => {
                            let _ = write.write_all(&head(1_000)).await;
                            let _ = write.write_all(b"abc").await;
                            tokio::time::sleep(Duration::from_secs(30)).await;
                        }
                        None => {
                            let _ = write
                                .write_all(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                                .await;
                        }
                    }
                    let _ = write.shutdown().await;
                });
            }
        });
        format!("http://{addr}/vm")
    }

    fn sha(bytes: &[u8]) -> String {
        hex::encode(digest::digest(&digest::SHA256, bytes).as_ref())
    }

    fn zst(bytes: &[u8]) -> Vec<u8> {
        ruzstd::encoding::compress_to_vec(bytes, ruzstd::encoding::CompressionLevel::Fastest)
    }

    /// What `obi-vm image` says for these files: each SHA-256 and size, plain and compressed.
    fn pin(bodies: &BTreeMap<&str, Vec<u8>>) -> Pin {
        let mut pin = Pin::new();
        for (name, body) in bodies {
            let packed = zst(body);
            pin.insert(name.to_string(), sha(body));
            pin.insert(format!("{name}.bytes"), body.len().to_string());
            pin.insert(format!("{name}.zst"), sha(&packed));
            pin.insert(format!("{name}.zst.bytes"), packed.len().to_string());
        }
        pin
    }

    fn bodies() -> BTreeMap<&'static str, Vec<u8>> {
        [
            ("vmlinuz", b"kernel".to_vec()),
            ("initrd", b"initrd".to_vec()),
            ("root.img", (0..300_000u32).map(|i| (i % 7) as u8).collect()),
        ]
        .into()
    }

    /// The server's paths for `bodies`, as `pin` names its folder.
    fn served(pin: &Pin, bodies: &BTreeMap<&str, Vec<u8>>) -> BTreeMap<String, Serve> {
        bodies
            .iter()
            .map(|(k, v)| {
                (
                    format!("/vm/{}/{k}.zst", pin["root.img"]),
                    Serve::Body(zst(v)),
                )
            })
            .collect()
    }

    fn dir() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("obid-vm-image-{}", uuid::Uuid::new_v4()))
    }

    async fn refused(base: &str, pin: &Pin) -> (String, std::path::PathBuf) {
        let dir = dir();
        let progress = Mutex::new(Progress::none());
        let why = fetch(base, &dir, pin, &progress, Duration::from_millis(500))
            .await
            .unwrap_err();
        assert!(!holds(&dir, pin));
        for name in FILES {
            assert!(
                !dir.join(name).exists() || name != "root.img",
                "{name} kept"
            );
            assert!(!dir.join(format!("{name}.zst.part")).exists());
            assert!(!dir.join(format!("{name}.unpack")).exists());
        }
        (why, dir)
    }

    #[tokio::test]
    async fn the_image_is_fetched_only_as_obi_vm_pins_it() {
        let bodies = bodies();
        let pin = pin(&bodies);
        let base = serve(served(&pin, &bodies)).await;
        let dir = dir();
        let progress = Mutex::new(Progress::none());
        fetch(&base, &dir, &pin, &progress, STALL).await.unwrap();
        assert!(holds(&dir, &pin));
        let done = progress.lock().unwrap().clone();
        let total = download_size(&pin);
        assert_eq!((done.state, done.done, done.total), ("ready", total, total));
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
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn a_download_that_isnt_the_pinned_one_is_refused_and_nothing_is_kept() {
        let bodies = bodies();
        let pin = pin(&bodies);
        let root = format!("/vm/{}/root.img.zst", pin["root.img"]);

        // Corrupted: its SHA-256 isn't the pinned .zst's.
        let mut paths = served(&pin, &bodies);
        let Serve::Body(mut packed) = paths[&root].clone() else {
            unreachable!()
        };
        let at = packed.len() / 2;
        packed[at] ^= 0xff;
        paths.insert(root.clone(), Serve::Body(packed));
        let (why, d) = refused(&serve(paths).await, &pin).await;
        assert!(why.contains("isn't the one this Oby boots"), "{why}");
        let _ = std::fs::remove_dir_all(d);

        // A good .zst of other bytes, pinned as the .zst but not as what it unpacks to.
        let other: Vec<u8> = vec![8u8; 300_000];
        let mut lying = pin.clone();
        lying.insert("root.img.zst".into(), sha(&zst(&other)));
        lying.insert("root.img.zst.bytes".into(), zst(&other).len().to_string());
        let mut paths = served(&pin, &bodies);
        paths.insert(root.clone(), Serve::Body(zst(&other)));
        let (why, d) = refused(&serve(paths).await, &lying).await;
        assert!(
            why.contains("doesn't unpack to the one this Oby boots"),
            "{why}"
        );
        let _ = std::fs::remove_dir_all(d);

        // More than the pin says: cut at the pinned size, whatever the server's length.
        let mut paths = served(&pin, &bodies);
        let mut more = zst(&bodies["root.img"]);
        more.extend_from_slice(&[0u8; 64]);
        paths.insert(root.clone(), Serve::Body(more));
        let (why, d) = refused(&serve(paths).await, &pin).await;
        assert!(why.contains("larger than this Oby pins it"), "{why}");
        let _ = std::fs::remove_dir_all(d);

        // Cut off part way.
        let mut paths = served(&pin, &bodies);
        let Serve::Body(packed) = paths[&root].clone() else {
            unreachable!()
        };
        paths.insert(
            root.clone(),
            Serve::CutOff(packed[..packed.len() / 2].to_vec()),
        );
        let (why, d) = refused(&serve(paths).await, &pin).await;
        assert!(why.contains("stopped part way"), "{why}");
        let _ = std::fs::remove_dir_all(d);

        // Stalled: nothing for longer than the stall limit.
        let mut paths = served(&pin, &bodies);
        paths.insert(root.clone(), Serve::Stall);
        let started = std::time::Instant::now();
        let (why, d) = refused(&serve(paths).await, &pin).await;
        assert!(why.contains("stopped part way"), "{why}");
        assert!(started.elapsed() < Duration::from_secs(10));
        let _ = std::fs::remove_dir_all(d);

        // Not published at all.
        let (why, d) = refused(&serve(BTreeMap::new()).await, &pin).await;
        assert!(why.contains("isn't published (404)"), "{why}");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn the_disk_must_hold_it_and_not_knowing_is_no() {
        assert!(enough_room(Some(SPARE + 100), 100).is_ok());
        let short = enough_room(Some(SPARE + 99), 100).unwrap_err();
        assert!(short.contains("free disk space"), "{short}");
        assert!(
            enough_room(None, 100)
                .unwrap_err()
                .contains("couldn't tell")
        );
    }

    #[tokio::test]
    async fn a_fetch_stopped_part_way_leaves_nothing() {
        let bodies = bodies();
        let pin = pin(&bodies);
        let mut paths = served(&pin, &bodies);
        paths.insert(
            format!("/vm/{}/root.img.zst", pin["root.img"]),
            Serve::Stall,
        );
        let base = serve(paths).await;
        let dir = dir();
        let progress = Mutex::new(Progress::none());
        // Stopped while root.img's download hangs, as turning sharing off or obid stopping does.
        let stopped = tokio::time::timeout(
            Duration::from_millis(800),
            fetch(&base, &dir, &pin, &progress, STALL),
        )
        .await;
        assert!(stopped.is_err(), "it was still fetching");
        assert!(dir.join("root.img.zst.part").exists());
        clear_partial(&dir);
        assert!(!dir.join("root.img.zst.part").exists());
        assert!(!holds(&dir, &pin));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_pin_names_a_whole_image_or_none() {
        let pin = pin(&bodies());
        assert!(whole(&pin));
        let mut half = pin.clone();
        half.remove("root.img.zst.bytes");
        assert!(!whole(&half));
        assert!(ask(Path::new("/nonexistent/obi-vm")).is_none());
    }
}
