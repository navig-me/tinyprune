use super::*;
use std::cell::RefCell;
use std::rc::Rc;
use tinyprune_core::resolve::{ItemOverridePolicy, ItemPolicyOverride};
use tinyprune_core::scheduler::{Observation, Project};
use tinyprune_watch::{RawEvent, RawKind, ScriptedEventSource};

#[derive(Default)]
struct Store {
    observations: Vec<Observation>,
    projects: Vec<Project>,
    deadlines: Vec<TrashRequest>,
}
impl ObservationStore for Store {
    fn observation(&self, identity: &FilesystemIdentity) -> Result<Option<Observation>, String> {
        Ok(self
            .observations
            .iter()
            .find(|o| o.identity == *identity)
            .cloned())
    }
    fn save_observation(&mut self, observation: Observation) -> Result<(), String> {
        self.observations
            .retain(|o| o.identity != observation.identity);
        self.observations.push(observation);
        Ok(())
    }
    fn projects(&self) -> Result<&[Project], String> {
        Ok(&self.projects)
    }
    fn publish_projects(&mut self, _: &str, projects: Vec<Project>) -> Result<(), String> {
        self.projects = projects;
        Ok(())
    }
    fn remove_below(&mut self, path: &str) -> Result<(), String> {
        self.observations
            .retain(|o| !within(&o.identity.path_hint, path));
        Ok(())
    }
}
impl AgentStore for Store {
    fn load_deadlines(&mut self) -> Result<Vec<TrashRequest>, String> {
        Ok(self.deadlines.clone())
    }
    fn replace_deadlines(&mut self, root: &str, deadlines: &[TrashRequest]) -> Result<(), String> {
        self.deadlines
            .retain(|r| !within(&r.candidate_identity.path_hint, root));
        self.deadlines.extend_from_slice(deadlines);
        Ok(())
    }
    fn remove_deadline(&mut self, request: &TrashRequest) -> Result<(), String> {
        self.deadlines.retain(|r| {
            r.candidate_identity != request.candidate_identity
                || r.scheduled_at != request.scheduled_at
        });
        Ok(())
    }
}
#[derive(Default)]
struct Audit {
    events: Vec<AuditEvent>,
    dangling: Vec<FilesystemIdentity>,
}
impl AuditSink for Audit {
    fn append(&mut self, event: AuditEvent) -> Result<(), String> {
        self.events.push(event);
        Ok(())
    }
}
impl AgentAudit for Audit {
    fn dangling_attempts(&mut self) -> Result<Vec<FilesystemIdentity>, String> {
        Ok(self.dangling.clone())
    }
    fn finish_recovery(
        &mut self,
        identity: &FilesystemIdentity,
        event: AuditEvent,
    ) -> Result<(), String> {
        self.dangling.retain(|i| i != identity);
        self.append(event)
    }
}
struct Policy(PolicySnapshot);
impl PolicyStore for Policy {
    fn load_snapshot(&mut self) -> Result<PolicySnapshot, String> {
        Ok(self.0.clone())
    }
}
type Tree = Rc<RefCell<Vec<RuleCandidate>>>;
struct Files {
    tree: Tree,
    moved: Vec<String>,
    fail: Vec<String>,
}
impl FileAccess for Files {
    fn inspect(&mut self, path: &str) -> Result<Option<RuleCandidate>, String> {
        Ok(self
            .tree
            .borrow()
            .iter()
            .find(|c| c.identity.path_hint == path)
            .cloned())
    }
    fn has_symbolic_link_ancestor(&mut self, _: &str, _: &str) -> Result<bool, String> {
        Ok(false)
    }
    fn has_protected_descendant(
        &mut self,
        path: &str,
        overrides: &[ItemPolicyOverride],
        _: bool,
        _: WalkBudget,
    ) -> Result<DescendantProtection, String> {
        Ok(
            if overrides.iter().any(|o| {
                o.path != path
                    && within(&o.path, path)
                    && matches!(o.policy, ItemOverridePolicy::Keep { .. })
            }) {
                DescendantProtection::Protected
            } else {
                DescendantProtection::None
            },
        )
    }
    fn move_to_trash(&mut self, path: &str, _: &FilesystemIdentity) -> Result<String, String> {
        if self.fail.iter().any(|p| p == path) {
            return Err("injected move failure".into());
        }
        self.moved.push(path.into());
        self.tree
            .borrow_mut()
            .retain(|c| !within(&c.identity.path_hint, path));
        Ok(format!("/trash{path}"))
    }
}
struct Index {
    tree: Tree,
    cursor: VecDeque<RuleCandidate>,
    available: bool,
    starts: Vec<String>,
}
impl IndexSource for Index {
    fn available(&mut self, _: &str) -> Result<bool, String> {
        Ok(self.available)
    }
    fn begin(&mut self, path: &str) -> Result<(), String> {
        self.starts.push(path.into());
        self.cursor = self
            .tree
            .borrow()
            .iter()
            .filter(|c| within(&c.identity.path_hint, path))
            .cloned()
            .collect();
        Ok(())
    }
    fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String> {
        let candidates = (0..limit.get())
            .filter_map(|_| self.cursor.pop_front())
            .collect();
        Ok(IndexBatch {
            candidates,
            complete: self.cursor.is_empty(),
        })
    }
}
fn candidate(path: &str, id: u8) -> RuleCandidate {
    RuleCandidate {
        identity: FilesystemIdentity {
            volume: Uuid(1),
            resource: vec![id],
            path_hint: path.into(),
            creation_time: Some(0.0),
            generation: None,
            is_persistent: true,
        },
        name: path.rsplit('/').next().unwrap().into(),
        kind: ItemKind::File,
        timestamps: CandidateTimestamps {
            modified: Some(0.0),
            ..Default::default()
        },
        platform_hidden: false,
    }
}
fn policy(root: &str) -> Policy {
    Policy(PolicySnapshot {
        rules: vec![LifetimeRule {
            id: Uuid(2),
            name: "expire".into(),
            scope: RuleScope::new(root, true).unwrap(),
            matcher: ItemMatcher::new(ItemKind::FileOrDirectory, vec![], vec![]).unwrap(),
            expiry_basis: ExpiryBasis::Modified,
            lifetime: RuleDuration(10.0),
            grace_period: None,
            action: FolderAction::TrashItem,
            state: RuleState::Active,
            match_mode: RuleMatchMode::Scoped,
        }],
        overrides: vec![],
        managed_roots: vec![root.into()],
        globally_paused: false,
        settings: AgentSettings::default(),
    })
}
type TestAgent = Agent<Files, Policy, Store, Audit, ScriptedEventSource, Index>;
fn agent(candidates: Vec<RuleCandidate>) -> TestAgent {
    let tree = Rc::new(RefCell::new(candidates));
    Agent::new(
        Files {
            tree: tree.clone(),
            moved: vec![],
            fail: vec![],
        },
        policy("/root"),
        Store::default(),
        Audit::default(),
        ScriptedEventSource::default(),
        Index {
            tree,
            cursor: VecDeque::new(),
            available: true,
            starts: vec![],
        },
    )
}
fn raw(path: &str, kind: RawKind) -> RawEvent {
    RawEvent {
        root: "/root".into(),
        path: path.into(),
        kind,
        is_directory: false,
    }
}
#[test]
fn windows_project_hydration_matches_the_project_itself_across_spellings() {
    let mut item = candidate(r"\\?\c:\managed\project", 1);
    let mut project = item.identity.clone();
    project.path_hint = "C:/Managed/Project".into();
    let store = Store {
        projects: vec![Project {
            identity: project,
            activity: 42.0,
        }],
        ..Default::default()
    };
    item = Hydrator(&store, PathFlavor::Windows)
        .hydrate(&item, &[], 50.0)
        .unwrap();
    assert_eq!(item.timestamps.project_activity, Some(42.0));
    assert!(same_path(
        r"\\?\c:\managed",
        "C:/MANAGED",
        PathFlavor::Windows
    ));
    assert!(!same_path("/managed", "/MANAGED", PathFlavor::Posix));
}
#[test]
fn scheduled_item_moves_at_deadline_with_scripted_clock() {
    let mut agent = agent(vec![candidate("/root/a", 1)]);
    assert_eq!(agent.tick_clock(&At(9.0)).unwrap().trashed, 0);
    assert_eq!(agent.tick_clock(&At(10.0)).unwrap().trashed, 1);
    assert_eq!(agent.files.moved, ["/root/a"]);
    assert!(agent.store.deadlines.is_empty());
}
#[test]
fn preview_and_pause_and_unavailable_never_move() {
    for mode in 0..3 {
        let mut agent = agent(vec![candidate("/root/a", 1)]);
        if mode == 0 {
            agent.policy.0.rules[0].state = RuleState::Preview;
        }
        if mode == 1 {
            agent.policy.0.globally_paused = true;
        }
        if mode == 2 {
            agent.index.available = false;
        }
        agent.tick(20.0).unwrap();
        agent.tick(400.0).unwrap();
        assert!(agent.files.moved.is_empty());
    }
}
#[test]
fn keep_descendant_blocks_parent() {
    let mut folder = candidate("/root/folder", 1);
    folder.kind = ItemKind::Directory;
    let mut agent = agent(vec![folder, candidate("/root/folder/keep", 2)]);
    agent.policy.0.overrides.push(ItemPolicyOverride::new(
        Uuid(9),
        None,
        "/root/folder/keep",
        ItemOverridePolicy::Keep {
            protect_descendants: true,
        },
    ));
    agent.tick(20.0).unwrap();
    assert!(agent.files.moved.is_empty());
}
#[test]
fn rename_preserves_first_observed_deadline() {
    let mut agent = agent(vec![candidate("/root/old", 1)]);
    agent.policy.0.rules[0].expiry_basis = ExpiryBasis::FirstObserved;
    agent.tick(0.0).unwrap();
    {
        let mut tree = agent.files.tree.borrow_mut();
        tree[0].identity.path_hint = "/root/new".into();
        tree[0].name = "new".into();
    }
    agent.events = ScriptedEventSource::new([vec![
        raw("/root/old", RawKind::RenameFrom(7)),
        raw("/root/new", RawKind::RenameTo(7)),
    ]]);
    agent.tick(5.0).unwrap();
    assert_eq!(agent.store.deadlines[0].scheduled_at, 10.0);
    assert_eq!(agent.store.observations[0].identity.path_hint, "/root/new");
    assert_eq!(agent.tick(10.0).unwrap().trashed, 1);
}
#[test]
fn overflow_reconciles_new_and_removed_items_in_bounded_batches() {
    let mut agent = agent(vec![candidate("/root/old", 1)]);
    agent.tick(0.0).unwrap();
    *agent.files.tree.borrow_mut() = vec![candidate("/root/new", 2), candidate("/root/other", 3)];
    agent.limits.index_entries = NonZeroUsize::new(1).unwrap();
    agent.events = ScriptedEventSource::new([vec![raw("/root", RawKind::QueueOverflow)]]);
    let report = agent.tick(20.0).unwrap();
    assert_eq!(report.indexed, 1);
    assert!(report.pending_work);
    assert!(agent.files.moved.is_empty());
    assert_eq!(agent.tick(20.0).unwrap().trashed, 2);
    assert!(!agent.files.moved.contains(&"/root/old".into()));
}
#[test]
fn failed_item_backs_off_without_blocking_others() {
    let mut agent = agent(vec![candidate("/root/a", 1), candidate("/root/b", 2)]);
    agent.files.fail.push("/root/a".into());
    let report = agent.tick(10.0).unwrap();
    assert_eq!(report.failures.len(), 1);
    assert_eq!(report.trashed, 1);
    assert_eq!(agent.tick(39.0).unwrap().executed, 0);
    assert_eq!(agent.tick(40.0).unwrap().executed, 1);
    assert_eq!(agent.tick(99.0).unwrap().executed, 0);
    assert_eq!(agent.tick(100.0).unwrap().executed, 1);
}
#[test]
fn restart_recovery_and_wake_replay_precede_cleanup() {
    let mut agent = agent(vec![candidate("/root/a", 1)]);
    agent.policy.0.rules[0].expiry_basis = ExpiryBasis::ObservedActivity;
    agent.tick(0.0).unwrap();
    let identity = agent.files.tree.borrow()[0].identity.clone();
    let mut restarted = Agent::new(
        agent.files,
        agent.policy,
        agent.store,
        Audit {
            dangling: vec![identity],
            ..Default::default()
        },
        ScriptedEventSource::new([vec![
            raw("/root/a", RawKind::Modified),
            raw("/root/a", RawKind::Attribute),
        ]]),
        agent.index,
    );
    restarted.files.tree.borrow_mut()[0].timestamps.modified = Some(95.0);
    restarted.limits.events = NonZeroUsize::new(1).unwrap();
    let report = restarted.tick(100.0).unwrap();
    assert_eq!(report.recovered, 1);
    assert!(report.pending_work);
    assert!(restarted.files.moved.is_empty());
    restarted.tick(100.0).unwrap();
    assert!(restarted.files.moved.is_empty());
    assert_eq!(restarted.store.deadlines[0].scheduled_at, 105.0);
    assert_eq!(restarted.tick(105.0).unwrap().trashed, 1);
    assert!(restarted.audit.dangling.is_empty());
}
#[test]
fn cancellation_mid_index_publishes_nothing_and_resume_continues() {
    let mut agent = agent(vec![candidate("/root/a", 1), candidate("/root/b", 2)]);
    agent.limits.index_entries = NonZeroUsize::new(1).unwrap();
    assert_eq!(agent.tick(20.0).unwrap().indexed, 1);
    assert!(agent.store.deadlines.is_empty());
    agent.cancel();
    let report = agent.tick(20.0).unwrap();
    assert!(report.cancelled);
    assert_eq!(report.indexed, 0);
    assert!(agent.files.moved.is_empty());
    agent.resume();
    assert_eq!(agent.tick(20.0).unwrap().trashed, 2);
}
#[test]
fn per_tick_execution_budget_and_targeted_event_scan() {
    let mut agent = agent(vec![candidate("/root/a", 1), candidate("/root/b", 2)]);
    agent.limits.due_items = NonZeroUsize::new(1).unwrap();
    assert_eq!(agent.tick(10.0).unwrap().trashed, 1);
    assert_eq!(agent.tick(10.0).unwrap().trashed, 1);
    agent.files.tree.borrow_mut().push(candidate("/root/c", 3));
    agent.events = ScriptedEventSource::new([vec![raw("/root/c", RawKind::Created)]]);
    assert_eq!(agent.tick(10.0).unwrap().trashed, 1);
    assert_eq!(agent.index.starts.last().unwrap(), "/root/c");
}

#[test]
fn absent_event_paths_reconcile_before_removing_schedules() {
    struct RejectMissingIndex(Index);
    impl IndexSource for RejectMissingIndex {
        fn available(&mut self, root: &str) -> Result<bool, String> {
            self.0.available(root)
        }
        fn begin(&mut self, path: &str) -> Result<(), String> {
            if path != "/root"
                && !self
                    .0
                    .tree
                    .borrow()
                    .iter()
                    .any(|c| c.identity.path_hint == path)
            {
                return Err("injected missing traversal root; incomplete enumeration".into());
            }
            self.0.begin(path)
        }
        fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String> {
            self.0.next_batch(limit)
        }
    }
    for mode in 0..5 {
        let mut survivor = candidate("/root/keep", 2);
        survivor.timestamps.modified = Some(100.0);
        let initial = agent(vec![candidate("/root/gone", 1), survivor]);
        let mut agent = Agent::new(
            initial.files,
            initial.policy,
            initial.store,
            initial.audit,
            initial.events,
            RejectMissingIndex(initial.index),
        );
        agent.tick(0.0).unwrap();
        if mode == 4 {
            assert_eq!(agent.tick(10.0).unwrap().trashed, 1);
        } else {
            agent
                .files
                .tree
                .borrow_mut()
                .retain(|c| c.identity.path_hint != "/root/gone");
        }
        let events = match mode {
            0 | 4 => vec![raw("/root/gone", RawKind::Removed)],
            1 => vec![raw("/root/gone", RawKind::Created)],
            2 => vec![raw("/root/gone", RawKind::Modified)],
            _ => vec![
                raw("/root/gone", RawKind::RenameFrom(7)),
                raw("/root/also-gone", RawKind::RenameTo(7)),
            ],
        };
        agent.events = ScriptedEventSource::new([events]);
        let report = agent.tick(10.0).unwrap();
        assert!(!report.pending_work);
        assert_eq!(agent.index.0.starts.last().unwrap(), "/root");
        assert_eq!(agent.store.deadlines.len(), 1);
        assert_eq!(
            agent.store.deadlines[0].candidate_identity.path_hint,
            "/root/keep"
        );
        assert_eq!(agent.store.deadlines[0].scheduled_at, 110.0);
        assert!(agent
            .store
            .observations
            .iter()
            .all(|o| o.identity.path_hint == "/root/keep"));
        assert_eq!(agent.files.moved.len(), usize::from(mode == 4));
    }
}

#[test]
fn runtime_pause_preview_and_root_disconnect_block_existing_deadlines() {
    for mode in 0..3 {
        let mut agent = agent(vec![candidate("/root/a", 1)]);
        agent.tick(0.0).unwrap();
        if mode == 0 {
            agent.policy.0.globally_paused = true;
        }
        if mode == 1 {
            agent.policy.0.rules[0].state = RuleState::Preview;
        }
        if mode == 2 {
            agent.index.available = false;
        }
        agent.tick(10.0).unwrap();
        assert!(agent.files.moved.is_empty());
    }
}

#[test]
fn failed_enumeration_requires_recovery_before_old_deadline_executes() {
    struct FailingIndex {
        inner: Index,
        fail: bool,
    }
    impl IndexSource for FailingIndex {
        fn available(&mut self, root: &str) -> Result<bool, String> {
            self.inner.available(root)
        }
        fn begin(&mut self, path: &str) -> Result<(), String> {
            self.inner.begin(path)
        }
        fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String> {
            if self.fail {
                Err("injected enumeration failure".into())
            } else {
                self.inner.next_batch(limit)
            }
        }
    }
    let initial = agent(vec![candidate("/root/a", 1)]);
    let mut agent = Agent::new(
        initial.files,
        initial.policy,
        initial.store,
        initial.audit,
        initial.events,
        FailingIndex {
            inner: initial.index,
            fail: false,
        },
    );
    agent.tick(0.0).unwrap();
    agent.index.fail = true;
    agent.reconcile("/root");
    assert!(agent.tick(10.0).is_err());
    assert!(agent.tick(20.0).is_err());
    assert!(agent.files.moved.is_empty());
    agent.index.fail = false;
    assert_eq!(agent.tick(20.0).unwrap().trashed, 1);
}

#[cfg(unix)]
#[test]
fn real_unix_tree_moves_expired_file_to_injected_trash() {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use tinyprune_unix::UnixFileAccess;
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Temp(PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let temp = Temp(
        std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "tinyprune-agent-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )),
    );
    let root = temp.0.join("managed");
    let trash = temp.0.join("trash");
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("expired");
    std::fs::write(&file, b"fixture").unwrap();
    // The index reads the actual tree in bounded calls using the real adapter's metadata.
    struct RealIndex {
        cursor: VecDeque<PathBuf>,
        files: UnixFileAccess,
    }
    impl IndexSource for RealIndex {
        fn available(&mut self, root: &str) -> Result<bool, String> {
            Ok(std::path::Path::new(root).is_dir())
        }
        fn begin(&mut self, path: &str) -> Result<(), String> {
            self.cursor = VecDeque::from([PathBuf::from(path)]);
            Ok(())
        }
        fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String> {
            let mut candidates = vec![];
            for _ in 0..limit.get() {
                let Some(path) = self.cursor.pop_front() else {
                    break;
                };
                if let Some(candidate) = self.files.inspect(path.to_str().unwrap())? {
                    if candidate.kind == ItemKind::Directory {
                        for entry in std::fs::read_dir(&path).map_err(|e| e.to_string())? {
                            self.cursor
                                .push_back(entry.map_err(|e| e.to_string())?.path());
                        }
                    }
                    candidates.push(candidate);
                }
            }
            Ok(IndexBatch {
                candidates,
                complete: self.cursor.is_empty(),
            })
        }
    }
    let mut files = UnixFileAccess::new(&trash);
    let modified = files
        .inspect(file.to_str().unwrap())
        .unwrap()
        .unwrap()
        .timestamps
        .modified
        .unwrap();
    let mut agent = Agent::new(
        files,
        policy(root.to_str().unwrap()),
        Store::default(),
        Audit::default(),
        ScriptedEventSource::default(),
        RealIndex {
            cursor: VecDeque::new(),
            files: UnixFileAccess::new(&trash),
        },
    );
    agent.limits.index_entries = NonZeroUsize::new(1).unwrap();
    let clock = At(modified + 20.0);
    assert!(agent.tick_clock(&clock).unwrap().pending_work);
    assert_eq!(agent.tick_clock(&clock).unwrap().trashed, 1);
    assert!(!file.exists());
    assert_eq!(std::fs::read_dir(trash.join("files")).unwrap().count(), 1);
    assert!(agent
        .audit
        .events
        .iter()
        .any(|e| e.kind == AuditKind::MovedToTrash));
}
