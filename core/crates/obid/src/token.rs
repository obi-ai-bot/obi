//! The API token every request carries (docs/runner-api.md, "obid only: configuration").
//!
//! It is `OBID_API_TOKEN` from the environment (at least 32 characters) or, when that is unset,
//! one obid makes on first start and keeps in `home/api-token` (0600), which the shells on the same
//! machine read. The token never appears in an answer, an event or a log.

use std::io::Write;
use std::path::{Path, PathBuf};

/// The environment variable that gives obid its token.
pub const ENV: &str = "OBID_API_TOKEN";
/// The file under `home` that keeps the token obid made, when the environment gives none.
pub const FILE: &str = "api-token";
/// The shortest token obid accepts.
pub const MIN_LEN: usize = 32;

#[derive(Debug, thiserror::Error)]
pub enum TokenError {
    #[error(
        "{ENV} is set but has fewer than {MIN_LEN} characters, or has spaces or control characters."
    )]
    WeakEnv,
    #[error(
        "{path} has no usable token (at least {MIN_LEN} characters, no spaces): remove it and obid makes a new one."
    )]
    WeakFile { path: PathBuf },
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("the system has no randomness to make a token with: {0}")]
    Random(String),
}

/// The token to answer to: `from_env` when given, else the one in `home/api-token`, made there now
/// when there is none.
pub fn load(home: &Path, from_env: Option<String>) -> Result<String, TokenError> {
    if let Some(token) = from_env {
        return if usable(&token) {
            Ok(token)
        } else {
            Err(TokenError::WeakEnv)
        };
    }
    let path = home.join(FILE);
    let io = |source| TokenError::Io {
        path: path.clone(),
        source,
    };
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            let token = text.trim_end_matches(['\n', '\r']).to_string();
            if !usable(&token) {
                return Err(TokenError::WeakFile { path });
            }
            keep_private(&path).map_err(io)?;
            Ok(token)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let token = make()?;
            write_new(&path, &token).map_err(io)?;
            Ok(token)
        }
        Err(e) => Err(io(e)),
    }
}

/// At least 32 characters, all visible ASCII: it goes in an `Authorization` header as it is.
fn usable(token: &str) -> bool {
    token.len() >= MIN_LEN && token.bytes().all(|b| b.is_ascii_graphic())
}

/// 32 random bytes as 64 hex characters.
fn make() -> Result<String, TokenError> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| TokenError::Random(e.to_string()))?;
    Ok(hex::encode(bytes))
}

/// Writes a file only its owner can read, failing if it exists.
fn write_new(path: &Path, token: &str) -> std::io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(token.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()
}

/// A token file others could read is made the owner's alone again.
fn keep_private(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(path)?.permissions().mode();
        if mode & 0o077 != 0 {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Whether `given` is `token`, in time that doesn't depend on where they differ.
pub fn same(given: &str, token: &str) -> bool {
    let (a, b) = (given.as_bytes(), token.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("obid-token-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn the_environment_wins_and_nothing_is_written() {
        let home = folder("env");
        let token = "x".repeat(32);
        assert_eq!(load(&home, Some(token.clone())).unwrap(), token);
        assert!(!home.join(FILE).exists());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_short_environment_token_is_refused() {
        let home = folder("short");
        for token in [
            "",
            "short",
            &"x".repeat(31),
            &format!("{} ", "x".repeat(32)),
        ] {
            assert!(matches!(
                load(&home, Some(token.to_string())),
                Err(TokenError::WeakEnv)
            ));
        }
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn makes_one_on_first_start_and_keeps_it() {
        let home = folder("make");
        let first = load(&home, None).unwrap();
        assert_eq!(first.len(), 64);
        assert!(first.bytes().all(|b| b.is_ascii_hexdigit()));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(home.join(FILE))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert_eq!(load(&home, None).unwrap(), first);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_broken_token_file_is_an_error_not_a_new_token() {
        let home = folder("broken");
        std::fs::write(home.join(FILE), "short\n").unwrap();
        assert!(matches!(
            load(&home, None),
            Err(TokenError::WeakFile { .. })
        ));
        assert_eq!(std::fs::read_to_string(home.join(FILE)).unwrap(), "short\n");
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn same_compares_whole_tokens() {
        assert!(same("abc", "abc"));
        assert!(!same("abc", "abd"));
        assert!(!same("ab", "abc"));
        assert!(!same("", "abc"));
    }
}
