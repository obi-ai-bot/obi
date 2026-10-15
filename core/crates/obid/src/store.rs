//! Where obid keeps its jobs: one JSON file per job in `home/jobs/` (0600), written whole and
//! renamed into place, so a crash leaves the old version or the new one, never half of one.

use std::path::{Path, PathBuf};

use crate::job::Job;

pub struct Store {
    dir: PathBuf,
}

impl Store {
    /// The store in `home/jobs`, made if it isn't there (0700).
    pub fn open(home: &Path) -> std::io::Result<Store> {
        let dir = home.join("jobs");
        make_private_dir(&dir)?;
        Ok(Store { dir })
    }

    fn path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    /// Writes the job.
    pub fn save(&self, job: &Job) -> std::io::Result<()> {
        let text = serde_json::to_vec_pretty(job).map_err(std::io::Error::other)?;
        write_private(&self.path(&job.id), &text)
    }

    /// Every job kept, oldest first. A file that doesn't read as a job is left alone and logged.
    pub fn load_all(&self) -> Vec<Job> {
        let mut jobs = Vec::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return jobs;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|e| e != "json") {
                continue;
            }
            match std::fs::read(&path).map(|bytes| serde_json::from_slice::<Job>(&bytes)) {
                Ok(Ok(job)) => jobs.push(job),
                Ok(Err(e)) => tracing::warn!("{} isn't a job: {e}", path.display()),
                Err(e) => tracing::warn!("can't read {}: {e}", path.display()),
            }
        }
        jobs.sort_by(|a, b| a.created.cmp(&b.created).then_with(|| a.id.cmp(&b.id)));
        jobs
    }
}

/// A folder only its owner can reach (0700), with its parents.
pub fn make_private_dir(dir: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(dir)
}

/// Writes `bytes` to `path` (0600) through a temporary file renamed into place.
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let temporary = path.with_extension(format!("tmp-{}-{n}", std::process::id()));
    {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        std::io::Write::write_all(&mut file, bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&temporary, path)
}

/// Every `*.json` file in `dir` that reads as a `T`; the others are left alone and logged.
pub fn load_dir<T: serde::de::DeserializeOwned>(dir: &Path) -> Vec<T> {
    let mut items = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return items;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "json") {
            continue;
        }
        match std::fs::read(&path).map(|bytes| serde_json::from_slice::<T>(&bytes)) {
            Ok(Ok(item)) => items.push(item),
            Ok(Err(e)) => tracing::warn!("{} doesn't read: {e}", path.display()),
            Err(e) => tracing::warn!("can't read {}: {e}", path.display()),
        }
    }
    items
}
