//! What this binary is and who it trusts, fixed at compile time (ADR 0012).
//!
//! * `TINYPRUNE_UPDATE_PUBLIC_KEY`: the ADR 0009 Ed25519 public key (base64, 32 bytes). Without it the
//!   updater is disabled, exactly like a Swift direct build without a Sparkle key.
//! * `TINYPRUNE_BUILD`: the monotonic build number (the release workflow's run number). Without it
//!   (`0`) this is an unstamped development build and updates are disabled.
//! * `TINYPRUNE_VERSION`: marketing version; defaults to this crate's version.
//!
//! The feed URL is a constant. It is not configurable at runtime in released builds.

use crate::crypto::PublicKey;
use crate::manifest::Installed;

pub const FEED_URL: &str = "https://tinyprune.com/updates/rust/rust-update-feed.json";

pub const VERSION: &str = match option_env!("TINYPRUNE_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};
pub const BUILD: u64 = parse_build(option_env!("TINYPRUNE_BUILD"));
const PUBLIC_KEY: Option<&str> = option_env!("TINYPRUNE_UPDATE_PUBLIC_KEY");

/// The base64 public key compiled into this binary, for release tooling to cross-check against the
/// signing Environment's configured key.
pub fn embedded_public_key() -> Option<&'static str> {
    PUBLIC_KEY
}

/// Non-numeric or empty input yields 0 (development build), never a guess.
const fn parse_build(text: Option<&str>) -> u64 {
    let Some(text) = text else { return 0 };
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes.len() > 18 {
        return 0;
    }
    let mut value = 0u64;
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if !b.is_ascii_digit() {
            return 0;
        }
        value = value * 10 + (b - b'0') as u64;
        i += 1;
    }
    value
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Disabled {
    NoPublicKey,
    InvalidPublicKey,
    NoBuildNumber,
    UnsupportedOs,
    /// Not under `<data>/versions/`: package-manager or hand-copied binaries are never replaced.
    NotManaged,
}
impl std::fmt::Display for Disabled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::NoPublicKey => "this build has no update key embedded, so in-app updates are disabled",
            Self::InvalidPublicKey => "the embedded update key is not a valid Ed25519 public key",
            Self::NoBuildNumber => "this is an unstamped development build (no build number), so updates are disabled",
            Self::UnsupportedOs => "the Rust runtime updater supports Linux and Windows only; macOS updates through the app",
            Self::NotManaged => "this copy is not in a TinyPrune-managed versions directory (for example a package-manager or hand-copied install); update it with the tool that installed it",
        })
    }
}

#[derive(Debug, Clone)]
pub struct Trust {
    pub installed: Installed,
    pub key: PublicKey,
    pub feed_url: String,
    /// Test-only builds may use a loopback `http://` feed.
    pub allow_loopback_http: bool,
}

/// `Err` explains why updating is unavailable in this build.
pub fn trust() -> Result<Trust, Disabled> {
    let key = PublicKey::from_base64(PUBLIC_KEY.ok_or(Disabled::NoPublicKey)?)
        .map_err(|_| Disabled::InvalidPublicKey)?;
    if BUILD == 0 {
        return Err(Disabled::NoBuildNumber);
    }
    #[allow(unused_mut)]
    let mut trust = Trust {
        installed: Installed {
            version: VERSION.to_owned(),
            build: BUILD,
        },
        key,
        feed_url: FEED_URL.to_owned(),
        allow_loopback_http: false,
    };
    // Compiled only into the end-to-end test binary (feature `test-overrides`), never into released
    // artifacts: the key and build stay compile-time; only the feed location may be redirected.
    #[cfg(feature = "test-overrides")]
    if let Ok(url) = std::env::var("TINYPRUNE_UPDATE_FEED_URL") {
        trust.feed_url = url;
        trust.allow_loopback_http = true;
    }
    Ok(trust)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn build_number_parsing_is_strict() {
        assert_eq!(parse_build(Some("123")), 123);
        for bad in [
            None,
            Some(""),
            Some("12a"),
            Some("-1"),
            Some(" 1"),
            Some("99999999999999999999"),
        ] {
            assert_eq!(parse_build(bad), 0, "{bad:?}");
        }
    }
    #[test]
    fn plain_dev_build_is_disabled() {
        // No key/build are set when the unit tests are compiled.
        assert!(matches!(trust(), Err(Disabled::NoPublicKey)));
    }
    #[test]
    fn feed_url_is_https_and_pinned_to_the_project_domain() {
        assert!(crate::transport::is_https(FEED_URL));
        assert!(FEED_URL.starts_with("https://tinyprune.com/updates/"));
    }
}
