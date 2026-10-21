use super::*;
use std::sync::atomic::{AtomicU64, AtomicUsize};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Tree(PathBuf);
impl Tree {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "tinyprune-scan-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn file(&self, name: &str) {
        fs::File::create(self.0.join(name)).unwrap();
    }
    fn cursor(&self, options: ScanOptions) -> ScanCursor {
        ScanCursor::new(&self.0, options, CancellationToken::default()).unwrap()
    }
}
impl Drop for Tree {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn collect(cursor: &mut ScanCursor) -> (Vec<Entry>, ScanBatch) {
    let mut entries = Vec::new();
    loop {
        let mut batch = cursor.next_batch();
        entries.append(&mut batch.entries);
        if batch.finished {
            return (entries, batch);
        }
    }
}
#[test]
fn batching_is_streaming_and_bounded() {
    let tree = Tree::new();
    for i in 0..31 {
        tree.file(&format!("file{i}"));
    }
    let options = ScanOptions {
        batch_entries: NonZeroUsize::new(3).unwrap(),
        ..Default::default()
    };
    let mut cursor = tree.cursor(options);
    let first = cursor.next_batch();
    assert_eq!(first.entries.len(), 3);
    assert!(!first.finished);
    let (remaining, end) = collect(&mut cursor);
    assert_eq!(remaining.len() + first.entries.len(), 32);
    assert!(!end.partial);
}
#[test]
fn cancellation_and_hard_caps_never_make_complete_metadata() {
    let tree = Tree::new();
    tree.file("a");
    let token = CancellationToken::default();
    let mut cursor = ScanCursor::new(&tree.0, ScanOptions::default(), token.clone()).unwrap();
    token.cancel();
    let batch = cursor.next_batch();
    assert!(batch.finished && batch.cancelled && batch.entries.is_empty());
    let mut snapshot = ScanSnapshot::default();
    snapshot.append(batch);
    assert!(snapshot.candidates().is_err());
    let options = ScanOptions {
        total_entries: Some(1),
        ..Default::default()
    };
    let (_, end) = collect(&mut tree.cursor(options));
    assert!(end.truncated);
}
#[test]
fn cancellation_between_batches() {
    let tree = Tree::new();
    tree.file("a");
    tree.file("b");
    let token = CancellationToken::default();
    let options = ScanOptions {
        batch_entries: NonZeroUsize::new(1).unwrap(),
        ..Default::default()
    };
    let mut cursor = ScanCursor::new(&tree.0, options, token.clone()).unwrap();
    assert_eq!(cursor.next_batch().entries.len(), 1);
    token.cancel();
    assert!(cursor.next_batch().cancelled);
}
struct Ticking(AtomicUsize);
impl TimeSource for Ticking {
    fn elapsed(&self) -> Duration {
        Duration::from_millis(self.0.fetch_add(1, Ordering::Relaxed) as u64)
    }
}
#[test]
fn injected_time_caps_without_sleeping() {
    let tree = Tree::new();
    tree.file("a");
    let options = ScanOptions {
        total_time: Some(Duration::from_millis(2)),
        ..Default::default()
    };
    let mut cursor = ScanCursor::with_time(
        &tree.0,
        options,
        CancellationToken::default(),
        Arc::new(Ticking(AtomicUsize::new(0))),
    )
    .unwrap();
    assert!(cursor.next_batch().truncated);
}
#[test]
fn batch_time_and_volume_boundary_are_enforced() {
    let tree = Tree::new();
    tree.file("a");
    tree.file("b");
    let options = ScanOptions {
        batch_time: Duration::from_millis(2),
        ..Default::default()
    };
    let mut cursor = ScanCursor::with_time(
        &tree.0,
        options,
        CancellationToken::default(),
        Arc::new(Ticking(AtomicUsize::new(0))),
    )
    .unwrap();
    let batch = cursor.next_batch();
    assert_eq!(batch.entries.len(), 1);
    assert!(!batch.finished && !batch.truncated);
    let actual = match &batch.entries[0].outcome {
        EntryOutcome::Candidate(c) => c.identity.volume,
        _ => panic!("expected root metadata"),
    };
    // Exercise the mount-volume branch without requiring privileged mount setup.
    cursor.volume = Some(Uuid(actual.0.wrapping_add(1)));
    let (entries, end) = collect(&mut cursor);
    assert!(!end.partial);
    assert!(entries
        .iter()
        .all(|e| matches!(e.outcome, EntryOutcome::OtherVolume)));
    let options = ScanOptions {
        allow_other_volumes: true,
        ..Default::default()
    };
    let mut cursor = tree.cursor(options);
    cursor.volume = Some(Uuid(actual.0.wrapping_add(1)));
    assert!(collect(&mut cursor)
        .0
        .iter()
        .all(|e| matches!(e.outcome, EntryOutcome::Candidate(_))));
}
#[test]
fn vanishing_entries_are_partial_and_agent_retains_schedules() {
    let tree = Tree::new();
    tree.file("vanish");
    let path = tree.0.join("vanish");
    let mut cursor =
        ScanCursor::new(&path, ScanOptions::default(), CancellationToken::default()).unwrap();
    fs::remove_file(&path).unwrap();
    let (entries, end) = collect(&mut cursor);
    assert!(matches!(entries[0].outcome, EntryOutcome::Vanished));
    assert!(end.partial);
    let mut source = ProductionIndexSource::default();
    source.begin(path.to_str().unwrap()).unwrap();
    let error = source
        .next_batch(NonZeroUsize::new(256).unwrap())
        .err()
        .unwrap();
    assert!(error.contains(path.to_str().unwrap()), "{error}");
    assert!(
        error.contains("entry vanished during enumeration"),
        "{error}"
    );
}
#[test]
fn index_errors_preserve_unreadable_entry_reason() {
    let tree = Tree::new();
    fs::create_dir_all(tree.0.join("a/b")).unwrap();
    let mut source = ProductionIndexSource {
        options: ScanOptions {
            open_directories: NonZeroUsize::new(1).unwrap(),
            ..Default::default()
        },
        ..Default::default()
    };
    source.begin(tree.0.to_str().unwrap()).unwrap();
    let error = source
        .next_batch(NonZeroUsize::new(256).unwrap())
        .err()
        .unwrap();
    assert!(
        error.contains(tree.0.join("a").to_str().unwrap()),
        "{error}"
    );
    assert!(
        error.contains("open-directory budget reached; subtree retained"),
        "{error}"
    );
}
#[test]
fn hidden_and_noise_are_retained_for_shared_policy_and_protection() {
    let tree = Tree::new();
    fs::create_dir(tree.0.join(".git")).unwrap();
    tree.file(".git/index");
    tree.file(".hidden");
    tree.file("e\u{301}");
    let (entries, end) = collect(&mut tree.cursor(ScanOptions::default()));
    assert!(!end.partial);
    assert_eq!(entries.len(), 5);
    let native_names: Vec<_> = fs::read_dir(&tree.0)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    let names: Vec<_> = entries
        .iter()
        .filter_map(|e| match &e.outcome {
            EntryOutcome::Candidate(c) => Some(c.name.as_str()),
            _ => None,
        })
        .collect();
    assert!(names.contains(&".hidden"));
    // Some filesystems canonicalize names themselves; the scanner must preserve what they return.
    for name in native_names {
        assert!(names.contains(&name.to_str().unwrap()));
    }
    let git_index = tree.0.join(".git/index");
    #[cfg(windows)]
    let flavor = tinyprune_core::path::PathFlavor::Windows;
    #[cfg(not(windows))]
    let flavor = tinyprune_core::path::PathFlavor::Posix;
    assert!(!tinyprune_core::scheduler::meaningful_activity_with_flavor(
        git_index.to_str().unwrap(),
        tree.0.to_str().unwrap(),
        flavor
    ));
}
#[test]
fn scope_depth_and_metadata_snapshot() {
    let tree = Tree::new();
    fs::create_dir(tree.0.join("dir")).unwrap();
    tree.file("dir/child");
    let options = ScanOptions {
        max_depth: Some(1),
        include_root: false,
        ..Default::default()
    };
    let mut cursor = tree.cursor(options);
    let mut snapshot = ScanSnapshot::default();
    assert!(snapshot.candidates().is_err());
    loop {
        let batch = cursor.next_batch();
        let done = batch.finished;
        snapshot.append(batch);
        if done {
            break;
        }
    }
    assert_eq!(snapshot.candidates().unwrap().len(), 1);
    let options = ScanOptions {
        max_depth: Some(0),
        ..Default::default()
    };
    assert_eq!(collect(&mut tree.cursor(options)).0.len(), 1);
}
#[cfg(unix)]
#[test]
fn symlink_loops_and_link_ancestors_are_not_followed() {
    use std::os::unix::fs::symlink;
    let tree = Tree::new();
    fs::create_dir(tree.0.join("dir")).unwrap();
    tree.file("dir/file");
    symlink(&tree.0, tree.0.join("dir/loop")).unwrap();
    let (entries, end) = collect(&mut tree.cursor(ScanOptions::default()));
    assert!(!end.partial);
    assert_eq!(entries.len(), 4);
    assert_eq!(
        entries
            .iter()
            .filter(|e| matches!(e.outcome, EntryOutcome::SymlinkOrReparsePoint))
            .count(),
        1
    );
    let mut linked = ScanCursor::new(
        tree.0.join("dir/loop/dir"),
        ScanOptions::default(),
        CancellationToken::default(),
    )
    .unwrap();
    assert!(collect(&mut linked).1.partial);
}
#[cfg(unix)]
#[test]
fn permission_denied_subtree_is_partial() {
    use std::os::unix::fs::PermissionsExt;
    let tree = Tree::new();
    let denied = tree.0.join("denied");
    fs::create_dir(&denied).unwrap();
    tree.file("denied/child");
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o0)).unwrap();
    // Root/privileged runners can bypass mode bits; still restore before dropping the tree.
    let bypassed = fs::read_dir(&denied).is_ok();
    let (entries, end) = collect(&mut tree.cursor(ScanOptions::default()));
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o700)).unwrap();
    if bypassed {
        eprintln!("permission test: runner bypasses mode bits; denial assertion unavailable");
        return;
    }
    assert!(end.partial);
    assert!(entries
        .iter()
        .any(|e| e.path == denied && matches!(e.outcome, EntryOutcome::Unreadable(_))));
}
#[cfg(unix)]
#[test]
fn invalid_native_path_is_preserved_not_replaced() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    let tree = Tree::new();
    let path = tree.0.join(OsStr::from_bytes(b"bad\xff"));
    let created = fs::File::create(&path).is_ok();
    // APFS rejects illegal byte sequences at creation; Linux filesystems commonly permit them.
    // In either case a native path presented to the scanner must survive its error outcome.
    let mut cursor = if created {
        tree.cursor(ScanOptions::default())
    } else {
        ScanCursor::new(&path, ScanOptions::default(), CancellationToken::default()).unwrap()
    };
    let (entries, end) = collect(&mut cursor);
    assert!(end.partial);
    assert!(entries
        .iter()
        .any(|e| e.path == path && matches!(e.outcome, EntryOutcome::Unreadable(_))));
}
#[test]
fn open_directory_budget_flags_partial() {
    let tree = Tree::new();
    fs::create_dir_all(tree.0.join("a/b/c")).unwrap();
    let options = ScanOptions {
        open_directories: NonZeroUsize::new(1).unwrap(),
        ..Default::default()
    };
    assert!(collect(&mut tree.cursor(options)).1.partial);
}
#[test]
fn preview_is_bounded_and_does_not_mutate_tree() {
    let tree = Tree::new();
    tree.file("a");
    tree.file("b");
    let before = fs::metadata(tree.0.join("a")).unwrap();
    let options = ScanOptions {
        total_entries: Some(1),
        ..Default::default()
    };
    let mut cursor = preview(&tree.0, options, CancellationToken::default()).unwrap();
    assert!(collect(&mut cursor).1.truncated);
    let after = fs::metadata(tree.0.join("a")).unwrap();
    assert_eq!(before.len(), after.len());
    assert_eq!(before.modified().unwrap(), after.modified().unwrap());
    assert_eq!(fs::read_dir(&tree.0).unwrap().count(), 2);
}
#[test]
#[ignore = "50k throughput fixture; run explicitly in release"]
fn bench_50k_metadata_entries() {
    let tree = Tree::new();
    for dir in 0..100 {
        fs::create_dir(tree.0.join(format!("d{dir}"))).unwrap();
        for file in 0..500 {
            tree.file(&format!("d{dir}/f{file}"));
        }
    }
    let start = Instant::now();
    let (entries, end) = collect(&mut tree.cursor(ScanOptions::default()));
    let elapsed = start.elapsed();
    assert!(!end.partial && !end.truncated);
    assert_eq!(entries.len(), 50_101);
    eprintln!(
        "bench: {} entries in {:.3}s = {:.0} entries/sec",
        entries.len(),
        elapsed.as_secs_f64(),
        entries.len() as f64 / elapsed.as_secs_f64()
    );
    assert!(
        elapsed < Duration::from_secs(10),
        "50k metadata traversal exceeded 10 seconds"
    );
}
