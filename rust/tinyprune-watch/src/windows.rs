use super::windows_notify::{record, RenamePairing};
use super::{Coalescer, EventBatch, EventSource, RawEvent, RawKind};
use std::ffi::OsString;
use std::fs;
use std::io;
use std::num::NonZeroUsize;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::fs::MetadataExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{
    CloseHandle, ERROR_IO_INCOMPLETE, ERROR_NOTIFY_ENUM_DIR, HANDLE, WAIT_FAILED, WAIT_TIMEOUT,
};
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::System::Threading::{CreateEventW, ResetEvent, WaitForSingleObject};
use windows::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

const BUFFER_BYTES: usize = 64 * 1024;
const FILTER: FILE_NOTIFY_CHANGE = FILE_NOTIFY_CHANGE(
    FILE_NOTIFY_CHANGE_FILE_NAME.0
        | FILE_NOTIFY_CHANGE_DIR_NAME.0
        | FILE_NOTIFY_CHANGE_ATTRIBUTES.0
        | FILE_NOTIFY_CHANGE_SIZE.0
        | FILE_NOTIFY_CHANGE_LAST_WRITE.0
        | FILE_NOTIFY_CHANGE_CREATION.0,
);

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: each successfully opened handle has one owner.
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

struct Watch {
    root: PathBuf,
    handle: Handle,
    overlapped: Box<OVERLAPPED>,
    // u32 storage meets ReadDirectoryChangesW's DWORD alignment requirement.
    buffer: Box<[u32]>,
    count: usize,
    offset: usize,
    pending: bool,
    disabled: bool,
    pairing: RenamePairing,
}

// SAFETY: a watch is exclusively accessed through &mut self. All memory used by
// pending kernel I/O is boxed and stays at a stable address across thread moves.
unsafe impl Send for Watch {}

impl Watch {
    fn arm(&mut self) -> io::Result<()> {
        self.count = 0;
        self.offset = 0;
        // SAFETY: handle is live; both boxes remain allocated until cancellation
        // completes or this I/O completes. Only one operation uses this buffer.
        unsafe {
            ReadDirectoryChangesW(
                self.handle.0,
                self.buffer.as_mut_ptr().cast(),
                BUFFER_BYTES as u32,
                true,
                FILTER,
                None,
                Some(&mut *self.overlapped),
                None,
            )
        }
        .map_err(io::Error::from)?;
        self.pending = true;
        Ok(())
    }

    fn lost(&mut self, coalescer: &mut Coalescer) {
        self.pairing.reset();
        self.count = 0;
        self.offset = 0;
        coalescer.push(RawEvent {
            root: self.root.clone(),
            path: self.root.clone(),
            kind: RawKind::QueueOverflow,
            is_directory: true,
        });
    }

    fn complete(&mut self, coalescer: &mut Coalescer) -> io::Result<bool> {
        if !self.pending {
            return Ok(false);
        }
        let mut count = 0;
        // SAFETY: the operation's handle, OVERLAPPED and output pointer are live.
        let result =
            unsafe { GetOverlappedResult(self.handle.0, &*self.overlapped, &mut count, false) };
        if result
            .as_ref()
            .is_err_and(|error| error.code() == ERROR_IO_INCOMPLETE.to_hresult())
        {
            return Ok(false);
        }
        self.pending = false;
        match result {
            Ok(()) if count > 0 && count as usize <= BUFFER_BYTES => {
                self.count = count as usize;
                self.offset = 0;
            }
            Ok(()) => {
                self.lost(coalescer);
                self.arm_or_disable(coalescer);
            }
            Err(error) if error.code() == ERROR_NOTIFY_ENUM_DIR.to_hresult() => {
                self.lost(coalescer);
                self.arm_or_disable(coalescer);
            }
            Err(_) => {
                // Disconnected/deleted roots and other failed notifications leave
                // coverage incomplete. Recreate this source after reconciliation.
                self.lost(coalescer);
                self.disabled = true;
            }
        }
        Ok(true)
    }

    fn arm_or_disable(&mut self, coalescer: &mut Coalescer) {
        if self.arm().is_err() {
            self.lost(coalescer);
            self.disabled = true;
        }
    }

    fn process(&mut self, coalescer: &mut Coalescer) {
        // SAFETY: count is checked against the buffer allocation at completion;
        // the kernel is finished and no new operation is armed while parsing.
        let bytes =
            unsafe { std::slice::from_raw_parts(self.buffer.as_ptr().cast::<u8>(), self.count) };
        match record(&bytes[self.offset..]) {
            Ok((action, name, next)) => {
                let path = self.root.join(OsString::from_wide(&name));
                // FILE_NOTIFY_INFORMATION has no directory bit. Missing paths
                // (notably removals) have an unknown/false directory hint.
                let is_directory = fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir());
                let kind = self.pairing.kind(action);
                if is_directory && matches!(kind, RawKind::Created | RawKind::RenameTo(_)) {
                    coalescer.rescan(self.root.clone());
                }
                coalescer.push(RawEvent {
                    root: self.root.clone(),
                    path,
                    kind,
                    is_directory,
                });
                if next == 0 {
                    self.offset = self.count;
                } else {
                    self.offset += next;
                }
            }
            Err(_) => self.lost(coalescer),
        }
        if self.offset == self.count {
            self.arm_or_disable(coalescer);
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        if self.pending {
            // SAFETY: cancellation is followed by a blocking completion wait.
            // Even ERROR_NOT_FOUND means the request may just have completed;
            // never free its buffer/OVERLAPPED before observing completion.
            unsafe {
                let _ = CancelIoEx(self.handle.0, Some(&*self.overlapped));
                let mut count = 0;
                loop {
                    match GetOverlappedResult(self.handle.0, &*self.overlapped, &mut count, false) {
                        Err(error) if error.code() == ERROR_IO_INCOMPLETE.to_hresult() => {
                            std::thread::yield_now()
                        }
                        _ => break,
                    }
                }
            }
        }
    }
}

/// Recursive metadata-only Windows invalidation source. A rescan is required
/// after loss; recreate the source to restore coverage for unavailable roots.
pub struct WindowsEventSource {
    watches: Vec<Watch>,
    event: Handle,
    coalescer: Coalescer,
    cursor: usize,
}

// SAFETY: handles are thread-independent kernel objects; Watch documents the
// stable exclusive I/O ownership. Moving never relocates pending I/O storage.
unsafe impl Send for WindowsEventSource {}

impl WindowsEventSource {
    pub fn new(roots: impl IntoIterator<Item = PathBuf>) -> io::Result<Self> {
        // A shared manual-reset event wakes polling for any root, without the
        // WaitForMultipleObjects 64-handle limit. Completions are probed per root.
        let event =
            Handle(unsafe { CreateEventW(None, true, false, None) }.map_err(io::Error::from)?);
        let mut source = Self {
            watches: Vec::new(),
            event,
            coalescer: Coalescer::default(),
            cursor: 0,
        };
        for root in roots {
            if !root.is_absolute()
                || root
                    .components()
                    .any(|part| matches!(part, std::path::Component::ParentDir))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "roots must be absolute without parent components",
                ));
            }
            for ancestor in root.ancestors() {
                let metadata = fs::symlink_metadata(ancestor)?;
                if !metadata.is_dir()
                    || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0
                {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "root ancestors must be real directories",
                    ));
                }
            }
            let root = fs::canonicalize(root)?;
            // Canonical spellings still need Windows case-insensitive overlap
            // checks. CompareStringOrdinal avoids Unicode expanding case folds.
            for other in &source.watches {
                if overlaps(&root, &other.root) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "roots must not overlap",
                    ));
                }
            }
            let wide: Vec<u16> = root.as_os_str().encode_wide().chain(Some(0)).collect();
            let handle = Handle(
                unsafe {
                    CreateFileW(
                        PCWSTR(wide.as_ptr()),
                        FILE_LIST_DIRECTORY.0,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        None,
                        OPEN_EXISTING,
                        FILE_FLAG_BACKUP_SEMANTICS
                            | FILE_FLAG_OVERLAPPED
                            | FILE_FLAG_OPEN_REPARSE_POINT,
                        None,
                    )
                }
                .map_err(io::Error::from)?,
            );
            let mut overlapped = Box::<OVERLAPPED>::default();
            overlapped.hEvent = source.event.0;
            let mut watch = Watch {
                root,
                handle,
                overlapped,
                buffer: vec![0; BUFFER_BYTES / 4].into_boxed_slice(),
                count: 0,
                offset: 0,
                pending: false,
                disabled: false,
                pairing: RenamePairing::default(),
            };
            watch.arm()?;
            source.watches.push(watch);
        }
        Ok(source)
    }

    fn pending(&self) -> bool {
        self.watches.iter().any(|watch| watch.offset < watch.count)
    }
}

fn overlaps(left: &std::path::Path, right: &std::path::Path) -> bool {
    use windows::Win32::Globalization::{CompareStringOrdinal, CSTR_EQUAL};
    let mut left = left.components();
    let mut right = right.components();
    loop {
        let (Some(left), Some(right)) = (left.next(), right.next()) else {
            return true;
        };
        let left: Vec<u16> = left.as_os_str().encode_wide().collect();
        let right: Vec<u16> = right.as_os_str().encode_wide().collect();
        // SAFETY: both slices contain initialized UTF-16 code units.
        if unsafe { CompareStringOrdinal(&left, &right, true) } != CSTR_EQUAL {
            return false;
        }
    }
}

impl EventSource for WindowsEventSource {
    fn poll(&mut self, timeout: Duration, limit: NonZeroUsize) -> io::Result<EventBatch> {
        if !self.coalescer.output.is_empty() {
            return Ok(self.coalescer.batch(limit.get(), self.pending()));
        }
        let start = Instant::now();
        loop {
            // Reset before probing: a completion racing the probe either appears
            // in GetOverlappedResult or leaves the event signaled for the wait.
            unsafe { ResetEvent(self.event.0) }.map_err(io::Error::from)?;
            let mut completed = false;
            for watch in &mut self.watches {
                if watch.disabled {
                    continue;
                }
                if !fs::symlink_metadata(&watch.root).is_ok_and(|metadata| {
                    metadata.is_dir()
                        && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 == 0
                }) {
                    watch.lost(&mut self.coalescer);
                    watch.disabled = true;
                    completed = true;
                    continue;
                }
                completed |= watch.complete(&mut self.coalescer)?;
            }
            if self.pending() || completed || start.elapsed() >= timeout || self.watches.is_empty()
            {
                break;
            }
            let remaining = timeout.saturating_sub(start.elapsed());
            // Periodic availability probes detect root removal even on systems
            // that do not complete a recursive notification for the root itself.
            let millis = remaining
                .as_millis()
                .saturating_add(u128::from(
                    !remaining.subsec_nanos().is_multiple_of(1_000_000),
                ))
                .min(1000) as u32;
            let result = unsafe { WaitForSingleObject(self.event.0, millis) };
            if result == WAIT_FAILED {
                return Err(io::Error::last_os_error());
            }
            if result == WAIT_TIMEOUT && start.elapsed() >= timeout {
                break;
            }
        }
        for _ in 0..limit.get() {
            let count = self.watches.len();
            let next = (0..count)
                .map(|offset| (self.cursor + offset) % count)
                .find(|index| self.watches[*index].offset < self.watches[*index].count);
            let Some(index) = next else {
                break;
            };
            self.watches[index].process(&mut self.coalescer);
            self.cursor = (index + 1) % count;
        }
        let pending = self.pending();
        if !pending {
            // Preserve pairs if another completion is already queued; otherwise
            // unmatched names become ordinary remove/create hints at queue drain.
            let mut completed = false;
            for watch in &mut self.watches {
                if !watch.disabled {
                    completed |= watch.complete(&mut self.coalescer)?;
                }
            }
            if !completed {
                for watch in &mut self.watches {
                    watch.pairing.reset();
                }
                self.coalescer.drained();
            }
        }
        Ok(self.coalescer.batch(limit.get(), self.pending()))
    }
}

#[cfg(test)]
#[path = "windows_tests.rs"]
mod tests;
