//! A guest job's code and commits on the host's disk (#829's review): sealed with a key of their
//! own that's kept only in memory, so they're never in the clear under `home/g/<cid>/` (nor after a
//! crash), and read back a piece at a time, never whole into memory.

use std::path::{Path, PathBuf};

use aws_lc_rs::aead::{Aad, CHACHA20_POLY1305, LessSafeKey, Nonce, UnboundKey};
use aws_lc_rs::digest;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// The most one sealed piece holds.
const PIECE: usize = 1024 * 1024;
/// How much of the start is kept in the clear in memory: a bundle's header, for its heads.
const HEAD: usize = 64 * 1024;

fn sealing(key: &[u8; 32]) -> LessSafeKey {
    LessSafeKey::new(UnboundKey::new(&CHACHA20_POLY1305, key).expect("a 32-byte key"))
}

/// Each key seals one file, so a counter is a nonce used once.
fn nonce(n: u64) -> Nonce {
    let mut bytes = [0u8; 12];
    bytes[4..].copy_from_slice(&n.to_be_bytes());
    Nonce::assume_unique_for_key(bytes)
}

/// A sealed file being written.
pub struct Writer {
    path: PathBuf,
    file: tokio::fs::File,
    key: [u8; 32],
    pieces: u64,
    pub bytes: u64,
    hash: digest::Context,
    head: Vec<u8>,
}

impl Writer {
    pub async fn create(path: &Path) -> std::io::Result<Writer> {
        let mut key = [0u8; 32];
        aws_lc_rs::rand::fill(&mut key).map_err(|_| std::io::Error::other("no random key"))?;
        Ok(Writer {
            path: path.to_owned(),
            file: tokio::fs::File::create(path).await?,
            key,
            pieces: 0,
            bytes: 0,
            hash: digest::Context::new(&digest::SHA256),
            head: Vec::new(),
        })
    }

    pub async fn write(&mut self, data: &[u8]) -> std::io::Result<()> {
        let key = sealing(&self.key);
        for piece in data.chunks(PIECE) {
            let mut sealed = piece.to_vec();
            key.seal_in_place_append_tag(nonce(self.pieces), Aad::empty(), &mut sealed)
                .map_err(|_| std::io::Error::other("couldn't seal"))?;
            self.pieces += 1;
            self.file
                .write_all(&(sealed.len() as u32).to_be_bytes())
                .await?;
            self.file.write_all(&sealed).await?;
        }
        self.hash.update(data);
        self.bytes += data.len() as u64;
        let room = HEAD.saturating_sub(self.head.len()).min(data.len());
        self.head.extend_from_slice(&data[..room]);
        Ok(())
    }

    pub async fn finish(mut self) -> std::io::Result<Sealed> {
        self.file.flush().await?;
        Ok(Sealed {
            path: self.path,
            key: self.key,
            sha256: hex::encode(self.hash.finish().as_ref()),
            bytes: self.bytes,
            head: self.head,
        })
    }
}

/// A sealed file, whole.
pub struct Sealed {
    path: PathBuf,
    key: [u8; 32],
    pub sha256: String,
    pub bytes: u64,
    /// Its first 64 KiB, in the clear.
    pub head: Vec<u8>,
}

impl Sealed {
    /// Its pieces in the clear, in order; an error ends it.
    pub fn read(&self) -> impl futures_util::Stream<Item = std::io::Result<Vec<u8>>> + use<> {
        let (path, key) = (self.path.clone(), sealing(&self.key));
        futures_util::stream::unfold(
            (None::<tokio::fs::File>, path, key, 0u64, false),
            |(file, path, key, n, over)| async move {
                if over {
                    return None;
                }
                let mut file = match file {
                    Some(file) => file,
                    None => match tokio::fs::File::open(&path).await {
                        Ok(file) => file,
                        Err(e) => return Some((Err(e), (None, path, key, n, true))),
                    },
                };
                let mut len = [0u8; 4];
                match file.read_exact(&mut len).await {
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return None,
                    Err(e) => return Some((Err(e), (None, path, key, n, true))),
                }
                let len = u32::from_be_bytes(len) as usize;
                if len > PIECE + 16 {
                    let e = std::io::Error::other("a sealed piece is too long");
                    return Some((Err(e), (None, path, key, n, true)));
                }
                let mut piece = vec![0u8; len];
                if let Err(e) = file.read_exact(&mut piece).await {
                    return Some((Err(e), (None, path, key, n, true)));
                }
                match key.open_in_place(nonce(n), Aad::empty(), &mut piece) {
                    Ok(clear) => {
                        let clear = clear.to_vec();
                        Some((Ok(clear), (Some(file), path, key, n + 1, false)))
                    }
                    Err(_) => {
                        let e = std::io::Error::other("a sealed piece doesn't open");
                        Some((Err(e), (None, path, key, n, true)))
                    }
                }
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;

    #[tokio::test]
    async fn what_is_sealed_reads_back_and_isnt_on_disk_in_the_clear() {
        let dir = std::env::temp_dir().join(format!("obid-sealed-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("in.bundle");
        let data: Vec<u8> = b"# v2 git bundle\n"
            .iter()
            .copied()
            .chain((0..3 * PIECE + 7).map(|i| (i % 251) as u8))
            .collect();
        let mut writer = Writer::create(&path).await.unwrap();
        writer.write(&data[..10]).await.unwrap();
        writer.write(&data[10..]).await.unwrap();
        let sealed = writer.finish().await.unwrap();
        assert_eq!(sealed.bytes, data.len() as u64);
        assert_eq!(&sealed.head[..], &data[..HEAD]);
        let on_disk = std::fs::read(&path).unwrap();
        assert!(!on_disk.windows(15).any(|w| w == b"# v2 git bundle"));
        let back: Vec<u8> = sealed.read().map(|p| p.unwrap()).concat().await;
        assert_eq!(back, data);
        // A changed byte on disk doesn't read back.
        let mut bad = on_disk.clone();
        bad[10] ^= 1;
        std::fs::write(&path, bad).unwrap();
        let first = std::pin::pin!(sealed.read()).next().await.unwrap();
        assert!(first.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
