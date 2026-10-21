//! Versioned install layout and the atomic "current" pointer.
//!
//! ```text
//! <root>/versions/<version>-b<build>/{bin,share,VERSION}   one directory per installed build
//! <root>/current                                           Linux: symlink -> versions/<name> (relative)
//!                                                          Windows: text file holding <name>
//! <root>/update/                                           downloads, staging, state.json
//! ```
//! `<root>` is the per-user data directory (Linux `${XDG_DATA_HOME:-~/.local/share}/tinyprune`,
//! Windows `%LOCALAPPDATA%\TinyPrune`). The service and shims resolve `current`, so a swap is one
//! atomic rename. A running Windows executable cannot be overwritten or deleted, so a new build is
//! always staged side by side and only the pointer moves; `tinyprune-launcher` resolves it at start.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const VERSIONS: &str = "versions";
pub const CURRENT: &str = "current";
pub const UPDATE_DIR: &str = "update";

pub fn version_dir_name(version: &str, build: u64) -> String {
    format!("{version}-b{build}")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PointerKind {
    /// Atomic rename of a symlink over `current` (Unix).
    Symlink,
    /// Atomic rename of a small text file over `current` (Windows, where symlinks need privilege).
    File,
}
impl PointerKind {
    pub fn native() -> Self {
        if cfg!(windows) {
            Self::File
        } else {
            Self::Symlink
        }
    }
}

#[derive(Debug, Clone)]
pub struct Layout {
    pub root: PathBuf,
}
impl Layout {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
    pub fn from_environment() -> io::Result<Self> {
        let missing = || io::Error::new(io::ErrorKind::NotFound, "user data directory unavailable");
        #[cfg(windows)]
        let root =
            PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(missing)?).join("TinyPrune");
        #[cfg(target_os = "macos")]
        let root = PathBuf::from(std::env::var_os("HOME").ok_or_else(missing)?)
            .join("Library/Application Support/TinyPrune");
        #[cfg(all(unix, not(target_os = "macos")))]
        let root = match std::env::var_os("XDG_DATA_HOME") {
            Some(v) if Path::new(&v).is_absolute() => PathBuf::from(v),
            _ => PathBuf::from(std::env::var_os("HOME").ok_or_else(missing)?).join(".local/share"),
        }
        .join("tinyprune");
        Ok(Self { root })
    }
    pub fn versions(&self) -> PathBuf {
        self.root.join(VERSIONS)
    }
    pub fn current(&self) -> PathBuf {
        self.root.join(CURRENT)
    }
    pub fn update_dir(&self) -> PathBuf {
        self.root.join(UPDATE_DIR)
    }
    pub fn state_file(&self) -> PathBuf {
        self.update_dir().join("state.json")
    }
    pub fn version_path(&self, name: &str) -> PathBuf {
        self.versions().join(name)
    }
}

/// Everything the swap logic needs from a filesystem. The real implementation is [`StdFs`]; tests use
/// an in-memory model with Windows semantics (locked running directories, no overwrite).
pub trait InstallFs {
    fn create_dir_all(&self, path: &Path) -> io::Result<()>;
    fn is_dir(&self, path: &Path) -> bool;
    /// Move a directory to a path that does not exist; must fail if `to` exists.
    fn rename_dir(&self, from: &Path, to: &Path) -> io::Result<()>;
    fn remove_dir_all(&self, path: &Path) -> io::Result<()>;
    /// Names of directories directly inside `dir` (missing dir = empty).
    fn list_dirs(&self, dir: &Path) -> io::Result<Vec<String>>;
    /// Version directory name `current` points at; `None` if there is no pointer.
    fn read_current(&self, layout: &Layout) -> io::Result<Option<String>>;
    /// Atomically repoint `current` at an existing `versions/<name>`.
    fn set_current(&self, layout: &Layout, name: &str) -> io::Result<()>;
}

/// Windows error codes that mean "somebody has the file open right now": ACCESS_DENIED, SHARING_VIOLATION,
/// LOCK_VIOLATION. Virus scanners and indexers hold freshly written files and directories for a moment,
/// and a rename (a directory move, or the pointer replace) fails until they let go.
pub(crate) fn is_transient_sharing_error(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(5 | 32 | 33))
}

/// Run `op`, retrying a transient sharing error up to `attempts` times with `delay` between tries.
/// Any other error, or the last transient one, is returned unchanged.
pub(crate) fn retry_transient<T>(
    attempts: u32,
    delay: std::time::Duration,
    mut op: impl FnMut() -> io::Result<T>,
) -> io::Result<T> {
    let mut tries = 0;
    loop {
        match op() {
            Err(e) if tries < attempts && is_transient_sharing_error(&e) => {
                tries += 1;
                std::thread::sleep(delay);
            }
            other => return other,
        }
    }
}

/// `fs::rename`, retried on Windows only (elsewhere those codes mean something else and are real).
fn rename_retrying(from: &Path, to: &Path) -> io::Result<()> {
    if cfg!(windows) {
        retry_transient(40, std::time::Duration::from_millis(100), || {
            fs::rename(from, to)
        })
    } else {
        fs::rename(from, to)
    }
}

pub struct StdFs {
    pub pointer: PointerKind,
}
impl StdFs {
    pub fn native() -> Self {
        Self {
            pointer: PointerKind::native(),
        }
    }
}
impl InstallFs for StdFs {
    fn create_dir_all(&self, path: &Path) -> io::Result<()> {
        fs::create_dir_all(path)
    }
    fn is_dir(&self, path: &Path) -> bool {
        fs::symlink_metadata(path)
            .map(|m| m.is_dir())
            .unwrap_or(false)
    }
    fn rename_dir(&self, from: &Path, to: &Path) -> io::Result<()> {
        // rename(2) would silently replace an empty directory; refuse so a name is never reused.
        if fs::symlink_metadata(to).is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "destination exists",
            ));
        }
        rename_retrying(from, to)
    }
    fn remove_dir_all(&self, path: &Path) -> io::Result<()> {
        fs::remove_dir_all(path)
    }
    fn list_dirs(&self, dir: &Path) -> io::Result<Vec<String>> {
        let entries = match fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(e),
        };
        let mut names = vec![];
        for entry in entries {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                if let Some(name) = entry.file_name().to_str() {
                    names.push(name.to_owned());
                }
            }
        }
        names.sort();
        Ok(names)
    }
    fn read_current(&self, layout: &Layout) -> io::Result<Option<String>> {
        let current = layout.current();
        let meta = match fs::symlink_metadata(&current) {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
        let name = match self.pointer {
            PointerKind::Symlink => {
                if !meta.file_type().is_symlink() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "`current` is not a symlink",
                    ));
                }
                let target = fs::read_link(&current)?;
                target
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(str::to_owned)
            }
            PointerKind::File => {
                if !meta.is_file() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "`current` is not a file",
                    ));
                }
                Some(fs::read_to_string(&current)?.trim().to_owned())
            }
        };
        name.filter(|n| crate::version::is_path_safe(n))
            .map(Some)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "`current` names no valid version",
                )
            })
    }
    fn set_current(&self, layout: &Layout, name: &str) -> io::Result<()> {
        if !crate::version::is_path_safe(name) || !self.is_dir(&layout.version_path(name)) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "version directory does not exist",
            ));
        }
        let tmp = layout.root.join(format!("{CURRENT}.new"));
        let _ = fs::remove_file(&tmp);
        match self.pointer {
            PointerKind::Symlink => {
                #[cfg(unix)]
                std::os::unix::fs::symlink(Path::new(VERSIONS).join(name), &tmp)?;
                #[cfg(not(unix))]
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "symlink pointer needs Unix",
                ));
            }
            PointerKind::File => {
                use std::io::Write;
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&tmp)?;
                file.write_all(name.as_bytes())?;
                file.write_all(b"\n")?;
                file.sync_all()?;
            }
        }
        // One rename replaces the old pointer; readers see the old or the new target, never neither.
        // (std's Windows rename uses MoveFileExW with MOVEFILE_REPLACE_EXISTING.)
        let result = rename_retrying(&tmp, &layout.current());
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }
}

#[derive(Debug)]
pub enum SwapError {
    /// A directory for this build already exists and is the live one.
    AlreadyCurrent(String),
    Io(String),
}
impl std::fmt::Display for SwapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AlreadyCurrent(n) => write!(f, "version {n} is already the current install"),
            Self::Io(m) => write!(f, "install swap failed: {m}"),
        }
    }
}
impl std::error::Error for SwapError {}
fn io_err(e: io::Error) -> SwapError {
    SwapError::Io(e.to_string())
}

/// Move a fully staged and self-checked directory into `versions/<name>`.
pub fn place(
    fs: &dyn InstallFs,
    layout: &Layout,
    staged: &Path,
    name: &str,
) -> Result<(), SwapError> {
    fs.create_dir_all(&layout.versions()).map_err(io_err)?;
    let target = layout.version_path(name);
    if fs.is_dir(&target) {
        if fs.read_current(layout).map_err(io_err)?.as_deref() == Some(name) {
            return Err(SwapError::AlreadyCurrent(name.to_owned()));
        }
        // A leftover from an interrupted earlier attempt; it is not live.
        fs.remove_dir_all(&target).map_err(io_err)?;
    }
    fs.rename_dir(staged, &target).map_err(io_err)
}

/// Atomically make `name` current. Returns the previous pointer target.
pub fn activate(
    fs: &dyn InstallFs,
    layout: &Layout,
    name: &str,
) -> Result<Option<String>, SwapError> {
    let previous = fs.read_current(layout).map_err(io_err)?;
    fs.set_current(layout, name).map_err(io_err)?;
    Ok(previous)
}

/// Remove every installed version except the ones in `keep`. Best effort: a directory that cannot be
/// removed (on Windows, one whose executable is still running) is reported, never fatal.
pub fn prune(fs: &dyn InstallFs, layout: &Layout, keep: &[&str]) -> Vec<(String, String)> {
    let mut failed = vec![];
    let Ok(names) = fs.list_dirs(&layout.versions()) else {
        return failed;
    };
    for name in names {
        if keep.contains(&name.as_str()) {
            continue;
        }
        if let Err(e) = fs.remove_dir_all(&layout.version_path(&name)) {
            failed.push((name, e.to_string()));
        }
    }
    failed
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use std::collections::BTreeSet;
    use std::sync::Mutex;

    /// In-memory filesystem with Windows semantics: no overwrite on rename, directories in `locked`
    /// (a running exe) cannot be removed or replaced, and a failure can be injected into the pointer swap.
    #[derive(Default)]
    pub struct FakeWindowsFs {
        pub state: Mutex<FakeState>,
    }
    #[derive(Default)]
    pub struct FakeState {
        pub dirs: BTreeSet<PathBuf>,
        pub pointer: Option<String>,
        pub pointer_history: Vec<String>,
        pub locked: BTreeSet<String>,
        pub fail_set_current: bool,
    }
    impl FakeWindowsFs {
        pub fn with_installed(layout: &Layout, names: &[&str], current: Option<&str>) -> Self {
            let fs = Self::default();
            {
                let mut s = fs.state.lock().unwrap();
                s.dirs.insert(layout.versions());
                for n in names {
                    s.dirs.insert(layout.version_path(n));
                }
                s.pointer = current.map(str::to_owned);
            }
            fs
        }
        pub fn lock(&self, name: &str) {
            self.state.lock().unwrap().locked.insert(name.to_owned());
        }
        pub fn names(&self, layout: &Layout) -> Vec<String> {
            self.list_dirs(&layout.versions()).unwrap()
        }
    }
    fn denied() -> io::Error {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "file is in use by another process",
        )
    }
    impl InstallFs for FakeWindowsFs {
        fn create_dir_all(&self, path: &Path) -> io::Result<()> {
            self.state.lock().unwrap().dirs.insert(path.to_owned());
            Ok(())
        }
        fn is_dir(&self, path: &Path) -> bool {
            self.state.lock().unwrap().dirs.contains(path)
        }
        fn rename_dir(&self, from: &Path, to: &Path) -> io::Result<()> {
            let mut s = self.state.lock().unwrap();
            if s.dirs.contains(to) {
                return Err(io::Error::new(io::ErrorKind::AlreadyExists, "exists"));
            }
            if !s.dirs.remove(from) {
                return Err(io::Error::new(io::ErrorKind::NotFound, "missing"));
            }
            s.dirs.insert(to.to_owned());
            Ok(())
        }
        fn remove_dir_all(&self, path: &Path) -> io::Result<()> {
            let mut s = self.state.lock().unwrap();
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| s.locked.contains(n))
            {
                return Err(denied());
            }
            s.dirs.remove(path);
            Ok(())
        }
        fn list_dirs(&self, dir: &Path) -> io::Result<Vec<String>> {
            let s = self.state.lock().unwrap();
            Ok(s.dirs
                .iter()
                .filter(|d| d.parent() == Some(dir))
                .filter_map(|d| d.file_name()?.to_str().map(str::to_owned))
                .collect())
        }
        fn read_current(&self, _: &Layout) -> io::Result<Option<String>> {
            Ok(self.state.lock().unwrap().pointer.clone())
        }
        fn set_current(&self, layout: &Layout, name: &str) -> io::Result<()> {
            let mut s = self.state.lock().unwrap();
            if s.fail_set_current {
                return Err(denied());
            }
            if !s.dirs.contains(&layout.version_path(name)) {
                return Err(io::Error::new(io::ErrorKind::NotFound, "no such version"));
            }
            s.pointer = Some(name.to_owned());
            s.pointer_history.push(name.to_owned());
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::FakeWindowsFs;
    use super::*;
    use crate::test_support::TempDir;

    fn layout() -> Layout {
        Layout::new(r"C:\Users\u\AppData\Local\TinyPrune")
    }

    #[test]
    fn transient_sharing_errors_are_retried_and_real_errors_are_not() {
        use std::time::Duration;
        for code in [5, 32, 33] {
            let mut failures = 3;
            let result = retry_transient(5, Duration::ZERO, || {
                if failures > 0 {
                    failures -= 1;
                    Err(io::Error::from_raw_os_error(code))
                } else {
                    Ok(7)
                }
            });
            assert_eq!(result.unwrap(), 7, "code {code}");
        }
        // Gives up after the budget, returning the last error.
        let mut calls = 0;
        let err = retry_transient::<()>(2, Duration::ZERO, || {
            calls += 1;
            Err(io::Error::from_raw_os_error(32))
        })
        .unwrap_err();
        assert_eq!((calls, err.raw_os_error()), (3, Some(32)));
        // A genuine error is returned at once.
        let mut calls = 0;
        let err = retry_transient::<()>(5, Duration::ZERO, || {
            calls += 1;
            Err(io::Error::from_raw_os_error(2))
        })
        .unwrap_err();
        assert_eq!((calls, err.raw_os_error()), (1, Some(2)));
    }

    // --- Windows swap logic, against the abstract filesystem ---
    #[test]
    fn windows_swap_stages_side_by_side_while_old_exe_is_locked() {
        let l = layout();
        let fs = FakeWindowsFs::with_installed(&l, &["0.1.0-b1"], Some("0.1.0-b1"));
        fs.lock("0.1.0-b1"); // the running daemon/CLI
        let staged = l.versions().join(".stage-abc");
        fs.create_dir_all(&staged).unwrap();
        place(&fs, &l, &staged, "0.2.0-b2").unwrap();
        let previous = activate(&fs, &l, "0.2.0-b2").unwrap();
        assert_eq!(previous.as_deref(), Some("0.1.0-b1"));
        assert_eq!(fs.read_current(&l).unwrap().as_deref(), Some("0.2.0-b2"));
        assert_eq!(
            fs.names(&l),
            ["0.1.0-b1", "0.2.0-b2"],
            "old build stays intact for rollback"
        );
    }
    #[test]
    fn windows_pointer_failure_leaves_the_old_build_current() {
        let l = layout();
        let fs = FakeWindowsFs::with_installed(&l, &["0.1.0-b1", "0.2.0-b2"], Some("0.1.0-b1"));
        fs.state.lock().unwrap().fail_set_current = true;
        assert!(activate(&fs, &l, "0.2.0-b2").is_err());
        assert_eq!(fs.read_current(&l).unwrap().as_deref(), Some("0.1.0-b1"));
    }
    #[test]
    fn windows_prune_skips_locked_directories_without_failing() {
        let l = layout();
        let fs = FakeWindowsFs::with_installed(
            &l,
            &["0.0.9-b0", "0.1.0-b1", "0.2.0-b2"],
            Some("0.2.0-b2"),
        );
        fs.lock("0.0.9-b0");
        let failed = prune(&fs, &l, &["0.2.0-b2", "0.1.0-b1"]);
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].0, "0.0.9-b0");
        assert_eq!(fs.names(&l), ["0.0.9-b0", "0.1.0-b1", "0.2.0-b2"]);
    }
    #[test]
    fn place_refuses_live_name_and_replaces_stale_leftover() {
        let l = layout();
        let fs = FakeWindowsFs::with_installed(&l, &["0.2.0-b2", "0.3.0-b3"], Some("0.3.0-b3"));
        let staged = l.versions().join(".stage-1");
        fs.create_dir_all(&staged).unwrap();
        assert!(matches!(
            place(&fs, &l, &staged, "0.3.0-b3"),
            Err(SwapError::AlreadyCurrent(_))
        ));
        place(&fs, &l, &staged, "0.2.0-b2").unwrap(); // stale, not live
        assert!(!fs.is_dir(&staged));
    }

    // --- Real filesystem (Unix symlink pointer; file pointer works on any OS) ---
    fn real_roundtrip(kind: PointerKind) {
        let dir = TempDir::new();
        let l = Layout::new(dir.path().join("tinyprune"));
        let fs = StdFs { pointer: kind };
        for name in ["0.1.0-b1", "0.2.0-b2"] {
            fs.create_dir_all(&l.version_path(name)).unwrap();
        }
        assert_eq!(fs.read_current(&l).unwrap(), None);
        assert_eq!(activate(&fs, &l, "0.1.0-b1").unwrap(), None);
        assert_eq!(
            activate(&fs, &l, "0.2.0-b2").unwrap().as_deref(),
            Some("0.1.0-b1")
        );
        assert_eq!(fs.read_current(&l).unwrap().as_deref(), Some("0.2.0-b2"));
        assert!(
            !l.root.join("current.new").exists(),
            "temp pointer cleaned up"
        );
        assert!(
            fs.set_current(&l, "9.9.9-b9").is_err(),
            "cannot point at a missing build"
        );
        assert!(fs.set_current(&l, "../escape").is_err());
        assert_eq!(fs.read_current(&l).unwrap().as_deref(), Some("0.2.0-b2"));
    }
    #[test]
    fn file_pointer_swap_on_real_fs() {
        real_roundtrip(PointerKind::File);
    }
    #[cfg(unix)]
    #[test]
    fn symlink_pointer_swap_is_atomic_and_relative() {
        real_roundtrip(PointerKind::Symlink);
        let dir = TempDir::new();
        let l = Layout::new(dir.path().join("tp"));
        let fs = StdFs {
            pointer: PointerKind::Symlink,
        };
        fs.create_dir_all(&l.version_path("1.0.0-b1")).unwrap();
        fs.set_current(&l, "1.0.0-b1").unwrap();
        assert_eq!(
            std::fs::read_link(l.current()).unwrap(),
            Path::new("versions/1.0.0-b1")
        );
    }
    // Linux only: rename(2) over a symlink is atomic for readers per POSIX and on Linux filesystems, but
    // macOS/APFS transiently answers EINVAL (observed). The updater only targets Linux and Windows.
    #[cfg(target_os = "linux")]
    #[test]
    fn symlink_swap_never_exposes_a_missing_pointer_under_concurrent_reads() {
        let dir = TempDir::new();
        let l = Layout::new(dir.path().join("tp"));
        let fs = StdFs {
            pointer: PointerKind::Symlink,
        };
        for n in ["a-b1", "b-b2"] {
            fs.create_dir_all(&l.version_path(n)).unwrap();
        }
        fs.set_current(&l, "a-b1").unwrap();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (s2, cur) = (stop.clone(), l.current());
        let reader = std::thread::spawn(move || {
            let mut reads = 0u32;
            while !s2.load(std::sync::atomic::Ordering::Relaxed) {
                if let Err(e) = std::fs::read_link(&cur) {
                    panic!("pointer vanished during swap: {e:?}");
                }
                reads += 1;
            }
            reads
        });
        for i in 0..300 {
            fs.set_current(&l, if i % 2 == 0 { "b-b2" } else { "a-b1" })
                .unwrap();
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        assert!(reader.join().unwrap() > 0);
    }
    #[cfg(unix)]
    #[test]
    fn read_current_rejects_a_real_directory_and_hostile_symlink() {
        let dir = TempDir::new();
        let l = Layout::new(dir.path().join("tp"));
        let fs = StdFs {
            pointer: PointerKind::Symlink,
        };
        std::fs::create_dir_all(l.current()).unwrap();
        assert!(
            fs.read_current(&l).is_err(),
            "legacy non-symlink `current` is not managed"
        );
        std::fs::remove_dir(l.current()).unwrap();
        std::os::unix::fs::symlink("versions/..", l.current()).unwrap();
        assert!(fs.read_current(&l).is_err());
    }
    #[test]
    fn std_fs_rename_refuses_existing_destination_and_prune_removes_old() {
        let dir = TempDir::new();
        let l = Layout::new(dir.path().join("tp"));
        let fs = StdFs {
            pointer: PointerKind::File,
        };
        for n in ["a-b1", "b-b2", "c-b3"] {
            fs.create_dir_all(&l.version_path(n)).unwrap();
        }
        assert!(fs
            .rename_dir(&l.version_path("a-b1"), &l.version_path("b-b2"))
            .is_err());
        assert!(prune(&fs, &l, &["c-b3", "b-b2"]).is_empty());
        assert_eq!(fs.list_dirs(&l.versions()).unwrap(), ["b-b2", "c-b3"]);
    }
}
