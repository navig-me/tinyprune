//! Durable volume identity for Unix item identities.
//!
//! `st_dev` is only a per-boot handle (it is renumbered across reboots, hot-plug and remounts), so it can
//! never key persisted observations. The volume id is derived, in order, from:
//! 1. the filesystem UUID (macOS `ATTR_VOL_UUID`; Linux `/dev/disk/by-uuid` matched via `/proc/self/mountinfo`),
//!    mixed with the mount's subvolume root on Linux so btrfs subvolumes with overlapping inode spaces differ;
//! 2. Linux `statfs` `f_fsid` + `f_type` when non-zero and the filesystem is not a known per-boot synthetic one;
//! 3. otherwise `st_dev` and the identity is reported **not** persistent, so stores drop it on reopen.
//!
//! The per-resource guard against inode reuse is the creation (birth) time, so callers additionally require one.

use std::collections::HashMap;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use tinyprune_core::uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Volume {
    pub id: Uuid,
    /// True when `id` survives reboot and remount.
    pub stable: bool,
}

type Key = (u64, u64, u64);

static CACHE: LazyLock<Mutex<HashMap<Key, Volume>>> = LazyLock::new(Default::default);

/// Resolve the volume for an item whose `lstat` device is `dev`. `target` is the path to ask the OS about
/// (callers pass a non-symlink; for symlinks use the parent so another volume is never queried).
pub(crate) fn volume(target: &Path, dev: u64) -> Volume {
    let fs = fs_info(target);
    let key = (dev, fs.map_or(0, |f| f.fsid), fs.map_or(0, |f| f.kind));
    if let Some(found) = CACHE.lock().ok().and_then(|c| c.get(&key).copied()) {
        return found;
    }
    let found = resolve(target, dev, fs);
    if let Ok(mut c) = CACHE.lock() {
        c.insert(key, found);
    }
    found
}

#[derive(Clone, Copy)]
struct FsInfo {
    fsid: u64,
    kind: u64,
}

fn fs_info(target: &Path) -> Option<FsInfo> {
    let path = CString::new(target.as_os_str().as_bytes()).ok()?;
    // SAFETY: zeroed statfs is a valid out-buffer; `path` is NUL-terminated and outlives the call.
    let mut info: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(path.as_ptr(), &mut info) } != 0 {
        return None;
    }
    // SAFETY: fsid_t is plain integers; viewing its bytes is sound.
    let bytes = unsafe { std::slice::from_raw_parts((&info.f_fsid as *const libc::fsid_t).cast::<u8>(), std::mem::size_of::<libc::fsid_t>()) };
    let fsid = bytes.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b));
    Some(FsInfo { fsid, kind: info.f_type as u64 })
}

fn resolve(target: &Path, dev: u64, fs: Option<FsInfo>) -> Volume {
    platform(target, dev, fs).unwrap_or(Volume { id: Uuid(dev as u128), stable: false })
}

#[cfg(target_os = "macos")]
fn platform(target: &Path, _dev: u64, _fs: Option<FsInfo>) -> Option<Volume> {
    // macOS f_fsid is derived from st_dev, so only the volume UUID is durable.
    #[repr(C)]
    struct Reply {
        length: u32,
        uuid: [u8; 16],
    }
    let path = CString::new(target.as_os_str().as_bytes()).ok()?;
    // SAFETY: attrlist is plain integers; zeroed then populated per getattrlist(2).
    let mut list: libc::attrlist = unsafe { std::mem::zeroed() };
    list.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    list.volattr = libc::ATTR_VOL_INFO | libc::ATTR_VOL_UUID;
    let mut reply = Reply { length: 0, uuid: [0; 16] };
    // SAFETY: valid NUL-terminated path, attrlist and a buffer of the stated size.
    let status = unsafe {
        libc::getattrlist(path.as_ptr(), (&mut list as *mut libc::attrlist).cast(), (&mut reply as *mut Reply).cast(), std::mem::size_of::<Reply>(), libc::FSOPT_NOFOLLOW)
    };
    if status != 0 || (reply.length as usize) < std::mem::size_of::<Reply>() || reply.uuid == [0; 16] {
        return None;
    }
    Some(Volume { id: Uuid(u128::from_be_bytes(reply.uuid)), stable: true })
}

#[cfg(target_os = "linux")]
fn platform(target: &Path, dev: u64, fs: Option<FsInfo>) -> Option<Volume> {
    if let Some(id) = uuid_volume(dev) {
        return Some(Volume { id, stable: true });
    }
    let fs = fs?;
    if fs.fsid == 0 || volatile_filesystem(fs.kind) {
        return None;
    }
    let _ = target;
    Some(Volume { id: derive(&[b"fsid", &fs.kind.to_be_bytes(), &fs.fsid.to_be_bytes()]), stable: true })
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn platform(_target: &Path, _dev: u64, _fs: Option<FsInfo>) -> Option<Volume> {
    None
}

/// Filesystems whose ids are assigned per boot or per mount, so inode identity is meaningless later.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn volatile_filesystem(kind: u64) -> bool {
    matches!(
        kind & 0xffff_ffff,
        0x0102_1994 // tmpfs/devtmpfs
        | 0x8584_58f6 // ramfs
        | 0x794c_7630 // overlayfs
        | 0x0000_9fa0 // procfs
        | 0x6265_6572 // sysfs
        | 0x6367_7270 // cgroup2
        | 0x0000_27e0 // cgroup v1
        | 0x6573_5546 // fuse
        | 0x1cd1 // devpts
    )
}

#[cfg(target_os = "linux")]
fn uuid_volume(dev: u64) -> Option<Uuid> {
    let (major, minor) = (libc::major(dev as libc::dev_t), libc::minor(dev as libc::dev_t));
    let mounts = std::fs::read_to_string("/proc/self/mountinfo").ok()?;
    let mount = parse_mountinfo(&mounts, u64::from(major), u64::from(minor))?;
    let source = std::fs::canonicalize(&mount.source).ok()?;
    for entry in std::fs::read_dir("/dev/disk/by-uuid").ok()?.flatten() {
        if std::fs::canonicalize(entry.path()).ok().as_deref() == Some(source.as_path()) {
            return Some(volume_uuid(&entry.file_name().to_string_lossy(), &mount.root));
        }
    }
    None
}

/// The mount row for a `major:minor` device.
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) struct Mount {
    pub source: String,
    /// Directory within the filesystem that is mounted (a btrfs subvolume or bind-mount path).
    pub root: String,
}

/// Parse `/proc/self/mountinfo`: `id parent maj:min root mount opts [optional…] - fstype source superopts`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn parse_mountinfo(text: &str, major: u64, minor: u64) -> Option<Mount> {
    let wanted = format!("{major}:{minor}");
    for line in text.lines() {
        let fields: Vec<&str> = line.split(' ').collect();
        let Some(separator) = fields.iter().position(|f| *f == "-") else { continue };
        if fields.len() < separator + 3 || fields.len() < 6 || fields[2] != wanted {
            continue;
        }
        let source = unescape(fields[separator + 2]);
        if !source.starts_with('/') {
            continue;
        }
        return Some(Mount { source, root: unescape(fields[3]) });
    }
    None
}

/// mountinfo escapes space, tab, newline and backslash as `\NNN` octal.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn unescape(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let octal = (i + 3 < bytes.len() && bytes[i] == b'\\' && bytes[i + 1..i + 4].iter().all(|b| (b'0'..=b'7').contains(b)))
            .then(|| bytes[i + 1..i + 4].iter().fold(0u32, |acc, b| acc * 8 + u32::from(b - b'0')))
            .and_then(|value| u8::try_from(value).ok());
        if let Some(byte) = octal {
            out.push(byte);
            i += 4;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A canonical UUID mounted at the filesystem root is used verbatim; otherwise the label (and subvolume root)
/// is hashed so distinct subvolumes of one filesystem never share an inode namespace.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn volume_uuid(label: &str, root: &str) -> Uuid {
    match Uuid::parse(label) {
        Some(uuid) if root == "/" => uuid,
        _ => derive(&[b"uuid", label.as_bytes(), root.as_bytes()]),
    }
}

/// Deterministic 128-bit FNV-1a over length-prefixed parts (stable across Rust versions, unlike `DefaultHasher`).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn derive(parts: &[&[u8]]) -> Uuid {
    const OFFSET: u128 = 0x6c62272e07bb014262b821756295c58d;
    const PRIME: u128 = 0x0000000001000000000000000000013b;
    let mut hash = OFFSET;
    for part in parts {
        for byte in (part.len() as u64).to_be_bytes().iter().chain(part.iter()) {
            hash = (hash ^ u128::from(*byte)).wrapping_mul(PRIME);
        }
    }
    Uuid(hash)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mountinfo_selects_device_and_decodes_escapes() {
        let text = "36 35 8:2 /sub\\040vol /mnt/data rw - ext4 /dev/sda2 rw\n37 35 0:30 / /run rw - tmpfs tmpfs rw\n";
        assert_eq!(parse_mountinfo(text, 8, 2), Some(Mount { source: "/dev/sda2".into(), root: "/sub vol".into() }));
        assert_eq!(parse_mountinfo(text, 0, 30), None, "non-device sources have no UUID");
        assert_eq!(parse_mountinfo(text, 9, 9), None);
    }

    #[test]
    fn uuid_volumes_are_deterministic_and_subvolume_distinct() {
        let label = "123e4567-e89b-12d3-a456-426614174000";
        assert_eq!(volume_uuid(label, "/"), Uuid::parse(label).unwrap());
        assert_ne!(volume_uuid(label, "/@home"), volume_uuid(label, "/@root"));
        assert_eq!(volume_uuid("ABCD-1234", "/"), volume_uuid("ABCD-1234", "/"));
        assert_ne!(derive(&[b"ab", b"c"]), derive(&[b"a", b"bc"]));
    }

    #[test]
    fn synthetic_filesystems_are_volatile() {
        assert!(volatile_filesystem(0x0102_1994));
        assert!(!volatile_filesystem(0xEF53));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_temp_volume_has_a_stable_uuid() {
        use std::os::unix::fs::MetadataExt;
        let dir = std::env::temp_dir();
        let dev = std::fs::metadata(&dir).unwrap().dev();
        let first = volume(&dir, dev);
        assert!(first.stable);
        assert_eq!(volume(&dir, dev), first);
    }
}
