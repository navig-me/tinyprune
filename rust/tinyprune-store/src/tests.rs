use super::*;
use std::{
    num::NonZeroUsize,
    sync::atomic::{AtomicUsize, Ordering},
};
fn identity(n: u8, path: &str) -> FilesystemIdentity {
    FilesystemIdentity {
        volume: Uuid(1),
        resource: vec![n],
        path_hint: path.into(),
        creation_time: Some(0.0),
        generation: Some(1),
        is_persistent: true,
    }
}
fn rule() -> LifetimeRule {
    LifetimeRule::new(
        Uuid(2),
        "expire",
        RuleScope::new("/root", true).unwrap(),
        ItemMatcher::new(ItemKind::File, vec![], vec![]).unwrap(),
        ExpiryBasis::Modified,
        RuleDuration(10.0),
        None,
        FolderAction::TrashItem,
        RuleState::Active,
        RuleMatchMode::Scoped,
    )
    .unwrap()
}
fn request(n: u8, at: f64) -> TrashRequest {
    TrashRequest {
        candidate_identity: identity(n, &format!("/root/{n}")),
        source: ScheduledSource::Rule(Uuid(2)),
        scheduled_at: at,
    }
}
fn event(kind: AuditKind, at: f64) -> AuditEvent {
    AuditEvent {
        occurred_at: at,
        kind,
        identity: Some(identity(1, "/root/a")),
        rule_id: Some(Uuid(2)),
        detail: Some("explanation".into()),
        bytes: Some(100),
        item_count: Some(2),
    }
}
fn candidate(n: u8) -> RuleCandidate {
    RuleCandidate::new(
        identity(n, &format!("/root/{n}")),
        n.to_string(),
        ItemKind::File,
        CandidateTimestamps {
            modified: Some(0.0),
            ..Default::default()
        },
    )
}
#[test]
fn windows_subtree_publication_and_removal_use_lexical_flavor() {
    for (root, native, alias) in [
        (
            r"C:\Managed\Tree",
            r"\\?\c:\managed\tree",
            "C:/MANAGED/TREE",
        ),
        (
            r"\\Server\Share\Tree",
            r"\\?\UNC\server\share\tree",
            "//SERVER/SHARE/TREE",
        ),
    ] {
        let mut store = Store::memory_with_flavor(PathFlavor::Windows).unwrap();
        store.replace_roots(&[root.into()], 0.0).unwrap();
        let mut item = candidate(1);
        item.identity.path_hint = native.into();
        // Include the scan root itself: is_descendant is deliberately strict.
        assert_eq!(
            store
                .publish_candidate_subtree(alias, &[item.clone()], 1.0)
                .unwrap(),
            1
        );
        let mut child = candidate(2);
        child.identity.path_hint = format!(r"{native}\Child.txt");
        store
            .publish_candidate_subtree(alias, &[item.clone(), child.clone()], 2.0)
            .unwrap();
        assert_eq!(
            store
                .candidate_page(alias, None, NonZeroUsize::new(10).unwrap())
                .unwrap()
                .len(),
            2
        );
        store.replace_roots(&[alias.into()], 3.0).unwrap();
        assert_eq!(
            store.candidate_count().unwrap(),
            2,
            "spelling changes must not cascade-delete candidates"
        );
        store
            .save_observation(Observation {
                identity: child.identity.clone(),
                first: 1.0,
                last: 2.0,
            })
            .unwrap();
        store
            .publish_projects(
                alias,
                vec![Project {
                    identity: item.identity.clone(),
                    activity: 2.0,
                }],
            )
            .unwrap();
        store.publish_projects(root, vec![]).unwrap();
        assert!(store.projects().unwrap().is_empty());
        let mut sibling = candidate(3);
        sibling.identity.path_hint = format!("{alias}-other/file");
        assert!(store
            .publish_candidate_subtree(alias, &[sibling], 4.0)
            .is_err());
        assert_eq!(
            store
                .publish_candidate_subtree(alias, &[item], 5.0)
                .unwrap(),
            1
        );
        assert!(store.observation(&child.identity).unwrap().is_some());
        store.remove_below(alias).unwrap();
        assert!(store.observation(&child.identity).unwrap().is_none());
        assert_eq!(store.candidate_count().unwrap(), 0);
    }
}

#[test]
fn default_store_keeps_posix_case_and_separator_semantics() {
    let store = Store::memory().unwrap();
    store.replace_roots(&["/Managed/Tree".into()], 0.0).unwrap();
    let mut item = candidate(1);
    item.identity.path_hint = "/Managed/Tree".into();
    store
        .publish_candidate_subtree("/Managed/Tree", &[item.clone()], 1.0)
        .unwrap();
    for path in ["/managed/tree", r"\Managed\Tree", "/Managed/Tree-other"] {
        item.identity.path_hint = path.into();
        assert!(
            store
                .publish_candidate_subtree("/Managed/Tree", &[item.clone()], 2.0)
                .is_err(),
            "{path}"
        );
    }
    assert_eq!(store.candidate_count().unwrap(), 1);
}
#[test]
fn windows_store_reopen_deadlines_and_trash_cleanup_accept_aliases() {
    let db = Temp::new();
    let root = r"C:\Managed\Tree";
    let alias = r"\\?\c:\managed\tree";
    let mut item = candidate(1);
    item.identity.path_hint = format!("{alias}\\folder");
    let mut child = candidate(2);
    child.identity.path_hint = "C:/MANAGED/TREE/folder/child".into();
    let mut sibling = candidate(3);
    sibling.identity.path_hint = "C:/MANAGED/TREE/folder-other".into();
    let mut request = request(1, 10.0);
    request.candidate_identity = item.identity.clone();
    {
        let mut store = Store::open_with_flavor(&db.0, PathFlavor::Windows).unwrap();
        store.replace_roots(&[root.into()], 0.0).unwrap();
        store
            .replace_candidates(alias, &[item.clone(), child.clone(), sibling.clone()], 1.0)
            .unwrap();
        store.replace_deadlines(root, &[request.clone()]).unwrap();
        store.replace_deadlines(alias, &[]).unwrap();
        assert!(store.load_deadlines().unwrap().is_empty());
        store.replace_deadlines(alias, &[request]).unwrap();
    }
    let mut store = Store::open_with_flavor(&db.0, PathFlavor::Windows).unwrap();
    assert_eq!(store.load_deadlines().unwrap().len(), 1);
    assert_eq!(
        store
            .candidate_page(alias, None, NonZeroUsize::new(10).unwrap())
            .unwrap()
            .len(),
        3
    );
    let mut moved = event(AuditKind::MovedToTrash, 12.0);
    moved.identity = Some(item.identity);
    store.append(moved).unwrap();
    let remaining = store
        .candidate_page(root, None, NonZeroUsize::new(10).unwrap())
        .unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].1.identity, sibling.identity);
    assert!(store.load_deadlines().unwrap().is_empty());
}
struct Temp(std::path::PathBuf);
impl Temp {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        Self(std::env::temp_dir().join(format!(
            "tinyprune-store-{}-{}.sqlite",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )))
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        for suffix in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.0.display()));
        }
    }
}
#[test]
fn migrations_empty_previous_newer_and_file_pragmas() {
    assert_eq!(
        Store::memory().unwrap().schema_version().unwrap(),
        SCHEMA_VERSION
    );
    let mut c = Connection::open_in_memory().unwrap();
    schema::previous(&c);
    let e = event(AuditKind::MovedToTrash, 1.0);
    c.execute(
        "INSERT INTO audit(occurred_at,kind,payload) VALUES(1,'movedToTrash',?)",
        [encode(&Event::from(&e)).unwrap()],
    )
    .unwrap();
    c.execute("INSERT INTO reclaim VALUES(1,1,2,100,2)", [])
        .unwrap();
    schema::migrate(&mut c).unwrap();
    let store = Store::from_connection(c).unwrap();
    assert_eq!(store.reclaim_totals().unwrap().bytes, 100);
    let mut newer = Connection::open_in_memory().unwrap();
    newer
        .pragma_update(None, "user_version", SCHEMA_VERSION + 1)
        .unwrap();
    assert!(schema::migrate(&mut newer).is_err());
    let path = Temp::new();
    let store = Store::open(&path.0).unwrap();
    assert!(store.database_bytes().unwrap() > 0);
    assert!(Store::memory().unwrap().database_bytes().unwrap() > 0);
    let c = store.lock().unwrap();
    assert_eq!(
        c.query_row("PRAGMA journal_mode", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "wal"
    );
    assert_eq!(
        c.query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn repositories_and_restart_roundtrip() {
    fn send<T: Send>() {}
    send::<Store>();
    let path = Temp::new();
    let mut s = Store::open(&path.0).unwrap();
    s.put_rule(&rule(), 1.0).unwrap();
    s.replace_roots(&["/root".into()], 1.0).unwrap();
    for (n, policy) in [
        ItemOverridePolicy::Inherit,
        ItemOverridePolicy::Keep {
            protect_descendants: true,
        },
        ItemOverridePolicy::CustomExpiry {
            expires_at: 42.0,
            state: RuleState::Preview,
        },
    ]
    .into_iter()
    .enumerate()
    {
        s.put_override(
            &ItemPolicyOverride::new(
                Uuid(n as u128 + 10),
                Some(identity(n as u8, "/root/a")),
                "/root/a",
                policy,
            ),
            2.0,
        )
        .unwrap();
    }
    let mut settings = AgentSettings::new(3.0, true);
    settings.path_flavor = PathFlavor::Windows;
    s.set_settings(true, settings, 3.0).unwrap();
    s.publish_projects(
        "/root",
        vec![Project {
            identity: identity(9, "/root/project"),
            activity: 9.0,
        }],
    )
    .unwrap();
    let p = s.load_snapshot().unwrap();
    assert_eq!(p.rules, [rule()]);
    assert_eq!(p.overrides.len(), 3);
    assert!(p.globally_paused);
    assert_eq!(p.settings, settings);
    drop(s);
    let mut s = Store::open(&path.0).unwrap();
    assert_eq!(s.projects().unwrap()[0].activity, 9.0);
    assert_eq!(s.load_snapshot().unwrap().overrides.len(), 3);
    s.remove_rule(Uuid(2), 4.0).unwrap();
    s.remove_override(Uuid(10), 4.0).unwrap();
    assert!(s.load_snapshot().unwrap().rules.is_empty());
    assert_eq!(s.load_snapshot().unwrap().overrides.len(), 2);
}
#[test]
fn transactional_audit_failure_rolls_back_mutations_and_ledger() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    s.replace_deadlines("/root", &[request(1, 1.0)]).unwrap();
    s.lock().unwrap().execute_batch("CREATE TRIGGER reject_audit BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'injected audit failure'); END;").unwrap();
    assert!(s.put_rule(&rule(), 1.0).is_err());
    assert!(s.load_snapshot().unwrap().rules.is_empty());
    assert!(s
        .put_override(
            &ItemPolicyOverride::new(
                Uuid(3),
                None,
                "/root/a",
                ItemOverridePolicy::Keep {
                    protect_descendants: true
                }
            ),
            1.0
        )
        .is_err());
    assert!(s
        .set_settings(true, AgentSettings::new(0.0, true), 1.0)
        .is_err());
    assert!(!s.load_snapshot().unwrap().globally_paused);
    assert!(s.replace_roots(&[], 1.0).is_err());
    assert_eq!(s.load_deadlines().unwrap().len(), 1);
    assert!(s.replace_deadlines("/root", &[request(2, 2.0)]).is_err());
    assert_eq!(
        s.load_deadlines().unwrap()[0].candidate_identity.resource,
        [1]
    );
    assert!(s.append(event(AuditKind::MovedToTrash, 2.0)).is_err());
    assert_eq!(s.reclaim_totals().unwrap().items, 0);
}
#[test]
fn successful_move_state_and_ledger_are_one_transaction() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    s.replace_deadlines("/root", &[request(1, 1.0)]).unwrap();
    let mut child = candidate(2);
    child.identity.path_hint = "/root/a/child".into();
    s.replace_candidates("/root", &[candidate(1), child, candidate(3)], 0.0)
        .unwrap();
    s.append(event(AuditKind::TrashAttempted, 1.0)).unwrap();
    s.lock().unwrap().execute_batch("CREATE TRIGGER reject_reclaim BEFORE INSERT ON reclaim BEGIN SELECT RAISE(ABORT,'injected ledger failure'); END;").unwrap();
    assert!(s.append(event(AuditKind::MovedToTrash, 2.0)).is_err());
    assert_eq!(s.load_deadlines().unwrap().len(), 1);
    assert_eq!(s.dangling_attempts().unwrap().len(), 1);
    assert_eq!(s.audit_events().unwrap().len(), 1);
    assert_eq!(s.candidate_count().unwrap(), 3);
    s.lock()
        .unwrap()
        .execute_batch("DROP TRIGGER reject_reclaim")
        .unwrap();
    s.append(event(AuditKind::MovedToTrash, 2.0)).unwrap();
    assert!(s.load_deadlines().unwrap().is_empty());
    assert!(s.dangling_attempts().unwrap().is_empty());
    assert_eq!(s.reclaim_totals().unwrap().bytes, 100);
    assert_eq!(s.candidate_count().unwrap(), 1);
    assert_eq!(
        s.candidate_page("/root", None, NonZeroUsize::new(10).unwrap())
            .unwrap()[0]
            .1
            .identity
            .resource,
        [3]
    );
}
#[test]
fn attempts_recovery_unknown_outcome_and_totals() {
    let path = Temp::new();
    {
        let mut s = Store::open(&path.0).unwrap();
        s.append(event(AuditKind::TrashAttempted, 1.0)).unwrap();
    }
    let mut s = Store::open(&path.0).unwrap();
    assert_eq!(s.dangling_attempts().unwrap().len(), 1);
    s.lock().unwrap().execute_batch("CREATE TRIGGER reject_audit BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'failure'); END;").unwrap();
    assert!(s.reconcile_attempts(2.0).is_err());
    assert_eq!(s.dangling_attempts().unwrap().len(), 1);
    s.lock()
        .unwrap()
        .execute_batch("DROP TRIGGER reject_audit")
        .unwrap();
    assert_eq!(s.reconcile_attempts(2.0).unwrap(), 1);
    assert_eq!(s.reconcile_attempts(2.0).unwrap(), 0);
    assert_eq!(s.audit_events().unwrap()[1].kind, AuditKind::SafetySkipped);
    assert_eq!(s.reclaim_totals().unwrap().items, 0);
    s.append(event(AuditKind::TrashAttempted, 3.0)).unwrap();
    s.append(event(AuditKind::TrashFailed, 4.0)).unwrap();
    assert!(s.dangling_attempts().unwrap().is_empty());
    s.append(event(AuditKind::MovedToTrash, 5.0)).unwrap();
    s.append(event(AuditKind::MovedToTrash, 86401.0)).unwrap();
    assert_eq!(s.reclaim_totals().unwrap().items, 4);
    assert_eq!(s.reclaim_totals().unwrap().bytes, 200);
    assert_eq!(s.reclaim_days(0.0, 172800.0).unwrap().len(), 2);
}
#[test]
fn pagination_stability_and_conditional_removal() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    let requests = vec![request(3, 10.0), request(1, 10.0), request(2, 10.0)];
    s.replace_deadlines("/root", &requests).unwrap();
    let first = s
        .deadline_page(None, NonZeroUsize::new(1).unwrap())
        .unwrap();
    assert_eq!(first.items[0].candidate_identity.resource, [1]);
    s.remove_deadline(&first.items[0]).unwrap();
    let next = s
        .deadline_page(first.next.as_ref(), NonZeroUsize::new(2).unwrap())
        .unwrap();
    assert_eq!(next.items.len(), 2);
    assert_eq!(next.items[0].candidate_identity.resource, [2]);
    assert!(next.next.is_none());
    let mut stale = request(2, 9.0);
    s.remove_deadline(&stale).unwrap();
    stale.scheduled_at = 10.0;
    stale.candidate_identity.generation = Some(2);
    s.remove_deadline(&stale).unwrap();
    assert_eq!(s.load_deadlines().unwrap().len(), 2);
    s.replace_candidates("/root", &[candidate(2), candidate(1)], 0.0)
        .unwrap();
    let one = s
        .candidate_page("/root", None, NonZeroUsize::new(1).unwrap())
        .unwrap();
    let two = s
        .candidate_page("/root", Some(&one[0].0), NonZeroUsize::new(1).unwrap())
        .unwrap();
    assert_eq!(one[0].1.identity.resource, [1]);
    assert_eq!(two[0].1.identity.resource, [2]);
}
#[test]
fn identity_hint_refresh_and_replacement_are_safe() {
    let path = Temp::new();
    let mut s = Store::open(&path.0).unwrap();
    let old = identity(1, "/root/old/a");
    s.save_observation(Observation {
        identity: old.clone(),
        first: 1.0,
        last: 2.0,
    })
    .unwrap();
    let mut renamed = old.clone();
    renamed.path_hint = "/root/new/a".into();
    s.save_observation(Observation {
        identity: renamed.clone(),
        first: 8.0,
        last: 9.0,
    })
    .unwrap();
    s.remove_below("/root/old").unwrap();
    drop(s);
    let mut s = Store::open(&path.0).unwrap();
    let o = s.observation(&renamed).unwrap().unwrap();
    assert_eq!((o.first, o.last), (1.0, 9.0));
    assert_eq!(o.identity.path_hint, "/root/new/a");
    let mut replaced = renamed.clone();
    replaced.generation = Some(2);
    assert!(s.observation(&replaced).unwrap().is_none());
    s.save_observation(Observation {
        identity: replaced.clone(),
        first: 20.0,
        last: 20.0,
    })
    .unwrap();
    assert_eq!(s.observation(&replaced).unwrap().unwrap().first, 20.0);
    s.publish_projects(
        "/root",
        vec![Project {
            identity: renamed.clone(),
            activity: 30.0,
        }],
    )
    .unwrap();
    s.publish_projects(
        "/root",
        vec![Project {
            identity: renamed,
            activity: 10.0,
        }],
    )
    .unwrap();
    assert_eq!(s.projects().unwrap()[0].activity, 30.0);
    s.publish_projects("/root", vec![]).unwrap();
    assert!(s.projects().unwrap().is_empty());
}
#[test]
fn config_roundtrip_and_decision_audit() {
    let mut s = Store::memory().unwrap();
    // Use the core renderer as the canonical supported config syntax.
    let keep = ItemPolicyOverride::new(
        Uuid(10),
        None,
        "/root/keep",
        ItemOverridePolicy::Keep {
            protect_descendants: true,
        },
    );
    let mut exportable = rule();
    exportable.lifetime = RuleDuration(60.0);
    exportable.matcher =
        ItemMatcher::new(ItemKind::FileOrDirectory, vec![], vec!["*.tmp".into()]).unwrap();
    let canonical = config::render(&[exportable], &["/root".into()], &[keep]);
    s.import_config(&canonical, "/home/test", 1.0).unwrap();
    assert_eq!(s.export_config().unwrap(), canonical);
    s.record_decision(1.0,true,&serde_json::json!({"item":"/root/a","scheduledAt":10,"rule":"expire","basis":"modified","projectContext":null,"override":null,"suppressionReason":"previewOnly"})).unwrap();
    assert_eq!(
        s.audit_records().unwrap().last().unwrap().kind,
        "previewMatch"
    );
}
#[test]
fn engine_with_durable_store_and_scripted_clock() {
    use tinyprune_agent::{Agent, IndexBatch, IndexSource};
    use tinyprune_watch::ScriptedEventSource;
    #[derive(Clone)]
    struct Files(Option<RuleCandidate>);
    impl FileAccess for Files {
        fn inspect(&mut self, _: &str) -> Result<Option<RuleCandidate>> {
            Ok(self.0.clone())
        }
        fn has_symbolic_link_ancestor(&mut self, _: &str, _: &str) -> Result<bool> {
            Ok(false)
        }
        fn has_protected_descendant(
            &mut self,
            _: &str,
            _: &[ItemPolicyOverride],
            _: bool,
            _: WalkBudget,
        ) -> Result<DescendantProtection> {
            Ok(DescendantProtection::None)
        }
        fn move_to_trash(&mut self, _: &str, _: &FilesystemIdentity) -> Result<String> {
            self.0 = None;
            Ok("/trash/1".into())
        }
    }
    struct Index(Option<RuleCandidate>);
    impl IndexSource for Index {
        fn available(&mut self, _: &str) -> Result<bool> {
            Ok(true)
        }
        fn begin(&mut self, _: &str) -> Result<()> {
            Ok(())
        }
        fn next_batch(&mut self, _: NonZeroUsize) -> Result<IndexBatch> {
            Ok(IndexBatch {
                candidates: self.0.take().into_iter().collect(),
                complete: true,
            })
        }
    }
    struct At(f64);
    impl Clock for At {
        fn now(&self) -> f64 {
            self.0
        }
    }
    let path = Temp::new();
    let store = Store::open(&path.0).unwrap();
    store.put_rule(&rule(), 0.0).unwrap();
    store.replace_roots(&["/root".into()], 0.0).unwrap();
    let mut agent = Agent::new(
        Files(Some(candidate(1))),
        store.clone(),
        store.clone(),
        store.clone(),
        ScriptedEventSource::default(),
        Index(Some(candidate(1))),
    );
    assert_eq!(agent.tick_clock(&At(9.0)).unwrap().trashed, 0);
    assert_eq!(agent.tick_clock(&At(10.0)).unwrap().trashed, 1);
    assert!(agent.store.load_deadlines().unwrap().is_empty());
    assert!(agent.audit.dangling_attempts().unwrap().is_empty());
    assert!(store
        .audit_events()
        .unwrap()
        .iter()
        .any(|e| e.kind == AuditKind::MovedToTrash));
}
#[test]
fn runtime_policy_cas_is_atomic_and_durable() {
    let path = Temp::new();
    let mut s = Store::open(&path.0).unwrap();
    assert_eq!(s.runtime_state().unwrap(), (0, None, 0));
    let mut policy = s.load_snapshot().unwrap();
    policy.rules.push(rule());
    policy.managed_roots.push("/root".into());
    policy.globally_paused = true;
    policy.overrides.push(ItemPolicyOverride::new(
        Uuid(8),
        None,
        "/root/keep",
        ItemOverridePolicy::Keep {
            protect_descendants: true,
        },
    ));
    assert_eq!(
        s.replace_policy(&policy, 0, Some(100.0), 30, 1.0).unwrap(),
        1
    );
    assert!(s.replace_policy(&policy, 0, None, 0, 2.0).is_err());
    assert_eq!(s.runtime_state().unwrap(), (1, Some(100.0), 30));
    s.lock().unwrap().execute_batch("CREATE TRIGGER reject_policy BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'failure'); END;").unwrap();
    policy.rules.clear();
    assert!(s.replace_policy(&policy, 1, None, 0, 2.0).is_err());
    assert_eq!(s.load_snapshot().unwrap().rules.len(), 1);
    assert_eq!(s.runtime_state().unwrap(), (1, Some(100.0), 30));
    s.lock()
        .unwrap()
        .execute_batch("DROP TRIGGER reject_policy")
        .unwrap();
    drop(s);
    let mut s = Store::open(&path.0).unwrap();
    assert_eq!(s.runtime_state().unwrap(), (1, Some(100.0), 30));
    assert_eq!(s.load_snapshot().unwrap().overrides.len(), 1);
    s.put_rule(&rule(), 3.0).unwrap();
    assert_eq!(s.runtime_state().unwrap().0, 2);
    let first = s.audit_page(None, NonZeroUsize::new(1).unwrap()).unwrap();
    let rest = s
        .audit_page(Some(first[0].id), NonZeroUsize::new(10).unwrap())
        .unwrap();
    assert_eq!(rest.len(), 1);
    assert_eq!(
        s.audit_recent(NonZeroUsize::new(1).unwrap()).unwrap()[0].id,
        rest[0].id
    );
}
#[test]
fn candidate_subtree_publication_preserves_unaffected_items() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into(), "/root/project".into()], 0.0)
        .unwrap();
    let mut nested = candidate(3);
    nested.identity.path_hint = "/root/project/a".into();
    s.publish_candidate_subtree("/root", &[candidate(1), candidate(2), nested], 1.0)
        .unwrap();
    assert_eq!(s.candidate_count().unwrap(), 3);
    assert_eq!(
        s.candidate_page("/root/project", None, NonZeroUsize::new(10).unwrap())
            .unwrap()
            .len(),
        1
    );
    s.publish_candidate_subtree("/root/1", &[], 2.0).unwrap();
    assert_eq!(s.candidate_count().unwrap(), 2);
    assert!(s
        .publish_candidate_subtree("/root/project", &[candidate(4)], 3.0)
        .is_err());
    assert_eq!(s.candidate_count().unwrap(), 2);
    s.publish_candidate_subtree("/root/project", &[], 4.0)
        .unwrap();
    assert_eq!(s.candidate_count().unwrap(), 1);
    let mut renamed = candidate(2);
    renamed.identity.path_hint = "/root/renamed/2".into();
    s.publish_candidate_subtree("/root/renamed", &[renamed], 5.0)
        .unwrap();
    s.remove_below("/root/2").unwrap();
    assert_eq!(s.candidate_count().unwrap(), 1);
    s.remove_below("/root/renamed").unwrap();
    assert_eq!(s.candidate_count().unwrap(), 0);
}
#[test]
fn audit_accessors_and_bounded_retention_preserve_reclaim_and_attempts() {
    let mut s = Store::memory().unwrap();
    let identity = identity(1, "/root/a");
    let wire = serde_json::json!({"item":{"volumeIdentifier":identity.volume.to_string(),"resourceIdentifier":"01","pathHint":"/root/a","creationTime":0.0,"generation":1},"marker":"old"});
    s.record_decision(1.0, false, &wire).unwrap();
    let mut newest = wire.clone();
    newest["marker"] = serde_json::json!("new");
    newest["item"]["pathHint"] = serde_json::json!("/root/renamed");
    s.record_decision(2.0, true, &newest).unwrap();
    let mut wrong = newest.clone();
    wrong["item"]["generation"] = serde_json::json!(2);
    wrong["marker"] = serde_json::json!("replacement");
    s.record_decision(3.0, false, &wrong).unwrap();
    assert_eq!(s.latest_decision(&identity).unwrap(), Some(newest));
    let mut other = identity.clone();
    other.resource = vec![99];
    assert!(s.latest_decision(&other).unwrap().is_none());
    s.append(event(AuditKind::MovedToTrash, 4.0)).unwrap();
    let mut pending = event(AuditKind::TrashAttempted, 5.0);
    pending.identity = Some(other);
    s.append(pending.clone()).unwrap();
    let records = s.audit_records().unwrap();
    assert!(records[0].event().unwrap().is_none());
    assert_eq!(records.last().unwrap().event().unwrap(), Some(pending));
    for at in 6..306 {
        s.record_decision(at as f64, true, &wire).unwrap();
    }
    assert_eq!(
        s.prune_audit(400.0).unwrap(),
        0,
        "retention 0 keeps forever"
    );
    let before = s.audit_records().unwrap().len();
    let policy = s.load_snapshot().unwrap();
    s.replace_policy(&policy, s.runtime_state().unwrap().0, None, 30, 400.0)
        .unwrap();
    assert_eq!(s.audit_records().unwrap().len(), before + 1);
    assert_eq!(s.prune_audit(399.0).unwrap(), 256);
    assert_eq!(s.reclaim_totals().unwrap().bytes, 100);
    assert_eq!(s.dangling_attempts().unwrap().len(), 1);
    assert_eq!(s.prune_audit(399.0).unwrap(), 48);
    assert_eq!(s.prune_audit(400.0).unwrap(), 0);
    assert_eq!(s.audit_records().unwrap().len(), 2);
    assert_eq!(s.reclaim_totals().unwrap().bytes, 100);
}
fn bulk_identity(n: u32) -> FilesystemIdentity {
    FilesystemIdentity {
        volume: Uuid(1),
        resource: n.to_be_bytes().to_vec(),
        path_hint: format!("/root/item{n:06}"),
        creation_time: Some(0.0),
        generation: Some(1),
        is_persistent: true,
    }
}
fn explanation(i: &FilesystemIdentity, marker: u32) -> serde_json::Value {
    serde_json::json!({"item":{"volumeIdentifier":i.volume.to_string(),"resourceIdentifier":hex(&i.resource),"pathHint":i.path_hint,"creationTime":0.0,"generation":1},"marker":marker})
}
fn changes(s: &Store) -> u64 {
    s.lock().unwrap().total_changes()
}
#[test]
fn file_reads_do_not_wait_for_an_open_writer_transaction() {
    let path = Temp::new();
    let s = Store::open(&path.0).unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    s.publish_candidate_subtree("/root", &[candidate(1)], 1.0)
        .unwrap();
    let writer = s.lock().unwrap();
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    writer
        .execute(
            "INSERT INTO audit(occurred_at,kind,payload) VALUES(9,'x','{}')",
            [],
        )
        .unwrap();
    // The writer mutex and an uncommitted write transaction are both held; every read still answers
    // from the committed snapshot through the independent reader connection.
    assert_eq!(s.candidate_count().unwrap(), 1);
    assert_eq!(s.runtime_state().unwrap().0, 1);
    assert_eq!(s.clone().load_snapshot().unwrap().managed_roots, ["/root"]);
    assert!(s
        .audit_recent(NonZeroUsize::new(5).unwrap())
        .unwrap()
        .iter()
        .all(|r| r.kind != "x"));
    assert!(s.database_bytes().unwrap() > 0);
    writer.execute_batch("ROLLBACK").unwrap();
}
#[test]
fn decisions_batch_is_idempotent_indexed_and_cleaned_with_candidates() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    const N: u32 = 10_000;
    let ids: Vec<_> = (0..N).map(bulk_identity).collect();
    let candidates: Vec<_> = ids
        .iter()
        .map(|i| {
            RuleCandidate::new(
                i.clone(),
                i.path_hint.clone(),
                ItemKind::File,
                CandidateTimestamps::default(),
            )
        })
        .collect();
    assert_eq!(
        s.publish_candidate_subtree("/root", &candidates, 1.0)
            .unwrap(),
        N as usize
    );
    let marker =
        |m: u32| -> Vec<serde_json::Value> { ids.iter().map(|i| explanation(i, m)).collect() };
    let first = marker(0);
    let rule_a = Uuid(0xa).to_string();
    let rule_b = Uuid(0xb).to_string();
    fn rows<'a>(
        ids: &'a [FilesystemIdentity],
        explanations: &'a [serde_json::Value],
        rule_a: &'a str,
        rule_b: &'a str,
    ) -> Vec<DecisionRow<'a>> {
        ids.iter()
            .zip(explanations)
            .enumerate()
            .map(|(n, (identity, explanation))| DecisionRow {
                identity,
                // Every 10th item is suppressed (no schedule).
                scheduled_at: if n % 10 == 0 {
                    None
                } else {
                    Some(1000.0 + n as f64)
                },
                rule_id: Some(if n % 2 == 0 { rule_a } else { rule_b }),
                preview: n % 3 == 0,
                explanation,
            })
            .collect()
    }
    let audit_before = s.audit_records().unwrap().len();
    assert_eq!(
        s.put_decisions(2.0, &rows(&ids, &first, &rule_a, &rule_b))
            .unwrap(),
        N as usize
    );
    assert_eq!(s.audit_records().unwrap().len(), audit_before + N as usize);
    // Unchanged batch: nothing recorded, no row or audit writes at all.
    let writes = changes(&s);
    assert_eq!(
        s.put_decisions(3.0, &rows(&ids, &first, &rule_a, &rule_b))
            .unwrap(),
        0
    );
    assert_eq!(changes(&s), writes);
    assert_eq!(s.audit_records().unwrap().len(), audit_before + N as usize);
    // One changed row is recorded and audited exactly once.
    let mut second = first.clone();
    second[7]["marker"] = serde_json::json!(99);
    assert_eq!(
        s.put_decisions(4.0, &rows(&ids, &second, &rule_a, &rule_b))
            .unwrap(),
        1
    );
    assert_eq!(s.latest_decision(&ids[7]).unwrap().unwrap()["marker"], 99);
    assert_eq!(
        s.audit_records().unwrap().len(),
        audit_before + N as usize + 1
    );
    // Aggregates: scheduled = non-multiples of 10; preview = multiples of 3.
    let scheduled: Vec<u32> = (0..N).filter(|n| n % 10 != 0).collect();
    let preview = scheduled.iter().filter(|n| *n % 3 == 0).count() as u64;
    let active = scheduled.len() as u64 - preview;
    let soon = scheduled
        .iter()
        .filter(|n| *n % 3 != 0 && 1000.0 + f64::from(**n) <= 1100.0)
        .count() as u64;
    assert_eq!(
        s.decision_counts(0.0, 1100.0).unwrap(),
        (active, preview, soon)
    );
    let stats = s.decision_rule_stats(1100.0).unwrap();
    assert_eq!(stats.len(), 2);
    assert_eq!(
        stats.iter().map(|s| s.1).sum::<u64>(),
        scheduled.len() as u64
    );
    let due = scheduled
        .iter()
        .filter(|n| 1000.0 + f64::from(**n) <= 1100.0)
        .count() as u64;
    assert_eq!(stats.iter().map(|s| s.2).sum::<u64>(), due);
    // Keyset pagination: stable, ordered, complete, honoring filters; total ignores the cursor.
    let limit = NonZeroUsize::new(997).unwrap();
    let mut cursor = None;
    let mut seen = vec![];
    loop {
        let (page, total) = s
            .decision_page(Some(&rule_a), Some(false), cursor.clone(), limit)
            .unwrap();
        let expected = scheduled
            .iter()
            .filter(|n| *n % 2 == 0 && *n % 3 != 0)
            .count() as u64;
        assert_eq!(total, expected);
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(at, k, _)| (*at, k.clone()));
        seen.extend(page.into_iter().map(|(at, k, _)| (at, k)));
    }
    assert_eq!(
        seen.len() as u64,
        s.decision_page(Some(&rule_a), Some(false), None, limit)
            .unwrap()
            .1
    );
    assert!(seen.windows(2).all(|w| w[0] < w[1]));
    let (unfiltered, total) = s
        .decision_page(None, None, None, NonZeroUsize::new(5).unwrap())
        .unwrap();
    assert_eq!((unfiltered.len(), total), (5, scheduled.len() as u64));
    assert_eq!(unfiltered[0].0, 1001.0);
    // Cleanup everywhere a candidate row disappears.
    s.publish_candidate_subtree("/root", &candidates[1..], 5.0)
        .unwrap();
    let current: i64 = s
        .lock()
        .unwrap()
        .query_row(
            "SELECT COUNT(*) FROM current_decisions WHERE identity_key=?",
            [key(&ids[0])],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(current, 0);
    assert_eq!(
        s.decision_counts(0.0, 0.0).unwrap().0 + s.decision_counts(0.0, 0.0).unwrap().1,
        scheduled.len() as u64
    );
    let mut moved = event(AuditKind::MovedToTrash, 6.0);
    moved.identity = Some(ids[1].clone());
    s.append(moved).unwrap();
    assert_eq!(
        s.decision_page(None, None, None, NonZeroUsize::new(1).unwrap())
            .unwrap()
            .1,
        scheduled.len() as u64 - 1
    );
    s.remove_below("/root/item000002").unwrap();
    assert_eq!(
        s.decision_page(None, None, None, NonZeroUsize::new(1).unwrap())
            .unwrap()
            .1,
        scheduled.len() as u64 - 2
    );
    s.replace_roots(&[], 7.0).unwrap();
    assert_eq!(
        s.decision_page(None, None, None, NonZeroUsize::new(1).unwrap())
            .unwrap()
            .1,
        0
    );
    assert_eq!(s.candidate_count().unwrap(), 0);
}
#[test]
fn decision_queries_use_indexes_without_sorting_or_scanning_tables() {
    let s = Store::memory().unwrap();
    let c = s.lock().unwrap();
    let plan = |query: &str| -> String {
        let mut statement = c.prepare(&format!("EXPLAIN QUERY PLAN {query}")).unwrap();
        let nulls = statement.parameter_count();
        let rows = statement
            .query_map(
                rusqlite::params_from_iter(std::iter::repeat_n(rusqlite::types::Null, nulls)),
                |r| r.get::<_, String>(3),
            )
            .unwrap();
        rows.map(|r| r.unwrap()).collect::<Vec<_>>().join(" | ")
    };
    for rule in [false, true] {
        for preview in [false, true] {
            for after in [false, true] {
                let p = plan(&decision_page_sql(rule, preview, after));
                assert!(
                    p.contains("USING INDEX") || p.contains("USING COVERING INDEX"),
                    "{rule}{preview}{after}: {p}"
                );
                assert!(
                    !p.contains("TEMP B-TREE") && !p.contains("SCAN current_decisions"),
                    "{rule}{preview}{after}: {p}"
                );
            }
            let p = plan(&decision_count_sql(rule, preview));
            assert!(p.contains("INDEX"), "{p}");
        }
    }
    for query in [
        "SELECT COUNT(*) FROM current_decisions WHERE preview=0 AND scheduled_at IS NOT NULL",
        "SELECT COUNT(*) FROM current_decisions WHERE preview=0 AND scheduled_at IS NOT NULL AND scheduled_at<=?1",
        "SELECT rule_id,COUNT(*),COALESCE(SUM(scheduled_at<=?1),0) FROM current_decisions WHERE scheduled_at IS NOT NULL AND rule_id IS NOT NULL GROUP BY rule_id ORDER BY rule_id",
    ] {
        let p = plan(query);
        assert!(p.contains("COVERING INDEX") && !p.contains("TEMP B-TREE"), "{p}");
    }
}
#[test]
fn identical_publications_write_nothing() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    let set = [candidate(1), candidate(2)];
    assert_eq!(s.publish_candidate_subtree("/root", &set, 1.0).unwrap(), 2);
    let (writes, audits) = (changes(&s), s.audit_records().unwrap().len());
    assert_eq!(s.publish_candidate_subtree("/root", &set, 2.0).unwrap(), 0);
    assert_eq!(
        (changes(&s), s.audit_records().unwrap().len()),
        (writes, audits)
    );
    let mut changed = set.clone();
    changed[1].name = "renamed".into();
    assert_eq!(
        s.publish_candidate_subtree("/root", &changed, 3.0).unwrap(),
        1
    );
    assert_eq!(
        s.publish_candidate_subtree("/root", &changed[..1], 4.0)
            .unwrap(),
        1
    );
    // Deadlines: identical set is a no-op; changed/vanished rows are the only writes.
    let deadlines = [request(1, 10.0), request(2, 20.0)];
    s.replace_deadlines("/root", &deadlines).unwrap();
    let (writes, audits) = (changes(&s), s.audit_records().unwrap().len());
    s.replace_deadlines("/root", &deadlines).unwrap();
    assert_eq!(
        (changes(&s), s.audit_records().unwrap().len()),
        (writes, audits)
    );
    s.replace_deadlines("/root", &[request(1, 10.0), request(2, 25.0)])
        .unwrap();
    assert_eq!(s.audit_records().unwrap().len(), audits + 1);
    s.replace_deadlines("/root", &[request(2, 25.0)]).unwrap();
    assert_eq!(s.load_deadlines().unwrap().len(), 1);
    // Observations: an unchanged save skips the write transaction.
    let observation = Observation {
        identity: identity(1, "/root/1"),
        first: 1.0,
        last: 2.0,
    };
    s.save_observation(observation.clone()).unwrap();
    let writes = changes(&s);
    s.save_observation(observation.clone()).unwrap();
    s.save_observation(Observation {
        first: 5.0,
        last: 1.5,
        ..observation.clone()
    })
    .unwrap();
    assert_eq!(changes(&s), writes);
    s.save_observation(Observation {
        last: 3.0,
        ..observation
    })
    .unwrap();
    assert!(changes(&s) > writes);
}
#[test]
fn migration_backfills_candidate_hints_from_every_previous_version() {
    for version in [1, 4] {
        let mut c = Connection::open_in_memory().unwrap();
        schema::at_version(&c, version);
        if version == 4 {
            c.execute("INSERT INTO roots VALUES('/root',0)", [])
                .unwrap();
            c.execute(
                "INSERT INTO candidates VALUES('k','/root',?)",
                [encode(&Candidate::from(&candidate(5))).unwrap()],
            )
            .unwrap();
        }
        schema::migrate(&mut c).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            SCHEMA_VERSION
        );
        if version == 4 {
            assert_eq!(
                c.query_row("SELECT path_hint FROM candidates", [], |r| r
                    .get::<_, String>(0))
                    .unwrap(),
                "/root/5"
            );
        }
    }
}
#[test]
fn decisions_without_a_candidate_are_skipped_and_never_orphaned() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    let (kept, trashed) = (bulk_identity(1), bulk_identity(2));
    let to_candidate = |i: &FilesystemIdentity| {
        RuleCandidate::new(
            i.clone(),
            i.path_hint.clone(),
            ItemKind::File,
            CandidateTimestamps::default(),
        )
    };
    s.publish_candidate_subtree("/root", &[to_candidate(&kept), to_candidate(&trashed)], 1.0)
        .unwrap();
    let (a, b) = (explanation(&kept, 1), explanation(&trashed, 1));
    let rule = Uuid(5).to_string();
    let rows = |with_trashed: bool| {
        let mut rows = vec![DecisionRow {
            identity: &kept,
            scheduled_at: Some(10.0),
            rule_id: Some(&rule),
            preview: false,
            explanation: &a,
        }];
        if with_trashed {
            rows.push(DecisionRow {
                identity: &trashed,
                scheduled_at: Some(11.0),
                rule_id: Some(&rule),
                preview: false,
                explanation: &b,
            });
        }
        rows
    };
    assert_eq!(s.put_decisions(2.0, &rows(true)).unwrap(), 2);
    // The item is trashed between evaluation and persistence: its stale decision must not come back.
    let mut moved = event(AuditKind::MovedToTrash, 3.0);
    moved.identity = Some(trashed.clone());
    s.append(moved).unwrap();
    let orphans = |s: &Store| -> i64 {
        s.lock().unwrap().query_row("SELECT COUNT(*) FROM current_decisions WHERE identity_key NOT IN (SELECT identity_key FROM candidates)", [], |r| r.get(0)).unwrap()
    };
    assert_eq!(orphans(&s), 0);
    let mut changed = b.clone();
    changed["marker"] = serde_json::json!(2);
    let stale = [DecisionRow {
        identity: &trashed,
        scheduled_at: Some(12.0),
        rule_id: Some(&rule),
        preview: true,
        explanation: &changed,
    }];
    let audits = s.audit_records().unwrap().len();
    assert_eq!(s.put_decisions(4.0, &stale).unwrap(), 0);
    assert_eq!(s.audit_records().unwrap().len(), audits);
    assert_eq!(
        s.decision_page(None, None, None, NonZeroUsize::new(10).unwrap())
            .unwrap()
            .1,
        1
    );
    assert_eq!(orphans(&s), 0);
    // A mixed batch records the live row only; the schema itself rejects orphan inserts.
    let mut next = a.clone();
    next["marker"] = serde_json::json!(3);
    let mixed = [
        DecisionRow {
            identity: &kept,
            scheduled_at: Some(10.0),
            rule_id: Some(&rule),
            preview: false,
            explanation: &next,
        },
        stale[0],
    ];
    assert_eq!(s.put_decisions(5.0, &mixed).unwrap(), 1);
    assert!(s
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO current_decisions VALUES('ghost','/root',1,NULL,0,'{}',1)",
            []
        )
        .is_err());
}
