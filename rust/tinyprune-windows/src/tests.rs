use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Tree(PathBuf);
impl Tree {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("tinyprune-windows-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn path(&self) -> &str { self.0.to_str().unwrap() }
    fn file(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        File::create(&path).unwrap();
        path
    }
}
impl Drop for Tree {
    fn drop(&mut self) { fs::remove_dir_all(&self.0).unwrap(); }
}
fn now() -> f64 { 100.0 }
fn budget() -> WalkBudget { WalkBudget { max_entries: 100, deadline: 101.0 } }
fn candidate(path: &Path) -> RuleCandidate { inspect_path(text(path).unwrap()).unwrap().unwrap() }
fn keep(path: &str, identity: Option<FilesystemIdentity>) -> ItemPolicyOverride {
    ItemPolicyOverride { id: Uuid(1), identity, path: path.into(), policy: ItemOverridePolicy::Keep { protect_descendants: true } }
}

#[test]
fn identity_uses_volume_and_128_bit_file_id_with_creation_time() {
    let tree = Tree::new();
    let path = tree.file("first");
    let first = candidate(&path);
    assert_eq!(first.identity.resource.len(), 16);
    assert!(first.identity.creation_time.is_some());
    let renamed = tree.0.join("renamed");
    fs::rename(&path, &renamed).unwrap();
    assert_eq!(first.identity, candidate(&renamed).identity);
    // Keep the old file alive, so an ID cannot be recycled for the replacement.
    File::create(&path).unwrap();
    assert_ne!(first.identity, candidate(&path).identity);
    assert!(!first.identity.is_persistent);
}

#[test]
fn missing_stale_identity_and_hint_mismatch_never_recycle() {
    let tree = Tree::new();
    let mut access = WindowsFileAccess::new(now);
    assert!(access.inspect(text(&tree.0.join("absent")).unwrap()).unwrap().is_none());
    let path = tree.file("item");
    let mut expected = candidate(&path).identity;
    expected.resource[0] ^= 1;
    assert!(access.move_to_trash(text(&path).unwrap(), &expected).unwrap_err().contains("identity changed"));
    expected = candidate(&path).identity;
    expected.path_hint.push('x');
    assert!(access.move_to_trash(text(&path).unwrap(), &expected).unwrap_err().contains("path hint"));
    assert!(path.exists());
}

#[test]
fn hints_use_windows_ordinal_case_comparison_and_long_prefix() {
    assert!(path_hints_equal("C:/Managed/Item", "\\\\?\\c:\\MANAGED\\item"));
    assert!(path_hints_equal("\\\\server\\share\\Item", "\\\\?\\UNC\\SERVER\\share\\item"));
    assert!(!within("C:\\managed-other\\item", "c:\\managed"));
    assert!(within("C:\\managed\\item", "c:\\MANAGED"));
    assert!(absolute("C:\\managed\\..\\item").is_err());
    assert!(absolute("C:\\managed\\file:stream").is_err());
    assert!(absolute("C:\\managed\\trailing.").is_err());
}

#[test]
fn hidden_dot_names_and_hidden_attributes_protect_descendants() {
    let tree = Tree::new();
    let path = tree.file(".dot");
    let mut access = WindowsFileAccess::new(now);
    assert_eq!(access.has_protected_descendant(tree.path(), &[], true, budget()).unwrap(), DescendantProtection::Protected);
    fs::rename(&path, tree.0.join("ordinary")).unwrap();
    let hidden = tree.file("attribute-hidden");
    assert!(!candidate(&hidden).platform_hidden);
    let native = wide(text(&absolute(text(&hidden).unwrap()).unwrap()).unwrap()).unwrap();
    // SAFETY: existing test-owned path, nul-terminated and live for the call.
    unsafe { SetFileAttributesW(PCWSTR(native.as_ptr()), FILE_ATTRIBUTE_HIDDEN) }.unwrap();
    assert!(candidate(&hidden).platform_hidden);
    assert_eq!(access.has_protected_descendant(tree.path(), &[], true, budget()).unwrap(), DescendantProtection::Protected);
    assert_eq!(access.has_protected_descendant(tree.path(), &[], false, budget()).unwrap(), DescendantProtection::None);
}

#[test]
fn keep_matches_case_insensitive_path_and_renamed_identity() {
    let tree = Tree::new();
    let path = tree.file("item");
    let identity = candidate(&path).identity;
    let mut access = WindowsFileAccess::new(now);
    assert_eq!(access.has_protected_descendant(tree.path(), &[keep(&text(&path).unwrap().to_uppercase(), None)], false, budget()).unwrap(), DescendantProtection::Protected);
    fs::rename(&path, tree.0.join("renamed")).unwrap();
    assert_eq!(access.has_protected_descendant(tree.path(), &[keep("C:\\unrelated\\old-name", Some(identity))], false, budget()).unwrap(), DescendantProtection::Protected);
}

#[test]
fn entry_and_injected_time_budgets_fail_closed() {
    let tree = Tree::new();
    tree.file("item");
    let mut access = WindowsFileAccess::new(now);
    for budget in [WalkBudget { max_entries: 0, deadline: 101.0 }, WalkBudget { max_entries: 100, deadline: 100.0 }, WalkBudget { max_entries: 100, deadline: f64::NAN }] {
        assert_eq!(access.has_protected_descendant(tree.path(), &[], false, budget).unwrap(), DescendantProtection::Indeterminate);
    }
}

#[test]
fn sharing_violations_are_retryable_and_preserve_source() {
    let tree = Tree::new();
    let path = tree.file("locked");
    let expected = candidate(&path).identity;
    let _lock = OpenOptions::new().read(true).share_mode(0).open(&path).unwrap();
    let mut access = WindowsFileAccess::new(now);
    assert!(access.inspect(text(&path).unwrap()).unwrap_err().contains("transient sharing violation"));
    assert!(access.move_to_trash(text(&path).unwrap(), &expected).unwrap_err().contains("transient sharing violation"));
    drop(_lock);
    assert!(path.exists());
}

#[test]
fn directory_junctions_are_rejected_including_managed_root() {
    let tree = Tree::new();
    let target = tree.0.join("target");
    fs::create_dir(&target).unwrap();
    File::create(target.join("item")).unwrap();
    let junction = tree.0.join("junction");
    let output = std::process::Command::new("cmd").args(["/C", "mklink", "/J"]).arg(&junction).arg(&target).output().unwrap();
    assert!(output.status.success(), "junction creation failed: {}", String::from_utf8_lossy(&output.stderr));
    let mut access = WindowsFileAccess::new(now);
    assert!(access.inspect(text(&junction).unwrap()).is_err());
    let child = junction.join("item");
    assert!(access.has_symbolic_link_ancestor(text(&child).unwrap(), tree.path()).unwrap());
    assert!(access.has_symbolic_link_ancestor(text(&child).unwrap(), text(&junction).unwrap()).unwrap());
    assert_eq!(access.has_protected_descendant(tree.path(), &[], false, budget()).unwrap(), DescendantProtection::Protected);
    fs::remove_dir(junction).unwrap();
}

#[test]
fn extended_length_paths_are_inspected_without_truncation() {
    let tree = Tree::new();
    let mut deep = absolute(tree.path()).unwrap();
    for _ in 0..6 { deep.push("a-long-directory-component-for-path-coverage-1234567890"); }
    fs::create_dir_all(&deep).unwrap();
    let item = deep.join("item");
    File::create(&item).unwrap();
    assert!(text(&item).unwrap().len() > 260);
    assert_eq!(candidate(&item).name, "item");
}

#[test]
fn permanent_delete_callback_is_vetoed() {
    let tree = Tree::new();
    let path = tree.file("item");
    let result = Rc::new(RefCell::new(RecycleResult::default()));
    let sink: IFileOperationProgressSink = RecycleSink { path: text(&path).unwrap().into(), expected: candidate(&path).identity, result: result.clone() }.into();
    // SAFETY: live interface; null item is deliberately unused by the fail-closed flags gate.
    assert!(unsafe { sink.PreDeleteItem(0, None) }.is_err());
    assert!(result.borrow().error.as_ref().unwrap().contains("permanent deletion"));
    assert!(path.exists());
}

#[test]
fn real_recycle_bin_round_trip_or_explicit_unavailability() {
    let tree = Tree::new();
    let path = tree.file("recycle-round-trip");
    let expected = candidate(&path).identity;
    let mut access = WindowsFileAccess::new(now);
    if let Err(reason) = recycle_available(text(&path).unwrap()) {
        assert!(access.move_to_trash(text(&path).unwrap(), &expected).is_err(), "unavailable bin unexpectedly succeeded: {reason}");
        assert!(path.exists());
        return;
    }
    let destination = access.move_to_trash(text(&path).unwrap(), &expected).unwrap();
    assert!(!path.exists());
    assert_eq!(candidate(Path::new(&destination)).identity, expected);
    // Restore the test-owned payload rather than permanently deleting anything from the bin.
    fs::rename(absolute(&destination).unwrap(), &path).unwrap();
    assert!(path.exists());
}
