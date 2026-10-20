use super::{Coalescer, EventBatch, EventSource, RawEvent, RawKind, WatchTable};
use std::collections::VecDeque;
use std::ffi::{CString, OsStr};
use std::fs::{self, ReadDir};
use std::io;
use std::num::NonZeroUsize;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

const MASK: u32 = libc::IN_CREATE
    | libc::IN_MODIFY
    | libc::IN_DELETE
    | libc::IN_ATTRIB
    | libc::IN_MOVED_FROM
    | libc::IN_MOVED_TO
    | libc::IN_DELETE_SELF
    | libc::IN_MOVE_SELF
    | libc::IN_ONLYDIR
    | libc::IN_DONT_FOLLOW
    | libc::IN_EXCL_UNLINK;
const BUFFER_SIZE: usize = 64 * 1024;

struct Walk {
    root: PathBuf,
    path: PathBuf,
    entries: Option<ReadDir>,
}

/// Linux-only recursive metadata watcher. Construction opens a nonblocking,
/// close-on-exec descriptor; recursive setup advances in bounded `poll` calls.
/// Roots must be absolute, nonoverlapping, real directories (not symlinks).
/// Neither this adapter nor an event batch authorizes a filesystem mutation.
pub struct InotifyEventSource {
    fd: OwnedFd,
    roots: Vec<PathBuf>,
    watches: WatchTable,
    walks: VecDeque<Walk>,
    removals: VecDeque<i32>,
    bytes: Vec<u8>,
    offset: usize,
    coalescer: Coalescer,
}

impl InotifyEventSource {
    pub fn new(roots: impl IntoIterator<Item = PathBuf>) -> io::Result<Self> {
        let mut normalized = Vec::<PathBuf>::new();
        for root in roots {
            if !root.is_absolute()
                || root
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "roots must be absolute without parent components",
                ));
            }
            let metadata = fs::symlink_metadata(&root)?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "root must be a real directory",
                ));
            }
            // Canonicalization inspects metadata only, rejects symlinked root
            // ancestors, and prevents aliases from sharing an inotify descriptor.
            let canonical = fs::canonicalize(&root)?;
            if canonical != root
                || normalized
                    .iter()
                    .any(|other| root.starts_with(other) || other.starts_with(&root))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "roots must be canonical and nonoverlapping",
                ));
            }
            normalized.push(root);
        }
        // SAFETY: flags are valid, and a successful result is a new owned fd.
        let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: ownership of the newly created fd is transferred exactly once.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let walks = normalized
            .iter()
            .map(|root| Walk {
                root: root.clone(),
                path: root.clone(),
                entries: None,
            })
            .collect();
        Ok(Self {
            fd,
            roots: normalized,
            watches: WatchTable::default(),
            walks,
            removals: VecDeque::new(),
            bytes: Vec::with_capacity(BUFFER_SIZE),
            offset: 0,
            coalescer: Coalescer::default(),
        })
    }

    fn enqueue(&mut self, root: PathBuf, path: PathBuf) {
        if !self.walks.iter().any(|walk| walk.path == path) {
            self.walks.push_back(Walk {
                root,
                path,
                entries: None,
            });
        }
    }

    fn remove_subtree(&mut self, path: &Path) {
        self.walks.retain(|walk| !walk.path.starts_with(path));
        self.removals.extend(self.watches.subtree(path));
    }

    fn walk_step(&mut self) -> io::Result<()> {
        let Some(mut walk) = self.walks.pop_front() else {
            return Ok(());
        };
        if walk.entries.is_none() {
            let path = CString::new(walk.path.as_os_str().as_bytes())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in watch path"))?;
            // SAFETY: path is NUL terminated, fd live, and mask valid.
            let descriptor =
                unsafe { libc::inotify_add_watch(self.fd.as_raw_fd(), path.as_ptr(), MASK) };
            if descriptor < 0 {
                let error = io::Error::last_os_error();
                self.coalescer.rescan(walk.root.clone());
                if matches!(
                    error.raw_os_error(),
                    Some(libc::ENOSPC | libc::ENOENT | libc::ENOTDIR | libc::ELOOP)
                ) {
                    return Ok(());
                }
                return Err(error);
            }
            self.watches
                .insert(descriptor, walk.root.clone(), walk.path.clone());
            // Install before enumeration so changes during enumeration are queued.
            match fs::read_dir(&walk.path) {
                Ok(entries) => walk.entries = Some(entries),
                Err(error) => {
                    self.coalescer.rescan(walk.root);
                    if error.kind() == io::ErrorKind::NotFound {
                        return Ok(());
                    }
                    return Err(error);
                }
            }
            self.walks.push_front(walk);
            return Ok(());
        }
        if let Some(entry) = walk.entries.as_mut().and_then(Iterator::next) {
            let child = entry.and_then(|entry| Ok((entry.path(), entry.file_type()?)));
            match child {
                Ok((path, kind)) if kind.is_dir() && !kind.is_symlink() => {
                    self.enqueue(walk.root.clone(), path);
                }
                Ok(_) => {}
                Err(error) => {
                    self.coalescer.rescan(walk.root.clone());
                    if error.kind() != io::ErrorKind::NotFound {
                        return Err(error);
                    }
                }
            }
            // Finish this directory before opening another ReadDir. The number
            // of live enumeration descriptors is constant, not tree-sized.
            self.walks.push_front(walk);
        }
        Ok(())
    }

    fn wait_readable(&self, timeout: Duration) -> io::Result<bool> {
        let millis = timeout.as_millis().saturating_add(u128::from(
            !timeout.subsec_nanos().is_multiple_of(1_000_000),
        ));
        let mut descriptor = libc::pollfd {
            fd: self.fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: descriptor points to one initialized pollfd for the call.
        let result = unsafe { libc::poll(&mut descriptor, 1, millis.min(i32::MAX as u128) as i32) };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        if descriptor.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            return Err(io::Error::other("inotify descriptor became unavailable"));
        }
        Ok(result != 0)
    }

    fn read_queue(&mut self) -> io::Result<bool> {
        self.bytes.resize(BUFFER_SIZE, 0);
        // SAFETY: buffer is writable for BUFFER_SIZE bytes and fd is live.
        let count = unsafe {
            libc::read(
                self.fd.as_raw_fd(),
                self.bytes.as_mut_ptr().cast(),
                self.bytes.len(),
            )
        };
        self.offset = 0;
        if count < 0 {
            self.bytes.clear();
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                self.coalescer.drained();
                return Ok(false);
            }
            return Err(error);
        }
        self.bytes.truncate(count as usize);
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "inotify descriptor closed",
            ));
        }
        Ok(true)
    }

    fn process_one(&mut self) -> io::Result<()> {
        let header_size = std::mem::size_of::<libc::inotify_event>();
        if self.bytes.len() - self.offset < header_size {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "short inotify header",
            ));
        }
        // SAFETY: the bounds above cover the complete header. Kernel records may
        // not be aligned to Rust's type, so use an unaligned value read.
        let event = unsafe {
            std::ptr::read_unaligned(
                self.bytes
                    .as_ptr()
                    .add(self.offset)
                    .cast::<libc::inotify_event>(),
            )
        };
        let name_start = self.offset + header_size;
        let end = name_start
            .checked_add(event.len as usize)
            .filter(|end| *end <= self.bytes.len())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "short inotify name"))?;
        self.offset = end;
        if event.mask & libc::IN_Q_OVERFLOW != 0 {
            for root in &self.roots {
                self.coalescer.push(RawEvent {
                    root: root.clone(),
                    path: root.clone(),
                    kind: RawKind::QueueOverflow,
                    is_directory: true,
                });
            }
            return Ok(());
        }
        let Some((root, parent)) = self.watches.0.get(&event.wd).cloned() else {
            return Ok(());
        };
        if event.mask & libc::IN_IGNORED != 0 {
            self.watches.0.remove(&event.wd);
            self.coalescer.rescan(root);
            return Ok(());
        }
        let name = &self.bytes[name_start..end];
        let name = &name[..name
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(name.len())];
        let path = if name.is_empty() {
            parent
        } else {
            parent.join(OsStr::from_bytes(name))
        };
        let is_directory = event.mask & libc::IN_ISDIR != 0 || name.is_empty();
        if is_directory
            && event.mask & (libc::IN_DELETE | libc::IN_MOVED_FROM | libc::IN_DELETE_SELF) != 0
        {
            self.remove_subtree(&path);
        }
        if is_directory && event.mask & (libc::IN_CREATE | libc::IN_MOVED_TO) != 0 {
            // A moved-in directory can already contain descendants. Signal the
            // consumer to index it, while incrementally restoring watch coverage.
            self.coalescer.rescan(root.clone());
            self.enqueue(root.clone(), path.clone());
        }
        if event.mask & libc::IN_MOVE_SELF != 0 {
            // Parent move events normally handled this; for roots or a missing
            // parent notification, paths are no longer trustworthy.
            self.coalescer.rescan(root.clone());
            self.remove_subtree(&path);
        }
        for (mask, kind) in [
            (libc::IN_CREATE, RawKind::Created),
            (libc::IN_MODIFY, RawKind::Modified),
            (libc::IN_DELETE | libc::IN_DELETE_SELF, RawKind::Removed),
            (libc::IN_ATTRIB, RawKind::Attribute),
            (libc::IN_MOVED_FROM, RawKind::RenameFrom(event.cookie)),
            (libc::IN_MOVED_TO, RawKind::RenameTo(event.cookie)),
        ] {
            if event.mask & mask != 0 {
                self.coalescer.push(RawEvent {
                    root: root.clone(),
                    path: path.clone(),
                    kind,
                    is_directory,
                });
            }
        }
        Ok(())
    }
}

impl EventSource for InotifyEventSource {
    fn poll(&mut self, timeout: Duration, limit: NonZeroUsize) -> io::Result<EventBatch> {
        if !self.coalescer.output.is_empty() {
            return Ok(self.coalescer.batch(
                limit.get(),
                self.offset < self.bytes.len()
                    || !self.walks.is_empty()
                    || !self.removals.is_empty(),
            ));
        }
        if self.offset == self.bytes.len()
            && self.walks.is_empty()
            && self.removals.is_empty()
            && !self.wait_readable(timeout)?
        {
            self.coalescer.drained();
            return Ok(self.coalescer.batch(limit.get(), false));
        }
        // Two independently bounded budgets prevent a busy queue from starving
        // recursive setup, and prevent a large tree from starving event reads.
        for _ in 0..limit.get() {
            if self.offset == self.bytes.len() && !self.read_queue()? {
                break;
            }
            self.process_one()?;
        }
        for _ in 0..limit.get() {
            if let Some(descriptor) = self.removals.pop_front() {
                // SAFETY: fd is live; EINVAL means the kernel already removed
                // this watch. Finish retirements before adding any new watch.
                unsafe { libc::inotify_rm_watch(self.fd.as_raw_fd(), descriptor) };
            } else if !self.walks.is_empty() {
                self.walk_step()?;
            } else {
                break;
            }
        }
        // A full buffer/budget may leave unread kernel events even when the
        // current byte buffer ended exactly on its final record.
        let pending = self.offset < self.bytes.len()
            || !self.walks.is_empty()
            || !self.removals.is_empty()
            || self.wait_readable(Duration::ZERO)?;
        if !pending {
            self.coalescer.drained()
        }
        Ok(self.coalescer.batch(limit.get(), pending))
    }
}
