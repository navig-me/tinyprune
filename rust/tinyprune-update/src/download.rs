//! Streaming download to a private temp file with a size cap and incremental SHA-256.
//! The file is exactly the bytes the signed feed promised, or it does not exist.

use crate::crypto::{random_hex, Sha256};
use crate::manifest::{Artifact, MAX_ARTIFACT_BYTES};
use crate::transport::Transport;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub enum DownloadError {
    Transport(String),
    /// Declared or streamed size exceeds the signed size / hard cap.
    TooLarge {
        limit: u64,
    },
    Truncated {
        received: u64,
        expected: u64,
    },
    HashMismatch,
    Io(String),
}
impl std::fmt::Display for DownloadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(m) => write!(f, "download failed: {m}"),
            Self::TooLarge { limit } => write!(f, "download exceeds the {limit} byte limit"),
            Self::Truncated { received, expected } => {
                write!(f, "download truncated: {received} of {expected} bytes")
            }
            Self::HashMismatch => f.write_str("download SHA-256 does not match the signed feed"),
            Self::Io(m) => write!(f, "could not write the download: {m}"),
        }
    }
}
impl std::error::Error for DownloadError {}

/// Deletes the file when dropped, so every failure path (and the success path after extraction)
/// leaves nothing behind.
pub struct TempDownload {
    path: PathBuf,
}
impl TempDownload {
    pub fn path(&self) -> &Path {
        &self.path
    }
}
impl Drop for TempDownload {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub fn download(
    transport: &dyn Transport,
    artifact: &Artifact,
    dir: &Path,
) -> Result<TempDownload, DownloadError> {
    let limit = artifact.size.min(MAX_ARTIFACT_BYTES);
    if artifact.size > MAX_ARTIFACT_BYTES {
        return Err(DownloadError::TooLarge {
            limit: MAX_ARTIFACT_BYTES,
        });
    }
    let body = transport
        .get(&artifact.url)
        .map_err(|e| DownloadError::Transport(e.to_string()))?;
    match body.content_length {
        Some(announced) if announced > limit => return Err(DownloadError::TooLarge { limit }),
        Some(announced) if announced < artifact.size => {
            return Err(DownloadError::Truncated {
                received: announced,
                expected: artifact.size,
            })
        }
        _ => {}
    }
    fs::create_dir_all(dir).map_err(|e| DownloadError::Io(e.to_string()))?;
    let path = dir.join(format!("download-{}.part", random_hex(8)));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file: File = options
        .open(&path)
        .map_err(|e| DownloadError::Io(e.to_string()))?;
    let temp = TempDownload { path };
    let mut hasher = Sha256::new();
    let mut received = 0u64;
    let mut reader = body.reader;
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let n = reader
            .read(&mut buffer)
            .map_err(|e| DownloadError::Transport(e.to_string()))?;
        if n == 0 {
            break;
        }
        received += n as u64;
        if received > limit {
            return Err(DownloadError::TooLarge { limit });
        }
        hasher.update(&buffer[..n]);
        file.write_all(&buffer[..n])
            .map_err(|e| DownloadError::Io(e.to_string()))?;
    }
    if received < artifact.size {
        return Err(DownloadError::Truncated {
            received,
            expected: artifact.size,
        });
    }
    if hasher.finish_hex() != artifact.sha256 {
        return Err(DownloadError::HashMismatch);
    }
    file.sync_all()
        .map_err(|e| DownloadError::Io(e.to_string()))?;
    Ok(temp)
}

#[cfg(test)]
pub(crate) mod testing {
    use crate::transport::{HttpBody, Transport, TransportError};
    use std::collections::HashMap;
    use std::io::{self, Read};
    use std::sync::Mutex;

    /// Scripted in-memory transport; records every requested URL.
    #[derive(Default)]
    pub struct FakeTransport {
        pub routes: Mutex<HashMap<String, Route>>,
        pub requests: Mutex<Vec<String>>,
    }
    #[derive(Clone)]
    pub struct Route {
        pub body: Vec<u8>,
        /// What Content-Length claims (None = absent).
        pub announced: Option<u64>,
        /// Fail the read after this many bytes, as a dropped connection would.
        pub fail_after: Option<usize>,
        /// Serve this many extra bytes of garbage beyond `body` (a lying server).
        pub endless: bool,
    }
    impl Route {
        pub fn ok(body: &[u8]) -> Self {
            Self {
                announced: Some(body.len() as u64),
                body: body.to_vec(),
                fail_after: None,
                endless: false,
            }
        }
    }
    impl FakeTransport {
        pub fn with(routes: Vec<(&str, Route)>) -> Self {
            Self {
                routes: Mutex::new(routes.into_iter().map(|(u, r)| (u.to_owned(), r)).collect()),
                ..Self::default()
            }
        }
        pub fn set(&self, url: &str, route: Route) {
            self.routes.lock().unwrap().insert(url.to_owned(), route);
        }
    }
    struct Body {
        route: Route,
        position: usize,
    }
    impl Read for Body {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            if self.route.fail_after.is_some_and(|n| self.position >= n) {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "connection reset",
                ));
            }
            let end = self
                .route
                .fail_after
                .map_or(self.route.body.len(), |n| n.min(self.route.body.len()));
            if self.position >= end {
                if self.route.endless && self.route.fail_after.is_none() {
                    out.fill(b'A');
                    return Ok(out.len());
                }
                return Ok(0);
            }
            let n = out.len().min(end - self.position);
            out[..n].copy_from_slice(&self.route.body[self.position..self.position + n]);
            self.position += n;
            Ok(n)
        }
    }
    impl Transport for FakeTransport {
        fn get(&self, url: &str) -> Result<HttpBody, TransportError> {
            self.requests.lock().unwrap().push(url.to_owned());
            if !crate::transport::is_https(url) {
                return Err(TransportError::InsecureUrl(url.to_owned()));
            }
            let route = self
                .routes
                .lock()
                .unwrap()
                .get(url)
                .cloned()
                .ok_or(TransportError::Status(404))?;
            Ok(HttpBody {
                content_length: route.announced,
                reader: Box::new(Body { route, position: 0 }),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;
    use crate::crypto::sha256_hex;
    use crate::test_support::TempDir;

    const URL: &str = "https://example.test/a.tar.gz";
    fn artifact(bytes: &[u8]) -> Artifact {
        Artifact {
            url: URL.into(),
            sha256: sha256_hex(bytes),
            size: bytes.len() as u64,
        }
    }
    fn leftovers(dir: &Path) -> usize {
        fs::read_dir(dir).map(|d| d.count()).unwrap_or(0)
    }

    #[test]
    fn valid_download_matches_bytes_and_cleans_up_on_drop() {
        let dir = TempDir::new();
        let data: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        let transport = FakeTransport::with(vec![(URL, Route::ok(&data))]);
        let file = download(&transport, &artifact(&data), dir.path()).unwrap();
        assert_eq!(fs::read(file.path()).unwrap(), data);
        drop(file);
        assert_eq!(leftovers(dir.path()), 0);
    }
    #[test]
    fn hash_mismatch_leaves_nothing() {
        let dir = TempDir::new();
        let good = b"genuine release bytes";
        let transport = FakeTransport::with(vec![(URL, Route::ok(b"evil! release bytes"))]);
        let mut a = artifact(good);
        a.size = 19;
        assert!(matches!(
            download(&transport, &a, dir.path()),
            Err(DownloadError::HashMismatch)
        ));
        assert_eq!(leftovers(dir.path()), 0);
    }
    #[test]
    fn truncated_download_is_detected_whether_announced_dropped_or_silent() {
        let dir = TempDir::new();
        let data = vec![7u8; 100_000];
        let a = artifact(&data);
        // Connection dropped mid-body.
        let mut route = Route::ok(&data);
        route.fail_after = Some(50_000);
        let t = FakeTransport::with(vec![(URL, route)]);
        assert!(matches!(
            download(&t, &a, dir.path()),
            Err(DownloadError::Transport(_))
        ));
        // Clean EOF early with an honest short Content-Length.
        let mut route = Route::ok(&data[..60_000]);
        route.announced = Some(60_000);
        let t = FakeTransport::with(vec![(URL, route)]);
        assert!(matches!(
            download(&t, &a, dir.path()),
            Err(DownloadError::Truncated {
                expected: 100_000,
                ..
            })
        ));
        // Clean EOF early with no Content-Length.
        let mut route = Route::ok(&data[..60_000]);
        route.announced = None;
        let t = FakeTransport::with(vec![(URL, route)]);
        assert!(matches!(
            download(&t, &a, dir.path()),
            Err(DownloadError::Truncated {
                received: 60_000,
                ..
            })
        ));
        assert_eq!(leftovers(dir.path()), 0);
    }
    #[test]
    fn oversize_is_refused_from_header_stream_and_manifest() {
        let dir = TempDir::new();
        let data = vec![1u8; 1000];
        let a = artifact(&data);
        let mut route = Route::ok(&data);
        route.announced = Some(10_000_000);
        let t = FakeTransport::with(vec![(URL, route)]);
        assert!(matches!(
            download(&t, &a, dir.path()),
            Err(DownloadError::TooLarge { limit: 1000 })
        ));
        // Server lies about (or omits) Content-Length and never stops: the cap still holds.
        let mut route = Route::ok(&data);
        route.announced = None;
        route.endless = true;
        let t = FakeTransport::with(vec![(URL, route)]);
        assert!(matches!(
            download(&t, &a, dir.path()),
            Err(DownloadError::TooLarge { limit: 1000 })
        ));
        // A signed feed cannot raise the hard ceiling.
        let mut huge = a.clone();
        huge.size = MAX_ARTIFACT_BYTES + 1;
        let t = FakeTransport::default();
        assert!(matches!(
            download(&t, &huge, dir.path()),
            Err(DownloadError::TooLarge { .. })
        ));
        assert!(
            t.requests.lock().unwrap().is_empty(),
            "no request is made for an over-cap artifact"
        );
        assert_eq!(leftovers(dir.path()), 0);
    }
    #[test]
    fn non_https_artifact_never_reaches_the_network_layer_as_success() {
        let dir = TempDir::new();
        let mut a = artifact(b"x");
        a.url = "http://example.test/a".into();
        let t = FakeTransport::with(vec![]);
        assert!(matches!(
            download(&t, &a, dir.path()),
            Err(DownloadError::Transport(_))
        ));
    }
}
