//! Signed feed: format, strict validation, platform selection and the version/build gate.
//!
//! The feed is one JSON document with a detached Ed25519 signature (`<feed>.sig`, base64). The
//! signature is checked over the exact received bytes BEFORE the JSON is parsed. Artifacts are
//! authenticated by the SHA-256 and size recorded in the signed feed (ADR 0012).

use crate::crypto::{is_sha256_hex, sha256_hex, PublicKey};
use crate::transport::{is_acceptable_url, Transport};
use crate::version::{is_path_safe, Version};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Read;

pub const FORMAT: &str = "tinyprune-rust-update-v1";
pub const MAX_FEED_BYTES: u64 = 256 * 1024;
pub const MAX_SIGNATURE_BYTES: u64 = 1024;
/// Hard ceiling regardless of what a (signed) feed claims.
pub const MAX_ARTIFACT_BYTES: u64 = 256 * 1024 * 1024;
const MAX_RELEASES: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Feed {
    pub format: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated: Option<String>,
    pub releases: Vec<Release>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Release {
    pub version: String,
    /// Monotonic build number; the authoritative update order.
    pub build: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published: Option<String>,
    /// Keyed by platform, e.g. `linux-x86_64`, `windows-x86_64`.
    pub artifacts: BTreeMap<String, Artifact>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artifact {
    pub url: String,
    /// Lowercase hex SHA-256 of the archive bytes.
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArchiveKind {
    TarGz,
    Zip,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Platform {
    pub key: String,
    pub archive: ArchiveKind,
}
impl Platform {
    /// `None` on macOS and any OS/arch the Rust runtime does not package (macOS uses Sparkle).
    pub fn current() -> Option<Self> {
        let arch = std::env::consts::ARCH;
        match std::env::consts::OS {
            "linux" => Some(Self::new("linux", arch, ArchiveKind::TarGz)),
            "windows" => Some(Self::new("windows", arch, ArchiveKind::Zip)),
            _ => None,
        }
    }
    pub fn new(os: &str, arch: &str, archive: ArchiveKind) -> Self {
        Self {
            key: format!("{os}-{arch}"),
            archive,
        }
    }
}

/// What this copy is. `build == 0` means an unstamped development build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installed {
    pub version: String,
    pub build: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    pub version: String,
    pub build: u64,
    pub notes_url: Option<String>,
    pub published: Option<String>,
    pub platform: String,
    pub artifact: Artifact,
}
impl Offer {
    /// Binds a user's confirmation to the exact signed offer they were shown. It is a consistency
    /// check (the offer cannot change between "check" and "install"), not a secret.
    pub fn confirmation_token(&self) -> String {
        sha256_hex(
            format!(
                "tinyprune-update-confirm-v1\n{}\n{}\n{}\n{}\n{}",
                self.platform, self.version, self.build, self.artifact.sha256, self.artifact.url
            )
            .as_bytes(),
        )[..32]
            .to_owned()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Check {
    UpToDate,
    Available(Offer),
    /// The signed feed has no artifact for this OS/architecture.
    Unsupported {
        platform: String,
    },
}

#[derive(Debug)]
pub enum FeedError {
    Transport(String),
    TooLarge(&'static str),
    BadSignature(String),
    Malformed(String),
    /// A release the feed would offer is oversize, non-HTTPS, or otherwise unacceptable.
    Rejected(String),
    /// The newest build in this feed is older than one already seen: replayed/rolled-back feed.
    FeedRolledBack {
        seen: u64,
        feed: u64,
    },
    /// Latest published build/version is below the installed one.
    Downgrade {
        installed: u64,
        offered: u64,
    },
    /// Same build number as installed but different content identity.
    BuildReused(u64),
}
impl std::fmt::Display for FeedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(m) => write!(f, "could not fetch the update feed: {m}"),
            Self::TooLarge(what) => write!(f, "{what} exceeds its size limit"),
            Self::BadSignature(m) => write!(f, "update feed signature rejected: {m}"),
            Self::Malformed(m) => write!(f, "update feed is malformed: {m}"),
            Self::Rejected(m) => write!(f, "update feed entry rejected: {m}"),
            Self::FeedRolledBack { seen, feed } => {
                write!(f, "update feed is older (build {feed}) than one already seen (build {seen}); refusing")
            }
            Self::Downgrade { installed, offered } => {
                write!(
                    f,
                    "refusing downgrade: installed build {installed}, feed offers {offered}"
                )
            }
            Self::BuildReused(build) => write!(
                f,
                "feed reuses installed build number {build} for different content"
            ),
        }
    }
}
impl std::error::Error for FeedError {}

fn read_bounded(
    transport: &dyn Transport,
    url: &str,
    max: u64,
    what: &'static str,
) -> Result<Vec<u8>, FeedError> {
    let body = transport
        .get(url)
        .map_err(|e| FeedError::Transport(e.to_string()))?;
    if body.content_length.is_some_and(|len| len > max) {
        return Err(FeedError::TooLarge(what));
    }
    let mut bytes = Vec::new();
    body.reader
        .take(max + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| FeedError::Transport(e.to_string()))?;
    if bytes.len() as u64 > max {
        return Err(FeedError::TooLarge(what));
    }
    Ok(bytes)
}

/// Fetch `feed_url` and `feed_url + ".sig"`, verify, then parse and validate.
pub fn fetch_feed(
    transport: &dyn Transport,
    feed_url: &str,
    key: &PublicKey,
) -> Result<Feed, FeedError> {
    let bytes = read_bounded(transport, feed_url, MAX_FEED_BYTES, "feed")?;
    let signature = read_bounded(
        transport,
        &format!("{feed_url}.sig"),
        MAX_SIGNATURE_BYTES,
        "feed signature",
    )?;
    let signature =
        std::str::from_utf8(&signature).map_err(|_| FeedError::BadSignature("not UTF-8".into()))?;
    verify_and_parse(&bytes, signature, key)
}

pub fn verify_and_parse(
    feed_bytes: &[u8],
    signature_b64: &str,
    key: &PublicKey,
) -> Result<Feed, FeedError> {
    key.verify(feed_bytes, signature_b64)
        .map_err(|e| FeedError::BadSignature(e.to_string()))?;
    let feed: Feed =
        serde_json::from_slice(feed_bytes).map_err(|e| FeedError::Malformed(e.to_string()))?;
    validate(&feed)?;
    Ok(feed)
}

fn validate(feed: &Feed) -> Result<(), FeedError> {
    let bad = |m: String| Err(FeedError::Malformed(m));
    if feed.format != FORMAT {
        return bad(format!("unsupported format {:?}", feed.format));
    }
    if feed.releases.is_empty() || feed.releases.len() > MAX_RELEASES {
        return bad("release count out of range".into());
    }
    let mut builds = std::collections::BTreeSet::new();
    for release in &feed.releases {
        if release.build == 0 || !builds.insert(release.build) {
            return bad(format!("build {} is zero or duplicated", release.build));
        }
        if !is_path_safe(&release.version) || Version::parse(&release.version).is_err() {
            return bad(format!("bad version {:?}", release.version));
        }
        if let Some(url) = &release.notes_url {
            if !is_acceptable_url(url) {
                return bad("notes URL is not HTTPS".into());
            }
        }
        for (platform, artifact) in &release.artifacts {
            if platform.is_empty()
                || !platform
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
            {
                return bad(format!("bad platform key {platform:?}"));
            }
            if !is_sha256_hex(&artifact.sha256) {
                return bad(format!("bad sha256 for {platform}"));
            }
            if artifact.size == 0 {
                return bad(format!("zero size for {platform}"));
            }
        }
    }
    Ok(())
}

/// Decide what the signed `feed` means for this copy. `max_feed_build_seen` is persisted local state.
pub fn evaluate(
    feed: &Feed,
    platform: &Platform,
    installed: &Installed,
    max_feed_build_seen: u64,
) -> Result<Check, FeedError> {
    let newest = feed.releases.iter().map(|r| r.build).max().unwrap_or(0);
    if newest < max_feed_build_seen {
        return Err(FeedError::FeedRolledBack {
            seen: max_feed_build_seen,
            feed: newest,
        });
    }
    let Some(latest) = feed
        .releases
        .iter()
        .filter(|r| r.artifacts.contains_key(&platform.key))
        .max_by_key(|r| r.build)
    else {
        return Ok(Check::Unsupported {
            platform: platform.key.clone(),
        });
    };
    let installed_version =
        Version::parse(&installed.version).map_err(|e| FeedError::Malformed(e.to_string()))?;
    let latest_version =
        Version::parse(&latest.version).map_err(|e| FeedError::Malformed(e.to_string()))?;
    if latest.build < installed.build {
        return Err(FeedError::Downgrade {
            installed: installed.build,
            offered: latest.build,
        });
    }
    if latest.build == installed.build {
        return if latest_version == installed_version {
            Ok(Check::UpToDate)
        } else {
            Err(FeedError::BuildReused(latest.build))
        };
    }
    if latest_version < installed_version {
        return Err(FeedError::Downgrade {
            installed: installed.build,
            offered: latest.build,
        });
    }
    let artifact = latest.artifacts[&platform.key].clone();
    if !is_acceptable_url(&artifact.url) {
        return Err(FeedError::Rejected(format!(
            "artifact URL for build {} is not HTTPS",
            latest.build
        )));
    }
    if artifact.size > MAX_ARTIFACT_BYTES {
        return Err(FeedError::Rejected(format!(
            "artifact for build {} is {} bytes, over the {} byte limit",
            latest.build, artifact.size, MAX_ARTIFACT_BYTES
        )));
    }
    Ok(Check::Available(Offer {
        version: latest.version.clone(),
        build: latest.build,
        notes_url: latest.notes_url.clone(),
        published: latest.published.clone(),
        platform: platform.key.clone(),
        artifact,
    }))
}

#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;
    use crate::crypto::testing::TestKey;

    pub fn key() -> TestKey {
        TestKey::from_seed([42; 32])
    }
    pub fn linux() -> Platform {
        Platform::new("linux", "x86_64", ArchiveKind::TarGz)
    }
    /// `(version, build, Some((artifact url, artifact bytes)))` per release; `None` = no Linux artifact.
    #[allow(clippy::type_complexity)]
    pub fn feed_with(releases: Vec<(&str, u64, Option<(&str, &[u8])>)>) -> Feed {
        Feed {
            format: FORMAT.into(),
            generated: None,
            releases: releases
                .into_iter()
                .map(|(version, build, artifact)| Release {
                    version: version.into(),
                    build,
                    notes_url: None,
                    published: None,
                    artifacts: artifact
                        .into_iter()
                        .map(|(url, bytes)| {
                            (
                                "linux-x86_64".to_owned(),
                                Artifact {
                                    url: url.into(),
                                    sha256: sha256_hex(bytes),
                                    size: bytes.len() as u64,
                                },
                            )
                        })
                        .collect(),
                })
                .collect(),
        }
    }
    pub fn signed(feed: &Feed) -> (Vec<u8>, String) {
        let bytes = serde_json::to_vec(feed).unwrap();
        let sig = key().sign_b64(&bytes);
        (bytes, sig)
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;

    const URL: &str = "https://example.test/a.tar.gz";
    fn installed(version: &str, build: u64) -> Installed {
        Installed {
            version: version.into(),
            build,
        }
    }

    #[test]
    fn valid_signed_feed_offers_newer_build() {
        let feed = feed_with(vec![
            ("0.1.0", 5, Some((URL, b"old"))),
            ("0.2.0", 6, Some((URL, b"new"))),
        ]);
        let (bytes, sig) = signed(&feed);
        let parsed = verify_and_parse(&bytes, &sig, &key().public()).unwrap();
        match evaluate(&parsed, &linux(), &installed("0.1.0", 5), 0).unwrap() {
            Check::Available(offer) => {
                assert_eq!((offer.version.as_str(), offer.build), ("0.2.0", 6));
                assert_eq!(offer.artifact.sha256, sha256_hex(b"new"));
                assert_eq!(offer.confirmation_token().len(), 32);
            }
            other => panic!("{other:?}"),
        }
    }
    #[test]
    fn tampered_feed_and_wrong_key_are_rejected_before_parsing() {
        let feed = feed_with(vec![("0.2.0", 6, Some((URL, b"new")))]);
        let (mut bytes, sig) = signed(&feed);
        let middle = bytes.len() / 2;
        bytes[middle] ^= 1;
        assert!(matches!(
            verify_and_parse(&bytes, &sig, &key().public()),
            Err(FeedError::BadSignature(_))
        ));
        let (bytes, sig) = signed(&feed);
        let other = crate::crypto::testing::TestKey::from_seed([1; 32]).public();
        assert!(matches!(
            verify_and_parse(&bytes, &sig, &other),
            Err(FeedError::BadSignature(_))
        ));
        // Properly signed garbage is still malformed, not accepted.
        let garbage = b"{\"format\":\"nope\",\"releases\":[]}".to_vec();
        let sig = key().sign_b64(&garbage);
        assert!(matches!(
            verify_and_parse(&garbage, &sig, &key().public()),
            Err(FeedError::Malformed(_))
        ));
    }
    #[test]
    fn downgrade_and_build_reuse_are_refused() {
        let feed = feed_with(vec![("0.1.0", 4, Some((URL, b"x")))]);
        assert!(matches!(
            evaluate(&feed, &linux(), &installed("0.1.0", 5), 0),
            Err(FeedError::Downgrade {
                installed: 5,
                offered: 4
            })
        ));
        // Higher build but lower semantic version is also a downgrade.
        let feed = feed_with(vec![("0.1.0", 9, Some((URL, b"x")))]);
        assert!(matches!(
            evaluate(&feed, &linux(), &installed("0.2.0", 5), 0),
            Err(FeedError::Downgrade { .. })
        ));
        let feed = feed_with(vec![("0.1.1", 5, Some((URL, b"x")))]);
        assert!(matches!(
            evaluate(&feed, &linux(), &installed("0.1.0", 5), 0),
            Err(FeedError::BuildReused(5))
        ));
        let feed = feed_with(vec![("0.1.0", 5, Some((URL, b"x")))]);
        assert_eq!(
            evaluate(&feed, &linux(), &installed("0.1.0", 5), 0).unwrap(),
            Check::UpToDate
        );
    }
    #[test]
    fn replayed_older_feed_is_refused() {
        let feed = feed_with(vec![("0.1.0", 5, Some((URL, b"x")))]);
        assert!(matches!(
            evaluate(&feed, &linux(), &installed("0.1.0", 1), 9),
            Err(FeedError::FeedRolledBack { seen: 9, feed: 5 })
        ));
    }
    #[test]
    fn unsupported_platform_is_reported_not_guessed() {
        let feed = feed_with(vec![("0.2.0", 6, Some((URL, b"x")))]);
        let mac = Platform::new("macos", "aarch64", ArchiveKind::TarGz);
        assert_eq!(
            evaluate(&feed, &mac, &installed("0.1.0", 5), 0).unwrap(),
            Check::Unsupported {
                platform: "macos-aarch64".into()
            }
        );
        let none = feed_with(vec![("0.2.0", 6, None)]);
        assert!(matches!(
            evaluate(&none, &linux(), &installed("0.1.0", 5), 0).unwrap(),
            Check::Unsupported { .. }
        ));
    }
    #[test]
    fn rejects_http_oversize_and_bad_entries() {
        let feed = feed_with(vec![("0.2.0", 6, Some(("http://example.test/a", b"x")))]);
        assert!(matches!(
            evaluate(&feed, &linux(), &installed("0.1.0", 5), 0),
            Err(FeedError::Rejected(_))
        ));
        let mut feed = feed_with(vec![("0.2.0", 6, Some((URL, b"x")))]);
        feed.releases[0]
            .artifacts
            .get_mut("linux-x86_64")
            .unwrap()
            .size = MAX_ARTIFACT_BYTES + 1;
        assert!(matches!(
            evaluate(&feed, &linux(), &installed("0.1.0", 5), 0),
            Err(FeedError::Rejected(_))
        ));
        for mutate in [
            |f: &mut Feed| f.releases[0].version = "../../x".into(),
            |f: &mut Feed| f.releases[0].build = 0,
            |f: &mut Feed| {
                f.releases[0]
                    .artifacts
                    .get_mut("linux-x86_64")
                    .unwrap()
                    .sha256 = "ABC".into()
            },
            |f: &mut Feed| {
                f.releases[0]
                    .artifacts
                    .get_mut("linux-x86_64")
                    .unwrap()
                    .size = 0
            },
            |f: &mut Feed| f.format = "other".into(),
            |f: &mut Feed| f.releases.push(f.releases[0].clone()),
        ] {
            let mut feed = feed_with(vec![("0.2.0", 6, Some((URL, b"x")))]);
            mutate(&mut feed);
            let (bytes, sig) = signed(&feed);
            assert!(matches!(
                verify_and_parse(&bytes, &sig, &key().public()),
                Err(FeedError::Malformed(_))
            ));
        }
    }
    #[test]
    fn confirmation_token_changes_with_any_offer_field() {
        let feed = feed_with(vec![("0.2.0", 6, Some((URL, b"new")))]);
        let Check::Available(a) = evaluate(&feed, &linux(), &installed("0.1.0", 5), 0).unwrap()
        else {
            panic!()
        };
        let mut b = a.clone();
        b.artifact.sha256 = sha256_hex(b"other");
        let mut c = a.clone();
        c.build += 1;
        assert_ne!(a.confirmation_token(), b.confirmation_token());
        assert_ne!(a.confirmation_token(), c.confirmation_token());
    }
}
