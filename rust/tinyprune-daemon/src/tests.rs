use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
use tinyprune_ipc::{AgentService, Client, Request, Response};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct ScriptClock(AtomicU64);
impl Clock for ScriptClock {
    fn now(&self) -> f64 {
        self.0.load(Ordering::SeqCst) as f64
    }
}
struct Fixture {
    path: PathBuf,
    root: String,
    clock: Arc<ScriptClock>,
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "tinyprune-runtime-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(path.join("tree")).unwrap();
        let path = fs::canonicalize(path).unwrap();
        Self {
            root: codec::path(&path.join("tree")).unwrap(),
            path,
            clock: Arc::new(ScriptClock(AtomicU64::new(1_800_000_000))),
        }
    }
    fn item(&self, relative: &str) -> String {
        codec::path(&self.path.join("tree").join(relative)).unwrap()
    }
    fn options(&self) -> Options {
        Options {
            paths: Paths {
                data: self.path.join("data"),
                endpoint: self.path.join("ipc/agent.sock"),
                logs: self.path.join("logs"),
            },
            reconcile_interval: Duration::from_secs(300),
            tick_interval: Duration::from_millis(1),
            trash: Some(self.path.join("trash")),
        }
    }
    fn daemon(&self) -> Daemon {
        Daemon::open(self.options(), self.clock.clone()).unwrap()
    }
    fn root(&self) -> ipc::Root {
        codec::root(&self.root)
    }
    fn rule(&self) -> ipc::Rule {
        ipc::Rule {
            id: "00000000-0000-0000-0000-000000000001".into(),
            name: "Fixture".into(),
            scope: ipc::Scope {
                path: self.root.clone(),
                recursive: false,
            },
            matcher: ipc::Matcher {
                item_kind: ipc::ItemKind::File,
                exact_names: vec![],
                glob_patterns: vec![],
            },
            expiry_basis: ipc::ExpiryBasis::FirstObserved,
            lifetime: 60.0,
            grace_period: None,
            action: ipc::FolderAction::TrashItem,
            state: ipc::RuleState::Active,
            match_mode: ipc::MatchMode::Scoped,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
fn acknowledged(response: Response) -> u64 {
    match response {
        Response::Acknowledged(a) => a.revision,
        value => panic!("Expected acknowledgement, got {value:?}"),
    }
}
fn settle(daemon: &Daemon) {
    let mut idle = 0;
    for _ in 0..100 {
        if daemon.tick().unwrap().pending_work {
            idle = 0;
        } else {
            idle += 1;
            if idle == 2 {
                return;
            }
        }
    }
    panic!("engine failed to settle");
}
fn loopback(
    service: Arc<Service>,
) -> (Client<ipc::loopback::Loopback>, JoinHandle<io::Result<()>>) {
    let (client, server) = ipc::loopback::pair();
    let server = ipc::Server::new(service, ipc::ServerOptions::default())
        .unwrap()
        .dispatch(server)
        .unwrap();
    (
        Client::connect(client, ipc::VersionRange::default(), ipc::DEFAULT_MAX_FRAME).unwrap(),
        server,
    )
}
#[test]
fn loopback_operations_preview_pause_settings_and_recovery() {
    let fixture = Fixture::new();
    let file = fixture.item("old.tmp");
    fs::write(&file, b"fixture").unwrap();
    let daemon = fixture.daemon();
    let (mut client, worker) = loopback(daemon.service.clone());
    assert!(matches!(
        client.request(Request::Health).unwrap(),
        Response::Health(_)
    ));
    let revision = acknowledged(client.request(Request::AddRoot(fixture.root())).unwrap());
    let revision = acknowledged(
        client
            .request(Request::SaveRule {
                rule: fixture.rule(),
                roots: None,
                keep_paths: vec![],
                unkeep_paths: vec![],
                revision,
            })
            .unwrap(),
    );
    settle(&daemon);
    let before = daemon.service.state_for_test_audit_count();
    match client
        .request(Request::PreviewRule(fixture.rule()))
        .unwrap()
    {
        Response::RulePreview(p) => assert_eq!(p.matches, 1),
        other => panic!("{other:?}"),
    }
    assert!(Path::new(&file).exists());
    assert_eq!(before, daemon.service.state_for_test_audit_count());
    assert!(
        matches!(client.request(Request::LoadRoots).unwrap(), Response::Roots(v) if v.len()==1)
    );
    assert!(
        matches!(client.request(Request::LoadUpcoming { rule_id: Some(fixture.rule().id), disposition: Some(ipc::Disposition::Active), after: None, limit: 1 }).unwrap(), Response::UpcomingPage(p) if p.total_count == 1)
    );
    assert!(
        matches!(client.request(Request::ExplainItem { path: file.clone() }).unwrap(), Response::ItemExplanation(e) if e.explanation.rule.is_some() && e.explanation.basis_date.is_some())
    );
    assert!(matches!(
        client
            .request(Request::ItemSize { path: file.clone() })
            .unwrap(),
        Response::ItemSize { bytes: 7, .. }
    ));
    acknowledged(
        client
            .request(Request::SetGlobalPause { paused: true })
            .unwrap(),
    );
    fixture.clock.0.fetch_add(120, Ordering::SeqCst);
    settle(&daemon);
    assert!(Path::new(&file).exists());
    acknowledged(
        client
            .request(Request::UpdateSettings(ipc::Settings {
                default_grace_period_seconds: 3.0,
                protect_hidden_files: true,
                activity_retention_days: 14,
            }))
            .unwrap(),
    );
    assert!(
        matches!(client.request(Request::LoadSettings).unwrap(), Response::Settings(s) if s.activity_retention_days==14 && s.protect_hidden_files)
    );
    acknowledged(
        client
            .request(Request::SetItemOverrides {
                changes: vec![ipc::OverrideChange {
                    path: file.clone(),
                    policy: Some(ipc::OverridePolicy::Keep {
                        protect_descendants: true,
                    }),
                }],
            })
            .unwrap(),
    );
    acknowledged(
        client
            .request(Request::SetGlobalPause { paused: false })
            .unwrap(),
    );
    settle(&daemon);
    assert!(Path::new(&file).exists());
    acknowledged(
        client
            .request(Request::ClearItemOverride { path: file.clone() })
            .unwrap(),
    );
    acknowledged(
        client
            .request(Request::PauseUntil {
                until: fixture.clock.now() + 20.0,
            })
            .unwrap(),
    );
    settle(&daemon);
    assert!(Path::new(&file).exists());
    fixture.clock.0.fetch_add(21, Ordering::SeqCst);
    settle(&daemon);
    assert!(!Path::new(&file).exists());
    assert!(
        matches!(client.request(Request::LoadActivity { limit: 100 }).unwrap(), Response::Activity(v) if !v.is_empty())
    );
    assert!(
        matches!(client.request(Request::LoadOverview).unwrap(), Response::Overview(v) if v.reclaimed.as_ref().unwrap().lifetime_items==1)
    );
    assert!(
        matches!(client.request(Request::SaveRule { rule: fixture.rule(), roots: None, keep_paths: vec![], unkeep_paths: vec![], revision }).unwrap(), Response::Failure(e) if e.code==ipc::ErrorCode::PolicyConflict)
    );
    drop(client);
    worker.join().unwrap().unwrap();
    drop(daemon);
    let daemon = fixture.daemon();
    assert!(
        matches!(daemon.service.handle(Request::LoadSettings), Response::Settings(s) if s.activity_retention_days==14)
    );
    assert!(
        matches!(daemon.service.handle(Request::LoadOverview), Response::Overview(v) if v.reclaimed.as_ref().unwrap().lifetime_items==1)
    );
}
#[test]
fn loopback_policy_config_crud_and_dangerous_roots() {
    let fixture = Fixture::new();
    let daemon = fixture.daemon();
    let (mut client, worker) = loopback(daemon.service.clone());
    #[cfg(unix)]
    assert!(matches!(
        client
            .request(Request::AddRoot(ipc::Root {
                id: "invalid".into(),
                name: "System".into(),
                path: "/usr".into()
            }))
            .unwrap(),
        Response::Failure(_)
    ));
    let revision = acknowledged(client.request(Request::AddRoot(fixture.root())).unwrap());
    let revision = acknowledged(
        client
            .request(Request::SaveRule {
                rule: fixture.rule(),
                roots: None,
                keep_paths: vec![],
                unkeep_paths: vec![],
                revision,
            })
            .unwrap(),
    );
    let mut policy = match client.request(Request::LoadPolicy).unwrap() {
        Response::Policy(p) => p,
        other => panic!("{other:?}"),
    };
    assert_eq!(policy.revision, revision);
    policy.rules[0].name = "Edited".into();
    acknowledged(client.request(Request::ReplacePolicy(policy)).unwrap());
    #[cfg(unix)]
    {
        let text = match client.request(Request::ExportConfig).unwrap() {
            Response::Config { text } => text,
            other => panic!("{other:?}"),
        };
        let revision = match client.request(Request::LoadPolicy).unwrap() {
            Response::Policy(p) => p.revision,
            other => panic!("{other:?}"),
        };
        acknowledged(
            client
                .request(Request::ImportConfig {
                    text,
                    activate: false,
                    revision,
                })
                .unwrap(),
        );
    }
    let policy = match client.request(Request::LoadPolicy).unwrap() {
        Response::Policy(p) => p,
        other => panic!("{other:?}"),
    };
    for rule in policy.rules {
        acknowledged(client.request(Request::DeleteRule { id: rule.id }).unwrap());
    }
    acknowledged(client.request(Request::CancelPreview).unwrap());
    acknowledged(client.request(Request::RebuildIndex).unwrap());
    acknowledged(
        client
            .request(Request::RemoveRoot {
                id: fixture.root().id,
            })
            .unwrap(),
    );
    assert!(
        matches!(client.request(Request::LoadRoots).unwrap(), Response::Roots(v) if v.is_empty())
    );
    drop(client);
    worker.join().unwrap().unwrap();
}
#[cfg(unix)]
#[test]
fn broad_roots_cannot_activate_and_single_instance_is_enforced() {
    let fixture = Fixture::new();
    let daemon = fixture.daemon();
    assert!(Daemon::open(fixture.options(), fixture.clock.clone()).is_err());
    let home = fs::canonicalize(std::env::var("HOME").unwrap())
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    let root = codec::root(&home);
    let revision = acknowledged(daemon.service.handle(Request::AddRoot(root)));
    let mut rule = fixture.rule();
    rule.scope.path = home;
    assert!(matches!(
        daemon.service.handle(Request::SaveRule {
            rule: rule.clone(),
            roots: None,
            keep_paths: vec![],
            unkeep_paths: vec![],
            revision
        }),
        Response::Failure(_)
    ));
    rule.state = ipc::RuleState::Preview;
    acknowledged(daemon.service.handle(Request::SaveRule {
        rule,
        roots: None,
        keep_paths: vec![],
        unkeep_paths: vec![],
        revision,
    }));
}
#[cfg(unix)]
#[test]
fn real_unix_socket_trash_keep_and_midway_restart() {
    let fixture = Fixture::new();
    let old = fixture.item("old.tmp");
    let keep = fixture.item("keep.tmp");
    fs::write(&old, b"old").unwrap();
    fs::write(&keep, b"keep").unwrap();
    let daemon = fixture.daemon();
    private_dir(fixture.options().paths.endpoint.parent().unwrap()).unwrap();
    let listener = ipc::unix::Listener::bind(fixture.options().paths.endpoint).unwrap();
    let server = ipc::Server::new(daemon.service.clone(), ipc::ServerOptions::default()).unwrap();
    let worker = std::thread::spawn(move || {
        let stream = listener.accept().unwrap();
        let worker = server.dispatch(stream).unwrap();
        worker.join().unwrap().unwrap();
    });
    let mut client = Client::connect(
        ipc::unix::connect(&fixture.options().paths.endpoint).unwrap(),
        ipc::VersionRange::default(),
        ipc::DEFAULT_MAX_FRAME,
    )
    .unwrap();
    let revision = acknowledged(client.request(Request::AddRoot(fixture.root())).unwrap());
    acknowledged(
        client
            .request(Request::SaveRule {
                rule: fixture.rule(),
                roots: None,
                keep_paths: vec![keep.clone()],
                unkeep_paths: vec![],
                revision,
            })
            .unwrap(),
    );
    settle(&daemon);
    fixture.clock.0.fetch_add(30, Ordering::SeqCst);
    drop(client);
    worker.join().unwrap();
    drop(daemon);
    let daemon = fixture.daemon();
    settle(&daemon);
    assert!(Path::new(&old).exists());
    // On a filesystem with durable identity (birth time + stable volume id) FirstObserved survives the restart:
    // the item was first observed 30s before it, so it is due 60s after that observation, not after the restart.
    // Otherwise (e.g. no btime) identities are nonpersistent and the timer legitimately restarts.
    let persistent = tinyprune_unix::UnixFileAccess::new(fixture.path.join("trash"))
        .inspect_metadata(&old)
        .unwrap()
        .unwrap()
        .candidate
        .identity
        .is_persistent;
    if persistent {
        fixture.clock.0.fetch_add(29, Ordering::SeqCst);
        settle(&daemon);
        assert!(
            Path::new(&old).exists(),
            "59s after first observation is not yet due"
        );
        fixture.clock.0.fetch_add(2, Ordering::SeqCst);
    } else {
        fixture.clock.0.fetch_add(61, Ordering::SeqCst);
    }
    settle(&daemon);
    assert!(!Path::new(&old).exists());
    assert!(Path::new(&keep).exists());
    assert_eq!(
        fs::read_dir(fixture.path.join("trash/files"))
            .unwrap()
            .count(),
        1
    );
    assert!(
        matches!(daemon.service.handle(Request::LoadOverview), Response::Overview(v) if v.reclaimed.as_ref().unwrap().lifetime_items==1)
    );
    assert!(
        matches!(daemon.service.handle(Request::LoadActivity { limit: 100 }), Response::Activity(v) if v.iter().any(|e| e.kind==ipc::ActivityKind::MovedToTrash))
    );
}
#[test]
fn explain_directory_reports_protected_descendant_like_preview() {
    let fixture = Fixture::new();
    let dir = fixture.item("sub");
    let child = fixture.item("sub/child.tmp");
    fs::create_dir_all(&dir).unwrap();
    fs::write(&child, b"x").unwrap();
    let daemon = fixture.daemon();
    let service = &daemon.service;
    let revision = acknowledged(service.handle(Request::AddRoot(fixture.root())));
    let mut rule = fixture.rule();
    rule.matcher.item_kind = ipc::ItemKind::Directory;
    rule.expiry_basis = ipc::ExpiryBasis::Modified;
    rule.state = ipc::RuleState::Preview;
    acknowledged(service.handle(Request::SaveRule {
        rule: rule.clone(),
        roots: None,
        keep_paths: vec![child.clone()],
        unkeep_paths: vec![],
        revision,
    }));
    settle(&daemon);
    let explained = match service.handle(Request::ExplainItem { path: dir.clone() }) {
        Response::ItemExplanation(e) => e.explanation,
        other => panic!("{other:?}"),
    };
    assert_eq!(
        explained.suppression_reason,
        Some(ipc::Suppression::ProtectedDescendant)
    );
    match service.handle(Request::PreviewRule(rule)) {
        Response::RulePreview(p) => assert!(p.samples.iter().any(|s| {
            codec::same_path(&s.explanation.item.path_hint, &dir)
                && s.explanation.suppression_reason == Some(ipc::Suppression::ProtectedDescendant)
        })),
        other => panic!("{other:?}"),
    }
}
#[test]
fn unchanged_skips_are_not_reaudited_on_reconcile() {
    let fixture = Fixture::new();
    fs::write(fixture.item("a.tmp"), b"x").unwrap();
    let daemon = fixture.daemon();
    let service = &daemon.service;
    let revision = acknowledged(service.handle(Request::AddRoot(fixture.root())));
    let mut rule = fixture.rule();
    rule.state = ipc::RuleState::Preview;
    acknowledged(service.handle(Request::SaveRule {
        rule,
        roots: None,
        keep_paths: vec![],
        unkeep_paths: vec![],
        revision,
    }));
    settle(&daemon);
    let count = |service: &Service| match service.handle(Request::LoadActivity { limit: 1000 }) {
        Response::Activity(v) => v.len(),
        other => panic!("{other:?}"),
    };
    let first = count(service);
    for _ in 0..5 {
        acknowledged(service.handle(Request::RebuildIndex));
        settle(&daemon);
    }
    assert_eq!(count(service), first);
}
#[test]
fn reads_are_answered_while_the_engine_is_busy() {
    let fixture = Fixture::new();
    fs::write(fixture.item("a.tmp"), b"x").unwrap();
    let daemon = fixture.daemon();
    let service = &daemon.service;
    let revision = acknowledged(service.handle(Request::AddRoot(fixture.root())));
    acknowledged(service.handle(Request::SaveRule {
        rule: fixture.rule(),
        roots: None,
        keep_paths: vec![],
        unkeep_paths: vec![],
        revision,
    }));
    settle(&daemon);
    // The guard stands in for a long scan turn; every read must still answer (they would deadlock
    // here if they waited for the engine).
    let _scan = service.hold_engine_for_test();
    let _decisions = service.hold_decisions_for_test();
    assert!(matches!(
        service.handle(Request::LoadOverview),
        Response::Overview(v) if v.deadline_summary.as_ref().unwrap().active == 1 && v.indexed_items >= 1
    ));
    assert!(matches!(
        service.handle(Request::LoadUpcoming { rule_id: None, disposition: None, after: None, limit: 10 }),
        Response::UpcomingPage(p) if p.total_count == 1 && p.items.len() == 1
    ));
    assert!(matches!(
        service.handle(Request::LoadActivity { limit: 10 }),
        Response::Activity(_)
    ));
    assert!(matches!(
        service.handle(Request::LoadPolicy),
        Response::Policy(_)
    ));
    assert!(matches!(
        service.handle(Request::LoadSettings),
        Response::Settings(_)
    ));
    assert!(matches!(
        service.handle(Request::ExplainItem {
            path: fixture.item("a.tmp")
        }),
        Response::ItemExplanation(_)
    ));
}
#[cfg(unix)]
#[test]
fn abandoned_connections_do_not_stop_the_agent() {
    let fixture = Fixture::new();
    let daemon = fixture.daemon();
    let endpoint = fixture.options().paths.endpoint;
    let shutdown = Arc::new(AtomicBool::new(false));
    struct StopOnDrop(Arc<AtomicBool>);
    impl Drop for StopOnDrop {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }
    std::thread::scope(|scope| {
        let runner = scope.spawn(|| daemon.run(shutdown.clone()));
        // Unwinding must stop the scoped daemon thread too, or a failed assertion hangs forever.
        let _stop = StopOnDrop(shutdown.clone());
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let connect = || loop {
            assert!(!runner.is_finished(), "agent exited early");
            assert!(
                std::time::Instant::now() < deadline,
                "agent connection deadline exceeded"
            );
            match ipc::unix::connect(&endpoint) {
                Ok(stream) => {
                    stream
                        .set_read_timeout(Some(Duration::from_millis(200)))
                        .unwrap();
                    stream
                        .set_write_timeout(Some(Duration::from_millis(200)))
                        .unwrap();
                    break stream;
                }
                Err(_) => std::thread::yield_now(),
            }
        };
        // Clients that vanish immediately or mid-frame (these made macOS accept fail with EINVAL).
        for i in 0..300 {
            let mut stream = connect();
            if i % 2 == 0 {
                let _ = stream.write_all(&[0, 0, 0, 9, b'{']);
            }
            drop(stream);
        }
        loop {
            let result = Client::connect(
                connect(),
                ipc::VersionRange::default(),
                ipc::DEFAULT_MAX_FRAME,
            )
            .and_then(|mut client| client.request(Request::Health));
            match result {
                Ok(Response::Health(_)) => break,
                Ok(other) => panic!("unexpected health response: {other:?}"),
                // Saturation intentionally drops connections at the 16-worker limit.
                // Wait for abandoned workers to release their permits, bounded by deadline.
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::ConnectionReset
                            | io::ErrorKind::ConnectionAborted
                            | io::ErrorKind::BrokenPipe
                            | io::ErrorKind::UnexpectedEof
                            | io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                    ) =>
                {
                    std::thread::yield_now()
                }
                Err(error) => panic!("health request failed: {error}"),
            }
        }
        assert!(!runner.is_finished());
        shutdown.store(true, Ordering::Release);
        runner.join().unwrap().unwrap();
        // Tolerated errors are counted (possibly zero on kernels that never fail these accepts).
        let _ = daemon.tolerated_accept_errors();
    });
}
#[test]
fn changed_candidates_get_decisions_without_a_full_pass_and_trashed_ones_leave_no_row() {
    let fixture = Fixture::new();
    let a = fixture.item("a.tmp");
    fs::write(&a, b"x").unwrap();
    let daemon = fixture.daemon();
    let service = &daemon.service;
    let revision = acknowledged(service.handle(Request::AddRoot(fixture.root())));
    acknowledged(service.handle(Request::SaveRule {
        rule: fixture.rule(),
        roots: None,
        keep_paths: vec![],
        unkeep_paths: vec![],
        revision,
    }));
    settle(&daemon);
    let total = |service: &Service| match service.handle(Request::LoadUpcoming {
        rule_id: None,
        disposition: None,
        after: None,
        limit: 10,
    }) {
        Response::UpcomingPage(p) => p.total_count,
        other => panic!("{other:?}"),
    };
    assert_eq!(total(service), 1);
    let history = match service.handle(Request::LoadActivity { limit: 1000 }) {
        Response::Activity(items) => items,
        other => panic!("{other:?}"),
    };
    let expected_rule = fixture.rule().id;
    assert!(history.iter().any(|item| {
        item.identity.as_ref().is_some_and(|identity| codec::flavor().equal(&identity.path_hint, &a))
            && item.rule_id.as_deref() == Some(expected_rule.as_str())
    }), "compact scheduling activity lost its identity or rule");
    fs::write(fixture.item("b.tmp"), b"y").unwrap();
    acknowledged(service.handle(Request::RebuildIndex));
    settle(&daemon);
    assert_eq!(total(service), 2);
    // Both become due and are trashed: no decision rows may linger for trashed items.
    fixture.clock.0.fetch_add(120, Ordering::SeqCst);
    settle(&daemon);
    assert!(!Path::new(&a).exists());
    assert_eq!(total(service), 0);
    assert!(matches!(
        service.handle(Request::LoadOverview),
        Response::Overview(v) if v.deadline_summary.as_ref().unwrap().active == 0
    ));
}
/// The polling fallback (platforms without a native watcher) notices a new file through its directory's
/// mtime well before the slow full rescan is due (clock +70 s of a 300 s interval).
#[cfg(not(any(target_os = "linux", windows)))]
#[test]
fn polling_fallback_detects_new_files_before_the_full_rescan() {
    let fixture = Fixture::new();
    fs::write(fixture.item("a.tmp"), b"x").unwrap();
    let daemon = fixture.daemon();
    let service = &daemon.service;
    let revision = acknowledged(service.handle(Request::AddRoot(fixture.root())));
    let mut rule = fixture.rule();
    rule.lifetime = 1_000_000.0;
    acknowledged(service.handle(Request::SaveRule {
        rule,
        roots: None,
        keep_paths: vec![],
        unkeep_paths: vec![],
        revision,
    }));
    settle(&daemon);
    let total = |service: &Service| match service.handle(Request::LoadUpcoming {
        rule_id: None,
        disposition: None,
        after: None,
        limit: 10,
    }) {
        Response::UpcomingPage(p) => p.total_count,
        other => panic!("{other:?}"),
    };
    assert_eq!(total(service), 1);
    // Pin the root's mtime in the past so the later creation is distinguishable on coarse filesystems.
    let old = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
    fs::File::open(&fixture.root)
        .unwrap()
        .set_modified(old)
        .unwrap();
    fixture.clock.0.fetch_add(35, Ordering::SeqCst);
    settle(&daemon); // this poll observes the pinned mtime
    fs::write(fixture.item("b.tmp"), b"y").unwrap();
    fixture.clock.0.fetch_add(35, Ordering::SeqCst);
    settle(&daemon);
    assert_eq!(total(service), 2);
}

#[cfg(windows)]
#[test]
fn windows_native_and_core_paths_share_root_authorization_across_restart() {
    let fixture = Fixture::new();
    fs::write(fixture.item("a.tmp"), b"x").unwrap();
    let native_root = fixture.path.join("tree").to_str().unwrap().to_owned();
    assert!(native_root.starts_with(r"\\?\"));
    let daemon = fixture.daemon();
    let service = &daemon.service;
    let revision = acknowledged(service.handle(Request::AddRoot(codec::root(&native_root))));
    let mut rule = fixture.rule();
    rule.state = ipc::RuleState::Preview;
    acknowledged(service.handle(Request::SaveRule {
        rule: rule.clone(),
        roots: None,
        keep_paths: vec![],
        unkeep_paths: vec![],
        revision,
    }));
    settle(&daemon);
    assert!(matches!(
        service.handle(Request::ExplainItem {
            path: fixture.root.clone()
        }),
        Response::ItemExplanation(_)
    ));
    acknowledged(service.handle(Request::SetItemOverrides {
        changes: vec![ipc::OverrideChange {
            path: fixture.root.clone(),
            policy: Some(ipc::OverridePolicy::Keep {
                protect_descendants: true,
            }),
        }],
    }));
    acknowledged(service.handle(Request::ClearItemOverride {
        path: native_root.clone(),
    }));
    let policy = match service.handle(Request::LoadPolicy) {
        Response::Policy(p) => p,
        other => panic!("{other:?}"),
    };
    assert!(
        policy.overrides.is_empty(),
        "native spelling must clear the normalized override"
    );
    acknowledged(service.handle(Request::ReplacePolicy(policy)));
    assert!(matches!(
        service.handle(Request::PreviewRule(rule.clone())),
        Response::RulePreview(p) if p.matches == 1
    ));
    let sibling = fixture.path.join("tree-sibling").join("a.tmp");
    assert!(matches!(
        service.handle(Request::ExplainItem { path: codec::path(&sibling).unwrap() }),
        Response::Failure(e) if e.code == ipc::ErrorCode::InvalidRequest
    ));
    drop(daemon);
    let daemon = fixture.daemon();
    assert!(matches!(
        daemon.service.handle(Request::PreviewRule(rule)),
        Response::RulePreview(p) if p.matches == 1
    ));
    acknowledged(daemon.service.handle(Request::RemoveRoot {
        id: codec::root(&native_root).id,
    }));
}
