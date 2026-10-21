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

struct DecisionFixture {
    candidates: Vec<RuleCandidate>,
    deadlines: Vec<TrashRequest>,
    values: Vec<serde_json::Value>,
}
/// `rows` candidates under `/root` with deterministic shuffled schedule keys and ~1 KiB explanations.
fn decision_fixture(rows: usize) -> DecisionFixture {
    let candidates: Vec<_> = (0..rows).map(|n| {
        let mut item = candidate(0);
        item.identity.resource = (n as u128).to_be_bytes().to_vec();
        item.identity.path_hint = format!("/root/group-{:04}/item-{n:06}.dat", n / 1000);
        item
    }).collect();
    let deadlines: Vec<_> = candidates.iter().enumerate().map(|(n, item)| TrashRequest {
        candidate_identity: item.identity.clone(),
        source: ScheduledSource::Rule(Uuid(2)),
        scheduled_at: 2_000_000.0 + ((n * 7919) % rows) as f64,
    }).collect();
    let values: Vec<_> = deadlines.iter().map(|deadline| serde_json::json!({
        "item": {
            "volumeIdentifier": deadline.candidate_identity.volume.to_string(),
            "resourceIdentifier": hex(&deadline.candidate_identity.resource),
            "pathHint": deadline.candidate_identity.path_hint,
            "creationTime": 0.0, "generation": 1, "isPersistent": true
        },
        "scheduledAt": deadline.scheduled_at, "rule": {"id": Uuid(2).to_string()},
        "basis": "modified", "diagnosticContext": "x".repeat(768)
    })).collect();
    DecisionFixture { candidates, deadlines, values }
}
/// Fresh file-backed store holding the fixture's candidates and deadlines, fully checkpointed so a
/// measurement starts from an empty WAL.
fn fixture_store(path: &Path, fixture: &DecisionFixture) -> Store {
    let mut store = Store::open(path).unwrap();
    store.replace_roots(&["/root".into()], 0.0).unwrap();
    store.publish_candidate_subtree("/root", &fixture.candidates, 0.0).unwrap();
    AgentStore::replace_deadlines(&mut store, "/root", &fixture.deadlines).unwrap();
    store.lock().unwrap().execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
    store
}
fn put_page(store: &Store, fixture: &DecisionFixture, page: usize, size: usize) -> usize {
    let rule_id = Uuid(2).to_string();
    let start = page * size;
    let end = (start + size).min(fixture.deadlines.len());
    let rows: Vec<_> = (start..end).map(|n| DecisionRow {
        identity: &fixture.deadlines[n].candidate_identity,
        scheduled_at: Some(fixture.deadlines[n].scheduled_at),
        rule_id: Some(&rule_id), preview: false, explanation: &fixture.values[n],
    }).collect();
    store.put_decisions(1.0, &rows).unwrap()
}
fn decision_total(store: &Store) -> i64 {
    store.read().unwrap().query_row("SELECT COUNT(*) FROM current_decisions", [], |r| r.get(0)).unwrap()
}
fn temp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tinyprune-store-{label}-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn file_store_disables_autocheckpoint_and_keeps_full_synchronous() {
    let dir = temp_dir("pragmas");
    let store = Store::open(dir.join("p.sqlite")).unwrap();
    {
        let c = store.lock().unwrap();
        assert_eq!(c.query_row("PRAGMA wal_autocheckpoint", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
        assert_eq!(c.query_row("PRAGMA synchronous", [], |r| r.get::<_, i64>(0)).unwrap(), 2, "FULL");
        assert_eq!(c.query_row("PRAGMA journal_mode", [], |r| r.get::<_, String>(0)).unwrap(), "wal");
    }
    drop(store);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn checkpoint_is_noop_for_memory_store_and_small_wal() {
    let store = Store::memory().unwrap();
    assert_eq!(store.wal_bytes(), 0);
    assert_eq!(store.checkpoint_if_needed(0).unwrap(), None);
    assert_eq!(store.checkpoint_idle().unwrap(), None);
    let dir = temp_dir("noop");
    let store = Store::open(dir.join("n.sqlite")).unwrap();
    assert_eq!(store.checkpoint_if_needed(u64::MAX).unwrap(), None);
    drop(store);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn checkpoint_with_pinned_reader_does_not_block_and_completes_after_release() {
    let dir = temp_dir("pinned");
    let path = dir.join("r.sqlite");
    let fixture = decision_fixture(2048);
    let store = fixture_store(&path, &fixture);
    // An independent connection pins a snapshot taken before the decisions are written.
    let pinned = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    pinned.execute_batch("BEGIN").unwrap();
    assert_eq!(
        pinned.query_row("SELECT COUNT(*) FROM current_decisions", [], |r| r.get::<_, i64>(0)).unwrap(),
        0
    );
    assert_eq!(put_page(&store, &fixture, 0, 2048), 2048);
    assert!(store.wal_bytes() > 0);
    // Never waits for the pinned reader: returns promptly, reports busy, backfills nothing past the pin.
    let started = std::time::Instant::now();
    let partial = store.checkpoint_if_needed(0).unwrap().expect("WAL is over the limit");
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
    assert!(partial.checkpointed_frames < partial.log_frames, "{partial:?}");
    let idle = store.checkpoint_idle().unwrap().expect("WAL file exists");
    assert!(idle.busy, "{idle:?}");
    // The pinned snapshot stays consistent while checkpoints ran, and Store reads and writes proceed.
    assert_eq!(
        pinned.query_row("SELECT COUNT(*) FROM current_decisions", [], |r| r.get::<_, i64>(0)).unwrap(),
        0
    );
    assert_eq!(decision_total(&store), 2048);
    store.record_decision(2.0, false, &fixture.values[0]).unwrap();
    pinned.execute_batch("COMMIT").unwrap();
    let done = store.checkpoint_idle().unwrap().expect("WAL file exists");
    assert!(!done.busy, "{done:?}");
    assert_eq!(store.wal_bytes(), 0);
    assert_eq!(decision_total(&store), 2048);
    drop(pinned);
    drop(store);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn checkpoint_under_concurrent_read_traffic_keeps_data_and_bounds_wal() {
    use std::sync::atomic::AtomicBool;
    const LIMIT: u64 = 1024 * 1024;
    const PAGES: usize = 5;
    let dir = temp_dir("bounded");
    let path = dir.join("b.sqlite");
    let fixture = decision_fixture(4096 * PAGES);
    let store = fixture_store(&path, &fixture);
    let stop = AtomicBool::new(false);
    let reads = AtomicUsize::new(0);
    let (mut first_page, mut max_wal, mut checkpoints) = (0u64, 0u64, 0usize);
    std::thread::scope(|scope| {
        scope.spawn(|| {
            while !stop.load(Ordering::Acquire) {
                store.decision_page(None, None, None, NonZeroUsize::new(5).unwrap()).unwrap();
                reads.fetch_add(1, Ordering::Relaxed);
            }
        });
        for page in 0..PAGES {
            put_page(&store, &fixture, page, 4096);
            let after = store.wal_bytes();
            if page == 0 {
                first_page = after;
            }
            max_wal = max_wal.max(after);
            if store.checkpoint_if_needed(LIMIT).unwrap().is_some() {
                checkpoints += 1;
            }
        }
        stop.store(true, Ordering::Release);
    });
    assert!(reads.load(Ordering::Relaxed) > 0);
    // One page of WAL is far above the limit, so every page is followed by a checkpoint and the log
    // restarts: the file never exceeds limit + about one page (unbounded growth would be PAGES pages).
    assert!(first_page > 2 * LIMIT, "fixture page too small: {first_page}");
    assert_eq!(checkpoints, PAGES);
    assert!(max_wal <= LIMIT + 2 * first_page, "{max_wal} vs one page {first_page}");
    assert!(max_wal < PAGES as u64 * first_page * 3 / 4, "WAL never recycled: {max_wal}");
    assert_eq!(decision_total(&store), (4096 * PAGES) as i64);
    assert!(!store.checkpoint_idle().unwrap().unwrap().busy);
    assert_eq!(store.wal_bytes(), 0);
    let check: String = store.read().unwrap().query_row("PRAGMA integrity_check", [], |r| r.get(0)).unwrap();
    assert_eq!(check, "ok");
    drop(store);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn reopen_after_unclean_exit_replays_uncheckpointed_wal() {
    const CHILD: &str = "TINYPRUNE_STORE_CRASH_DIR";
    const NAME: &str = "tests::reopen_after_unclean_exit_replays_uncheckpointed_wal";
    if let Some(dir) = std::env::var_os(CHILD) {
        // Child: write durable decisions without any checkpoint, then die without running destructors.
        let fixture = decision_fixture(2048);
        let store = fixture_store(&PathBuf::from(dir).join("crash.sqlite"), &fixture);
        assert_eq!(put_page(&store, &fixture, 0, 2048), 2048);
        assert!(store.wal_bytes() > 0);
        std::process::abort();
    }
    let dir = temp_dir("crash");
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", NAME, "--test-threads=1", "--nocapture"])
        .env(CHILD, &dir)
        .status()
        .unwrap();
    assert!(!status.success(), "child must die uncleanly: {status:?}");
    let path = dir.join("crash.sqlite");
    let wal_before = std::fs::metadata(dir.join("crash.sqlite-wal")).map_or(0, |m| m.len());
    assert!(wal_before > 0, "the crash must leave committed frames in the WAL");
    let store = Store::open(&path).unwrap();
    assert_eq!(store.candidate_count().unwrap(), 2048);
    assert_eq!(decision_total(&store), 2048);
    let check: String = store.read().unwrap().query_row("PRAGMA integrity_check", [], |r| r.get(0)).unwrap();
    assert_eq!(check, "ok");
    store.checkpoint_idle().unwrap();
    assert_eq!(store.wal_bytes(), 0);
    assert_eq!(decision_total(&store), 2048);
    drop(store);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
#[ignore = "100k production Store API checkpoint/read-traffic diagnostic"]
fn bench_put_decisions_checkpoint_and_readers() {
    use std::io::Write as _;
    use std::sync::atomic::AtomicBool;
    use std::time::{Duration, Instant};
    const ROWS: usize = 100_000;
    const MIB: u64 = 1024 * 1024;
    let dir = temp_dir("api");
    let fixture = decision_fixture(ROWS);
    let mut report = String::from("\n### Production Store 100k decision checkpoint/read-traffic controls\n\nReal Store schema/API with preloaded candidates and deadlines, FULL/WAL throughout. Twenty-five 4096-row pages, deterministic shuffled schedule keys. Preparation excluded; reader requests reproduce upcoming COUNT + one-row reads every 10 ms. `SQLite autocheckpoint` rows are the previous production behaviour (and isolated controls); `manual` rows use the current Store: autocheckpoint off, `Store::checkpoint_if_needed(limit)` between pages (timed separately, included in `wall`). `idle` runs `Store::checkpoint_idle` (TRUNCATE) after every page. The final TRUNCATE after all pages is timed separately.\n\n| mode | IPC-like readers | read requests | put_decisions total ms | between-page checkpoints (count) | between-page checkpoint ms | wall ms | max WAL bytes | final checkpoint ms | WAL bytes before final | checkpoint busy |\n|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    print!("{report}");
    struct StopReader<'a>(&'a AtomicBool);
    impl Drop for StopReader<'_> {
        fn drop(&mut self) { self.0.store(true, Ordering::Release); }
    }
    // (label, SQLite autocheckpoint frames, manual limit, truncate when idle after each page, readers)
    let cases: [(&str, i64, Option<u64>, bool, bool); 8] = [
        ("SQLite autocheckpoint 1000 (previous default)", 1000, None, false, false),
        ("SQLite autocheckpoint 1000 (previous default)", 1000, None, false, true),
        ("SQLite autocheckpoint 10000", 10_000, None, false, true),
        ("no checkpoint at all (unbounded WAL control)", 0, None, false, true),
        ("manual PASSIVE over 64 MiB", 0, Some(64 * MIB), false, true),
        ("manual PASSIVE over 16 MiB", 0, Some(16 * MIB), false, true),
        ("manual PASSIVE over 0 (every page)", 0, Some(0), false, true),
        ("manual idle TRUNCATE after every page", 0, None, true, true),
    ];
    for (case, (label, frames, limit, idle, readers)) in cases.into_iter().enumerate() {
        let path = dir.join(format!("case-{case}.sqlite"));
        let (put_ms, wall_ms, between_ms, between_count, max_wal);
        let final_ms;
        let wal_bytes;
        let checkpoint_busy;
        let requests = AtomicUsize::new(0);
        {
            let store = fixture_store(&path, &fixture);
            store.lock().unwrap().pragma_update(None, "wal_autocheckpoint", frames).unwrap();
            let stop = AtomicBool::new(false);
            let reader = store.clone();
            let (mut put, mut between, mut count, mut high) = (0.0, 0.0, 0usize, 0u64);
            let wall = Instant::now();
            std::thread::scope(|scope| {
                let _stop_reader = StopReader(&stop);
                if readers {
                    scope.spawn(|| {
                        while !stop.load(Ordering::Acquire) {
                            reader.decision_page(None, None, None, NonZeroUsize::new(1).unwrap()).unwrap();
                            requests.fetch_add(1, Ordering::Relaxed);
                            std::thread::sleep(Duration::from_millis(10));
                        }
                    });
                }
                for page in 0..ROWS.div_ceil(4096) {
                    let started = Instant::now();
                    put_page(&store, &fixture, page, 4096);
                    put += started.elapsed().as_secs_f64() * 1000.0;
                    high = high.max(store.wal_bytes());
                    let started = Instant::now();
                    let ran = match (limit, idle) {
                        (Some(limit), _) => store.checkpoint_if_needed(limit).unwrap().is_some(),
                        (None, true) => store.checkpoint_idle().unwrap().is_some(),
                        (None, false) => false,
                    };
                    if ran {
                        count += 1;
                        between += started.elapsed().as_secs_f64() * 1000.0;
                    }
                }
            });
            (put_ms, between_ms, between_count, max_wal) = (put, between, count, high);
            wall_ms = wall.elapsed().as_secs_f64() * 1000.0;
            wal_bytes = store.wal_bytes();
            let started = Instant::now();
            checkpoint_busy = store.lock().unwrap().query_row(
                "PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get::<_, i64>(0)
            ).unwrap();
            final_ms = started.elapsed().as_secs_f64() * 1000.0;
        }
        let row = format!("| {label} | {readers} | {} | {put_ms:.3} | {between_count} | {between_ms:.3} | {wall_ms:.3} | {max_wal} | {final_ms:.3} | {wal_bytes} | {checkpoint_busy} |\n", requests.load(Ordering::Relaxed));
        print!("{row}");
        report.push_str(&row);
        std::fs::remove_file(path).unwrap();
    }
    if let Some(path) = std::env::var_os("TINYPRUNE_BENCH_OUT") {
        std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap()
            .write_all(report.as_bytes()).unwrap();
    }
    std::fs::remove_dir_all(dir).unwrap();
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
    let audit = s.audit_records().unwrap();
    let compact: serde_json::Value = decode(&audit.last().unwrap().payload).unwrap();
    assert_eq!(compact["version"], 1);
    assert_eq!(compact["identityKey"], key(ids.last().unwrap()));
    assert_eq!(compact["item"]["pathHint"], first.last().unwrap()["item"]["pathHint"]);
    assert_eq!(compact["item"]["isPersistent"], true);
    assert!(compact.get("marker").is_none());
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
    // Deletion archives the last full explanation atomically; compact scheduling history alone is
    // never returned as an Explanation after the current projection is gone.
    assert_eq!(s.latest_decision(&trashed).unwrap(), Some(b.clone()));
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
#[test]
fn update_deadlines_touches_only_the_named_identities() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    s.replace_deadlines(
        "/root",
        &[request(1, 10.0), request(2, 20.0), request(3, 30.0)],
    )
    .unwrap();
    let audits = s.audit_records().unwrap().len();
    // 1 moves, 2 loses its deadline, 3 is not evaluated and must survive untouched.
    s.update_deadlines(
        "/root",
        &[
            request(1, 0.0).candidate_identity,
            request(2, 0.0).candidate_identity,
        ],
        &[request(1, 15.0)],
    )
    .unwrap();
    let rows: Vec<(u8, f64)> = s
        .load_deadlines()
        .unwrap()
        .iter()
        .map(|r| (r.candidate_identity.resource[0], r.scheduled_at))
        .collect();
    assert_eq!(rows, [(1, 15.0), (3, 30.0)]);
    assert_eq!(s.audit_records().unwrap().len(), audits + 1);
    // Identical update: no row rewrite and no audit.
    let writes = changes(&s);
    s.update_deadlines(
        "/root",
        &[request(1, 0.0).candidate_identity],
        &[request(1, 15.0)],
    )
    .unwrap();
    assert_eq!(
        (changes(&s), s.audit_records().unwrap().len()),
        (writes, audits + 1)
    );
    // A non-finite time fails the whole transaction.
    assert!(s
        .update_deadlines(
            "/root",
            &[request(3, 0.0).candidate_identity],
            &[request(2, f64::NAN)]
        )
        .is_err());
    assert_eq!(s.load_deadlines().unwrap().len(), 2);
}
#[test]
fn upsert_candidates_changes_only_named_rows_and_retires_nothing() {
    let s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    s.publish_candidate_subtree("/root", &[candidate(1), candidate(2)], 1.0)
        .unwrap();
    let audits = s.audit_records().unwrap().len();
    // 1 is unchanged, 3 is new, 2 is not named and must stay.
    assert_eq!(
        s.upsert_candidates(&[candidate(1), candidate(3)], 2.0)
            .unwrap(),
        1
    );
    assert_eq!(s.candidate_count().unwrap(), 3);
    assert_eq!(s.audit_records().unwrap().len(), audits + 1);
    let (writes, audits) = (changes(&s), s.audit_records().unwrap().len());
    assert_eq!(
        s.upsert_candidates(&[candidate(1), candidate(3)], 3.0)
            .unwrap(),
        0
    );
    assert_eq!(
        (changes(&s), s.audit_records().unwrap().len()),
        (writes, audits)
    );
    let mut outside = candidate(4);
    outside.identity.path_hint = "/elsewhere/4".into();
    assert!(s.upsert_candidates(&[outside], 4.0).is_err());
    assert_eq!(s.candidate_count().unwrap(), 3);
}
fn windows_candidate(n: u32, path: &str) -> RuleCandidate {
    let mut identity = bulk_identity(n);
    identity.path_hint = path.into();
    RuleCandidate::new(
        identity,
        n.to_string(),
        ItemKind::File,
        CandidateTimestamps::default(),
    )
}
#[test]
fn windows_flavor_containment_handles_varied_spellings_in_publication_and_removal() {
    let mut s = Store::memory_with_flavor(PathFlavor::Windows).unwrap();
    s.replace_roots(&[r"C:\Root".into(), r"\\?\D:\Data\X".into()], 0.0)
        .unwrap();
    let first = [
        windows_candidate(1, r"C:\Root\a"),
        windows_candidate(2, "c:/ROOT/sub/b"),
        windows_candidate(3, r"\\?\c:\root\.\sub\..\c"),
    ];
    // A different spelling of the same subtree publishes and later retires the same rows.
    assert_eq!(
        s.publish_candidate_subtree(r"\\?\c:\root", &first, 1.0)
            .unwrap(),
        3
    );
    s.publish_candidate_subtree("d:/data/x", &[windows_candidate(4, r"D:\DATA\x\file")], 2.0)
        .unwrap();
    assert_eq!(s.candidate_count().unwrap(), 4);
    assert_eq!(
        s.candidate_page(r"C:\ROOT", None, NonZeroUsize::new(10).unwrap())
            .unwrap()
            .len(),
        3
    );
    assert_eq!(
        s.candidate_page(r"D:\Data\X", None, NonZeroUsize::new(10).unwrap())
            .unwrap()
            .len(),
        1
    );
    // Only the second spelling remains in the next scan of the subtree: the other two vanished.
    assert_eq!(
        s.publish_candidate_subtree(r"C:\Root", &first[1..2], 3.0)
            .unwrap(),
        2
    );
    assert_eq!(s.candidate_count().unwrap(), 2);
    // A sibling that merely shares a prefix is outside the subtree and outside every root.
    assert!(s
        .publish_candidate_subtree(r"C:\Root", &[windows_candidate(5, r"C:\Root-other\x")], 4.0)
        .is_err());
    s.remove_below(r"c:\root\SUB").unwrap();
    assert_eq!(s.candidate_count().unwrap(), 1);
    s.remove_below(r"C:\ROOT").unwrap();
    assert_eq!(s.candidate_count().unwrap(), 1, "the D: root is untouched");
}
#[test]
fn windows_flavor_publication_grows_near_linearly() {
    fn run(n: u32) -> f64 {
        let s = Store::memory_with_flavor(PathFlavor::Windows).unwrap();
        s.replace_roots(&[r"C:\Root".into()], 0.0).unwrap();
        let items: Vec<_> = (0..n)
            .map(|i| windows_candidate(i, &format!(r"C:\Root\Dir{:03}\File{i:06}.dat", i / 100)))
            .collect();
        let start = std::time::Instant::now();
        s.publish_candidate_subtree(r"\\?\C:\Root", &items, 1.0)
            .unwrap();
        // Republish identical rows (full containment sweep over every stored row), then a vanishing subtree.
        s.publish_candidate_subtree(r"c:/root", &items, 2.0)
            .unwrap();
        s.publish_candidate_subtree(r"C:\Root\Dir000", &[], 3.0)
            .unwrap();
        start.elapsed().as_secs_f64() * 1000.0
    }
    let (small, large) = (
        (0..2).map(|_| run(4_000)).fold(f64::MAX, f64::min),
        (0..2).map(|_| run(8_000)).fold(f64::MAX, f64::min),
    );
    assert!(
        large < small * 3.0 + 100.0,
        "4k rows {small:.0} ms, 8k rows {large:.0} ms"
    );
}
#[test]
fn subtree_queries_use_the_path_key_index_and_rekey_across_flavors() {
    let path = Temp::new();
    {
        let s = Store::open_with_flavor(&path.0, PathFlavor::Windows).unwrap();
        s.replace_roots(&[r"C:\Root".into()], 0.0).unwrap();
        s.publish_candidate_subtree(r"C:\Root", &[windows_candidate(1, r"C:\Root\a")], 1.0)
            .unwrap();
        let plan: String = s
            .lock()
            .unwrap()
            .prepare("EXPLAIN QUERY PLAN SELECT identity_key,path_hint FROM candidates WHERE path_key=?1 OR (path_key>=?2 AND path_key<?3)")
            .unwrap()
            .query_map(["a", "b", "c"], |r| r.get::<_, String>(3))
            .unwrap()
            .map(|r| r.unwrap())
            .collect::<Vec<_>>()
            .join(" ");
        assert!(plan.contains("candidate_key"), "{plan}");
    }
    // The other flavor re-keys every row on open; reopening as Windows re-keys back.
    drop(Store::open(&path.0).unwrap());
    let mut s = Store::open_with_flavor(&path.0, PathFlavor::Windows).unwrap();
    assert_eq!(s.candidate_count().unwrap(), 1);
    s.remove_below(r"c:/ROOT").unwrap();
    assert_eq!(s.candidate_count().unwrap(), 0);
}

#[test]
fn compact_decision_audit_failure_rolls_back_projection_and_archival() {
    let mut s = Store::memory().unwrap();
    s.replace_roots(&["/root".into()], 0.0).unwrap();
    let identity = bulk_identity(1);
    let candidate = RuleCandidate::new(
        identity.clone(),
        identity.path_hint.clone(),
        ItemKind::File,
        CandidateTimestamps::default(),
    );
    s.publish_candidate_subtree("/root", &[candidate], 1.0).unwrap();
    let mut full = explanation(&identity, 1);
    full["context"] = serde_json::json!("x".repeat(4096));
    let row = DecisionRow {
        identity: &identity,
        scheduled_at: Some(10.0),
        rule_id: None,
        preview: false,
        explanation: &full,
    };
    s.put_decisions(2.0, &[row]).unwrap();
    let audit = s.audit_records().unwrap();
    let compact = &audit.last().unwrap().payload;
    assert!(compact.len() < full.to_string().len() / 2);
    assert_eq!(s.latest_decision(&identity).unwrap(), Some(full.clone()));
    s.lock().unwrap().execute_batch(
        "CREATE TRIGGER fail_decision_audit BEFORE INSERT ON audit WHEN NEW.kind='schedulingDecision' BEGIN SELECT RAISE(ABORT,'injected audit failure'); END;"
    ).unwrap();
    let next = explanation(&identity, 2);
    assert!(s.put_decisions(3.0, &[DecisionRow { explanation: &next, ..row }]).is_err());
    assert_eq!(s.latest_decision(&identity).unwrap(), Some(full.clone()));
    // The full archive is part of removal, not a best-effort supplemental transaction.
    assert!(s.remove_below(&identity.path_hint).is_err());
    assert_eq!(s.candidate_count().unwrap(), 1);
    s.lock().unwrap().execute_batch("DROP TRIGGER fail_decision_audit").unwrap();
    s.remove_below(&identity.path_hint).unwrap();
    assert_eq!(s.latest_decision(&identity).unwrap(), Some(full));
}

#[test]
fn v8_drops_only_obsolete_path_hint_indexes_and_keeps_full_durability() {
    let c = Connection::open_in_memory().unwrap();
    schema::at_version(&c, 7);
    let s = Store::from_connection(c).unwrap();
    let c = s.lock().unwrap();
    let names = strings(&c, "SELECT name FROM sqlite_master WHERE type='index'", []).unwrap();
    assert!(!names.iter().any(|n| n == "candidate_path" || n == "observation_path"));
    for retained in ["candidate_key", "observation_key", "candidate_root", "decisions_root",
        "decisions_due", "decisions_rule", "decisions_preview", "decision_identity"] {
        assert!(names.iter().any(|n| n == retained), "{retained}");
    }
    assert_eq!(c.query_row("PRAGMA synchronous", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
}
