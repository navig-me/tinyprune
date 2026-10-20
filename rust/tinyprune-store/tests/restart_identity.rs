//! Observation lifetimes across a store reopen (daemon restart): FirstObserved/last survive for the same
//! identity, and reset for replaced files or reused inodes. Fakes cover every platform; a real-tree test
//! covers the Unix adapter's durable identity.
#[cfg(unix)]
use std::path::Path;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use tinyprune_core::rule::*;
use tinyprune_core::scheduler::{self, MetadataSource, ObservationStore, ScanPolicy};
use tinyprune_core::trash::Clock;
use tinyprune_core::uuid::Uuid;
use tinyprune_store::Store;

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Dir(PathBuf);
impl Dir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "tinyprune-restart-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(std::fs::canonicalize(path).unwrap())
    }
    fn db(&self) -> PathBuf {
        self.0.join("state.sqlite")
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct At(f64);
impl Clock for At {
    fn now(&self) -> f64 {
        self.0
    }
}
struct Snapshot(Vec<RuleCandidate>);
impl MetadataSource for Snapshot {
    fn candidates(&self) -> Result<&[RuleCandidate], String> {
        Ok(&self.0)
    }
}

fn rule(root: &str) -> LifetimeRule {
    LifetimeRule::new(
        Uuid(2),
        "first observed",
        RuleScope::new(root, true).unwrap(),
        ItemMatcher::new(ItemKind::File, vec![], vec![]).unwrap(),
        ExpiryBasis::FirstObserved,
        RuleDuration(60.0),
        None,
        FolderAction::TrashItem,
        RuleState::Active,
        RuleMatchMode::Scoped,
    )
    .unwrap()
}
const SETTINGS: AgentSettings = AgentSettings {
    default_grace_period_seconds: 0.0,
    protect_hidden_files: false,
    path_flavor: PathFlavor::Posix,
};

fn scan(
    store: &mut Store,
    root: &str,
    candidates: Vec<RuleCandidate>,
    now: f64,
    removed: &[String],
) {
    let rules = [rule(root)];
    let policy = ScanPolicy {
        root,
        rules: &rules,
        overrides: &[],
        settings: &SETTINGS,
    };
    scheduler::scan(
        &Snapshot(candidates),
        store,
        &At(now),
        &policy,
        &[],
        removed,
    )
    .unwrap();
}

fn observed(store: &Store, identity: &FilesystemIdentity) -> Option<(f64, f64)> {
    store
        .observation(identity)
        .unwrap()
        .map(|o| (o.first, o.last))
}

fn fake(resource: u8, birth: Option<f64>, path: &str, kind: ItemKind) -> RuleCandidate {
    RuleCandidate::new(
        FilesystemIdentity {
            volume: Uuid(0xABCD),
            resource: vec![resource],
            path_hint: path.into(),
            creation_time: birth,
            generation: None,
            is_persistent: true,
        },
        path.rsplit('/').next().unwrap().into(),
        kind,
        CandidateTimestamps {
            modified: Some(1.0),
            ..Default::default()
        },
    )
}

#[test]
fn unchanged_file_keeps_first_and_last_observed_across_reopen() {
    let dir = Dir::new();
    let file = fake(1, Some(50.0), "/root/a.tmp", ItemKind::File);
    {
        let mut store = Store::open(dir.db()).unwrap();
        scan(&mut store, "/root", vec![file.clone()], 1_000.0, &[]);
        assert_eq!(observed(&store, &file.identity), Some((1_000.0, 1_000.0)));
    }
    let mut store = Store::open(dir.db()).unwrap();
    assert_eq!(
        observed(&store, &file.identity),
        Some((1_000.0, 1_000.0)),
        "reopen must retain the observation"
    );
    scan(&mut store, "/root", vec![file.clone()], 1_030.0, &[]);
    let (first, last) = observed(&store, &file.identity).unwrap();
    assert_eq!(first, 1_000.0, "FirstObserved deadline must not restart");
    assert_eq!(last, 1_000.0_f64.max(1.0));
}

#[test]
fn replaced_file_and_reused_inode_reset_the_timer() {
    let dir = Dir::new();
    let original = fake(1, Some(50.0), "/root/a.tmp", ItemKind::File);
    {
        let mut store = Store::open(dir.db()).unwrap();
        scan(&mut store, "/root", vec![original.clone()], 1_000.0, &[]);
    }
    let mut store = Store::open(dir.db()).unwrap();
    // New inode at the same path (atomic-save replacement): different resource, so a fresh observation.
    let replaced = fake(2, Some(900.0), "/root/a.tmp", ItemKind::File);
    scan(&mut store, "/root", vec![replaced.clone()], 1_100.0, &[]);
    assert_eq!(
        observed(&store, &replaced.identity),
        Some((1_100.0, 1_100.0))
    );
    // Same inode number reissued to a new file (different birth time): the old record must not apply.
    let reused = fake(1, Some(1_050.0), "/root/b.tmp", ItemKind::File);
    assert_ne!(reused.identity, original.identity);
    assert_eq!(
        observed(&store, &reused.identity),
        None,
        "stale record is invisible after inode reuse"
    );
    scan(&mut store, "/root", vec![reused.clone()], 1_200.0, &[]);
    assert_eq!(observed(&store, &reused.identity), Some((1_200.0, 1_200.0)));
}

#[test]
fn fractional_birth_times_round_trip_bit_exactly() {
    let dir = Dir::new();
    let mut store = Store::open(dir.db()).unwrap();
    let mut seed = 0x9E37_79B9_7F4A_7C15_u64;
    let candidates: Vec<RuleCandidate> = (0..200u32)
        .map(|n| {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let birth = 1.7e9 + (seed >> 11) as f64 / (1u64 << 53) as f64 * 1e8;
            let mut candidate = fake(1, Some(birth), &format!("/root/{n}.tmp"), ItemKind::File);
            candidate.identity.resource = n.to_be_bytes().to_vec();
            candidate
        })
        .collect();
    scan(&mut store, "/root", candidates.clone(), 1_000.0, &[]);
    for candidate in &candidates {
        assert!(
            observed(&store, &candidate.identity).is_some(),
            "{:?}",
            candidate.identity.creation_time
        );
    }
}

#[test]
fn nonpersistent_identities_are_dropped_on_reopen() {
    let dir = Dir::new();
    let mut transient = fake(1, None, "/root/a.tmp", ItemKind::File);
    transient.identity.is_persistent = false;
    {
        let mut store = Store::open(dir.db()).unwrap();
        scan(&mut store, "/root", vec![transient.clone()], 1_000.0, &[]);
        assert!(observed(&store, &transient.identity).is_some());
    }
    assert_eq!(
        observed(&Store::open(dir.db()).unwrap(), &transient.identity),
        None
    );
}

#[test]
fn directory_rename_preserves_descendants_across_restart() {
    let dir = Dir::new();
    let before = |path: &str, res| fake(res, Some(50.0), path, ItemKind::File);
    let old_children = [before("/root/old/a.tmp", 10), before("/root/old/b.tmp", 11)];
    {
        let mut store = Store::open(dir.db()).unwrap();
        scan(&mut store, "/root", old_children.to_vec(), 1_000.0, &[]);
    }
    // Daemon restarts, then discovers the rename: scan the new subtree first, then drop the old path.
    let mut store = Store::open(dir.db()).unwrap();
    let new_children = [before("/root/new/a.tmp", 10), before("/root/new/b.tmp", 11)];
    scan(
        &mut store,
        "/root",
        new_children.to_vec(),
        1_040.0,
        &["/root/old".to_string()],
    );
    drop(store);
    let store = Store::open(dir.db()).unwrap();
    for (child, moved) in old_children.iter().zip(&new_children) {
        assert_eq!(child.identity, moved.identity);
        let (first, _) = observed(&store, &moved.identity)
            .expect("descendant observation survived rename and removal of old path");
        assert_eq!(first, 1_000.0);
    }
}

#[cfg(unix)]
mod real_tree {
    use super::*;
    use std::fs;
    use tinyprune_core::trash::FileAccess;
    use tinyprune_unix::UnixFileAccess;

    fn inspect(files: &mut UnixFileAccess, path: &Path) -> RuleCandidate {
        files.inspect(path.to_str().unwrap()).unwrap().unwrap()
    }

    #[test]
    fn reopen_keeps_observation_and_replacement_resets() {
        let dir = Dir::new();
        let tree = dir.0.join("tree");
        fs::create_dir_all(tree.join("old")).unwrap();
        let root = tree.to_str().unwrap().to_owned();
        fs::write(tree.join("old/a.tmp"), b"a").unwrap();
        fs::write(tree.join("keep.tmp"), b"k").unwrap();
        let mut files = UnixFileAccess::new(dir.0.join("trash"));
        let first = inspect(&mut files, &tree.join("keep.tmp"));
        let nested = inspect(&mut files, &tree.join("old/a.tmp"));
        if !first.identity.is_persistent {
            eprintln!("filesystem lacks birth time or a durable volume id; durable-identity assertions skipped");
            return;
        }
        {
            let mut store = Store::open(dir.db()).unwrap();
            scan(
                &mut store,
                &root,
                vec![first.clone(), nested.clone()],
                1_000.0,
                &[],
            );
        }
        let db = dir.db();
        let mut store = Store::open(&db).unwrap();
        assert_eq!(
            observed(
                &store,
                &inspect(&mut files, &tree.join("keep.tmp")).identity
            ),
            Some((1_000.0, 1_000.0))
        );

        // Directory rename across a reopen: descendants keep their first-observed time.
        fs::rename(tree.join("old"), tree.join("new")).unwrap();
        let moved = inspect(&mut files, &tree.join("new/a.tmp"));
        assert_eq!(moved.identity, nested.identity);
        scan(
            &mut store,
            &root,
            vec![inspect(&mut files, &tree.join("keep.tmp")), moved.clone()],
            1_040.0,
            &[tree.join("old").to_str().unwrap().to_owned()],
        );
        drop(store);
        let mut store = Store::open(&db).unwrap();
        assert_eq!(
            observed(&store, &moved.identity).map(|o| o.0),
            Some(1_000.0)
        );

        // A different file at the same path (atomic-save style) is a new identity with a fresh timer.
        fs::rename(tree.join("keep.tmp"), tree.join("parked.tmp")).unwrap();
        fs::write(tree.join("keep.tmp"), b"replacement").unwrap();
        let replacement = inspect(&mut files, &tree.join("keep.tmp"));
        assert_ne!(replacement.identity, first.identity);
        scan(&mut store, &root, vec![replacement.clone()], 1_100.0, &[]);
        assert_eq!(
            observed(&store, &replacement.identity).map(|o| o.0),
            Some(1_100.0)
        );
    }
}
