//! Minimal HTTP surface. The updater only ever issues plain GETs: no cookies, no query string, no
//! identifiers, no request body. `Transport` is injectable so tests never touch the network.

use std::io::Read;
use std::time::Duration;

pub struct HttpBody {
    /// As announced by the server; untrusted, used only for early refusal.
    pub content_length: Option<u64>,
    pub reader: Box<dyn Read + Send>,
}

#[derive(Debug)]
pub enum TransportError {
    /// Not `https://` (or, with test overrides, loopback `http://`).
    InsecureUrl(String),
    Status(u16),
    Io(String),
}
impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InsecureUrl(url) => write!(f, "refusing non-HTTPS URL {url}"),
            Self::Status(code) => write!(f, "server answered HTTP {code}"),
            Self::Io(message) => write!(f, "network error: {message}"),
        }
    }
}
impl std::error::Error for TransportError {}

pub trait Transport: Send + Sync {
    fn get(&self, url: &str) -> Result<HttpBody, TransportError>;
}

/// `https://host/...` only.
pub fn is_https(url: &str) -> bool {
    url.len() > "https://".len()
        && url.len() <= 2048
        && url
            .get(.."https://".len())
            .is_some_and(|p| p.eq_ignore_ascii_case("https://"))
        && url.bytes().all(|b| b.is_ascii_graphic())
        && !url["https://".len()..].starts_with('/')
}

/// HTTPS, or (only in a `test-overrides` build) loopback HTTP. Released builds accept HTTPS only, and
/// `cfg!` makes that a compile-time constant, not a runtime switch.
pub fn is_acceptable_url(url: &str) -> bool {
    is_https(url) || (cfg!(feature = "test-overrides") && is_loopback_http(url))
}

pub struct UreqTransport {
    agent: ureq::Agent,
    allow_loopback_http: bool,
}

impl UreqTransport {
    /// HTTPS only, rustls with the bundled Mozilla roots, at most 3 redirects (each must also be HTTPS).
    pub fn new() -> Self {
        Self::build(false)
    }
    /// Test-only: additionally allows `http://127.0.0.1`/`localhost` feeds for the Docker end-to-end.
    #[cfg(feature = "test-overrides")]
    pub fn new_allowing_loopback_http() -> Self {
        Self::build(true)
    }
    fn build(allow_loopback_http: bool) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .https_only(!allow_loopback_http)
            .max_redirects(3)
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(30)))
            .timeout_global(Some(Duration::from_secs(20 * 60)))
            // Constant: no version, platform or machine identifier.
            .user_agent("TinyPrune-Updater")
            .build()
            .into();
        Self {
            agent,
            allow_loopback_http,
        }
    }
}
impl Default for UreqTransport {
    fn default() -> Self {
        Self::new()
    }
}

fn is_loopback_http(url: &str) -> bool {
    [
        "http://127.0.0.1:",
        "http://localhost:",
        "http://127.0.0.1/",
        "http://localhost/",
    ]
    .iter()
    .any(|p| url.starts_with(p))
}

impl Transport for UreqTransport {
    fn get(&self, url: &str) -> Result<HttpBody, TransportError> {
        if !is_https(url) && !(self.allow_loopback_http && is_loopback_http(url)) {
            return Err(TransportError::InsecureUrl(url.to_owned()));
        }
        let response = self.agent.get(url).call().map_err(|error| match error {
            ureq::Error::StatusCode(code) => TransportError::Status(code),
            other => TransportError::Io(other.to_string()),
        })?;
        let content_length = response.body().content_length();
        Ok(HttpBody {
            content_length,
            reader: Box::new(response.into_body().into_reader()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn https_only() {
        assert!(is_https("https://tinyprune.com/updates/x.json"));
        assert!(is_https("HTTPS://tinyprune.com/x"));
        for bad in [
            "http://tinyprune.com/x",
            "ftp://x/y",
            "https://",
            "https:///x",
            "file:///etc/passwd",
            "https://a b/",
            "//tinyprune.com/x",
            "",
        ] {
            assert!(!is_https(bad), "{bad}");
        }
    }
    #[test]
    fn real_transport_refuses_plain_http_without_dialing() {
        let transport = UreqTransport::new();
        assert!(matches!(
            transport.get("http://127.0.0.1:1/feed"),
            Err(TransportError::InsecureUrl(_))
        ));
        assert!(!transport.allow_loopback_http);
    }
}
