//! Unreleased Unix metadata and freedesktop Trash adapter; not a platform agent.
#![cfg(unix)]

mod identity;

use std::ffi::CString;
use std::fs::{self, Metadata, OpenOptions};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tinyprune_core::resolve::{keep_covers, keep_protects_descendant, ItemPolicyOverride};
use tinyprune_core::rule::{CandidateTimestamps, FilesystemIdentity, ItemKind, RuleCandidate};
use tinyprune_core::trash::{DescendantProtection, FileAccess, WalkBudget};

pub struct UnixFileAccess {
    home_trash: PathBuf,
}

/// ctime is metadata-change time, not creation or indexed activity time.
pub struct UnixInspection {
    pub candidate: RuleCandidate,
    pub changed_at: f64,
}

impl UnixFileAccess {
    /// Inject the home Trash root (containing `files` and `info`), even in tests.
    pub fn new(home_trash: impl Into<PathBuf>) -> Self {
        Self { home_trash: home_trash.into() }
    }

    pub fn from_environment() -> Result<Self, String> {
        let data = match std::env::var_os("XDG_DATA_HOME").filter(|p| Path::new(p).is_absolute()) {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(std::env::var_os("HOME").ok_or("HOME is unset")?).join(".local/share"),
        };
        Ok(Self::new(data.join("Trash")))
    }

    pub fn inspect_metadata(&self, path: &str) -> Result<Option<UnixInspection>, String> {
        let metadata = match fs::symlink_metadata(path) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.to_string()),
        };
        if metadata.file_type().is_symlink() {
            return Err(format!("symbolic link is not eligible: {path}"));
        }
        Ok(Some(UnixInspection {
            candidate: candidate(Path::new(path), &metadata)?,
            changed_at: metadata.ctime() as f64 + metadata.ctime_nsec() as f64 / 1e9,
        }))
    }

    fn trash_root(&self, source: &Path, device: u64) -> Result<(PathBuf, Option<PathBuf>), String> {
        // Find the existing parent before creating anything on a potentially different volume.
        let mut existing = self.home_trash.as_path();
        while !existing.exists() {
            existing = existing.parent().ok_or("Trash directory has no existing ancestor")?;
        }
        if fs::metadata(existing).map_err(err)?.dev() == device {
            prepare_trash(&self.home_trash)?;
            return Ok((self.home_trash.clone(), None));
        }
        let mut top = source.parent().ok_or("cannot trash a filesystem root")?.to_path_buf();
        while let Some(parent) = top.parent() {
            if fs::symlink_metadata(parent).map_err(err)?.dev() != device { break; }
            top = parent.to_path_buf();
        }
        // SAFETY: geteuid has no arguments or preconditions.
        let root = top.join(format!(".Trash-{}", unsafe { libc::geteuid() }));
        prepare_trash(&root).map_err(|e| format!("same-device Trash unavailable (cross-device copy is forbidden): {e}"))?;
        if fs::symlink_metadata(&root).map_err(err)?.dev() != device {
            return Err("cross-device Trash refused; copy/delete is forbidden".into());
        }
        Ok((root, Some(top)))
    }
}

fn err(error: io::Error) -> String { error.to_string() }

fn text(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| "path is not UTF-8; core FileAccess cannot represent it (never converted lossily)".into())
}

fn absolute(path: &Path) -> Result<(), String> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
        return Err("expected an absolute path without dot components".into());
    }
    Ok(())
}

fn candidate(path: &Path, m: &Metadata) -> Result<RuleCandidate, String> {
    // Creation (birth) time is the inode-reuse guard: statx btime on Linux, st_birthtime on macOS. Without it,
    // or without a durable volume id, the identity is process-local and stores drop it on reopen.
    let created = m.created().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs_f64());
    let volume = identity::volume(if m.file_type().is_symlink() { path.parent().unwrap_or(path) } else { path }, m.dev());
    Ok(RuleCandidate {
        identity: FilesystemIdentity {
            volume: volume.id, resource: m.ino().to_be_bytes().to_vec(),
            path_hint: text(path)?.into(), creation_time: created, generation: None,
            is_persistent: volume.stable && created.is_some(),
        },
        name: text(Path::new(path.file_name().ok_or("filesystem root is not an item")?))?.into(),
        kind: if m.is_dir() { ItemKind::Directory } else { ItemKind::File },
        timestamps: CandidateTimestamps {
            created, modified: Some(m.mtime() as f64 + m.mtime_nsec() as f64 / 1e9),
            accessed: Some(m.atime() as f64 + m.atime_nsec() as f64 / 1e9), ..Default::default()
        },
        platform_hidden: false,
    })
}

fn reject_symlink_ancestors(path: &Path) -> Result<(), String> {
    for parent in path.ancestors().skip(1) {
        if fs::symlink_metadata(parent).map_err(err)?.file_type().is_symlink() {
            return Err(format!("symbolic link ancestor: {}", parent.display()));
        }
    }
    Ok(())
}

fn prepare_trash(root: &Path) -> Result<(), String> {
    absolute(root)?;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(root).map_err(err)?;
    for directory in [root.to_path_buf(), root.join("files"), root.join("info")] {
        reject_symlink_ancestors(&directory)?;
        match fs::DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => {},
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {},
            Err(e) => return Err(err(e)),
        }
        let m = fs::symlink_metadata(&directory).map_err(err)?;
        // SAFETY: geteuid has no preconditions.
        if !m.is_dir() || m.file_type().is_symlink() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0 {
            return Err(format!("insecure Trash directory: {} (requires owned directory mode 0700)", directory.display()));
        }
    }
    Ok(())
}

impl FileAccess for UnixFileAccess {
    fn inspect(&mut self, path: &str) -> Result<Option<RuleCandidate>, String> {
        Ok(self.inspect_metadata(path)?.map(|i| i.candidate))
    }

    fn has_symbolic_link_ancestor(&mut self, path: &str, below_root: &str) -> Result<bool, String> {
        let path = Path::new(path);
        let root = Path::new(below_root);
        absolute(path)?;
        absolute(root)?;
        if !path.starts_with(root) { return Err("item is outside managed root".into()); }
        for parent in path.ancestors().skip(1) {
            if parent == root { break; }
            if fs::symlink_metadata(parent).map_err(err)?.file_type().is_symlink() { return Ok(true); }
        }
        Ok(false)
    }

    fn has_protected_descendant(&mut self, path: &str, overrides: &[ItemPolicyOverride], protect_hidden: bool, budget: WalkBudget) -> Result<DescendantProtection, String> {
        if overrides.iter().any(|keep| keep_protects_descendant(path, keep, None, &keep.path, None)) {
            return Ok(DescendantProtection::Protected);
        }
        if !protect_hidden && !overrides.iter().any(|o| o.identity.is_some() && matches!(o.policy, tinyprune_core::resolve::ItemOverridePolicy::Keep { .. })) {
            return Ok(DescendantProtection::None);
        }
        let mut stack = vec![fs::read_dir(path).map_err(err)?];
        let mut visited = 0;
        while let Some(entries) = stack.last_mut() {
            let Some(entry) = entries.next() else { stack.pop(); continue; };
            let entry = entry.map_err(err)?;
            visited += 1;
            if visited > budget.max_entries || !budget.deadline.is_finite() || now() >= budget.deadline { return Ok(DescendantProtection::Indeterminate); }
            let child = entry.path();
            let name = entry.file_name();
            if protect_hidden && name.as_bytes().starts_with(b".") { return Ok(DescendantProtection::Protected); }
            let metadata = fs::symlink_metadata(&child).map_err(err)?;
            let item = candidate(&child, &metadata)?;
            if overrides.iter().any(|keep| keep_covers(Some(&item.identity), text(&child).unwrap_or(""), keep, None)) {
                return Ok(DescendantProtection::Protected);
            }
            if metadata.is_dir() && !metadata.file_type().is_symlink() { stack.push(fs::read_dir(child).map_err(err)?); }
        }
        Ok(DescendantProtection::None)
    }

    fn move_to_trash(&mut self, path: &str, expected: &FilesystemIdentity) -> Result<String, String> {
        let source = Path::new(path);
        absolute(source)?;
        reject_symlink_ancestors(source)?;
        let initial = self.inspect(path)?.ok_or("item disappeared before Trash")?;
        if initial.identity != *expected { return Err("filesystem identity changed before Trash".into()); }
        let device = fs::symlink_metadata(source).map_err(err)?.dev();
        let (trash, top) = self.trash_root(source, device)?;
        if source.starts_with(&trash) || trash.starts_with(source) { return Err("cannot trash the Trash directory or its contents".into()); }
        if fs::metadata(trash.join("files")).map_err(err)?.dev() != device { return Err("cross-device Trash refused; copy/delete is forbidden".into()); }
        let stored_path = top.as_ref().map_or(Ok(source), |top| source.strip_prefix(top).map_err(|e| e.to_string()))?;
        let contents = format!("[Trash Info]\nPath={}\nDeletionDate={}\n", percent_encode(stored_path.as_os_str().as_bytes()), deletion_date()?);
        let name = source.file_name().ok_or("cannot trash root")?;
        for suffix in 0..u64::MAX {
            let mut unique = name.to_os_string();
            if suffix != 0 { unique.push(format!(".{suffix}")); }
            let destination = trash.join("files").join(&unique);
            let result_path = text(&destination)?.to_owned();
            unique.push(".trashinfo");
            let info = trash.join("info").join(unique);
            let mut record = match OpenOptions::new().write(true).create_new(true).mode(0o600).open(&info) {
                Ok(file) => file,
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(err(e)),
            };
            let prepared: Result<(), String> = (|| {
                record.write_all(contents.as_bytes()).map_err(err)?;
                record.sync_all().map_err(err)?;
                reject_symlink_ancestors(source)?;
                if self.inspect(path)?.ok_or("item disappeared before Trash")?.identity != *expected {
                    return Err("filesystem identity changed before Trash".into());
                }
                Ok(())
            })();
            if let Err(error) = prepared {
                fs::remove_file(&info).map_err(err)?;
                return Err(error);
            }
            match rename_no_replace(source, &destination) {
                Ok(()) => {
                    if self.inspect(&result_path)?.ok_or("trashed item disappeared")?.identity != *expected {
                        return Err(format!("concurrent identity replacement detected after move; item retained at {result_path}"));
                    }
                    return Ok(result_path);
                },
                Err(error) => {
                    fs::remove_file(&info).map_err(err)?; // Only our newly-created metadata, never user content.
                    if error.kind() == io::ErrorKind::AlreadyExists { continue; }
                    return Err(error.to_string());
                },
            }
        }
        Err("Trash name space exhausted".into())
    }
}

fn now() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64() }

fn percent_encode(bytes: &[u8]) -> String {
    let mut output = String::new();
    for &byte in bytes {
        if byte.is_ascii_alphanumeric() || b"-_.~/".contains(&byte) { output.push(byte as char); }
        else { use std::fmt::Write; write!(output, "%{byte:02X}").expect("writing to String"); }
    }
    output
}

fn deletion_date() -> Result<String, String> {
    // SAFETY: localtime_r initializes the supplied tm on success; pointers live for the call.
    unsafe {
        let time = libc::time(std::ptr::null_mut());
        let mut local = std::mem::MaybeUninit::<libc::tm>::uninit();
        if libc::localtime_r(&time, local.as_mut_ptr()).is_null() { return Err("cannot format Trash deletion date".into()); }
        let local = local.assume_init();
        Ok(format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}", local.tm_year + 1900, local.tm_mon + 1, local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec))
    }
}

fn rename_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    let source = CString::new(source.as_os_str().as_bytes())?;
    let destination = CString::new(destination.as_os_str().as_bytes())?;
    // SAFETY: both C strings are NUL-terminated and valid for the duration of the call.
    #[cfg(target_os = "linux")]
    let result = unsafe { libc::renameat2(libc::AT_FDCWD, source.as_ptr(), libc::AT_FDCWD, destination.as_ptr(), libc::RENAME_NOREPLACE) };
    #[cfg(target_os = "macos")]
    let result = unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let result = { let _ = (source, destination); return Err(io::Error::new(io::ErrorKind::Unsupported, "atomic no-replace rename unavailable on this Unix")); };
    if result == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn cross_device_rename_refuses_without_copying() {
        let Ok(shared) = fs::metadata("/dev/shm") else { return };
        let temp = std::env::temp_dir();
        if shared.dev() == fs::metadata(&temp).unwrap().dev() { return; }
        let name = format!("tinyprune-cross-device-{}-{}", std::process::id(), now().to_bits());
        let source = Path::new("/dev/shm").join(&name);
        let Ok(mut file) = OpenOptions::new().write(true).create_new(true).open(&source) else { return };
        file.write_all(b"retained").unwrap();
        let destination = temp.join(name);
        let error = rename_no_replace(&source, &destination).unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::EXDEV));
        assert_eq!(fs::read(&source).unwrap(), b"retained");
        assert!(!destination.exists());
        fs::remove_file(source).unwrap();
    }
}
