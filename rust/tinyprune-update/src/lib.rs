//! Unreleased updater for the Rust runtime (Linux/Windows). macOS keeps Sparkle. See ADR 0012.
//!
//! * `interlock`, `layout`, `version` (always built, std only): the Trash/update interlock the agent
//!   embeds, and the install layout the launcher resolves.
//! * everything else (feature `client`, default): signed-feed check, verified download, staged install,
//!   rollback and the `tinyprune update` command. It runs in the user's CLI/UI process, never in the
//!   agent, which has no network access.

pub mod interlock;
pub mod layout;
pub mod version;

#[cfg(feature = "client")]
pub mod archive;
#[cfg(feature = "client")]
pub mod build_info;
#[cfg(feature = "client")]
pub mod cli;
#[cfg(feature = "client")]
pub mod crypto;
#[cfg(feature = "client")]
pub mod download;
#[cfg(feature = "client")]
pub mod install;
#[cfg(feature = "client")]
pub mod manifest;
#[cfg(feature = "client")]
pub mod state;
#[cfg(feature = "client")]
pub mod system;
#[cfg(feature = "client")]
pub mod transport;
#[cfg(feature = "client")]
pub mod updater;

#[cfg(test)]
pub(crate) mod test_support {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};

    /// Unique directory under the system temp dir, removed on drop.
    pub struct TempDir(PathBuf);
    impl TempDir {
        pub fn new() -> Self {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let path = std::env::temp_dir().join(format!(
                "tinyprune-update-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        pub fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
