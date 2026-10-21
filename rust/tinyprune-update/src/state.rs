//! Client-owned updater state and the `checkForNewVersions` setting, one small JSON file under the
//! install root. It mirrors the Swift app's semantics: the setting is read at use time, defaults to
//! ON when absent, controls only the automatic *check* (at most once a day), and never installs.
//! The agent never reads it (it has no network and no update logic).

use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub const AUTO_CHECK_INTERVAL_SECS: f64 = 24.0 * 60.0 * 60.0;

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    /// `None` = never set = on (Swift: absent key means enabled).
    #[serde(default)]
    pub check_for_new_versions: Option<bool>,
    #[serde(default)]
    pub last_check: Option<f64>,
    /// Highest build ever seen in a verified feed; a feed below it is refused (replay protection).
    #[serde(default)]
    pub max_feed_build_seen: u64,
    /// Version directory kept as the rollback target after the last successful update.
    #[serde(default)]
    pub previous: Option<String>,
}
impl State {
    pub fn checks_enabled(&self) -> bool {
        self.check_for_new_versions.unwrap_or(true)
    }
    pub fn auto_check_due(&self, now: f64) -> bool {
        self.checks_enabled()
            && self
                .last_check
                .is_none_or(|last| now - last >= AUTO_CHECK_INTERVAL_SECS || last > now)
    }
}

pub struct StateFile {
    path: PathBuf,
}
impl StateFile {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
    /// Missing file = defaults. A present-but-unreadable file is an error: silently resetting
    /// `maxFeedBuildSeen` would weaken rollback protection.
    pub fn load(&self) -> io::Result<State> {
        match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("update state is corrupt ({}): {e}", self.path.display()),
                )
            }),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(e),
        }
    }
    pub fn save(&self, state: &State) -> io::Result<()> {
        let dir: &Path = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "state path has no parent")
        })?;
        fs::create_dir_all(dir)?;
        let tmp = self.path.with_extension("json.tmp");
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(&serde_json::to_vec_pretty(state).map_err(io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(&tmp, &self.path)
    }
    /// Load, mutate, save.
    pub fn update(&self, change: impl FnOnce(&mut State)) -> io::Result<State> {
        let mut state = self.load()?;
        change(&mut state);
        self.save(&state)?;
        Ok(state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    #[test]
    fn defaults_on_and_checks_at_most_daily() {
        let state = State::default();
        assert!(state.checks_enabled());
        assert!(state.auto_check_due(1000.0));
        let state = State {
            last_check: Some(1000.0),
            ..State::default()
        };
        assert!(!state.auto_check_due(1000.0 + 3600.0));
        assert!(state.auto_check_due(1000.0 + AUTO_CHECK_INTERVAL_SECS));
        assert!(
            state.auto_check_due(10.0),
            "a clock set backwards does not suppress checks forever"
        );
        let off = State {
            check_for_new_versions: Some(false),
            ..State::default()
        };
        assert!(!off.checks_enabled());
        assert!(
            !off.auto_check_due(1e12),
            "disabled means no automatic check ever"
        );
    }
    #[test]
    fn roundtrip_and_corruption_is_an_error_not_a_reset() {
        let dir = TempDir::new();
        let file = StateFile::new(dir.path().join("update/state.json"));
        assert_eq!(file.load().unwrap(), State::default());
        let saved = file
            .update(|s| {
                s.max_feed_build_seen = 12;
                s.check_for_new_versions = Some(false);
                s.previous = Some("0.1.0-b1".into());
            })
            .unwrap();
        assert_eq!(file.load().unwrap(), saved);
        fs::write(dir.path().join("update/state.json"), b"{not json").unwrap();
        assert_eq!(file.load().unwrap_err().kind(), io::ErrorKind::InvalidData);
    }
}
