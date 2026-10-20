//! Check and confirmed-install orchestration on top of `manifest` and `install`.

use crate::build_info::{Disabled, Trust};
use crate::install::{self, InstallContext, InstallError, Installation};
use crate::layout::Layout;
use crate::manifest::{self, Check, FeedError, Offer, Platform};
use crate::state::StateFile;
use crate::transport::Transport;
use std::path::Path;

#[derive(Debug)]
pub enum UpdateError {
    Disabled(Disabled),
    Feed(FeedError),
    Install(InstallError),
    /// `install` was asked to proceed but the signed feed no longer offers what the user confirmed.
    ConfirmationMismatch,
    /// Nothing newer is available.
    NothingToInstall,
    State(String),
}
impl std::fmt::Display for UpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Disabled(d) => d.fmt(f),
            Self::Feed(e) => e.fmt(f),
            Self::Install(e) => e.fmt(f),
            Self::ConfirmationMismatch => f.write_str("the confirmation token does not match the current signed offer; run `tinyprune update check` again and confirm the offer you want"),
            Self::NothingToInstall => f.write_str("there is no newer build to install"),
            Self::State(m) => write!(f, "could not read or write update state: {m}"),
        }
    }
}
impl std::error::Error for UpdateError {}

/// True only for a binary that lives under `<root>/versions/`. Package-manager copies (`/usr/bin`,
/// Homebrew, WinGet, ...) and hand-copied binaries are never touched.
pub fn is_managed(layout: &Layout, exe: &Path) -> bool {
    let (Ok(exe), Ok(versions)) = (exe.canonicalize(), layout.versions().canonicalize()) else {
        return false;
    };
    exe.starts_with(&versions)
}

pub struct Updater<'a> {
    pub layout: &'a Layout,
    pub transport: &'a dyn Transport,
    pub trust: &'a Trust,
    pub platform: Option<Platform>,
    pub state: StateFile,
}

impl Updater<'_> {
    fn platform(&self) -> Result<&Platform, UpdateError> {
        self.platform
            .as_ref()
            .ok_or(UpdateError::Disabled(Disabled::UnsupportedOs))
    }

    /// Fetch, verify and evaluate the signed feed. Records the check time and the highest verified
    /// build (replay protection) only for a feed that passed every check.
    pub fn check(&self, now: f64) -> Result<Check, UpdateError> {
        let platform = self.platform()?;
        let state = self
            .state
            .load()
            .map_err(|e| UpdateError::State(e.to_string()))?;
        let feed = manifest::fetch_feed(self.transport, &self.trust.feed_url, &self.trust.key)
            .map_err(UpdateError::Feed)?;
        let check = manifest::evaluate(
            &feed,
            platform,
            &self.trust.installed,
            state.max_feed_build_seen,
        )
        .map_err(UpdateError::Feed)?;
        let newest = feed.releases.iter().map(|r| r.build).max().unwrap_or(0);
        self.state
            .update(|s| {
                s.max_feed_build_seen = s.max_feed_build_seen.max(newest);
                s.last_check = Some(now);
            })
            .map_err(|e| UpdateError::State(e.to_string()))?;
        Ok(check)
    }

    /// Install only if a fresh, verified feed still offers exactly what `confirmation` names.
    pub fn install_confirmed<'p>(
        &self,
        confirmation: &str,
        now: f64,
        parts: impl FnOnce(&Offer) -> InstallParts<'p>,
    ) -> Result<Installation, UpdateError> {
        let offer = match self.check(now)? {
            Check::Available(offer) => offer,
            Check::Unsupported { .. } => {
                return Err(UpdateError::Disabled(Disabled::UnsupportedOs))
            }
            Check::UpToDate => return Err(UpdateError::NothingToInstall),
        };
        if !constant_time_eq(
            offer.confirmation_token().as_bytes(),
            confirmation.trim().as_bytes(),
        ) {
            return Err(UpdateError::ConfirmationMismatch);
        }
        let parts = parts(&offer);
        let ctx = InstallContext {
            layout: self.layout,
            fs: parts.fs,
            transport: self.transport,
            platform: self.platform()?,
            installed: &self.trust.installed,
            daemon: parts.daemon,
            restarter: parts.restarter,
            checker: parts.checker,
            sleeper: parts.sleeper,
            state: &self.state,
            limits: crate::archive::Limits::default(),
            lease: InstallContext::DEFAULT_LEASE,
            drain_timeout: InstallContext::DEFAULT_DRAIN,
            min_lease_remaining: InstallContext::DEFAULT_MIN_LEASE,
            health_timeout: InstallContext::DEFAULT_HEALTH,
            poll_interval: InstallContext::DEFAULT_POLL,
        };
        install::install(&ctx, &offer).map_err(UpdateError::Install)
    }
}

/// The side-effecting collaborators of an install (real ones in `system`; fakes in tests).
pub struct InstallParts<'a> {
    pub fs: &'a dyn crate::layout::InstallFs,
    pub daemon: &'a dyn install::DaemonControl,
    pub restarter: &'a dyn install::Restarter,
    pub checker: &'a dyn install::SelfCheck,
    pub sleeper: &'a dyn install::Sleeper,
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::testing::TestKey;
    use crate::download::testing::{FakeTransport, Route};
    use crate::manifest::fixtures::{feed_with, linux, signed};
    use crate::manifest::Installed;
    use crate::test_support::TempDir;

    const FEED: &str = "https://updates.example/feed.json";
    const ART: &str = "https://updates.example/a.tar.gz";

    struct Rig {
        dir: TempDir,
        layout: Layout,
        transport: FakeTransport,
        trust: Trust,
    }
    fn rig(installed_build: u64) -> Rig {
        let dir = TempDir::new();
        let layout = Layout::new(dir.path().join("tinyprune"));
        let trust = Trust {
            installed: Installed {
                version: "0.1.0".into(),
                build: installed_build,
            },
            key: TestKey::from_seed([42; 32]).public(),
            feed_url: FEED.into(),
            allow_loopback_http: false,
        };
        Rig {
            dir,
            layout,
            transport: FakeTransport::default(),
            trust,
        }
    }
    fn serve(rig: &Rig, bytes: &[u8], sig: &str) {
        rig.transport.set(FEED, Route::ok(bytes));
        rig.transport
            .set(&format!("{FEED}.sig"), Route::ok(sig.as_bytes()));
    }
    fn updater(rig: &Rig) -> Updater<'_> {
        Updater {
            layout: &rig.layout,
            transport: &rig.transport,
            trust: &rig.trust,
            platform: Some(linux()),
            state: StateFile::new(rig.layout.state_file()),
        }
    }

    #[test]
    fn check_offers_newer_build_and_records_state() {
        let r = rig(1);
        let (bytes, sig) = signed(&feed_with(vec![("0.2.0", 2, Some((ART, b"new")))]));
        serve(&r, &bytes, &sig);
        let u = updater(&r);
        assert!(matches!(u.check(1000.0).unwrap(), Check::Available(o) if o.build == 2));
        let s = u.state.load().unwrap();
        assert_eq!((s.max_feed_build_seen, s.last_check), (2, Some(1000.0)));
        // Only plain GETs of the feed and its signature were made.
        assert_eq!(
            *r.transport.requests.lock().unwrap(),
            [FEED.to_string(), format!("{FEED}.sig")]
        );
        let _ = &r.dir;
    }
    #[test]
    fn tampered_feed_is_rejected_and_state_is_untouched() {
        let r = rig(1);
        let (mut bytes, sig) = signed(&feed_with(vec![("9.9.9", 99, Some((ART, b"evil")))]));
        let at = bytes.len() / 3;
        bytes[at] ^= 1;
        serve(&r, &bytes, &sig);
        let u = updater(&r);
        assert!(matches!(
            u.check(1.0),
            Err(UpdateError::Feed(FeedError::BadSignature(_)))
        ));
        assert_eq!(
            u.state.load().unwrap().max_feed_build_seen,
            0,
            "a rejected feed never moves the replay floor"
        );
    }
    #[test]
    fn replayed_older_feed_and_downgrade_are_refused() {
        let r = rig(1);
        let (b2, s2) = signed(&feed_with(vec![("0.2.0", 2, Some((ART, b"new")))]));
        serve(&r, &b2, &s2);
        let u = updater(&r);
        u.check(1.0).unwrap();
        // An attacker (or stale mirror) now serves the older, validly signed feed.
        let (b1, s1) = signed(&feed_with(vec![("0.1.0", 1, Some((ART, b"old")))]));
        serve(&r, &b1, &s1);
        assert!(matches!(
            u.check(2.0),
            Err(UpdateError::Feed(FeedError::FeedRolledBack { .. }))
        ));
        // Installed newer than anything the feed offers.
        let newer = rig(7);
        serve(&newer, &b1, &s1);
        assert!(matches!(
            updater(&newer).check(1.0),
            Err(UpdateError::Feed(FeedError::Downgrade { .. }))
        ));
    }
    #[test]
    fn unsupported_platform_and_disabled_os() {
        let r = rig(1);
        let (bytes, sig) = signed(&feed_with(vec![("0.2.0", 2, None)]));
        serve(&r, &bytes, &sig);
        assert!(matches!(
            updater(&r).check(1.0).unwrap(),
            Check::Unsupported { .. }
        ));
        let mut u = updater(&r);
        u.platform = None;
        assert!(matches!(
            u.check(1.0),
            Err(UpdateError::Disabled(Disabled::UnsupportedOs))
        ));
    }
    #[test]
    fn oversize_feed_and_signature_are_refused() {
        let r = rig(1);
        r.transport.set(
            FEED,
            Route::ok(&vec![b' '; (manifest::MAX_FEED_BYTES + 1) as usize]),
        );
        r.transport.set(&format!("{FEED}.sig"), Route::ok(b"x"));
        assert!(matches!(
            updater(&r).check(1.0),
            Err(UpdateError::Feed(FeedError::TooLarge(_)))
        ));
        let (bytes, _) = signed(&feed_with(vec![("0.2.0", 2, Some((ART, b"new")))]));
        r.transport.set(FEED, Route::ok(&bytes));
        r.transport
            .set(&format!("{FEED}.sig"), Route::ok(&vec![b'A'; 4096]));
        assert!(matches!(
            updater(&r).check(1.0),
            Err(UpdateError::Feed(FeedError::TooLarge(_)))
        ));
    }
    #[test]
    fn network_failure_is_reported_not_swallowed() {
        let r = rig(1);
        assert!(matches!(
            updater(&r).check(1.0),
            Err(UpdateError::Feed(FeedError::Transport(_)))
        ));
    }
    #[test]
    fn install_requires_the_exact_confirmation_token_before_anything_else() {
        let r = rig(1);
        let (bytes, sig) = signed(&feed_with(vec![("0.2.0", 2, Some((ART, b"new")))]));
        serve(&r, &bytes, &sig);
        let u = updater(&r);
        let panics =
            |_: &Offer| -> InstallParts<'static> { panic!("no side effects before confirmation") };
        assert!(matches!(
            u.install_confirmed("", 1.0, panics),
            Err(UpdateError::ConfirmationMismatch)
        ));
        assert!(matches!(
            u.install_confirmed("0123456789abcdef0123456789abcdef", 1.0, panics),
            Err(UpdateError::ConfirmationMismatch)
        ));
        assert!(
            !r.transport
                .requests
                .lock()
                .unwrap()
                .iter()
                .any(|u| u == ART),
            "artifact never downloaded without confirmation"
        );
        // A confirmation for a different offer (e.g. an earlier build) no longer matches.
        let Check::Available(offer) = u.check(1.0).unwrap() else {
            panic!()
        };
        let mut stale = offer.clone();
        stale.build = 1;
        assert!(matches!(
            u.install_confirmed(&stale.confirmation_token(), 1.0, panics),
            Err(UpdateError::ConfirmationMismatch)
        ));
    }
    #[test]
    fn up_to_date_has_nothing_to_install() {
        let r = rig(2);
        let (bytes, sig) = signed(&feed_with(vec![("0.1.0", 2, Some((ART, b"x")))]));
        serve(&r, &bytes, &sig);
        let panics = |_: &Offer| -> InstallParts<'static> { panic!() };
        assert!(matches!(
            updater(&r).install_confirmed("x", 1.0, panics),
            Err(UpdateError::NothingToInstall)
        ));
    }
    #[test]
    fn managed_detection_only_accepts_binaries_under_versions() {
        let r = rig(1);
        let inside = r.layout.version_path("0.1.0-b1/bin");
        std::fs::create_dir_all(&inside).unwrap();
        std::fs::write(inside.join("tinyprune"), "x").unwrap();
        let outside = r.dir.path().join("homebrew-bin");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("tinyprune"), "x").unwrap();
        assert!(is_managed(&r.layout, &inside.join("tinyprune")));
        assert!(!is_managed(&r.layout, &outside.join("tinyprune")));
        assert!(!is_managed(
            &r.layout,
            Path::new("/usr/bin/definitely-not-here")
        ));
    }
}
