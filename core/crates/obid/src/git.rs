//! obid's own git: its clones (`home/clones/<owner>/<name>`, whose push URL is invalid, so nothing
//! an agent runs can push) and the jobs' worktrees (`home/worktrees/<job id>`). This git runs
//! outside any sandbox, so it never runs a hook or an fsmonitor, whatever a worktree or another
//! Obi's branch holds, and it never asks for a password.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::process::Command;

/// The push URL every clone gets: git refuses it, so no push leaves from a clone (AGENTS.md,
/// "Agents can't publish").
pub const NO_PUSH_URL: &str = "obid-agents-cannot-push:///";

/// How long one git command may take before obid gives up on it.
const GIT_TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct GitError(pub String);

/// The settings every git call of obid's carries.
const SAFE: &[&str] = &[
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "credential.interactive=never",
    "-c",
    "protocol.ext.allow=never",
];

/// Runs git with `args` in `dir`; its stdout, trimmed, or why it failed.
pub async fn run(dir: &Path, args: &[&OsStr], extra: &[(&str, &str)]) -> Result<String, GitError> {
    let mut command = Command::new("git");
    command
        .current_dir(dir)
        .args(SAFE)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_COMMON_DIR")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    for (key, value) in extra {
        command.env(key, value);
    }
    let shown = args
        .iter()
        .map(|a| a.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ");
    let output = tokio::time::timeout(GIT_TIMEOUT, command.output())
        .await
        .map_err(|_| {
            GitError(format!(
                "git {shown} took more than {} seconds",
                GIT_TIMEOUT.as_secs()
            ))
        })?
        .map_err(|e| GitError(format!("git can't run: {e}")))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let line = stderr
            .lines()
            .rfind(|l| !l.trim().is_empty())
            .unwrap_or("")
            .trim()
            .to_owned();
        return Err(GitError(format!("git {shown} failed: {line}")));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// [`run`] with plain string arguments.
pub async fn git(dir: &Path, args: &[&str]) -> Result<String, GitError> {
    let args: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
    run(dir, &args, &[]).await
}

/// The clone of `repo` (`owner/name`) under `home`.
pub fn clone_path(home: &Path, repo: &str) -> PathBuf {
    let mut path = home.join("clones");
    for part in repo.split('/') {
        path.push(part);
    }
    path
}

/// Makes the clone of `repo` from `remote` if there is none, with its push URL invalid, then
/// fetches `refspecs` from origin. Answers the clone's path.
pub async fn ensure_clone(
    home: &Path,
    repo: &str,
    remote: &str,
    refspecs: &[String],
) -> Result<PathBuf, GitError> {
    let clone = clone_path(home, repo);
    if !clone.join(".git").is_dir() {
        let parent = clone.parent().expect("a clone has a parent");
        std::fs::create_dir_all(parent)
            .map_err(|e| GitError(format!("can't make {}: {e}", parent.display())))?;
        let partial = parent.join(format!(
            ".{}.cloning",
            clone.file_name().unwrap_or_default().to_string_lossy()
        ));
        let _ = std::fs::remove_dir_all(&partial);
        run(
            parent,
            &[
                "clone".as_ref(),
                "--no-checkout".as_ref(),
                "--quiet".as_ref(),
                "--".as_ref(),
                remote.as_ref(),
                partial.as_os_str(),
            ],
            &[],
        )
        .await?;
        git(&partial, &["config", "remote.origin.pushurl", NO_PUSH_URL]).await?;
        std::fs::rename(&partial, &clone)
            .map_err(|e| GitError(format!("can't move the clone into place: {e}")))?;
    } else {
        // A clone made before is held to the same rules.
        git(&clone, &["config", "remote.origin.url", remote]).await?;
        git(&clone, &["config", "remote.origin.pushurl", NO_PUSH_URL]).await?;
    }
    exclude_obi_folders(&clone)?;
    if !refspecs.is_empty() {
        let mut args: Vec<&str> = vec![
            "fetch",
            "--quiet",
            "--no-tags",
            "--no-write-fetch-head",
            "origin",
        ];
        args.extend(refspecs.iter().map(String::as_str));
        git(&clone, &args).await?;
    }
    Ok(clone)
}

/// `.obi/` (what obid hands an agent: quoted inputs and context) and `.oby/` (the Swift runner's)
/// are never part of the work: excluded in the clone's `info/exclude`, which every worktree shares.
pub fn exclude_obi_folders(clone: &Path) -> Result<(), GitError> {
    let info = clone.join(".git").join("info");
    std::fs::create_dir_all(&info)
        .map_err(|e| GitError(format!("can't make {}: {e}", info.display())))?;
    let exclude = info.join("exclude");
    let text = std::fs::read_to_string(&exclude).unwrap_or_default();
    let mut lines: Vec<&str> = text.lines().collect();
    let mut changed = false;
    for folder in ["/.obi/", "/.oby/"] {
        if !lines.contains(&folder) {
            lines.push(folder);
            changed = true;
        }
    }
    if changed {
        let mut joined = lines.join("\n");
        joined.push('\n');
        std::fs::write(&exclude, joined)
            .map_err(|e| GitError(format!("can't write {}: {e}", exclude.display())))?;
    }
    Ok(())
}

/// Whether `commit` is a commit the clone has.
pub async fn has_commit(clone: &Path, commit: &str) -> bool {
    git(clone, &["cat-file", "-e", &format!("{commit}^{{commit}}")])
        .await
        .is_ok()
}

/// A worktree's git directories: its own (`<common>/worktrees/<name>`) and the common one.
pub async fn worktree_dirs(worktree: &Path) -> Result<(PathBuf, PathBuf), GitError> {
    let admin = git(
        worktree,
        &["rev-parse", "--path-format=absolute", "--git-dir"],
    )
    .await?;
    let common = git(
        worktree,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    .await?;
    Ok((PathBuf::from(admin), PathBuf::from(common)))
}

/// A valid branch name, as git and the spec allow it (no option-like or odd names).
pub fn is_branch_name(name: &str) -> bool {
    let ok_chars = name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'/' | b'-'));
    !name.is_empty()
        && name.len() <= 200
        && ok_chars
        && !name.starts_with(['-', '/', '.'])
        && !name.contains("..")
        && !name.contains("//")
        && !name.ends_with('/')
        && !name.ends_with('.')
        && !name.ends_with(".lock")
        && !name.contains("/.")
}

/// A full commit id, lower-case hex.
pub fn is_sha(text: &str) -> bool {
    (text.len() == 40 || text.len() == 64)
        && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_names() {
        for good in ["main", "feature/average", "oby/fix-12", "v1.2"] {
            assert!(is_branch_name(good), "{good}");
        }
        for bad in [
            "",
            "-x",
            "--upload-pack=sh",
            "a..b",
            "a//b",
            "a/",
            "a.",
            "a.lock",
            "a/.b",
            "a b",
            ".x",
            "/x",
        ] {
            assert!(!is_branch_name(bad), "{bad}");
        }
    }
}
