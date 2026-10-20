#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tinyprune_core::resolve::{ItemOverridePolicy, ItemPolicyOverride};
use tinyprune_core::rule::{AgentSettings, FilesystemIdentity, ItemKind, RuleState};
use tinyprune_core::trash::*;
use tinyprune_core::uuid::Uuid;
use tinyprune_unix::UnixFileAccess;

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Tree(PathBuf);
impl Tree {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("tinyprune-unix-{}-{}-{}", std::process::id(), epoch().to_bits(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&root).unwrap();
        Self(root.canonicalize().unwrap())
    }
    fn path(&self, name: &str) -> PathBuf { self.0.join(name) }
    fn files(&self) -> UnixFileAccess { UnixFileAccess::new(self.path("Trash")) }
}
impl Drop for Tree { fn drop(&mut self) { fs::remove_dir_all(&self.0).unwrap(); } }
fn epoch() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64() }
fn s(path: &Path) -> &str { path.to_str().unwrap() }
fn identity(files: &mut UnixFileAccess, path: &Path) -> FilesystemIdentity { files.inspect(s(path)).unwrap().unwrap().identity }
fn budget(max_entries: usize) -> WalkBudget { WalkBudget { max_entries, deadline: epoch() + 60.0 } }

#[test]
fn trash_file_directory_and_info() {
    let tree = Tree::new();
    let mut files = tree.files();
    let file = tree.path("space #é%.txt");
    fs::write(&file, b"retained").unwrap();
    let id = identity(&mut files, &file);
    let inspection = files.inspect_metadata(s(&file)).unwrap().unwrap();
    assert!(inspection.changed_at > 0.0);
    assert!(inspection.candidate.timestamps.modified.is_some());
    assert_eq!(inspection.candidate.kind, ItemKind::File);
    let trashed = files.move_to_trash(s(&file), &id).unwrap();
    assert!(!file.exists());
    assert_eq!(fs::read(&trashed).unwrap(), b"retained");
    let info = fs::read_to_string(tree.path("Trash/info/space #é%.txt.trashinfo")).unwrap();
    let encoded = s(&file).replace(' ', "%20").replace('#', "%23").replace('é', "%C3%A9").replace("%.txt", "%25.txt");
    assert!(info.starts_with(&format!("[Trash Info]\nPath={encoded}\nDeletionDate=")), "{info}");
    let date = info.lines().last().unwrap().strip_prefix("DeletionDate=").unwrap();
    assert_eq!(date.len(), 19);
    assert_eq!(&date[10..11], "T");
    let directory = tree.path("folder");
    fs::create_dir(&directory).unwrap();
    fs::write(directory.join("child"), b"child retained").unwrap();
    let id = identity(&mut files, &directory);
    assert_eq!(files.inspect(s(&directory)).unwrap().unwrap().kind, ItemKind::Directory);
    let moved = files.move_to_trash(s(&directory), &id).unwrap();
    assert!(!directory.exists());
    assert!(Path::new(&moved).join("child").is_file());
}

#[test]
fn collisions_never_overwrite_files_or_info() {
    let tree = Tree::new();
    let mut files = tree.files();
    let item = tree.path("same");
    fs::write(&item, b"first").unwrap();
    let id = identity(&mut files, &item);
    let first = files.move_to_trash(s(&item), &id).unwrap();
    // An orphaned destination must be respected even without its .trashinfo.
    fs::write(tree.path("Trash/files/same.1"), b"orphan").unwrap();
    // An existing info record must be respected even without its payload.
    fs::write(tree.path("Trash/info/same.2.trashinfo"), b"old record").unwrap();
    fs::write(&item, b"second").unwrap();
    let id = identity(&mut files, &item);
    let second = files.move_to_trash(s(&item), &id).unwrap();
    assert_eq!(Path::new(&second).file_name().unwrap(), "same.3");
    assert_eq!(fs::read(first).unwrap(), b"first");
    assert_eq!(fs::read(second).unwrap(), b"second");
    assert_eq!(fs::read(tree.path("Trash/files/same.1")).unwrap(), b"orphan");
    assert_eq!(fs::read(tree.path("Trash/info/same.2.trashinfo")).unwrap(), b"old record");
}

#[test]
fn symlinks_and_replaced_identity_are_rejected() {
    let tree = Tree::new();
    let mut files = tree.files();
    fs::create_dir(tree.path("real")).unwrap();
    fs::write(tree.path("real/item"), b"original").unwrap();
    symlink(tree.path("real"), tree.path("link")).unwrap();
    assert!(files.has_symbolic_link_ancestor(s(&tree.path("link/item")), s(&tree.0)).unwrap());
    assert!(files.inspect(s(&tree.path("link"))).unwrap_err().contains("symbolic link"));
    let original = identity(&mut files, &tree.path("real/item"));
    assert!(files.move_to_trash(s(&tree.path("link/item")), &original).unwrap_err().contains("symbolic link ancestor"));
    fs::rename(tree.path("real/item"), tree.path("old")).unwrap();
    fs::write(tree.path("real/item"), b"replacement").unwrap();
    let replacement = identity(&mut files, &tree.path("real/item"));
    assert_ne!(original, replacement);
    assert!(files.move_to_trash(s(&tree.path("real/item")), &original).unwrap_err().contains("identity changed"));
    assert!(tree.path("real/item").exists());
}

#[test]
fn walks_enforce_bounds_hidden_and_keep_protection() {
    let tree = Tree::new();
    let mut files = tree.files();
    fs::create_dir_all(tree.path("root/nested")).unwrap();
    fs::write(tree.path("root/nested/item"), b"x").unwrap();
    let root = tree.path("root");
    assert_eq!(files.has_protected_descendant(s(&root), &[], true, budget(0)).unwrap(), DescendantProtection::Indeterminate);
    assert_eq!(files.has_protected_descendant(s(&root), &[], true, budget(1)).unwrap(), DescendantProtection::Indeterminate);
    assert_eq!(files.has_protected_descendant(s(&root), &[], true, budget(2)).unwrap(), DescendantProtection::None);
    assert_eq!(files.has_protected_descendant(s(&root), &[], true, WalkBudget { max_entries: 100, deadline: 0.0 }).unwrap(), DescendantProtection::Indeterminate);
    fs::write(tree.path("root/.secret"), b"x").unwrap();
    assert_eq!(files.has_protected_descendant(s(&root), &[], true, budget(100)).unwrap(), DescendantProtection::Protected);
    // Hidden protection is decided by the coordinator; false means dot entries are not protected.
    assert_eq!(files.has_protected_descendant(s(&root), &[], false, budget(0)).unwrap(), DescendantProtection::None);
    let kept = tree.path("root/nested/item");
    let kept_id = identity(&mut files, &kept);
    let keep = ItemPolicyOverride::new(Uuid(10), Some(kept_id), "/old/location", ItemOverridePolicy::Keep { protect_descendants: false });
    assert_eq!(files.has_protected_descendant(s(&root), &[keep], false, budget(100)).unwrap(), DescendantProtection::Protected);
    // Recorded Keep paths fail toward protection even when their target has disappeared.
    let keep = ItemPolicyOverride::new(Uuid(11), None, s(&tree.path("root/missing")), ItemOverridePolicy::Keep { protect_descendants: false });
    assert_eq!(files.has_protected_descendant(s(&root), &[keep], false, budget(0)).unwrap(), DescendantProtection::Protected);
}

#[test]
fn walks_do_not_follow_symlinks_and_trash_directory_symlinks_are_rejected() {
    let tree = Tree::new();
    let mut files = tree.files();
    fs::create_dir(tree.path("root")).unwrap();
    fs::create_dir(tree.path("external")).unwrap();
    fs::write(tree.path("external/.hidden"), b"x").unwrap();
    symlink(tree.path("external"), tree.path("root/link")).unwrap();
    assert_eq!(files.has_protected_descendant(s(&tree.path("root")), &[], true, budget(10)).unwrap(), DescendantProtection::None);
    symlink(tree.path("root"), tree.path("Trash")).unwrap();
    let item = tree.path("item");
    fs::write(&item, b"x").unwrap();
    let id = identity(&mut files, &item);
    assert!(files.move_to_trash(s(&item), &id).is_err());
    assert!(item.exists());
    assert!(!tree.path("root/files").exists());
}

struct Store(PolicySnapshot);
impl PolicyStore for Store { fn load_snapshot(&mut self) -> Result<PolicySnapshot, String> { Ok(self.0.clone()) } }
struct Audit(Vec<AuditEvent>);
impl AuditSink for Audit { fn append(&mut self, event: AuditEvent) -> Result<(), String> { self.0.push(event); Ok(()) } }
struct WallClock;
impl Clock for WallClock { fn now(&self) -> f64 { epoch() } }
struct Gate;
impl UpdateGate for Gate { fn acquire_trash_permit(&mut self) -> Result<bool, String> { Ok(true) } }
struct Sizes;
impl SizeMeasurer for Sizes { fn measure(&mut self, _: &str) -> Option<SizeMeasurement> { None } }

#[test]
fn coordinator_moves_due_tree_but_keep_descendant_blocks_it() {
    let tree = Tree::new();
    let mut files = tree.files();
    fs::create_dir(tree.path("managed")).unwrap();
    let mut audit = Audit(Vec::new());
    let mut gate = Gate;
    let mut sizes = Sizes;
    for protected in [false, true] {
        let directory = tree.path(if protected { "managed/blocked" } else { "managed/due" });
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("child"), b"retained").unwrap();
        let id = identity(&mut files, &directory);
        let mut overrides = vec![ItemPolicyOverride::new(Uuid(1), Some(id.clone()), s(&directory), ItemOverridePolicy::CustomExpiry { expires_at: 0.0, state: RuleState::Active })];
        if protected {
            overrides.push(ItemPolicyOverride::new(Uuid(2), None, s(&directory.join("child")), ItemOverridePolicy::Keep { protect_descendants: false }));
        }
        let mut store = Store(PolicySnapshot { rules: Vec::new(), overrides, managed_roots: vec![s(&tree.path("managed")).into()], globally_paused: false, settings: AgentSettings::default() });
        let mut coordinator = TrashCoordinator { policy: &mut store, files: &mut files, audit: &mut audit, clock: &WallClock, gate: &mut gate, hydrator: None, sizes: &mut sizes, walk_limits: DescendantWalkLimits::default() };
        let result = coordinator.execute(&TrashRequest { candidate_identity: id, source: ScheduledSource::CustomOverride(Uuid(1)), scheduled_at: 0.0 }).unwrap();
        if protected {
            assert!(matches!(&result, Outcome::Skipped(reason) if reason == "folder contains a protected descendant"));
            assert!(directory.join("child").exists());
            assert!(!tree.path("Trash/files/blocked").exists());
        } else {
            let Outcome::MovedToTrash { trashed_path, .. } = result else { panic!("expected move: {result:?}"); };
            assert!(Path::new(&trashed_path).starts_with(tree.path("Trash/files")));
            assert!(Path::new(&trashed_path).join("child").exists());
            assert!(!directory.exists());
        }
    }
    assert_eq!(audit.0.iter().filter(|event| event.kind == AuditKind::MovedToTrash).count(), 1);
    assert_eq!(audit.0.iter().filter(|event| event.kind == AuditKind::SafetySkipped).count(), 1);
}
