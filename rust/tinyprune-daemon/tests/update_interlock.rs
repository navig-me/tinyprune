//! Update/Trash interlock through the real daemon service (ADR 0012): a quiesced agent must not move a
//! due item to Trash, and must resume once the updater releases the lease.
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tinyprune_core::trash::Clock;
use tinyprune_daemon::{Daemon, Options, Paths};
use tinyprune_ipc::{self as ipc, AgentService, ErrorCode, Request, Response, UpdatePhase};

struct ScriptClock(AtomicU64);
impl Clock for ScriptClock {
    fn now(&self) -> f64 {
        self.0.load(Ordering::SeqCst) as f64
    }
}
fn settle(daemon: &Daemon) {
    let mut idle = 0;
    for _ in 0..200 {
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
fn status(response: Response) -> ipc::UpdateStatus {
    match response {
        Response::UpdateStatus(s) => s,
        other => panic!("expected UpdateStatus, got {other:?}"),
    }
}
fn quiesce(token: &str, seconds: u32) -> Request {
    Request::QuiesceForUpdate {
        token: token.into(),
        target: "9.9.9".into(),
        lease_seconds: seconds,
    }
}

#[test]
fn quiesced_agent_does_not_trash_a_due_item_and_resumes_after_release() {
    let base = fs::canonicalize({
        let p = std::env::temp_dir().join(format!("tinyprune-interlock-{}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(p.join("tree")).unwrap();
        p
    })
    .unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(base.clone());
    let root = base.join("tree").to_str().unwrap().to_owned();
    let old = base.join("tree/old.tmp");
    fs::write(&old, b"old").unwrap();

    let clock = Arc::new(ScriptClock(AtomicU64::new(1_800_000_000)));
    let daemon = Daemon::open(
        Options {
            paths: Paths {
                data: base.join("data"),
                endpoint: base.join("ipc/agent.sock"),
                logs: base.join("logs"),
            },
            reconcile_interval: Duration::from_secs(300),
            tick_interval: Duration::from_millis(1),
            trash: Some(base.join("trash")),
        },
        clock.clone(),
    )
    .unwrap();
    let service = &daemon.service;

    let added = match service.handle(Request::AddRoot(ipc::Root {
        id: "root-1".into(),
        path: root.clone(),
        name: "Fixture".into(),
    })) {
        Response::Acknowledged(a) => a.revision,
        other => panic!("{other:?}"),
    };
    let rule = ipc::Rule {
        id: "00000000-0000-0000-0000-000000000001".into(),
        name: "Fixture".into(),
        scope: ipc::Scope {
            path: root,
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
    };
    assert!(matches!(
        service.handle(Request::SaveRule {
            rule,
            roots: None,
            keep_paths: vec![],
            unkeep_paths: vec![],
            revision: added
        }),
        Response::Acknowledged(_)
    ));
    settle(&daemon);
    assert!(old.exists(), "not due yet");
    assert_eq!(
        status(service.handle(Request::LoadUpdateStatus)).phase,
        UpdatePhase::Idle
    );

    // The updater quiesces: with nothing in flight the agent is immediately `quiesced`.
    let s = status(service.handle(quiesce("tok-1", 300)));
    assert_eq!(
        (s.phase, s.trash_in_flight, s.target.as_deref()),
        (UpdatePhase::Quiesced, 0, Some("9.9.9"))
    );
    assert!(s.lease_remaining_seconds.unwrap() > 0.0);
    // A second updater is refused; a stranger cannot release.
    assert!(
        matches!(service.handle(quiesce("tok-2", 300)), Response::Failure(f) if f.code == ErrorCode::Busy)
    );
    assert!(matches!(
        service.handle(Request::ReleaseUpdateQuiesce {
            token: "tok-2".into()
        }),
        Response::Failure(_)
    ));
    // Malformed requests never open or close the gate.
    assert!(
        matches!(service.handle(quiesce("", 300)), Response::Failure(f) if f.code == ErrorCode::InvalidRequest)
    );
    assert!(matches!(
        service.handle(quiesce("tok-3", 0)),
        Response::Failure(_)
    ));

    // The item becomes due while quiesced: it must NOT be trashed.
    clock.0.fetch_add(120, Ordering::SeqCst);
    settle(&daemon);
    assert!(
        Path::new(&old).exists(),
        "Trash is blocked while the update lease is held"
    );
    assert_eq!(
        status(service.handle(Request::LoadUpdateStatus)).phase,
        UpdatePhase::Quiesced
    );
    assert!(matches!(
        service.handle(Request::LoadActivity { limit: 100 }),
        Response::Activity(items) if items.iter().any(|i| i.kind == ipc::ActivityKind::SafetySkipped)
            && !items.iter().any(|i| i.kind == ipc::ActivityKind::MovedToTrash)
    ));

    // Released: the retained deadline is honored and the item is trashed.
    assert_eq!(
        status(service.handle(Request::ReleaseUpdateQuiesce {
            token: "tok-1".into()
        }))
        .phase,
        UpdatePhase::Idle
    );
    for _ in 0..4 {
        clock.0.fetch_add(400, Ordering::SeqCst);
        settle(&daemon);
        if !old.exists() {
            break;
        }
    }
    assert!(!old.exists(), "pruning resumes after release");
    assert_eq!(fs::read_dir(base.join("trash/files")).unwrap().count(), 1);
}
