//! Unreleased event-source infrastructure, not a platform-support promise.
//! Events are hints for reinspection, never authorization to Trash.

use std::collections::{HashSet, VecDeque};
use std::io;
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::time::Duration;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::InotifyEventSource;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum EventKind {
    Created,
    Modified,
    Removed,
    Attribute,
    Renamed { from: PathBuf, cookie: u32 },
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct PathEvent {
    pub root: PathBuf,
    pub path: PathBuf,
    pub kind: EventKind,
    pub is_directory: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EventBatch {
    pub events: Vec<PathEvent>,
    /// Each root must be re-enumerated. A signal is never permission to Trash.
    pub must_rescan: Vec<PathBuf>,
    /// Call again with zero timeout to continue bounded outstanding work.
    pub pending_work: bool,
}

/// Synchronous, pollable hints. `limit` bounds raw events, directory entries,
/// and returned path events per call. Zero timeout never waits. Implementations
/// may return earlier than timeout, particularly while recursive setup is pending.
pub trait EventSource {
    fn poll(&mut self, timeout: Duration, limit: NonZeroUsize) -> io::Result<EventBatch>;
}

/// Raw hints also used by the deterministic fake; no clock or sleeping required.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RawKind {
    Created,
    Modified,
    Removed,
    Attribute,
    RenameFrom(u32),
    RenameTo(u32),
    QueueOverflow,
    WatchLimit,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RawEvent {
    pub root: PathBuf,
    pub path: PathBuf,
    pub kind: RawKind,
    pub is_directory: bool,
}

#[derive(Default)]
struct Coalescer {
    // Preserve unmatched moves across bounded reads until the source is drained.
    moves: Vec<RawEvent>,
    output: VecDeque<PathEvent>,
    rescans: Vec<PathBuf>,
}

impl Coalescer {
    fn rescan(&mut self, root: PathBuf) {
        if !self.rescans.contains(&root) {
            self.rescans.push(root);
        }
    }

    fn emit(&mut self, event: RawEvent, kind: EventKind) {
        self.output.push_back(PathEvent {
            root: event.root,
            path: event.path,
            kind,
            is_directory: event.is_directory,
        });
    }

    fn push(&mut self, event: RawEvent) {
        match event.kind {
            RawKind::QueueOverflow | RawKind::WatchLimit => {
                self.moves.retain(|pending| pending.root != event.root);
                self.rescan(event.root);
            }
            RawKind::RenameFrom(cookie) if cookie != 0 => {
                // A continuously busy queue might never drain. Bound retained
                // cookies and downgrade excess moves to conservative hints.
                if self.moves.len() == 4096 {
                    self.rescan(event.root.clone());
                    self.emit(event, EventKind::Removed);
                } else {
                    self.moves.push(event);
                }
            }
            RawKind::RenameTo(cookie) if cookie != 0 => {
                let index = self.moves.iter().position(|pending| {
                    pending.kind == RawKind::RenameFrom(cookie) && pending.root == event.root
                });
                if let Some(index) = index {
                    let from = self.moves.remove(index).path;
                    self.emit(event, EventKind::Renamed { from, cookie });
                } else {
                    self.emit(event, EventKind::Created);
                }
            }
            RawKind::Created | RawKind::RenameTo(_) => self.emit(event, EventKind::Created),
            RawKind::Removed | RawKind::RenameFrom(_) => self.emit(event, EventKind::Removed),
            RawKind::Modified => self.emit(event, EventKind::Modified),
            RawKind::Attribute => self.emit(event, EventKind::Attribute),
        }
    }

    fn drained(&mut self) {
        for event in std::mem::take(&mut self.moves) {
            self.emit(event, EventKind::Removed);
        }
    }

    fn batch(&mut self, limit: usize, pending: bool) -> EventBatch {
        let mut seen = HashSet::new();
        let mut events = Vec::new();
        while events.len() < limit {
            let Some(event) = self.output.pop_front() else { break };
            if seen.insert(event.clone()) {
                events.push(event);
            }
        }
        EventBatch {
            events,
            must_rescan: std::mem::take(&mut self.rescans),
            pending_work: pending || !self.output.is_empty() || !self.moves.is_empty(),
        }
    }
}

/// Each frame is one drain of an event queue. Cookie pairs may straddle bounded
/// polls within a frame. Unpaired moves become remove/create hints at its end.
/// Empty frames model a timeout. Polling never sleeps, regardless of timeout.
#[derive(Default)]
pub struct ScriptedEventSource {
    frames: VecDeque<VecDeque<RawEvent>>,
    coalescer: Coalescer,
}

impl ScriptedEventSource {
    pub fn new(frames: impl IntoIterator<Item = Vec<RawEvent>>) -> Self {
        Self {
            frames: frames.into_iter().map(VecDeque::from).collect(),
            coalescer: Coalescer::default(),
        }
    }
}

impl EventSource for ScriptedEventSource {
    fn poll(&mut self, _timeout: Duration, limit: NonZeroUsize) -> io::Result<EventBatch> {
        if self.coalescer.output.is_empty() {
            if let Some(frame) = self.frames.front_mut() {
                for _ in 0..limit.get() {
                    let Some(event) = frame.pop_front() else { break };
                    self.coalescer.push(event);
                }
                if frame.is_empty() {
                    self.frames.pop_front();
                    self.coalescer.drained();
                }
            }
        }
        Ok(self.coalescer.batch(limit.get(), !self.frames.is_empty()))
    }
}

// Shared, pure descriptor bookkeeping. Paths are byte-preserving PathBufs;
// prefix operations use components rather than textual prefixes.
#[cfg(any(target_os = "linux", test))]
#[derive(Default)]
struct WatchTable(std::collections::BTreeMap<i32, (PathBuf, PathBuf)>);

#[cfg(any(target_os = "linux", test))]
impl WatchTable {
    fn insert(&mut self, descriptor: i32, root: PathBuf, path: PathBuf) {
        self.0.insert(descriptor, (root, path));
    }

    fn subtree(&mut self, path: &std::path::Path) -> Vec<i32> {
        let descriptors: Vec<_> = self.0.iter()
            .filter(|(_, (_, watched))| watched.starts_with(path))
            .map(|(descriptor, _)| *descriptor).collect();
        for descriptor in &descriptors {
            self.0.remove(descriptor);
        }
        descriptors
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(path: &str, kind: RawKind) -> RawEvent {
        RawEvent { root: "/root".into(), path: path.into(), kind, is_directory: false }
    }

    fn poll(source: &mut ScriptedEventSource, limit: usize) -> EventBatch {
        source.poll(Duration::ZERO, NonZeroUsize::new(limit).unwrap()).unwrap()
    }

    #[test]
    fn coalesces_duplicates_but_preserves_different_changes() {
        let mut source = ScriptedEventSource::new([vec![
            raw("/root/a", RawKind::Created), raw("/root/a", RawKind::Modified),
            raw("/root/a", RawKind::Modified), raw("/root/a", RawKind::Attribute),
            raw("/root/a", RawKind::Removed),
        ]]);
        let batch = poll(&mut source, 10);
        assert_eq!(batch.events.iter().map(|e| &e.kind).collect::<Vec<_>>(),
            vec![&EventKind::Created, &EventKind::Modified, &EventKind::Attribute, &EventKind::Removed]);
        assert!(!batch.pending_work);
    }

    #[test]
    fn pairs_rename_across_bounded_polls_and_flushes_unpaired_moves() {
        let mut source = ScriptedEventSource::new([vec![
            raw("/root/a", RawKind::RenameFrom(7)), raw("/root/b", RawKind::RenameTo(7)),
            raw("/root/out", RawKind::RenameFrom(8)), raw("/root/in", RawKind::RenameTo(9)),
        ]]);
        assert!(poll(&mut source, 1).events.is_empty());
        assert_eq!(poll(&mut source, 1).events[0].kind,
            EventKind::Renamed { from: "/root/a".into(), cookie: 7 });
        assert!(poll(&mut source, 1).events.is_empty());
        assert_eq!(poll(&mut source, 1).events[0].kind, EventKind::Created);
        assert_eq!(poll(&mut source, 1).events[0].kind, EventKind::Removed);
        assert!(!poll(&mut source, 1).pending_work);
    }

    #[test]
    fn overflow_and_limit_exhaustion_deduplicate_rescan_and_discard_cookie() {
        let mut source = ScriptedEventSource::new([vec![
            raw("/root/a", RawKind::RenameFrom(1)), raw("/root", RawKind::QueueOverflow),
            raw("/root", RawKind::WatchLimit), raw("/root/b", RawKind::RenameTo(1)),
        ]]);
        let batch = poll(&mut source, 8);
        assert_eq!(batch.must_rescan, vec![PathBuf::from("/root")]);
        assert_eq!(batch.events[0].kind, EventKind::Created);
    }

    #[test]
    fn script_drives_component_aware_watch_removal_and_replacement() {
        let mut table = WatchTable::default();
        table.insert(1, "/root".into(), "/root".into());
        table.insert(2, "/root".into(), "/root/dir".into());
        table.insert(3, "/root".into(), "/root/dir/child".into());
        table.insert(4, "/root".into(), "/root/directory".into());
        let mut source = ScriptedEventSource::new([vec![raw("/root/dir", RawKind::Removed)]]);
        for event in poll(&mut source, 1).events {
            assert_eq!(table.subtree(&event.path), vec![2, 3]);
        }
        table.insert(2, "/root".into(), "/root/new".into());
        assert_eq!(table.0[&2].1, PathBuf::from("/root/new"));
        assert_eq!(table.0.len(), 3);
        assert!(table.subtree(std::path::Path::new("/root/missing")).is_empty());
    }

    #[test]
    fn directory_rename_script_retires_old_descendant_watches() {
        let mut table = WatchTable::default();
        table.insert(1, "/root".into(), "/root/old".into());
        table.insert(2, "/root".into(), "/root/old/child".into());
        let mut from = raw("/root/old", RawKind::RenameFrom(10));
        from.is_directory = true;
        let mut to = raw("/root/new", RawKind::RenameTo(10));
        to.is_directory = true;
        let mut source = ScriptedEventSource::new([vec![from, to]]);
        let batch = poll(&mut source, 2);
        assert!(batch.events[0].is_directory);
        let EventKind::Renamed { from, .. } = &batch.events[0].kind else { panic!("expected rename") };
        assert_eq!(table.subtree(from), vec![1, 2]);
        table.insert(3, "/root".into(), batch.events[0].path.clone());
        table.insert(4, "/root".into(), batch.events[0].path.join("child"));
        assert_eq!(table.subtree(std::path::Path::new("/root/old")), Vec::<i32>::new());
        assert_eq!(table.subtree(std::path::Path::new("/root/new")), vec![3, 4]);
    }

    #[test]
    fn a_busy_queue_bounds_retained_rename_cookies() {
        let frame = (1..=4097).map(|cookie| raw("/root/out", RawKind::RenameFrom(cookie))).collect();
        let mut source = ScriptedEventSource::new([frame]);
        for _ in 0..4096 {
            assert!(poll(&mut source, 1).events.is_empty());
        }
        let batch = poll(&mut source, 1);
        assert_eq!(batch.events.len(), 1);
        assert_eq!(batch.must_rescan, vec![PathBuf::from("/root")]);
        assert!(batch.pending_work);
        assert_eq!(source.coalescer.moves.len(), 0);
    }

    #[test]
    fn cookie_does_not_pair_across_roots_and_empty_frames_never_wait() {
        let mut incoming = raw("/other/b", RawKind::RenameTo(3));
        incoming.root = "/other".into();
        let mut source = ScriptedEventSource::new([
            vec![], vec![raw("/root/a", RawKind::RenameFrom(3)), incoming],
        ]);
        assert!(source.poll(Duration::from_secs(100), NonZeroUsize::new(8).unwrap()).unwrap().events.is_empty());
        let batch = poll(&mut source, 8);
        assert_eq!(batch.events[0].kind, EventKind::Created);
        assert_eq!(batch.events[1].kind, EventKind::Removed);
    }
}
