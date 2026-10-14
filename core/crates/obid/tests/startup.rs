//! `obid::serve` while it starts: a stop that comes while obid measures `home/worktrees` stops it
//! there, without its saying it listens (docs/runner-api.md, "obid only: configuration": SIGTERM
//! or SIGINT exits 0 within 10 seconds).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use obid::config::Config;

struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("obid-startup-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Folder(path)
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn config(folder: &Path) -> Config {
    let text = serde_json::json!({
        "listen": "127.0.0.1:0",
        "home": folder.join("home"),
        "owner": "wellington",
    })
    .to_string();
    Config::parse(&text).unwrap()
}

/// Worktrees enough that measuring them isn't instant.
fn fill_worktrees(home: &Path, folders: usize, files: usize) {
    for d in 0..folders {
        let dir = home.join("worktrees").join(format!("wt-{d}"));
        std::fs::create_dir_all(&dir).unwrap();
        for f in 0..files {
            std::fs::write(dir.join(format!("f{f}")), b"x").unwrap();
        }
    }
}

/// A stop that is there before obid has measured `home/worktrees` ends `serve` with Ok, and obid
/// never says it listens. (Before, obid finished the walk, said it listened, and only then
/// stopped: on a large worktrees folder, past the 10 seconds.)
#[tokio::test(flavor = "multi_thread")]
async fn a_stop_before_obid_is_ready_stops_it_without_saying_it_listens() {
    let folder = Folder::new("stop-first");
    fill_worktrees(&folder.0.join("home"), 20, 100);
    let said_ready = Arc::new(AtomicBool::new(false));
    let told = said_ready.clone();
    let result = obid::serve(
        config(&folder.0),
        "t".repeat(64),
        std::future::ready(()),
        move |_| told.store(true, Ordering::SeqCst),
    )
    .await;
    assert!(result.is_ok(), "{result:?}");
    assert!(
        !said_ready.load(Ordering::SeqCst),
        "obid said it listens after it was told to stop"
    );
}

/// A stop that comes while obid measures ends `serve` about then, not once the walk is done:
/// the walk here takes far longer than the time `serve` is given to return.
#[tokio::test(flavor = "multi_thread")]
async fn a_stop_while_obid_measures_ends_the_walk() {
    let folder = Folder::new("stop-while-measuring");
    let home = folder.0.join("home");
    fill_worktrees(&home, 50, 400);
    // How long one whole measurement of this folder takes on this machine.
    let started = Instant::now();
    let _ = obid::api::Cleanup::measure(&home);
    let walk = started.elapsed();

    let said_ready = Arc::new(AtomicBool::new(false));
    let told = said_ready.clone();
    let started = Instant::now();
    let result = obid::serve(
        config(&folder.0),
        "t".repeat(64),
        tokio::time::sleep(Duration::from_millis(1)),
        move |_| told.store(true, Ordering::SeqCst),
    )
    .await;
    let took = started.elapsed();
    assert!(result.is_ok(), "{result:?}");
    if !said_ready.load(Ordering::SeqCst) {
        // The stop came first, as it does unless the walk is quicker than a millisecond: serve
        // returned without waiting for the rest of it.
        assert!(
            took < walk + Duration::from_secs(1),
            "serve took {took:?} after a stop; one walk takes {walk:?}"
        );
    }
}
