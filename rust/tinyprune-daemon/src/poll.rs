//! Bounded polling fallback for platforms without a native watcher in `tinyprune-watch` (macOS).
//!
//! Two cadences, both injectable through the clock and never faster than the work they cause:
//! - A directory-change poll walks directory entries (names and the mtime of directories only, never
//!   file contents or per-file metadata). A directory's mtime changes when entries are created, removed or
//!   renamed in it, so the topmost changed directories become `Modified` hints and only their subtrees
//!   are rescanned, like a native watcher would request. The walk is incremental (a fixed entry budget per
//!   poll) and repeats no sooner than `max(interval / 10, 1 s, 10 x` the real cost of the last walk`)`.
//! - A full rescan of each root, no sooner than `max(interval, 10 x` the real duration of the last scan`)`
//!   after that scan finished, catches what directory mtimes cannot (in-place content changes, changes that
//!   raced the poll baseline, too many changed directories). Nothing is queued while a scan or decision
//!   pass is running.
use crate::index::Pace;
use std::{
    collections::{HashMap, VecDeque},
    fs::{self, ReadDir},
    io,
    num::NonZeroUsize,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};
use tinyprune_core::trash::Clock;
use tinyprune_watch::{EventBatch, EventKind, EventSource, PathEvent};

/// Directory entries examined per `poll`.
const WALK_ENTRIES: usize = 8192;
/// Simultaneously open directory handles; deeper directories are not descended (a full rescan covers them).
const OPEN_DIRECTORIES: usize = 256;
/// More changed directories than this are answered with a root rescan hint instead.
const MAX_DIRECTORY_HINTS: usize = 64;
const SCAN_FACTOR: f64 = 10.0;
const WALK_FACTOR: f64 = 10.0;
const MIN_POLL_SECONDS: f64 = 1.0;

struct Walk {
    pending: VecDeque<PathBuf>,
    stack: Vec<(PathBuf, ReadDir)>,
    found: HashMap<PathBuf, SystemTime>,
    spent: Duration,
}
impl Walk {
    fn new(roots: &[PathBuf]) -> Self {
        Self {
            pending: roots.iter().cloned().collect(),
            stack: vec![],
            found: HashMap::new(),
            spent: Duration::ZERO,
        }
    }
    fn open(&mut self, path: PathBuf) {
        let Some(modified) = fs::symlink_metadata(&path)
            .ok()
            .filter(|m| m.is_dir())
            .and_then(|m| m.modified().ok())
        else {
            return;
        };
        self.found.insert(path.clone(), modified);
        if self.stack.len() < OPEN_DIRECTORIES {
            if let Ok(entries) = fs::read_dir(&path) {
                self.stack.push((path, entries));
            }
        }
    }
    /// Examines at most `budget` entries; true when every root has been walked.
    fn step(&mut self, budget: usize) -> bool {
        let started = Instant::now();
        let mut used = 0;
        let done = loop {
            if used >= budget {
                break false;
            }
            let Some((path, entries)) = self.stack.last_mut() else {
                match self.pending.pop_front() {
                    Some(root) => {
                        self.open(root);
                        continue;
                    }
                    None => break true,
                }
            };
            match entries.next() {
                None => {
                    self.stack.pop();
                }
                Some(Err(_)) => used += 1,
                Some(Ok(entry)) => {
                    used += 1;
                    // `file_type` does not follow symbolic links; links are never descended.
                    if entry.file_type().is_ok_and(|t| t.is_dir()) {
                        let child = path.join(entry.file_name());
                        self.open(child);
                    }
                }
            }
        };
        self.spent += started.elapsed();
        done
    }
}

pub(crate) struct Poller {
    roots: Vec<PathBuf>,
    clock: Arc<dyn Clock + Send + Sync>,
    interval: f64,
    pace: Arc<Pace>,
    stamps: HashMap<PathBuf, SystemTime>,
    baselined: bool,
    walk: Option<Walk>,
    next_poll: f64,
    walk_seconds: f64,
    next_full: f64,
    cursor: usize,
}
impl Poller {
    pub fn new(
        roots: Vec<PathBuf>,
        clock: Arc<dyn Clock + Send + Sync>,
        interval: Duration,
        pace: Arc<Pace>,
    ) -> Self {
        let now = clock.now();
        let interval = interval.as_secs_f64();
        Self {
            roots,
            clock,
            interval,
            pace,
            stamps: HashMap::new(),
            baselined: false,
            walk: None,
            // The baseline walk starts immediately, before the initial scan reads the same directories.
            next_poll: now,
            walk_seconds: 0.0,
            next_full: now + interval,
            cursor: 0,
        }
    }
    fn poll_wait(&self) -> f64 {
        (self.interval / 10.0)
            .max(MIN_POLL_SECONDS)
            .max(WALK_FACTOR * self.walk_seconds)
    }
    fn containing_root(&self, path: &Path) -> Option<&PathBuf> {
        self.roots.iter().find(|root| path.starts_with(root))
    }
    /// Topmost changed directories against the previous walk; `None` when too many changed.
    fn changed(&self, found: &HashMap<PathBuf, SystemTime>) -> Option<Vec<PathBuf>> {
        let mut changed: Vec<&PathBuf> = found
            .iter()
            .filter(|(path, modified)| self.stamps.get(*path) != Some(modified))
            .map(|(path, _)| path)
            .collect();
        changed.sort();
        let mut topmost: Vec<PathBuf> = vec![];
        for path in changed {
            if !topmost.last().is_some_and(|top| path.starts_with(top)) {
                topmost.push(path.clone());
            }
        }
        (topmost.len() <= MAX_DIRECTORY_HINTS).then_some(topmost)
    }
}
impl EventSource for Poller {
    fn poll(&mut self, _timeout: Duration, limit: NonZeroUsize) -> io::Result<EventBatch> {
        // The baseline (and every later directory poll) runs even while a scan is in progress: it only
        // reads directory entries, and the baseline must precede the scan's own reads of the same directories.
        let now = self.clock.now();
        let mut batch = EventBatch::default();
        if self.walk.is_none() && now >= self.next_poll {
            self.walk = Some(Walk::new(&self.roots));
        }
        if let Some(walk) = self.walk.as_mut() {
            if walk.step(WALK_ENTRIES) {
                let walk = self.walk.take().expect("walk in progress");
                self.walk_seconds = walk.spent.as_secs_f64();
                if self.baselined {
                    match self.changed(&walk.found) {
                        Some(dirs) => {
                            batch.events = dirs
                                .into_iter()
                                .filter_map(|path| {
                                    Some(PathEvent {
                                        root: self.containing_root(&path)?.clone(),
                                        path,
                                        kind: EventKind::Modified,
                                        is_directory: true,
                                    })
                                })
                                .take(limit.get())
                                .collect();
                        }
                        None => {
                            batch.must_rescan = self.roots.clone();
                            self.next_full = now + self.interval;
                        }
                    }
                }
                self.stamps = walk.found;
                self.baselined = true;
                self.next_poll = now + self.poll_wait();
            }
        }
        batch.pending_work = self.walk.is_some();
        // Slow full rescan, measured from the end of the previous scan. Never queued behind a running
        // scan or pending decision pass (the cheap directory poll above is, so changes are never missed).
        if self.cursor != 0 || (batch.must_rescan.is_empty() && !self.pace.busy()) {
            let wait = self
                .interval
                .max(SCAN_FACTOR * self.pace.last_scan_seconds());
            if self.cursor != 0 || now >= self.next_full.max(self.pace.last_complete() + wait) {
                let end = (self.cursor + limit.get()).min(self.roots.len());
                batch.must_rescan = self.roots[self.cursor..end].to_vec();
                self.cursor = if end == self.roots.len() { 0 } else { end };
                batch.pending_work |= self.cursor != 0;
                if self.cursor == 0 {
                    self.next_full = now + self.interval;
                }
            }
        }
        Ok(batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    struct Clock(AtomicU64);
    impl tinyprune_core::trash::Clock for Clock {
        fn now(&self) -> f64 {
            self.0.load(Ordering::SeqCst) as f64
        }
    }
    fn limit() -> NonZeroUsize {
        NonZeroUsize::new(256).unwrap()
    }
    fn drain(poller: &mut Poller) -> EventBatch {
        let mut all = EventBatch::default();
        for _ in 0..1000 {
            let batch = poller.poll(Duration::ZERO, limit()).unwrap();
            all.events.extend(batch.events);
            all.must_rescan.extend(batch.must_rescan);
            if !batch.pending_work {
                return all;
            }
        }
        panic!("poller never settled");
    }
    #[cfg(unix)]
    #[test]
    fn changed_directories_become_subtree_hints_and_quiet_trees_stay_quiet() {
        let base = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("tinyprune-poll-{}", std::process::id()));
        let root = base.join("root");
        fs::create_dir_all(root.join("a/deep")).unwrap();
        fs::create_dir_all(root.join("b")).unwrap();
        // Fix directory mtimes in the past so a later change is distinguishable even on filesystems with
        // coarse timestamps (no sleeping).
        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        for dir in [
            root.clone(),
            root.join("a"),
            root.join("a/deep"),
            root.join("b"),
        ] {
            fs::File::open(dir).unwrap().set_modified(old).unwrap();
        }
        let clock = Arc::new(Clock(AtomicU64::new(1000)));
        let mut poller = Poller::new(
            vec![root.clone()],
            clock.clone(),
            Duration::from_secs(100),
            Arc::new(Pace::default()),
        );
        // Baseline walk: nothing is reported.
        assert!(drain(&mut poller).events.is_empty());
        // Nothing changed and the next poll is not due: no hints, no rescan.
        clock.0.fetch_add(20, Ordering::SeqCst);
        let quiet = drain(&mut poller);
        assert!(quiet.events.is_empty() && quiet.must_rescan.is_empty());
        // A file appears in a/deep (its mtime changes; file contents are never read).
        fs::write(root.join("a/deep/new.tmp"), b"x").unwrap();
        clock.0.fetch_add(20, Ordering::SeqCst);
        let changed = drain(&mut poller);
        assert_eq!(changed.events.len(), 1);
        assert_eq!(changed.events[0].path, root.join("a/deep"));
        assert_eq!(changed.events[0].root, root);
        assert!(changed.must_rescan.is_empty());
        // Full rescan only after max(interval, ...) since the last scan finished.
        clock.0.fetch_add(200, Ordering::SeqCst);
        assert_eq!(drain(&mut poller).must_rescan, vec![root.clone()]);
        let _ = fs::remove_dir_all(base);
    }
}
