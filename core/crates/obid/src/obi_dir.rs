//! `.obi/` in a job's worktree: where obid hands the agent quoted data (`.obi/inputs/`,
//! `.obi/context/`). obid writes there itself, outside the job sandbox, and the worktree holds
//! whatever the repository commits, also a `.obi` or `.obi/<sub>` that is a link out of the
//! worktree (`.obi -> /anywhere`). So nothing here follows a link: every folder on the way must be
//! a real folder of the worktree's (checked with `symlink_metadata`), or obid refuses, and a file
//! is only ever created new (`O_EXCL`), never written through what was there.

use std::io::{Error, ErrorKind, Write};
use std::path::{Path, PathBuf};

/// The folder obid keeps in a worktree.
pub const OBI: &str = ".obi";

/// Why a path in `.obi/` can't be used.
fn not_a_folder(path: &Path) -> Error {
    Error::new(
        ErrorKind::InvalidData,
        format!(
            "{} isn't a folder (the repository has a link or a file there), so obid writes nothing through it",
            path.display()
        ),
    )
}

/// Whether `path` is a real folder (`Some(true)`), missing (`Some(false)`), or anything else, a
/// link included (`None`). The last part of `path` is never followed.
fn real_folder(path: &Path) -> std::io::Result<Option<bool>> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_dir() => Ok(Some(true)),
        Ok(_) => Ok(None),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(Some(false)),
        Err(e) => Err(e),
    }
}

/// `worktree/.obi/<sub>`, made where missing, each folder on the way checked to be a real
/// folder, not a link or a file. `Err` when one isn't: nothing is written then.
pub fn folder(worktree: &Path, sub: &str) -> std::io::Result<PathBuf> {
    let obi = worktree.join(OBI);
    let path = obi.join(sub);
    for folder in [&obi, &path] {
        match real_folder(folder)? {
            Some(true) => {}
            Some(false) => std::fs::create_dir(folder)?,
            None => return Err(not_a_folder(folder)),
        }
    }
    Ok(path)
}

/// Takes `worktree/.obi/<sub>` away with all it holds, when it is a real folder under a real
/// `.obi`. A link inside it is removed itself, never followed. Missing is fine; a link or a file
/// in place of either folder is `Err`, and nothing is removed.
pub fn clear(worktree: &Path, sub: &str) -> std::io::Result<()> {
    let obi = worktree.join(OBI);
    match real_folder(&obi)? {
        Some(false) => return Ok(()),
        None => return Err(not_a_folder(&obi)),
        Some(true) => {}
    }
    let path = obi.join(sub);
    match real_folder(&path)? {
        Some(false) => Ok(()),
        None => Err(not_a_folder(&path)),
        // Its own path is a real folder (checked above, and its parent too), and remove_dir_all
        // doesn't follow the links it finds inside.
        Some(true) => std::fs::remove_dir_all(&path),
    }
}

/// Writes `bytes` as the new file `name` in `dir` (a folder [`folder`] gave): what was there
/// under that name, a link or a file, is removed first, not written through, and the file is
/// created new.
pub fn write_new(dir: &Path, name: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
    let path = dir.join(name);
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_dir() => return Err(not_a_folder(&path)),
        Ok(_) => std::fs::remove_file(&path)?,
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)?;
    file.write_all(bytes)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("obid-obi-dir-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(path.join("worktree")).unwrap();
        std::fs::create_dir_all(path.join("victim/context")).unwrap();
        std::fs::write(path.join("victim/context/keep"), "keep").unwrap();
        path
    }

    #[test]
    fn real_folders_are_made_and_written() {
        let t = temp("real");
        let worktree = t.join("worktree");
        let dir = folder(&worktree, "inputs").unwrap();
        assert_eq!(dir, worktree.join(".obi/inputs"));
        write_new(&dir, "a.json", b"1").unwrap();
        write_new(&dir, "a.json", b"2").unwrap();
        assert_eq!(std::fs::read(dir.join("a.json")).unwrap(), b"2");
        clear(&worktree, "inputs").unwrap();
        assert!(!dir.exists());
        clear(&worktree, "inputs").unwrap();
        let _ = std::fs::remove_dir_all(&t);
    }

    #[test]
    fn a_link_on_the_way_is_refused_and_nothing_outside_changes() {
        let t = temp("links");
        let worktree = t.join("worktree");
        let victim = t.join("victim");
        // `.obi -> victim`.
        std::os::unix::fs::symlink(&victim, worktree.join(".obi")).unwrap();
        assert!(folder(&worktree, "context").is_err());
        assert!(clear(&worktree, "context").is_err());
        assert!(victim.join("context/keep").exists());
        std::fs::remove_file(worktree.join(".obi")).unwrap();
        // `.obi/context -> victim/context`.
        std::fs::create_dir(worktree.join(".obi")).unwrap();
        std::os::unix::fs::symlink(victim.join("context"), worktree.join(".obi/context")).unwrap();
        assert!(folder(&worktree, "context").is_err());
        assert!(clear(&worktree, "context").is_err());
        assert!(victim.join("context/keep").exists());
        std::fs::remove_file(worktree.join(".obi/context")).unwrap();
        // `.obi` a file.
        std::fs::remove_dir(worktree.join(".obi")).unwrap();
        std::fs::write(worktree.join(".obi"), "x").unwrap();
        assert!(folder(&worktree, "inputs").is_err());
        std::fs::remove_file(worktree.join(".obi")).unwrap();
        // A link inside a real folder: cleared as a link, never followed; a file named like a
        // link is replaced, not written through.
        let dir = folder(&worktree, "context").unwrap();
        std::os::unix::fs::symlink(victim.join("context"), dir.join("inner")).unwrap();
        std::os::unix::fs::symlink(victim.join("context/keep"), dir.join("notes.md")).unwrap();
        write_new(&dir, "notes.md", b"quoted").unwrap();
        assert_eq!(
            std::fs::read_to_string(victim.join("context/keep")).unwrap(),
            "keep"
        );
        clear(&worktree, "context").unwrap();
        assert!(victim.join("context/keep").exists());
        let _ = std::fs::remove_dir_all(&t);
    }
}
