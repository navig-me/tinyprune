use super::*;
use crate::archive::testing::{tar_gz, Entry};
use crate::crypto::sha256_hex;
use crate::download::testing::{FakeTransport, Route};
use crate::interlock::Interlock;
use crate::layout::{InstallFs, StdFs};
use crate::manifest::{ArchiveKind, Artifact};
use crate::test_support::TempDir;
use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

const URL: &str = "https://example.test/tinyprune-0.2.0-linux-x86_64.tar.gz";

fn package(extra: &[Entry]) -> Vec<u8> {
    let mut entries = vec![
        Entry::Dir("pkg/"),
        Entry::Dir("pkg/bin/"),
        Entry::File("pkg/bin/tinyprune", b"#!/bin/sh\n", 0o755),
        Entry::File("pkg/bin/tinyprune-agentd", b"#!/bin/sh\n", 0o755),
        Entry::File("pkg/VERSION", b"package_version=0.2.0\n", 0o644),
    ];
    entries.extend(extra.iter().map(|e| match e {
        Entry::File(n, d, m) => Entry::File(n, d, *m),
        _ => unreachable!(),
    }));
    tar_gz(&entries)
}
fn offer_for(bytes: &[u8]) -> Offer {
    Offer {
        version: "0.2.0".into(),
        build: 2,
        notes_url: None,
        published: None,
        platform: "linux-x86_64".into(),
        artifact: Artifact {
            url: URL.into(),
            sha256: sha256_hex(bytes),
            size: bytes.len() as u64,
        },
    }
}

type Log = Rc<RefCell<Vec<String>>>;
use std::rc::Rc;

struct Daemon {
    log: Log,
    quiesce: RefCell<Result<Status, ControlError>>,
    status: RefCell<Vec<Result<Status, ControlError>>>,
    health: RefCell<Vec<Result<String, ControlError>>>,
}
fn quiesced(remaining: u64) -> Status {
    Status {
        phase: Phase::Quiesced,
        target: Some("0.2.0".into()),
        trash_in_flight: 0,
        lease_remaining: Some(Duration::from_secs(remaining)),
    }
}
fn draining() -> Status {
    Status {
        phase: Phase::Draining,
        target: Some("0.2.0".into()),
        trash_in_flight: 1,
        lease_remaining: Some(Duration::from_secs(100)),
    }
}
impl DaemonControl for Daemon {
    fn quiesce(&self, _: &str, _: &str, _: Duration) -> Result<Status, ControlError> {
        self.log.borrow_mut().push("quiesce".into());
        self.quiesce.borrow().clone()
    }
    fn status(&self) -> Result<Status, ControlError> {
        self.log.borrow_mut().push("status".into());
        let mut s = self.status.borrow_mut();
        if s.len() > 1 {
            s.remove(0)
        } else {
            s[0].clone()
        }
    }
    fn release(&self, _: &str) -> Result<(), ControlError> {
        self.log.borrow_mut().push("release".into());
        Ok(())
    }
    fn health(&self) -> Result<String, ControlError> {
        self.log.borrow_mut().push("health".into());
        let mut h = self.health.borrow_mut();
        if h.len() > 1 {
            h.remove(0)
        } else {
            h[0].clone()
        }
    }
}
struct Restart {
    log: Log,
    results: RefCell<Vec<Result<RestartKind, String>>>,
    layout: Layout,
}
impl Restarter for Restart {
    fn restart(&self) -> Result<RestartKind, String> {
        let target = StdFs::native()
            .read_current(&self.layout)
            .unwrap()
            .expect("current pointer exists");
        self.log
            .borrow_mut()
            .push(format!("restart->{target}"));
        let mut r = self.results.borrow_mut();
        if r.len() > 1 {
            r.remove(0)
        } else {
            r[0].clone()
        }
    }
}
struct Checker {
    log: Log,
    result: Result<String, String>,
    current_at_check: RefCell<Option<Option<String>>>,
    layout: Layout,
}
impl SelfCheck for Checker {
    fn check(&self, dir: &Path, expected: &Expected<'_>) -> Result<CheckReport, String> {
        self.log.borrow_mut().push(format!(
            "selfcheck {} b{}",
            expected.version, expected.build
        ));
        assert!(
            dir.join("bin/tinyprune").is_file(),
            "self-check runs the staged binaries"
        );
        *self.current_at_check.borrow_mut() =
            Some(StdFs::native().read_current(&self.layout).unwrap());
        self.result
            .clone()
            .map(|daemon_version| CheckReport { daemon_version })
    }
}
#[derive(Default)]
struct NoSleep(Cell<u32>);
impl Sleeper for NoSleep {
    fn sleep(&self, _: Duration) {
        self.0.set(self.0.get() + 1);
    }
}

struct Rig {
    /// Keeps the temp directory alive for the test's duration.
    _dir: TempDir,
    layout: Layout,
    log: Log,
    transport: FakeTransport,
    daemon: Daemon,
    restart: Restart,
    checker: Checker,
    sleeper: NoSleep,
    state: StateFile,
    platform: Platform,
    installed: Installed,
    fs: StdFs,
    offer: Offer,
}
impl Rig {
    fn new() -> Self {
        let dir = TempDir::new();
        let layout = Layout::new(dir.path().join("tinyprune"));
        let log: Log = Rc::default();
        let bytes = package(&[]);
        let offer = offer_for(&bytes);
        let fs = StdFs::native();
        // An existing managed install: 0.1.0 build 1.
        std::fs::create_dir_all(layout.version_path("0.1.0-b1/bin")).unwrap();
        std::fs::write(layout.version_path("0.1.0-b1/bin/tinyprune"), "old").unwrap();
        fs.set_current(&layout, "0.1.0-b1").unwrap();
        Rig {
            transport: FakeTransport::with(vec![(URL, Route::ok(&bytes))]),
            daemon: Daemon {
                log: log.clone(),
                quiesce: RefCell::new(Ok(quiesced(100))),
                status: RefCell::new(vec![Ok(quiesced(90))]),
                health: RefCell::new(vec![Ok("0.2.0".into())]),
            },
            restart: Restart {
                log: log.clone(),
                results: RefCell::new(vec![Ok(RestartKind::Restarted)]),
                layout: layout.clone(),
            },
            checker: Checker {
                log: log.clone(),
                result: Ok("0.2.0".into()),
                current_at_check: RefCell::new(None),
                layout: layout.clone(),
            },
            sleeper: NoSleep::default(),
            state: StateFile::new(layout.state_file()),
            platform: Platform::new("linux", "x86_64", ArchiveKind::TarGz),
            installed: Installed {
                version: "0.1.0".into(),
                build: 1,
            },
            fs,
            offer,
            layout,
            log,
            _dir: dir,
        }
    }
    fn run(&self) -> Result<Installation, InstallError> {
        self.run_with(&self.daemon, &self.sleeper)
    }
    fn run_with(
        &self,
        daemon: &dyn DaemonControl,
        sleeper: &dyn Sleeper,
    ) -> Result<Installation, InstallError> {
        install(
            &InstallContext {
                layout: &self.layout,
                fs: &self.fs,
                transport: &self.transport,
                platform: &self.platform,
                installed: &self.installed,
                daemon,
                restarter: &self.restart,
                checker: &self.checker,
                sleeper,
                state: &self.state,
                limits: Limits::default(),
                lease: InstallContext::DEFAULT_LEASE,
                drain_timeout: Duration::from_secs(2),
                min_lease_remaining: InstallContext::DEFAULT_MIN_LEASE,
                health_timeout: Duration::from_secs(2),
                poll_interval: Duration::from_millis(250),
            },
            &self.offer,
        )
    }
    fn current(&self) -> String {
        self.fs.read_current(&self.layout).unwrap().unwrap()
    }
    fn events(&self) -> Vec<String> {
        self.log.borrow().clone()
    }
    fn versions(&self) -> Vec<String> {
        self.fs.list_dirs(&self.layout.versions()).unwrap()
    }
    fn assert_untouched(&self) {
        assert_eq!(self.current(), "0.1.0-b1");
        assert_eq!(
            self.versions(),
            ["0.1.0-b1"],
            "no staging or half-installed directory left behind"
        );
        let leftovers: Vec<_> = std::fs::read_dir(self.layout.update_dir())
            .map(|d| d.flatten().collect())
            .unwrap_or_default();
        assert!(
            leftovers.is_empty(),
            "no download files left: {leftovers:?}"
        );
    }
}

#[test]
fn valid_update_swaps_atomically_restarts_and_checks_health_in_order() {
    let rig = Rig::new();
    let done = rig.run().unwrap();
    assert_eq!(
        done,
        Installation {
            from: "0.1.0-b1".into(),
            to: "0.2.0-b2".into(),
            agent: AgentOutcome::Restarted,
            previous_kept: Some("0.1.0-b1".into()),
            prune_failures: vec![]
        }
    );
    assert_eq!(rig.current(), "0.2.0-b2");
    assert_eq!(
        rig.versions(),
        ["0.1.0-b1", "0.2.0-b2"],
        "previous kept for rollback"
    );
    assert!(rig
        .layout
        .version_path("0.2.0-b2/bin/tinyprune-agentd")
        .is_file());
    assert_eq!(
        rig.state.load().unwrap().previous.as_deref(),
        Some("0.1.0-b1")
    );
    // The self-check happened while `current` still pointed at the old build; the agent was
    // quiesced and the lease re-verified before the pointer moved; the restart saw the new pointer.
    assert_eq!(
        rig.checker
            .current_at_check
            .borrow()
            .clone()
            .unwrap()
            .as_deref(),
        Some("0.1.0-b1")
    );
    assert_eq!(
        rig.events(),
        [
            "selfcheck 0.2.0 b2",
            "health",
            "quiesce",
            "status",
            "restart->0.2.0-b2",
            "health"
        ]
    );
}

#[test]
fn hash_mismatch_changes_nothing_and_never_quiesces() {
    let rig = Rig::new();
    let mut bad = package(&[]);
    let last = bad.len() - 12;
    bad[last] ^= 0xff; // same length, different bytes
    rig.transport.set(URL, Route::ok(&bad));
    assert!(matches!(
        rig.run(),
        Err(InstallError::Download(DownloadError::HashMismatch))
    ));
    rig.assert_untouched();
    assert!(
        rig.events().is_empty(),
        "no self-check, quiesce or restart for unauthenticated bytes"
    );
}

#[test]
fn truncated_and_oversize_downloads_change_nothing() {
    let rig = Rig::new();
    let good = package(&[]);
    let mut cut = Route::ok(&good);
    cut.fail_after = Some(good.len() / 2);
    rig.transport.set(URL, cut);
    assert!(matches!(
        rig.run(),
        Err(InstallError::Download(DownloadError::Transport(_)))
    ));
    let mut endless = Route::ok(&good);
    endless.announced = None;
    endless.endless = true;
    rig.transport.set(URL, endless);
    assert!(matches!(
        rig.run(),
        Err(InstallError::Download(DownloadError::TooLarge { .. }))
    ));
    rig.assert_untouched();
    assert!(rig.events().is_empty());
}

#[test]
fn failed_self_check_never_reaches_the_pointer_or_the_agent() {
    let mut rig = Rig::new();
    rig.checker.result = Err("tinyprune --version exited 127".into());
    assert!(matches!(rig.run(), Err(InstallError::SelfCheck(_))));
    rig.assert_untouched();
    assert_eq!(
        rig.events(),
        ["selfcheck 0.2.0 b2"],
        "agent was never contacted"
    );
}

#[test]
fn package_without_required_binaries_is_rejected() {
    let rig = Rig::new();
    let bytes = tar_gz(&[
        Entry::Dir("pkg/"),
        Entry::File("pkg/bin/tinyprune", b"x", 0o755),
    ]);
    let mut rig = rig;
    rig.offer = offer_for(&bytes);
    rig.transport.set(URL, Route::ok(&bytes));
    assert!(matches!(rig.run(), Err(InstallError::BadPackage(_))));
    rig.assert_untouched();
}

#[test]
fn agent_that_cannot_quiesce_blocks_the_install_fail_closed() {
    for refusal in [
        ControlError::Unsupported,
        ControlError::Busy("held".into()),
        ControlError::Failed("io".into()),
    ] {
        let rig = Rig::new();
        *rig.daemon.quiesce.borrow_mut() = Err(refusal);
        assert!(matches!(rig.run(), Err(InstallError::Interlock(_))));
        rig.assert_untouched();
        assert!(!rig.events().iter().any(|e| e.starts_with("restart")));
    }
}

#[test]
fn lost_or_short_lease_aborts_before_the_swap() {
    for status in [
        quiesced(5),
        draining(),
        Status {
            phase: Phase::Idle,
            target: None,
            trash_in_flight: 0,
            lease_remaining: None,
        },
    ] {
        let rig = Rig::new();
        *rig.daemon.status.borrow_mut() = vec![Ok(status)];
        assert!(matches!(rig.run(), Err(InstallError::Interlock(_))));
        rig.assert_untouched();
        assert!(rig.events().contains(&"release".to_string()));
        assert!(!rig.events().iter().any(|e| e.starts_with("restart")));
    }
}

#[test]
fn no_running_agent_installs_without_restart_or_health_check() {
    let rig = Rig::new();
    *rig.daemon.quiesce.borrow_mut() = Err(ControlError::NotRunning);
    *rig.daemon.health.borrow_mut() = vec![Err(ControlError::NotRunning)];
    let done = rig.run().unwrap();
    assert_eq!(done.agent, AgentOutcome::NotRunning);
    assert_eq!(rig.current(), "0.2.0-b2");
    assert!(!rig.events().iter().any(|e| e.starts_with("restart")));
}

#[test]
fn unmanaged_agent_is_released_and_reported_as_needing_a_restart() {
    let rig = Rig::new();
    *rig.restart.results.borrow_mut() = vec![Ok(RestartKind::Unmanaged)];
    let done = rig.run().unwrap();
    assert_eq!(done.agent, AgentOutcome::ManualRestartRequired);
    assert!(
        rig.events().contains(&"release".to_string()),
        "pruning is not left stopped"
    );
}

#[test]
fn failed_health_check_rolls_back_pointer_and_restarts_the_old_build() {
    let rig = Rig::new();
    // Old agent reports 0.1.0 before the swap; the new one never answers correctly.
    *rig.daemon.health.borrow_mut() = vec![
        Ok("0.1.0".into()),
        Err(ControlError::Failed("connection refused".into())),
        Ok("0.1.0".into()),
    ];
    let result = rig.run();
    assert!(
        matches!(result, Err(InstallError::RolledBack(_))),
        "{result:?}"
    );
    assert_eq!(rig.current(), "0.1.0-b1", "pointer restored");
    let restarts: Vec<_> = rig
        .events()
        .into_iter()
        .filter(|e| e.starts_with("restart"))
        .collect();
    assert_eq!(restarts, ["restart->0.2.0-b2", "restart->0.1.0-b1"]);
    assert_eq!(
        rig.state.load().unwrap().previous,
        None,
        "a failed update records nothing"
    );
    assert_eq!(
        rig.versions(),
        ["0.1.0-b1"],
        "the failed build's directory is removed after a rollback"
    );
}

#[test]
fn wrong_version_after_restart_counts_as_failed_health() {
    let rig = Rig::new();
    *rig.daemon.health.borrow_mut() = vec![Ok("0.1.0".into())]; // still the old agent
    assert!(matches!(rig.run(), Err(InstallError::RolledBack(_))));
    assert_eq!(rig.current(), "0.1.0-b1");
}

#[test]
fn failed_restart_rolls_back_and_unrestorable_failure_is_reported_loudly() {
    let rig = Rig::new();
    *rig.restart.results.borrow_mut() =
        vec![Err("systemctl failed".into()), Ok(RestartKind::Restarted)];
    *rig.daemon.health.borrow_mut() = vec![Ok("0.1.0".into())];
    assert!(matches!(rig.run(), Err(InstallError::RolledBack(_))));
    assert_eq!(rig.current(), "0.1.0-b1");

    let rig = Rig::new();
    *rig.daemon.health.borrow_mut() =
        vec![Ok("0.1.0".into()), Err(ControlError::Failed("down".into()))];
    *rig.restart.results.borrow_mut() =
        vec![Ok(RestartKind::Restarted), Err("cannot restart".into())];
    assert!(matches!(rig.run(), Err(InstallError::RollbackFailed(_))));
}

// --- Interlock end-to-end with the real in-process Interlock ---

struct Real {
    gate: Arc<Interlock>,
    log: Log,
}
impl DaemonControl for Real {
    fn quiesce(&self, token: &str, target: &str, lease: Duration) -> Result<Status, ControlError> {
        self.log.borrow_mut().push("quiesce".into());
        self.gate
            .request_quiesce(token, target, lease)
            .map_err(|e| ControlError::Busy(e.to_string()))
    }
    fn status(&self) -> Result<Status, ControlError> {
        Ok(self.gate.status())
    }
    fn release(&self, token: &str) -> Result<(), ControlError> {
        self.log.borrow_mut().push("release".into());
        self.gate
            .release(token)
            .map_err(|e| ControlError::Failed(e.to_string()))
    }
    fn health(&self) -> Result<String, ControlError> {
        Ok("0.2.0".into())
    }
}
/// Advances the interlock's fake clock on every sleep; optionally ends an in-flight Trash after N sleeps.
struct ClockSleeper {
    ms: Arc<AtomicU64>,
    guard: RefCell<Option<crate::interlock::TrashGuard>>,
    release_after: u32,
    sleeps: Cell<u32>,
    gate: Arc<Interlock>,
    blocked_while_draining: Cell<bool>,
}
impl Sleeper for ClockSleeper {
    fn sleep(&self, d: Duration) {
        self.ms.fetch_add(d.as_millis() as u64, Ordering::SeqCst);
        self.sleeps.set(self.sleeps.get() + 1);
        if self.guard.borrow().is_some() {
            // New Trash must be refused for as long as the update is draining.
            self.blocked_while_draining
                .set(self.gate.begin_trash().is_err());
        }
        if self.sleeps.get() >= self.release_after {
            self.guard.borrow_mut().take(); // the in-flight move finishes on its own
        }
    }
}
fn interlock_rig(hold_trash: bool, release_after: u32) -> (Arc<Interlock>, Real, ClockSleeper) {
    let ms = Arc::new(AtomicU64::new(0));
    let clock = ms.clone();
    let gate = Interlock::with_clock(move || Duration::from_millis(clock.load(Ordering::SeqCst)));
    let guard = hold_trash.then(|| gate.begin_trash().unwrap());
    let sleeper = ClockSleeper {
        ms,
        guard: RefCell::new(guard),
        release_after,
        sleeps: Cell::new(0),
        gate: gate.clone(),
        blocked_while_draining: Cell::new(false),
    };
    (
        gate.clone(),
        Real {
            gate,
            log: Rc::default(),
        },
        sleeper,
    )
}

#[test]
fn install_is_blocked_while_a_trash_is_in_flight_and_nothing_is_cancelled() {
    let rig = Rig::new();
    let (gate, daemon, sleeper) = interlock_rig(true, u32::MAX); // the move never finishes within drain_timeout
    let result = rig.run_with(&daemon, &sleeper);
    assert!(
        matches!(result, Err(InstallError::Interlock(_))),
        "{result:?}"
    );
    rig.assert_untouched();
    assert!(
        sleeper.blocked_while_draining.get(),
        "new Trash was refused during the drain"
    );
    assert_eq!(
        gate.status().trash_in_flight,
        1,
        "the in-flight operation was not cancelled"
    );
    assert_eq!(
        gate.status().phase,
        Phase::Idle,
        "lease released after giving up: pruning resumes"
    );
    drop(sleeper);
    assert!(gate.begin_trash().is_ok());
}

#[test]
fn install_proceeds_after_the_in_flight_trash_finishes_and_trash_is_blocked_throughout() {
    let rig = Rig::new();
    let (gate, daemon, sleeper) = interlock_rig(true, 3);
    let done = rig.run_with(&daemon, &sleeper).unwrap();
    assert_eq!(done.agent, AgentOutcome::Restarted);
    assert_eq!(rig.current(), "0.2.0-b2");
    assert!(sleeper.blocked_while_draining.get());
    // The restart replaces the agent process; this in-process lease stays held, i.e. blocked until the
    // (new) process starts un-quiesced. Fail closed in the meantime:
    assert!(
        gate.begin_trash().is_err(),
        "no Trash can start between quiesce and the agent restart"
    );
}

#[test]
fn no_install_while_another_updater_holds_the_lease() {
    let rig = Rig::new();
    let (gate, daemon, sleeper) = interlock_rig(false, 0);
    gate.request_quiesce("someone-else", "0.9.0", Duration::from_secs(300))
        .unwrap();
    assert!(matches!(
        rig.run_with(&daemon, &sleeper),
        Err(InstallError::Interlock(_))
    ));
    rig.assert_untouched();
    assert!(
        gate.begin_trash().is_err(),
        "the other updater's lease is untouched"
    );
}
