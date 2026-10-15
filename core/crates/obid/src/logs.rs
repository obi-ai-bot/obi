//! obid's log layer (docs/ARCHITECTURE.md 5.4, decision D6): what the plug-in host logs under
//! the `tracing` target `obi_plugin` (a plug-in's stderr and `log` messages, and what the host
//! says about it) goes through [`Redacting`] before anything is written, which takes the secrets
//! obid holds (`crate::secrets`), plain and encoded, out of the whole line. The host has no
//! secrets and writes no log of its own: this layer is the only place they are taken out.

use std::io::Write;
use std::sync::Arc;

use tracing_subscriber::fmt::MakeWriter;

use crate::secrets::Secrets;

/// The `tracing` target plug-ins' words are logged under.
pub const PLUGIN_TARGET: &str = "obi_plugin";

/// Whether an event of `target` is a plug-in's, or the host's about one.
pub fn is_plugin_target(target: &str) -> bool {
    target == PLUGIN_TARGET
        || target
            .strip_prefix(PLUGIN_TARGET)
            .is_some_and(|rest| rest.starts_with("::"))
}

/// A [`MakeWriter`] that hands every line of the `obi_plugin` target to `inner` only once
/// `secrets` are taken out of it, and every other line as it is.
pub struct Redacting<M> {
    inner: M,
    secrets: Arc<Secrets>,
}

impl<M> Redacting<M> {
    pub fn new(inner: M, secrets: Arc<Secrets>) -> Redacting<M> {
        Redacting { inner, secrets }
    }
}

/// One line on its way to the log. For the `obi_plugin` target the formatter's writes are kept
/// until the line is complete (the formatter writes one event, whole, then drops its writer), and
/// the line is written redacted then.
pub struct Line<W: Write> {
    out: W,
    held: Option<Vec<u8>>,
    secrets: Arc<Secrets>,
}

impl<'a, M: MakeWriter<'a>> MakeWriter<'a> for Redacting<M> {
    type Writer = Line<M::Writer>;

    /// Without the event's metadata the line can't be told apart, so it is redacted too.
    fn make_writer(&'a self) -> Line<M::Writer> {
        Line {
            out: self.inner.make_writer(),
            held: Some(Vec::new()),
            secrets: self.secrets.clone(),
        }
    }

    fn make_writer_for(&'a self, meta: &tracing::Metadata<'_>) -> Line<M::Writer> {
        Line {
            out: self.inner.make_writer_for(meta),
            held: is_plugin_target(meta.target()).then(Vec::new),
            secrets: self.secrets.clone(),
        }
    }
}

impl<W: Write> Write for Line<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        match &mut self.held {
            Some(held) => {
                held.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            None => self.out.write(bytes),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self.held {
            // Written whole, when the line is done.
            Some(_) => Ok(()),
            None => self.out.flush(),
        }
    }
}

impl<W: Write> Drop for Line<W> {
    fn drop(&mut self) {
        if let Some(held) = self.held.take()
            && !held.is_empty()
        {
            let text = String::from_utf8_lossy(&held);
            let _ = self.out.write_all(self.secrets.redact(&text).as_bytes());
            let _ = self.out.flush();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Clone, Default)]
    struct Buffer(Arc<Mutex<Vec<u8>>>);

    impl Write for Buffer {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Buffer {
        fn text(&self) -> String {
            String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
        }
    }

    #[test]
    fn the_plugin_target_is_redacted_before_it_is_written() {
        let secrets = Arc::new(Secrets::default());
        let token = "0123456789abcdef0123456789abcdefZZ";
        secrets.learn("api-token", token);
        let buffer = Buffer::default();
        let writer = {
            let buffer = buffer.clone();
            Redacting::new(move || buffer.clone(), secrets)
        };
        let subscriber = tracing_subscriber::fmt()
            .with_writer(writer)
            .with_ansi(false)
            .finish();
        let encoded = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, token);
        tracing::subscriber::with_default(subscriber, || {
            tracing::info!(target: "obi_plugin", plugin = "leaky", "stderr: {token} and {encoded}");
            tracing::warn!(target: "obi_plugin", plugin = %token, "the host says so");
            tracing::info!(target: "obid::jobs", "obid's own line");
        });
        let log = buffer.text();
        assert!(!log.contains(token), "{log}");
        assert!(!log.contains(&encoded), "{log}");
        assert_eq!(log.matches("[redacted: api-token]").count(), 3, "{log}");
        assert!(log.contains("plugin=\"leaky\""), "{log}");
        assert!(log.contains("obid's own line"), "{log}");
        assert_eq!(log.lines().count(), 3, "{log}");
    }

    #[test]
    fn targets() {
        assert!(is_plugin_target("obi_plugin"));
        assert!(is_plugin_target("obi_plugin::conn"));
        assert!(!is_plugin_target("obi_plugin_host"));
        assert!(!is_plugin_target("obid"));
    }
}
