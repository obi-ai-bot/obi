//! What the job page shows of a job beyond its pipeline (#739): how big its change is (#736).
//! Paths and counts only, never what a file holds.

use serde::{Deserialize, Serialize};

/// The most files a diff lists by name; its totals count them all.
const BY_FILE_MAX: usize = 200;

/// One file's lines added and removed. A binary file counts 0 and 0.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    pub path: String,
    pub added: u64,
    pub removed: u64,
}

/// A change's size: files, lines added and removed, and each file's (the first
/// [`BY_FILE_MAX`], a path that holds a possible secret named as the scan names it). `round` is
/// the round it was read after.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Diff {
    pub files: u64,
    pub added: u64,
    pub removed: u64,
    pub by_file: Vec<FileDiff>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round: Option<u32>,
}

/// `git diff --numstat -z --no-renames`: `<added>\t<removed>\t<path>\0` per file, `-` for a
/// binary file's counts.
pub fn numstat(text: &str) -> Diff {
    let mut diff = Diff::default();
    for entry in text.split('\0').filter(|e| !e.is_empty()) {
        let mut parts = entry.splitn(3, '\t');
        let (Some(added), Some(removed), Some(path)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let added = added.trim().parse().unwrap_or(0);
        let removed = removed.parse().unwrap_or(0);
        diff.files += 1;
        diff.added += added;
        diff.removed += removed;
        if diff.by_file.len() < BY_FILE_MAX {
            diff.by_file.push(FileDiff {
                // A path that itself holds a possible secret is never repeated.
                path: crate::scan::shown_name(path),
                added,
                removed,
            });
        }
    }
    diff
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numstat_counts_every_file_and_reads_binaries_as_none() {
        let diff = numstat("3\t1\tsrc/a b.rs\0-\t-\tlogo.png\0\n10\t0\tnew.txt\0");
        assert_eq!((diff.files, diff.added, diff.removed), (3, 13, 1));
        assert_eq!(diff.by_file[0].path, "src/a b.rs");
        assert_eq!((diff.by_file[1].added, diff.by_file[1].removed), (0, 0));
        assert_eq!(numstat(""), Diff::default());
    }
}
