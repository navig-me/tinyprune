use super::*;
use crate::EventKind;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Tree(PathBuf);
impl Tree {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "tinyprune-watch-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(fs::canonicalize(path).unwrap())
    }
}
impl Drop for Tree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn until(source: &mut WindowsEventSource, predicate: impl Fn(&EventBatch) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        let batch = source
            .poll(Duration::from_millis(100), NonZeroUsize::new(1).unwrap())
            .unwrap();
        assert!(batch.events.len() <= 1);
        if predicate(&batch) {
            return;
        }
    }
    panic!("directory notification did not arrive before deadline");
}

#[test]
fn recursive_create_modify_rename_delete_and_cancel() {
    let tree = Tree::new();
    let nested = tree.0.join("nested");
    fs::create_dir(&nested).unwrap();
    let mut source = WindowsEventSource::new([tree.0.clone()]).unwrap();
    let old = nested.join("old");
    fs::write(&old, b"test-owned fixture").unwrap();
    until(&mut source, |batch| {
        batch
            .events
            .iter()
            .any(|event| event.path == old && event.kind == EventKind::Created)
    });
    fs::write(&old, b"updated fixture").unwrap();
    until(&mut source, |batch| {
        batch
            .events
            .iter()
            .any(|event| event.path == old && event.kind == EventKind::Modified)
    });
    let new = nested.join("new");
    fs::rename(&old, &new).unwrap();
    until(&mut source, |batch| {
        batch.events.iter().any(|event| {
            event.path == new
                && matches!(&event.kind, EventKind::Renamed { from, .. } if from == &old)
        })
    });
    fs::remove_file(&new).unwrap();
    until(&mut source, |batch| {
        batch
            .events
            .iter()
            .any(|event| event.path == new && event.kind == EventKind::Removed)
    });
    // The next request is pending. Drop must cancel and drain before freeing it.
    drop(source);
    fs::remove_dir(&nested).unwrap();
}

#[test]
fn overflow_simulation_marks_root_and_discards_pairing() {
    let tree = Tree::new();
    let mut source = WindowsEventSource::new([tree.0.clone()]).unwrap();
    source.watches[0].pairing.kind(4);
    // Inject the same loss path used for zero-byte/ERROR_NOTIFY_ENUM_DIR completions.
    source.watches[0].lost(&mut source.coalescer);
    assert!(matches!(
        source.watches[0].pairing.kind(5),
        RawKind::RenameTo(0)
    ));
    let batch = source
        .poll(Duration::ZERO, NonZeroUsize::new(1).unwrap())
        .unwrap();
    assert_eq!(batch.must_rescan, vec![tree.0.clone()]);
}

#[test]
fn root_unavailability_and_zero_timeout() {
    let tree = Tree::new();
    let mut source = WindowsEventSource::new([tree.0.clone()]).unwrap();
    let batch = source
        .poll(Duration::ZERO, NonZeroUsize::new(1).unwrap())
        .unwrap();
    assert!(batch.events.is_empty());
    fs::remove_dir(&tree.0).unwrap();
    until(&mut source, |batch| batch.must_rescan.contains(&tree.0));
}

#[test]
fn overlapping_and_relative_roots_are_rejected() {
    let tree = Tree::new();
    let child = tree.0.join("child");
    fs::create_dir(&child).unwrap();
    assert!(WindowsEventSource::new([tree.0.clone(), child]).is_err());
    assert!(WindowsEventSource::new([PathBuf::from("relative")]).is_err());
}
