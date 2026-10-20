//! Unreleased metadata-only streaming traversal. No persistence or Trash capability.
use std::fs::{self, Metadata, ReadDir};
use std::io;
use std::num::NonZeroUsize;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use std::time::{Duration, Instant};
use tinyprune_agent::{IndexBatch, IndexSource};
use tinyprune_core::rule::RuleCandidate;
use tinyprune_core::scheduler::MetadataSource;
use tinyprune_core::uuid::Uuid;

#[derive(Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);
impl CancellationToken {
    pub fn cancel(&self) { self.0.store(true, Ordering::Relaxed); }
    pub fn is_cancelled(&self) -> bool { self.0.load(Ordering::Relaxed) }
}

/// Monotonic elapsed time, injectable without sleeps.
pub trait TimeSource: Send + Sync { fn elapsed(&self) -> Duration; }
pub struct MonotonicTime(Instant);
impl Default for MonotonicTime { fn default() -> Self { Self(Instant::now()) } }
impl TimeSource for MonotonicTime { fn elapsed(&self) -> Duration { self.0.elapsed() } }

#[derive(Clone, Debug)]
pub struct ScanOptions {
    pub include_root: bool,
    /// 0 inspects only the root; 1 visits direct children. None is recursive.
    pub max_depth: Option<usize>,
    pub allow_other_volumes: bool,
    pub batch_entries: NonZeroUsize,
    pub batch_time: Duration,
    pub total_entries: Option<usize>,
    pub total_time: Option<Duration>,
    /// Bounds simultaneously open directory cursors; exceeding it is partial, never success.
    pub open_directories: NonZeroUsize,
}
impl Default for ScanOptions {
    fn default() -> Self {
        Self { include_root: true, max_depth: None, allow_other_volumes: false,
            batch_entries: NonZeroUsize::new(256).unwrap(), batch_time: Duration::from_millis(50),
            total_entries: None, total_time: None, open_directories: NonZeroUsize::new(256).unwrap() }
    }
}

// Successful entries dominate normal scans. Keep metadata inline to avoid one heap allocation
// per filesystem item; the batch already bounds the space consumed by exceptional variants.
#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum EntryOutcome {
    Candidate(RuleCandidate),
    SymlinkOrReparsePoint,
    OtherVolume,
    Vanished,
    /// Native path is retained in Entry, including names the core cannot represent.
    Unreadable(String),
}
#[derive(Debug)]
pub struct Entry { pub path: PathBuf, pub outcome: EntryOutcome }
#[derive(Debug, Default)]
pub struct ScanBatch {
    pub entries: Vec<Entry>,
    /// Cursor exhausted, including a cursor stopped by cancellation or a hard cap.
    pub finished: bool,
    /// Cumulative: failed/vanished entries mean prior schedules must be retained.
    pub partial: bool,
    pub cancelled: bool,
    pub truncated: bool,
}
struct Frame { path: PathBuf, entries: ReadDir, depth: usize }

pub struct ScanCursor {
    root: PathBuf,
    pending: Option<(PathBuf, usize)>,
    stack: Vec<Frame>,
    volume: Option<Uuid>,
    options: ScanOptions,
    cancellation: CancellationToken,
    time: Arc<dyn TimeSource>,
    start: Duration,
    visited: usize,
    partial: bool,
    finished: bool,
    cancelled: bool,
    truncated: bool,
}
impl ScanCursor {
    pub fn new(root: impl Into<PathBuf>, options: ScanOptions, cancellation: CancellationToken) -> Result<Self, String> {
        Self::with_time(root, options, cancellation, Arc::new(MonotonicTime::default()))
    }
    pub fn with_time(root: impl Into<PathBuf>, options: ScanOptions, cancellation: CancellationToken, time: Arc<dyn TimeSource>) -> Result<Self, String> {
        let root = root.into();
        if !root.is_absolute() || root.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
            return Err("expected absolute traversal root without dot components".into());
        }
        if options.batch_time.is_zero() { return Err("batch time must be positive".into()); }
        let start = time.elapsed();
        Ok(Self { pending: Some((root.clone(), 0)), root, stack: Vec::new(), volume: None,
            options, cancellation, time, start, visited: 0, partial: false, finished: false,
            cancelled: false, truncated: false })
    }
    fn stop(&mut self) {
        self.finished = true;
        self.pending = None;
        self.stack.clear();
    }
    /// Bounded by attempted entries, not successful candidates. A single OS call cannot be preempted.
    pub fn next_batch(&mut self) -> ScanBatch { self.next_with_limit(self.options.batch_entries) }
    fn next_with_limit(&mut self, limit: NonZeroUsize) -> ScanBatch {
        let start = self.time.elapsed();
        let limit = limit.get().min(self.options.batch_entries.get());
        let mut result = ScanBatch::default();
        let mut work = 0;
        while !self.finished && work < limit {
            if self.cancellation.is_cancelled() { self.cancelled = true; self.stop(); break; }
            let now = self.time.elapsed();
            if self.options.total_entries.is_some_and(|n| self.visited >= n)
                || self.options.total_time.is_some_and(|d| now.saturating_sub(self.start) >= d) {
                self.truncated = true; self.stop(); break;
            }
            if now.saturating_sub(start) >= self.options.batch_time { break; }
            let (path, depth) = if let Some(item) = self.pending.take() { item } else {
                let Some(frame) = self.stack.last_mut() else { self.stop(); break; };
                match frame.entries.next() {
                    Some(Ok(entry)) => (entry.path(), frame.depth + 1),
                    Some(Err(error)) => {
                        let path = frame.path.clone();
                        // Directory iterator failures may repeat indefinitely on some filesystems.
                        self.stack.pop();
                        self.partial = true; self.visited += 1; work += 1;
                        result.entries.push(Entry { path, outcome: EntryOutcome::Unreadable(error.to_string()) });
                        continue;
                    }
                    None => { self.stack.pop(); work += 1; continue; }
                }
            };
            work += 1; self.visited += 1;
            let outcome = self.inspect(&path, depth);
            if matches!(outcome, EntryOutcome::Unreadable(_) | EntryOutcome::Vanished) { self.partial = true; }
            if depth != 0 || self.options.include_root || !matches!(outcome, EntryOutcome::Candidate(_)) {
                result.entries.push(Entry { path, outcome });
            }
        }
        result.finished = self.finished;
        result.partial = self.partial;
        result.cancelled = self.cancelled;
        result.truncated = self.truncated;
        result
    }
    fn inspect(&mut self, path: &Path, depth: usize) -> EntryOutcome {
        let Some(text) = path.to_str() else { return EntryOutcome::Unreadable("native path cannot be represented by core UTF-8 strings; never converted lossily".into()); };
        // Reject symlink ancestors too (including a user-supplied scope beneath a link).
        if let Err(error) = reject_link_ancestors(path) { return EntryOutcome::Unreadable(error); }
        let metadata = match fs::symlink_metadata(path) {
            Ok(m) => m,
            Err(e) => return io_outcome(e),
        };
        if is_link(&metadata) { return EntryOutcome::SymlinkOrReparsePoint; }
        if !metadata.is_dir() && !metadata.is_file() {
            return EntryOutcome::Unreadable("special filesystem object is not an eligible item".into());
        }
        let candidate = match inspect_native(text) {
            Ok(Some(c)) => c,
            Ok(None) => return EntryOutcome::Vanished,
            Err(e) => return EntryOutcome::Unreadable(e),
        };
        let volume = self.volume.get_or_insert(candidate.identity.volume);
        if !self.options.allow_other_volumes && *volume != candidate.identity.volume { return EntryOutcome::OtherVolume; }
        if metadata.is_dir() && self.options.max_depth.is_none_or(|max| depth < max) {
            if self.stack.len() >= self.options.open_directories.get() {
                return EntryOutcome::Unreadable("open-directory budget reached; subtree retained".into());
            }
            // Recheck after adapter inspection, before opening a directory.
            if let Err(e) = reject_link_ancestors(path) { return EntryOutcome::Unreadable(e); }
            match fs::symlink_metadata(path) {
                Ok(m) if is_link(&m) => return EntryOutcome::SymlinkOrReparsePoint,
                Ok(_) => {},
                Err(e) => return io_outcome(e),
            }
            match fs::read_dir(path) {
                Ok(entries) => self.stack.push(Frame { path: path.to_owned(), entries, depth }),
                Err(e) => return io_outcome(e),
            }
        }
        EntryOutcome::Candidate(candidate)
    }
    pub fn root(&self) -> &Path { &self.root }
}
fn io_outcome(error: io::Error) -> EntryOutcome {
    if error.kind() == io::ErrorKind::NotFound { EntryOutcome::Vanished }
    else { EntryOutcome::Unreadable(error.to_string()) }
}
fn reject_link_ancestors(path: &Path) -> Result<(), String> {
    for parent in path.ancestors().skip(1) {
        let m = fs::symlink_metadata(parent).map_err(|e| e.to_string())?;
        if is_link(&m) { return Err("symlink/reparse ancestor is not traversable".into()); }
    }
    Ok(())
}
#[cfg(unix)]
fn is_link(metadata: &Metadata) -> bool { metadata.file_type().is_symlink() }
#[cfg(windows)]
fn is_link(metadata: &Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    metadata.file_attributes() & 0x400 != 0 // FILE_ATTRIBUTE_REPARSE_POINT, includes junctions.
}
#[cfg(unix)]
fn inspect_native(path: &str) -> Result<Option<RuleCandidate>, String> {
    // Metadata inspection does not consult or create the injected Trash directory.
    tinyprune_unix::UnixFileAccess::new(PathBuf::new()).inspect_metadata(path).map(|v| v.map(|i| i.candidate))
}
#[cfg(windows)]
fn inspect_native(path: &str) -> Result<Option<RuleCandidate>, String> {
    use tinyprune_core::trash::FileAccess;
    tinyprune_windows::WindowsFileAccess::default().inspect(path)
}

/// Explicit user-initiated dry-run traversal (ADR 0003). No store or executor is accepted.
/// Caller resolves managed-root access, chooses depth, and evaluates emitted candidates with the
/// shared resolver in Preview disposition. This API does not save policies or return match counts.
pub fn preview(root: impl Into<PathBuf>, mut options: ScanOptions, cancellation: CancellationToken) -> Result<ScanCursor, String> {
    options.batch_entries = NonZeroUsize::new(options.batch_entries.get().min(256)).unwrap();
    options.total_entries = Some(options.total_entries.unwrap_or(500_000).min(500_000));
    options.total_time = Some(options.total_time.unwrap_or(Duration::from_secs(20)).min(Duration::from_secs(20)));
    ScanCursor::new(root, options, cancellation)
}

/// Explicitly collected snapshot. Only complete successful snapshots satisfy MetadataSource.
#[derive(Default)]
pub struct ScanSnapshot { candidates: Vec<RuleCandidate>, finished: bool, incomplete: bool }
impl ScanSnapshot {
    pub fn append(&mut self, batch: ScanBatch) {
        self.incomplete |= self.finished || batch.partial || batch.cancelled || batch.truncated;
        self.finished = batch.finished;
        self.candidates.extend(batch.entries.into_iter().filter_map(|e| match e.outcome {
            EntryOutcome::Candidate(c) => Some(c), _ => None,
        }));
    }
}
impl MetadataSource for ScanSnapshot {
    fn candidates(&self) -> Result<&[RuleCandidate], String> {
        if !self.finished || self.incomplete { Err("incomplete metadata snapshot; retain previous schedules".into()) }
        else { Ok(&self.candidates) }
    }
}

/// Existing agent integration fails the entire reconciliation on partial enumeration. The agent
/// retains its prior deadlines and blocks execution until a successful full recovery.
#[derive(Default)]
pub struct ProductionIndexSource {
    pub options: ScanOptions,
    pub cancellation: CancellationToken,
    cursor: Option<ScanCursor>,
}
impl IndexSource for ProductionIndexSource {
    fn available(&mut self, root: &str) -> Result<bool, String> {
        if reject_link_ancestors(Path::new(root)).is_err() { return Ok(false); }
        let metadata = match fs::symlink_metadata(root) {
            Ok(m) => m,
            Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied) => return Ok(false),
            Err(e) => return Err(e.to_string()),
        };
        Ok(metadata.is_dir() && !is_link(&metadata) && fs::read_dir(root).is_ok())
    }
    fn begin(&mut self, path: &str) -> Result<(), String> {
        self.cursor = None;
        self.cursor = Some(ScanCursor::new(path, self.options.clone(), self.cancellation.clone())?);
        Ok(())
    }
    fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String> {
        let batch = self.cursor.as_mut().ok_or("enumeration has not begun")?.next_with_limit(limit);
        if batch.partial || batch.truncated || batch.cancelled {
            return Err("incomplete filesystem enumeration; retain previous schedules".into());
        }
        Ok(IndexBatch { candidates: batch.entries.into_iter().filter_map(|e| match e.outcome {
            EntryOutcome::Candidate(c) => Some(c), _ => None,
        }).collect(), complete: batch.finished })
    }
}

#[cfg(test)]
mod tests;
