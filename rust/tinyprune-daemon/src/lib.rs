//! In-development, unreleased local runtime. TinyPrune remains a macOS-only product.
mod codec;
mod events;
mod index;
#[cfg_attr(any(target_os = "linux", windows), allow(dead_code))]
mod poll;
mod preview;
mod service;
pub use service::Service;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread::JoinHandle,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tinyprune_core::{
    resolve::{self, Resolution},
    rule::*,
    scheduler::ObservationStore,
    trash::{Clock, PolicySnapshot},
};
use tinyprune_ipc as ipc;
use tinyprune_store::Store;
#[cfg(unix)]
type NativeFiles = tinyprune_unix::UnixFileAccess;
#[cfg(windows)]
type NativeFiles = tinyprune_windows::WindowsFileAccess;
type Engine = tinyprune_agent::Agent<
    NativeFiles,
    Store,
    index::DurableStore,
    Store,
    events::Events,
    index::DurableIndex,
>;

pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> f64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64()
    }
}
#[derive(Clone, Debug)]
pub struct Paths {
    pub data: PathBuf,
    pub endpoint: PathBuf,
    pub logs: PathBuf,
}
impl Paths {
    pub fn from_environment() -> io::Result<Self> {
        let missing = || io::Error::new(io::ErrorKind::NotFound, "User data directory unavailable");
        #[cfg(windows)]
        let data =
            PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(missing)?).join("TinyPrune");
        #[cfg(target_os = "macos")]
        let data = PathBuf::from(std::env::var_os("HOME").ok_or_else(missing)?)
            .join("Library/Application Support/TinyPrune");
        #[cfg(all(unix, not(target_os = "macos")))]
        let data = match std::env::var_os("XDG_DATA_HOME") {
            Some(v) if Path::new(&v).is_absolute() => PathBuf::from(v),
            _ => PathBuf::from(std::env::var_os("HOME").ok_or_else(missing)?).join(".local/share"),
        }
        .join("tinyprune");
        Ok(Self {
            logs: data.join("logs"),
            data,
            endpoint: ipc::default_endpoint()?,
        })
    }
}
#[derive(Clone)]
pub struct Options {
    pub paths: Paths,
    pub reconcile_interval: Duration,
    pub tick_interval: Duration,
    pub trash: Option<PathBuf>,
}
impl Options {
    pub fn from_environment() -> io::Result<Self> {
        Ok(Self {
            paths: Paths::from_environment()?,
            reconcile_interval: Duration::from_secs(300),
            tick_interval: Duration::from_millis(100),
            trash: None,
        })
    }
}
fn private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Data directory is a symlink",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
fn private_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    if path.try_exists()? && fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "State file is a symlink",
        ));
    }
    options.open(path)
}
fn io_error(message: String) -> io::Error {
    io::Error::other(message)
}
pub struct Daemon {
    pub service: Arc<Service>,
    options: Options,
    _lock: File,
    log: Mutex<File>,
    accept_errors: AtomicU64,
}
impl Daemon {
    pub fn open(options: Options, clock: Arc<dyn Clock + Send + Sync>) -> io::Result<Self> {
        if options.tick_interval.is_zero() || options.reconcile_interval.is_zero() {
            return Err(io_error("Intervals must be positive".into()));
        }
        private_dir(&options.paths.data)?;
        private_dir(&options.paths.logs)?;
        let lock = private_file(&options.paths.data.join("agent.lock"))?;
        lock.try_lock().map_err(|_| {
            io::Error::new(
                io::ErrorKind::AddrInUse,
                "Agent already running for this data directory",
            )
        })?;
        let database = options.paths.data.join("agent.sqlite3");
        drop(private_file(&database)?);
        let store = Store::open(database).map_err(io_error)?;
        let service = Arc::new(
            Service::new(
                store,
                clock,
                options.reconcile_interval,
                options.trash.clone(),
            )
            .map_err(io_error)?,
        );
        let log = private_file(&options.paths.logs.join("agent.jsonl"))?;
        Ok(Self {
            service,
            options,
            _lock: lock,
            log: Mutex::new(log),
            accept_errors: AtomicU64::new(0),
        })
    }
    pub fn tick(&self) -> Result<tinyprune_agent::TickReport, String> {
        let report = self.service.tick()?;
        if report.indexed != 0 || report.trashed != 0 {
            self.log(serde_json::json!({"event":"tick","indexed":report.indexed,"movedToTrash":report.trashed}))?;
        }
        Ok(report)
    }
    fn log(&self, event: serde_json::Value) -> Result<(), String> {
        let mut file = self.log.lock().map_err(|_| "Log lock poisoned")?;
        // Bounded diagnostic file; never log paths, requests, config, content, or error payloads.
        if file.metadata().map_err(|e| e.to_string())?.len() > 4 * 1024 * 1024 {
            file.set_len(0).map_err(|e| e.to_string())?;
        }
        use std::io::{Seek, SeekFrom};
        file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
        writeln!(file, "{event}").map_err(|e| e.to_string())
    }
    /// Number of accept/dispatch errors tolerated so far (also logged as a counter).
    pub fn tolerated_accept_errors(&self) -> u64 {
        self.accept_errors.load(Ordering::Relaxed)
    }
    /// Engine turns run on their own thread so a long scan never delays IPC; reads are answered from
    /// published store data and mutations wait only for the current bounded engine turn. Tests drive
    /// `tick` directly with a scripted clock, without sleeping.
    fn engine_loop(&self, shutdown: &AtomicBool) {
        while !shutdown.load(Ordering::Acquire) {
            match self.tick() {
                // More bounded work is queued: continue immediately, but let a waiting mutation in first.
                Ok(report) if report.pending_work => {
                    while self.service.has_waiters() && !shutdown.load(Ordering::Acquire) {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    continue;
                }
                Ok(_) => (),
                Err(_) => {
                    let _ = self.log(serde_json::json!({"event":"tickFailed"}));
                }
            }
            std::thread::park_timeout(self.options.tick_interval);
        }
    }
    /// Accept errors are per-connection or transient (a client that vanished before `accept`/peer
    /// verification completes yields ECONNABORTED/EINVAL on macOS; EINTR/EMFILE/ENFILE; Windows pipe errors).
    /// They are counted and logged, never fatal. Only a long unbroken run of failures is treated as a
    /// broken listener.
    fn accept_loop(
        &self,
        #[cfg(unix)] listener: ipc::unix::Listener,
        #[cfg(windows)] mut listener: ipc::windows::Listener,
        server: &ipc::Server,
        shutdown: &AtomicBool,
    ) -> io::Result<()> {
        const MAX_CONSECUTIVE_ERRORS: u32 = 1000;
        let mut workers: Vec<JoinHandle<io::Result<()>>> = vec![];
        let mut consecutive = 0u32;
        while !shutdown.load(Ordering::Acquire) {
            workers.retain(|worker| !worker.is_finished());
            let mut idle = false;
            for _ in 0..16 {
                let failure = match listener.accept() {
                    Ok(stream) => match server.dispatch(stream) {
                        Ok(worker) => {
                            consecutive = 0;
                            workers.push(worker);
                            continue;
                        }
                        // Saturated: the connection was dropped, the agent keeps serving.
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                            consecutive = 0;
                            continue;
                        }
                        Err(e) => e,
                    },
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        consecutive = 0;
                        idle = true;
                        break;
                    }
                    Err(e) => e,
                };
                let total = self.accept_errors.fetch_add(1, Ordering::Relaxed) + 1;
                consecutive += 1;
                let _ = self.log(serde_json::json!({
                    "event": "acceptError",
                    "kind": format!("{:?}", failure.kind()),
                    "os": failure.raw_os_error(),
                    "total": total
                }));
                if consecutive >= MAX_CONSECUTIVE_ERRORS {
                    return Err(failure);
                }
                // A peer that vanished or failed verification is per-connection: take the next one now.
                // Resource exhaustion (EMFILE/ENFILE, pipe/instance limits) needs a back-off.
                if !matches!(
                    failure.kind(),
                    io::ErrorKind::ConnectionAborted
                        | io::ErrorKind::ConnectionReset
                        | io::ErrorKind::InvalidInput
                        | io::ErrorKind::Interrupted
                        | io::ErrorKind::BrokenPipe
                        | io::ErrorKind::UnexpectedEof
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::PermissionDenied
                ) {
                    idle = true;
                    break;
                }
            }
            // A full turn of accepts means more may be waiting: go straight back to the listener.
            if idle {
                std::thread::park_timeout(Duration::from_millis(10));
            }
        }
        Ok(())
    }
    pub fn run(&self, shutdown: Arc<AtomicBool>) -> io::Result<()> {
        #[cfg(unix)]
        let listener = {
            let parent = self
                .options
                .paths
                .endpoint
                .parent()
                .ok_or_else(|| io_error("Endpoint needs parent".into()))?;
            private_dir(parent)?;
            // The instance lock is held. Remove only a dead same-user socket, never another file.
            if self.options.paths.endpoint.try_exists()? {
                use std::os::unix::fs::{FileTypeExt, MetadataExt};
                let m = fs::symlink_metadata(&self.options.paths.endpoint)?;
                if !m.file_type().is_socket() || m.uid() != ipc::unix::current_uid() {
                    return Err(io_error("Unsafe existing endpoint".into()));
                }
                if ipc::unix::connect(&self.options.paths.endpoint).is_ok() {
                    return Err(io_error("Endpoint already serves an agent".into()));
                }
                fs::remove_file(&self.options.paths.endpoint)?;
            }
            ipc::unix::Listener::bind(&self.options.paths.endpoint)?
        };
        #[cfg(windows)]
        let mut listener = ipc::windows::Listener::bind(
            self.options
                .paths
                .endpoint
                .to_str()
                .ok_or_else(|| io_error("pipe name is not UTF-8".into()))?,
        )?;
        listener.set_nonblocking(true)?;
        let server = ipc::Server::new(self.service.clone(), ipc::ServerOptions::default())?;
        let result = std::thread::scope(|scope| {
            let engine = scope.spawn(|| self.engine_loop(&shutdown));
            let result = self.accept_loop(listener, &server, &shutdown);
            shutdown.store(true, Ordering::Release);
            engine.thread().unpark();
            let _ = engine.join();
            result
        });
        self.service.stop()?;
        let _ = self.log(serde_json::json!({"event":"shutdown"}));
        // IPC workers are capped and transport-owned; do not wait on an idle client to shut down.
        result
    }
}

fn explain(
    candidate: &RuleCandidate,
    policy: &PolicySnapshot,
    store: &Store,
    now: f64,
) -> Result<ipc::Explanation, String> {
    let mut candidate = candidate.clone();
    // Observation dates matter only to rules measured from them; skip the lookup otherwise.
    let uses_observations = policy.rules.iter().any(|rule| {
        matches!(
            rule.expiry_basis,
            ExpiryBasis::FirstObserved | ExpiryBasis::ObservedActivity
        )
    });
    if uses_observations {
        if let Some(observation) = store.observation(&candidate.identity)? {
            candidate.timestamps.first_observed = Some(observation.first);
            candidate.timestamps.observed_activity = Some(observation.last);
        } else {
            candidate.timestamps.first_observed = Some(now);
            candidate.timestamps.observed_activity = Some(now);
        }
    }
    let project = store
        .projects()?
        .iter()
        .filter(|p| {
            codec::same_path(&candidate.identity.path_hint, &p.identity.path_hint)
                || codec::flavor()
                    .is_descendant(&candidate.identity.path_hint, &p.identity.path_hint)
        })
        .max_by_key(|p| p.identity.path_hint.len());
    candidate.timestamps.project_activity = project.map(|p| p.activity);
    let resolution = resolve::resolve(
        &candidate,
        &policy.rules,
        &policy.overrides,
        policy.globally_paused,
        &policy.settings,
    );
    explanation(&candidate, policy, resolution, project)
}
fn explanation(
    candidate: &RuleCandidate,
    policy: &PolicySnapshot,
    resolution: Resolution,
    project: Option<&tinyprune_core::scheduler::Project>,
) -> Result<ipc::Explanation, String> {
    let mut e = ipc::Explanation {
        item: codec::identity(&candidate.identity),
        scheduled_at: None,
        eligible_at: None,
        rule: None,
        basis: None,
        basis_date: None,
        project_context: project.map(|p| ipc::ProjectContext {
            identity: codec::identity(&p.identity),
            last_activity: Some(p.activity),
        }),
        item_override: None,
        suppression_reason: None,
        disposition: None,
        globally_paused: policy.globally_paused,
    };
    let override_id = match resolution {
        Resolution::Scheduled(v) => {
            e.scheduled_at = Some(v.scheduled_at);
            e.eligible_at = Some(v.eligible_at);
            e.basis = Some(codec::basis(v.basis));
            e.basis_date = Some(v.basis_date);
            e.disposition = Some(codec::disposition(v.disposition));
            e.rule = policy
                .rules
                .iter()
                .find(|r| r.id == v.rule_id)
                .map(codec::rule_wire);
            v.custom_override_id
        }
        Resolution::CustomExpiry {
            override_id,
            expires_at,
            disposition,
        } => {
            e.scheduled_at = Some(expires_at);
            e.eligible_at = Some(expires_at);
            e.basis = Some(ipc::ExpiryBasis::ExplicitDate);
            e.basis_date = Some(expires_at);
            e.disposition = Some(codec::disposition(disposition));
            Some(override_id)
        }
        Resolution::Protected { override_id, .. } => {
            e.suppression_reason = Some(ipc::Suppression::Protected);
            Some(override_id)
        }
        Resolution::Suppressed(v) => {
            e.suppression_reason = Some(codec::suppression(v));
            None
        }
        Resolution::NoRule => {
            e.suppression_reason = Some(ipc::Suppression::NoRule);
            None
        }
        Resolution::AmbiguousRules(_) => {
            e.suppression_reason = Some(ipc::Suppression::AmbiguousRules);
            None
        }
        Resolution::AmbiguousOverrides(_) => {
            e.suppression_reason = Some(ipc::Suppression::AmbiguousOverrides);
            None
        }
    };
    e.item_override = override_id
        .and_then(|id| policy.overrides.iter().find(|v| v.id == id))
        .map(codec::override_wire);
    Ok(e)
}
#[cfg(test)]
mod tests;
