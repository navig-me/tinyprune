use crate::{
    codec,
    events::Events,
    explain,
    index::{self, DurableIndex},
    preview, Engine, NativeFiles,
};
use std::{
    fs,
    num::NonZeroUsize,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tinyprune_core::{
    config, config_plan,
    resolve::{ItemOverridePolicy, ItemPolicyOverride},
    roots::{self, PathResolver},
    rule::*,
    trash::{Clock, DescendantProtection, FileAccess, PolicySnapshot, PolicyStore, WalkBudget},
};
use tinyprune_ipc::{self as d, AgentService};
use tinyprune_scan::CancellationToken;
use tinyprune_store::Store;

struct Resolver {
    homes: Vec<String>,
}
impl Resolver {
    fn new() -> Self {
        Self {
            homes: ["HOME", "USERPROFILE"]
                .iter()
                .filter_map(|k| std::env::var(k).ok())
                .collect(),
        }
    }
}
impl PathResolver for Resolver {
    fn canonical_path(&self, path: &str) -> String {
        fs::canonicalize(path)
            .ok()
            .and_then(|v| codec::path(&v).ok())
            .unwrap_or_else(|| path.into())
    }
    fn home_directories(&self) -> &[String] {
        &self.homes
    }
}
struct State {
    engine: Engine,
    interval: Duration,
    stopped: bool,
}
#[cfg(unix)]
fn native_files(trash: &Option<PathBuf>) -> Result<NativeFiles, String> {
    match trash {
        Some(path) => Ok(NativeFiles::new(path)),
        None => NativeFiles::from_environment(),
    }
}
#[cfg(windows)]
fn native_files(_: &Option<PathBuf>) -> Result<NativeFiles, String> {
    Ok(NativeFiles::default())
}
/// Engine mutation is serialized by `state`; reads use `store` (its own read path) and never wait for a
/// scan. Decisions are evaluated off the engine lock by `decisions` and published to the store, so
/// Overview/Upcoming answer from persisted data while a scan is running.
pub struct Service {
    state: Mutex<State>,
    store: Store,
    inspector: Mutex<NativeFiles>,
    clock: Arc<dyn Clock + Send + Sync>,
    preview: Mutex<Option<CancellationToken>>,
    stopped: AtomicBool,
    waiters: AtomicUsize,
    shared: Arc<index::Shared>,
    decisions: Mutex<index::Decisions>,
    /// Trash/update interlock (ADR 0012). Held by every Trash operation; the updater quiesces it.
    interlock: Arc<tinyprune_update::interlock::Interlock>,
}
/// Registers a request that is waiting for the engine so the tick thread yields to it.
struct Waiting<'a>(&'a AtomicUsize);
impl<'a> Waiting<'a> {
    fn new(counter: &'a AtomicUsize) -> Self {
        counter.fetch_add(1, Ordering::AcqRel);
        Self(counter)
    }
}
impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
/// Bounded entries per engine turn: each turn holds the engine lock for at most one batch.
const INDEX_BATCH: usize = 1024;
impl Service {
    /// Holds the engine lock, as a scan turn does, so tests can prove reads never wait for it.
    #[cfg(test)]
    pub(crate) fn hold_engine_for_test(&self) -> impl Sized + '_ {
        self.state.lock().unwrap()
    }
    #[cfg(test)]
    pub(crate) fn hold_decisions_for_test(&self) -> impl Sized + '_ {
        self.decisions.lock().unwrap()
    }
    #[cfg(test)]
    pub(crate) fn state_for_test_audit_count(&self) -> usize {
        self.store.audit_records().unwrap().len()
    }
    pub fn new(
        mut store: Store,
        clock: Arc<dyn Clock + Send + Sync>,
        interval: Duration,
        trash: Option<PathBuf>,
    ) -> Result<Self, String> {
        let mut snapshot = store.load_snapshot()?;
        if snapshot.settings.path_flavor != codec::flavor() {
            snapshot.settings.path_flavor = codec::flavor();
            let (revision, until, retention) = store.runtime_state()?;
            store.replace_policy(&snapshot, revision, until, retention, clock.now())?;
        }
        validate_policy(&snapshot)?;
        let files = native_files(&trash)?;
        let shared = Arc::new(index::Shared::default());
        let events = Events::new(
            &snapshot.managed_roots,
            clock.clone(),
            interval,
            shared.pace.clone(),
        )
        .map_err(|e| e.to_string())?;
        let index = DurableIndex::new(store.clone(), clock.clone(), shared.clone());
        let mut engine = tinyprune_agent::Agent::new(
            files,
            store.clone(),
            index::DurableStore::new(store.clone(), shared.clone()),
            store.clone(),
            events,
            index,
        );
        engine.limits.index_entries = NonZeroUsize::new(INDEX_BATCH).expect("nonzero");
        let interlock = tinyprune_update::interlock::Interlock::new();
        engine.update_interlock = Some(interlock.clone());
        Ok(Self {
            state: Mutex::new(State {
                engine,
                interval,
                stopped: false,
            }),
            store,
            inspector: Mutex::new(native_files(&trash)?),
            clock,
            preview: Mutex::new(None),
            stopped: AtomicBool::new(false),
            waiters: AtomicUsize::new(0),
            shared,
            decisions: Mutex::new(index::Decisions::default()),
            interlock,
        })
    }
    /// The interlock the agent engine must consult before every Trash operation.
    pub fn interlock(&self) -> &Arc<tinyprune_update::interlock::Interlock> {
        &self.interlock
    }
    /// Update interlock requests never touch the engine, so they cannot wait behind a scan turn.
    fn update_interlock(&self, request: &d::Request) -> Option<d::Response> {
        use tinyprune_update::interlock::{Phase, QuiesceError};
        let status = |s: tinyprune_update::interlock::Status| {
            d::Response::UpdateStatus(d::UpdateStatus {
                phase: match s.phase {
                    Phase::Idle => d::UpdatePhase::Idle,
                    Phase::Draining => d::UpdatePhase::Draining,
                    Phase::Quiesced => d::UpdatePhase::Quiesced,
                },
                target: s.target,
                trash_in_flight: s.trash_in_flight as u64,
                lease_remaining_seconds: s.lease_remaining.map(|d| d.as_secs_f64()),
            })
        };
        let failure = |e: QuiesceError| {
            d::Response::Failure(d::ServiceError {
                code: match e {
                    QuiesceError::AlreadyQuiescing => d::ErrorCode::Busy,
                    _ => d::ErrorCode::InvalidRequest,
                },
                message: e.to_string(),
            })
        };
        Some(match request {
            d::Request::LoadUpdateStatus => status(self.interlock.status()),
            d::Request::QuiesceForUpdate {
                token,
                target,
                lease_seconds,
            } => match self.interlock.request_quiesce(
                token,
                target,
                Duration::from_secs(u64::from(*lease_seconds)),
            ) {
                Ok(s) => status(s),
                Err(e) => failure(e),
            },
            d::Request::ReleaseUpdateQuiesce { token } => match self.interlock.release(token) {
                Ok(()) => status(self.interlock.status()),
                Err(e) => failure(e),
            },
            _ => return None,
        })
    }
    /// True while a request waits for the engine lock; the tick thread yields to it.
    pub(crate) fn has_waiters(&self) -> bool {
        self.waiters.load(Ordering::Acquire) > 0
    }
    pub fn tick(&self) -> Result<tinyprune_agent::TickReport, String> {
        // Same lock order as mutations: even concurrent tick callers cannot
        // change candidate metadata while an off-engine-lock page is publishing.
        let mut decisions = self.decisions.lock().map_err(|_| "Decision job poisoned")?;
        let mut report = {
            let mut state = self.state.lock().map_err(|_| "Runtime mutex poisoned")?;
            if state.stopped {
                return Err("Agent shutting down".into());
            }
            let now = self.clock.now();
            let (revision, until, retention) = state.engine.store.runtime_state()?;
            if until.is_some_and(|until| until <= now) {
                let mut policy = state.engine.policy.load_snapshot()?;
                policy.globally_paused = false;
                state
                    .engine
                    .store
                    .replace_policy(&policy, revision, None, retention, now)?;
            }
            let report = state.engine.tick(now)?;
            state
                .engine
                .store
                .prune_audit(now - retention as f64 * 86400.0)?;
            report
        };
        // Off the engine lock: evaluate full decisions for the published snapshot in bounded steps.
        let pending = decisions.advance(&self.shared, &self.store, self.clock.now())?;
        report.pending_work |= pending;
        Ok(report)
    }
    /// Called by the engine thread between ticks while work is queued, with no engine/decision lock
    /// held and no write transaction of ours open: a PASSIVE checkpoint that starts here can reach the
    /// end of the log, which lets SQLite restart the WAL from the beginning. A checkpoint that races a
    /// continuously committing writer never reaches the end, so the WAL would only grow (measured in the
    /// store README). Autocheckpoint is off on the writer, so this is the only checkpoint while work is
    /// queued, and it runs only once the log passes the default limit (cost grows with the distinct pages
    /// in the log, not with commits). Best effort: a failed or incomplete checkpoint only leaves the WAL
    /// larger until the next turn.
    pub(crate) fn checkpoint_between_pages(&self) {
        let _ = self
            .store
            .checkpoint_if_needed(tinyprune_store::DEFAULT_WAL_CHECKPOINT_BYTES);
    }
    /// One idle WAL maintenance step, run by the daemon's maintenance thread: when no scan or decision
    /// work is queued, backfill the whole WAL and truncate it. Uses the store's own checkpoint
    /// connection, never the writer mutex; a concurrent writer or reader just makes it a no-op.
    pub(crate) fn maintain_wal(&self) {
        if !self.shared.pace.busy() {
            let _ = self.store.checkpoint_idle();
        }
    }
    pub(crate) fn stop(&self) -> std::io::Result<()> {
        self.stopped.store(true, Ordering::Release);
        let mut state = self
            .state
            .lock()
            .map_err(|_| std::io::Error::other("Runtime mutex poisoned"))?;
        state.stopped = true;
        state.engine.cancel();
        drop(state);
        if let Some(token) = self
            .preview
            .lock()
            .map_err(|_| std::io::Error::other("Preview mutex poisoned"))?
            .as_ref()
        {
            token.cancel();
        }
        Ok(())
    }
    /// Requests that never touch the engine are answered from the store's read path, so a long scan
    /// (which holds the engine lock for each bounded batch) cannot delay them.
    fn read_only(&self, request: &d::Request) -> Option<Result<d::Response, String>> {
        if !matches!(
            request,
            d::Request::Health
                | d::Request::LoadPolicy
                | d::Request::LoadRoots
                | d::Request::LoadSettings
                | d::Request::LoadUpcoming { .. }
                | d::Request::LoadOverview
                | d::Request::LoadActivity { .. }
                | d::Request::ExplainItem { .. }
                | d::Request::ItemSize { .. }
                | d::Request::ExportConfig
        ) {
            return None;
        }
        Some(self.answer(request))
    }
    fn answer(&self, request: &d::Request) -> Result<d::Response, String> {
        if let d::Request::Health = request {
            return Ok(d::Response::Health(d::Health {
                protocol_version: d::PROTOCOL_VERSION,
                service_version: env!("CARGO_PKG_VERSION").into(),
            }));
        }
        let mut store = self.store.clone();
        let policy = store.load_snapshot()?;
        let (revision, until, retention) = store.runtime_state()?;
        let now = self.clock.now();
        match request {
            d::Request::LoadPolicy => Ok(d::Response::Policy(codec::snapshot(
                &policy, revision, until,
            ))),
            d::Request::LoadRoots => {
                Ok(d::Response::Roots(index::wire_roots(&policy.managed_roots)))
            }
            d::Request::LoadSettings => Ok(d::Response::Settings(codec::settings(
                policy.settings,
                retention,
            ))),
            d::Request::LoadUpcoming {
                rule_id,
                disposition,
                after,
                limit,
            } => upcoming(
                &store,
                rule_id.as_deref(),
                *disposition,
                after.as_ref(),
                *limit,
            )
            .map(d::Response::UpcomingPage),
            d::Request::LoadOverview => overview(&store, &policy, revision, until, now)
                .map(|v| d::Response::Overview(Box::new(v))),
            d::Request::LoadActivity { limit } => {
                activity(&store, *limit).map(d::Response::Activity)
            }
            d::Request::ExplainItem { path } => {
                authorize(path, &policy.managed_roots)?;
                let mut files = self
                    .inspector
                    .lock()
                    .map_err(|_| "Inspector mutex poisoned")?;
                let candidate = files.inspect(path)?.ok_or("Item no longer exists")?;
                store.refresh_projects()?;
                let mut e = explain(&candidate, &policy, &store, now)?;
                // Same descendant check as Preview and the pre-Trash coordinator (fail closed).
                if candidate.kind == ItemKind::Directory {
                    let protection = files.has_protected_descendant(
                        path,
                        &policy.overrides,
                        policy.settings.protect_hidden_files,
                        WalkBudget {
                            max_entries: 250_000,
                            deadline: now + 10.0,
                        },
                    )?;
                    if protection != DescendantProtection::None {
                        e.suppression_reason = Some(d::Suppression::ProtectedDescendant);
                    }
                }
                let value = serde_json::to_value(&e).map_err(|e| e.to_string())?;
                if store.latest_decision(&candidate.identity)?.as_ref() != Some(&value) {
                    store.record_decision(now, false, &value)?;
                }
                Ok(d::Response::ItemExplanation(Box::new(d::ItemExplanation {
                    path: path.clone(),
                    explanation: e,
                    overrides: policy.overrides.iter().map(codec::override_wire).collect(),
                })))
            }
            d::Request::ItemSize { path } => {
                authorize(path, &policy.managed_roots)?;
                let (bytes, items, truncated) = preview::size(path)?;
                Ok(d::Response::ItemSize {
                    path: path.clone(),
                    bytes,
                    items,
                    truncated,
                })
            }
            d::Request::ExportConfig => {
                if cfg!(windows) {
                    return Err("POSIX config codec cannot export Windows paths".into());
                }
                Ok(d::Response::Config {
                    text: config::render(&policy.rules, &policy.managed_roots, &policy.overrides),
                })
            }
            _ => unreachable!("not a read-only request"),
        }
    }
    fn dispatch(&self, request: d::Request) -> Result<d::Response, String> {
        if self.stopped.load(Ordering::Acquire) {
            return Err("Agent shutting down".into());
        }
        if let d::Request::CancelPreview = request {
            if let Some(token) = self
                .preview
                .lock()
                .map_err(|_| "Preview mutex poisoned")?
                .as_ref()
            {
                token.cancel();
            }
            return Ok(ack(self.store.runtime_state()?.0, vec![]));
        }
        if let d::Request::PreviewRule(rule) = &request {
            let mut slot = self.preview.lock().map_err(|_| "Preview mutex poisoned")?;
            if slot.is_some() {
                return Err("Preview already running".into());
            }
            let cancellation = CancellationToken::default();
            *slot = Some(cancellation.clone());
            drop(slot);
            let result = (|| {
                let mut store = self.store.clone();
                store.refresh_projects()?;
                let policy = store.load_snapshot()?;
                let core_rule = codec::rule(rule)?;
                validate_rule(&core_rule, &policy.managed_roots, true)?;
                preview::run(core_rule, policy, store, self.clock.now(), cancellation)
                    .map(d::Response::RulePreview)
            })();
            *self.preview.lock().map_err(|_| "Preview mutex poisoned")? = None;
            return result;
        }
        if let Some(answer) = self.read_only(&request) {
            return answer;
        }
        if let Some(answer) = self.update_interlock(&request) {
            return Ok(answer);
        }
        let waiting = Waiting::new(&self.waiters);
        // Serialize policy/candidate mutations with decision publication, not with reads.
        // A full page must never publish an explanation from a superseded policy.
        let _decisions = self.decisions.lock().map_err(|_| "Decision job poisoned")?;
        let mut state = self.state.lock().map_err(|_| "Runtime mutex poisoned")?;
        drop(waiting);
        let State {
            engine,
            interval,
            stopped,
        } = &mut *state;
        if *stopped {
            return Err("Agent shutting down".into());
        }
        let mut policy = engine.policy.load_snapshot()?;
        let (revision, mut until, mut retention) = engine.store.runtime_state()?;
        let now = self.clock.now();
        let old_roots = policy.managed_roots.clone();
        let mut expected = revision;
        match request {
            d::Request::Health
            | d::Request::LoadPolicy
            | d::Request::LoadRoots
            | d::Request::LoadSettings
            | d::Request::LoadUpcoming { .. }
            | d::Request::LoadOverview
            | d::Request::LoadActivity { .. }
            | d::Request::ExplainItem { .. }
            | d::Request::ItemSize { .. }
            | d::Request::ExportConfig
            | d::Request::QuiesceForUpdate { .. }
            | d::Request::ReleaseUpdateQuiesce { .. }
            | d::Request::LoadUpdateStatus => unreachable!("answered before taking the engine"),
            d::Request::ReplacePolicy(value) => {
                expected = value.revision;
                if value.rules.len() > 1024 || value.overrides.len() > 100_000 {
                    return Err("Policy exceeds resource limit".into());
                }
                policy.managed_roots = value.managed_roots.iter().map(|r| r.path.clone()).collect();
                policy.rules = value
                    .rules
                    .iter()
                    .map(codec::rule)
                    .collect::<Result<_, _>>()?;
                policy.overrides.clear();
                for value in value.overrides {
                    let candidate =
                        inspect_override(&mut engine.files, &value.path, &policy.managed_roots)?;
                    policy.overrides.push(ItemPolicyOverride::new_with_flavor(
                        codec::uuid(&value.id)?,
                        Some(candidate.identity),
                        &value.path,
                        codec::policy(&value.policy)?,
                        codec::flavor(),
                    ));
                }
                policy.globally_paused = value.globally_paused;
                until = value.paused_until;
                if until.is_some_and(|v| !v.is_finite()) {
                    return Err("Invalid pause deadline".into());
                }
            }
            d::Request::SaveRule {
                rule,
                roots,
                keep_paths,
                unkeep_paths,
                revision,
            } => {
                expected = revision;
                if let Some(roots) = roots {
                    policy.managed_roots = roots.into_iter().map(|r| r.path).collect();
                }
                let rule = codec::rule(&rule)?;
                validate_rule(&rule, &policy.managed_roots, false)?;
                if let Some(existing) = policy.rules.iter_mut().find(|r| r.id == rule.id) {
                    *existing = rule;
                } else {
                    policy.rules.push(rule);
                }
                for path in keep_paths {
                    change_override(
                        &mut engine.files,
                        &mut policy,
                        &path,
                        Some(d::OverridePolicy::Keep {
                            protect_descendants: true,
                        }),
                    )?;
                }
                for path in unkeep_paths {
                    change_override(&mut engine.files, &mut policy, &path, None)?;
                }
            }
            d::Request::DeleteRule { id } => {
                let id = codec::uuid(&id)?;
                policy.rules.retain(|r| r.id != id);
            }
            d::Request::SetItemOverride {
                path,
                policy: value,
            } => change_override(&mut engine.files, &mut policy, &path, Some(value))?,
            d::Request::ClearItemOverride { path } => {
                change_override(&mut engine.files, &mut policy, &path, None)?
            }
            d::Request::SetItemOverrides { changes } => {
                for change in changes {
                    change_override(&mut engine.files, &mut policy, &change.path, change.policy)?;
                }
            }
            d::Request::SetGlobalPause { paused } => {
                policy.globally_paused = paused;
                until = None;
            }
            d::Request::PauseUntil { until: value } => {
                if !value.is_finite() || value <= now {
                    return Err("Pause deadline must be in the future".into());
                }
                policy.globally_paused = true;
                until = Some(value);
            }
            d::Request::UpdateSettings(value) => {
                if !value.default_grace_period_seconds.is_finite()
                    || value.default_grace_period_seconds < 0.0
                {
                    return Err("Invalid settings".into());
                }
                policy.settings = AgentSettings {
                    default_grace_period_seconds: value.default_grace_period_seconds,
                    protect_hidden_files: value.protect_hidden_files,
                    path_flavor: codec::flavor(),
                };
                retention = value.activity_retention_days;
            }
            d::Request::AddRoot(root) => {
                if !policy.managed_roots.contains(&root.path) {
                    policy.managed_roots.push(root.path);
                }
            }
            d::Request::RemoveRoot { id } => {
                policy.managed_roots.retain(|r| codec::root(r).id != id);
                policy
                    .rules
                    .retain(|r| authorize(&r.scope.path, &policy.managed_roots).is_ok());
                policy
                    .overrides
                    .retain(|r| authorize(&r.path, &policy.managed_roots).is_ok());
            }
            d::Request::ImportConfig {
                text,
                activate,
                revision,
            } => {
                if cfg!(windows) {
                    return Err("POSIX config codec cannot import Windows paths".into());
                }
                expected = revision;
                let home = std::env::var("HOME").map_err(|_| "HOME unavailable")?;
                let document =
                    config::ConfigDocument::parse(&text, &home).map_err(|e| e.message)?;
                policy.managed_roots = document.roots.iter().map(|r| r.path.clone()).collect();
                policy.rules = config_plan::document_rules(
                    &document,
                    if activate {
                        RuleState::Active
                    } else {
                        RuleState::Preview
                    },
                )
                .map_err(|e| e.name())?;
                policy.overrides.clear();
                for value in document.exceptions {
                    change_override(
                        &mut engine.files,
                        &mut policy,
                        &value.path,
                        Some(d::OverridePolicy::Keep {
                            protect_descendants: value.protect_descendants,
                        }),
                    )?;
                }
            }
            d::Request::RebuildIndex => {
                for root in &policy.managed_roots {
                    engine.reconcile(root);
                }
                return Ok(ack(revision, vec![]));
            }
            d::Request::Unknown => return Err("Unknown operation".into()),
            d::Request::PreviewRule(_) | d::Request::CancelPreview => unreachable!(),
        }
        validate_policy(&policy)?;
        // Construct watcher before durable commit: failure cannot leave an acknowledged unwatched policy.
        let events = if old_roots != policy.managed_roots {
            Some(
                Events::new(
                    &policy.managed_roots,
                    self.clock.clone(),
                    *interval,
                    self.shared.pace.clone(),
                )
                .map_err(|e| e.to_string())?,
            )
        } else {
            None
        };
        let new_revision = engine
            .store
            .replace_policy(&policy, expected, until, retention, now)?;
        if let Some(events) = events {
            engine.events = events;
        }
        for root in &policy.managed_roots {
            engine.reconcile(root);
        }
        let ids = engine
            .store
            .audit_recent(NonZeroUsize::new(1).unwrap())?
            .iter()
            .map(|r| r.id.to_string())
            .collect();
        Ok(ack(new_revision, ids))
    }
}
impl AgentService for Service {
    fn handle(&self, request: d::Request) -> d::Response {
        match self.dispatch(request) {
            Ok(value) => value,
            Err(message) => d::Response::Failure(d::ServiceError {
                code: if message.contains("revision conflict") {
                    d::ErrorCode::PolicyConflict
                } else if message.contains("poison") {
                    d::ErrorCode::StorageUnavailable
                } else {
                    d::ErrorCode::InvalidRequest
                },
                message,
            }),
        }
    }
}
fn ack(revision: u64, audit_event_ids: Vec<String>) -> d::Response {
    d::Response::Acknowledged(d::Acknowledgement {
        revision,
        audit_event_ids,
    })
}
fn authorize(path: &str, roots: &[String]) -> Result<(), String> {
    let flavor = codec::flavor();
    if roots
        .iter()
        .any(|root| codec::same_path(path, root) || flavor.is_descendant(path, root))
    {
        Ok(())
    } else {
        Err("Path is outside managed roots".into())
    }
}
fn validate_rule(rule: &LifetimeRule, managed: &[String], preview: bool) -> Result<(), String> {
    authorize(&rule.scope.path, managed)?;
    roots::validate_root_with_flavor(
        &rule.name,
        &rule.scope.path,
        &[1],
        &Resolver::new(),
        codec::flavor(),
    )
    .map_err(str::to_owned)?;
    if !preview
        && rule.state == RuleState::Active
        && managed
            .iter()
            .filter(|r| {
                codec::same_path(r, &rule.scope.path)
                    || codec::flavor().is_descendant(&rule.scope.path, r)
            })
            .any(|r| roots::is_very_broad(r, &Resolver::new()))
    {
        return Err("Very broad roots are Preview-only".into());
    }
    Ok(())
}
fn validate_policy(policy: &PolicySnapshot) -> Result<(), String> {
    if policy.managed_roots.len() > 64
        || policy.rules.len() > 1024
        || policy.overrides.len() > 100_000
    {
        return Err("Policy exceeds resource limits".into());
    }
    let resolver = Resolver::new();
    for (index, root) in policy.managed_roots.iter().enumerate() {
        roots::validate_root_with_flavor("Managed root", root, &[1], &resolver, codec::flavor())
            .map_err(str::to_owned)?;
        if !codec::flavor().equal(
            &codec::flavor().normalize(&resolver.canonical_path(root)),
            &codec::flavor().normalize(root),
        ) {
            return Err("Managed roots must be canonical paths".into());
        }
        if policy.managed_roots[..index].iter().any(|r| {
            codec::same_path(root, r)
                || codec::flavor().is_descendant(root, r)
                || codec::flavor().is_descendant(r, root)
        }) {
            return Err("Managed roots must not overlap".into());
        }
    }
    let mut ids = std::collections::HashSet::new();
    for rule in &policy.rules {
        if !ids.insert(rule.id) {
            return Err("Duplicate rule identity".into());
        }
        validate_rule(rule, &policy.managed_roots, false)?;
    }
    Ok(())
}
fn inspect_override(
    files: &mut NativeFiles,
    path: &str,
    roots: &[String],
) -> Result<RuleCandidate, String> {
    authorize(path, roots)?;
    let root = roots
        .iter()
        .find(|r| codec::same_path(path, r) || codec::flavor().is_descendant(path, r))
        .ok_or("Root unavailable")?;
    if files.has_symbolic_link_ancestor(path, root)? {
        return Err("Symlink ancestor".into());
    }
    files
        .inspect(path)?
        .ok_or_else(|| "Item no longer exists".into())
}
fn change_override(
    files: &mut NativeFiles,
    policy: &mut PolicySnapshot,
    path: &str,
    value: Option<d::OverridePolicy>,
) -> Result<(), String> {
    authorize(path, &policy.managed_roots)?;
    let decoded = value.as_ref().map(codec::policy).transpose()?;
    let candidate = if decoded.is_some() {
        Some(inspect_override(files, path, &policy.managed_roots)?)
    } else {
        None
    };
    policy.overrides.retain(|o| {
        !codec::same_path(&o.path, path)
            && !candidate
                .as_ref()
                .is_some_and(|c| o.identity.as_ref() == Some(&c.identity))
    });
    if let (Some(value), Some(candidate)) = (decoded, candidate) {
        if !matches!(value, ItemOverridePolicy::Inherit) {
            policy.overrides.push(ItemPolicyOverride::new_with_flavor(
                config::rule_id("override", path),
                Some(candidate.identity),
                path,
                value,
                codec::flavor(),
            ));
        }
    }
    Ok(())
}

fn limit(value: u32) -> Result<usize, String> {
    if value == 0 || value > 1000 {
        Err("Limit must be 1..1000".into())
    } else {
        Ok(value as usize)
    }
}
/// Served from the persisted `current_decisions` index (keyset, aggregates); never evaluates candidates.
fn upcoming(
    store: &Store,
    rule: Option<&str>,
    disposition: Option<d::Disposition>,
    after: Option<&d::UpcomingCursor>,
    count: u32,
) -> Result<d::UpcomingPage, String> {
    let count = limit(count)?;
    if disposition == Some(d::Disposition::Unknown)
        || after.is_some_and(|v| !v.scheduled_at.is_finite())
    {
        return Err("Invalid upcoming filter/cursor".into());
    }
    let preview = disposition.map(|d| d == d::Disposition::Preview);
    let (mut rows, total_count) = store.decision_page(
        rule,
        preview,
        after.map(|a| (a.scheduled_at, a.identity_key.clone())),
        NonZeroUsize::new(count + 1).expect("nonzero"),
    )?;
    let more = rows.len() > count;
    rows.truncate(count);
    let next_cursor = if more {
        rows.last().map(|(at, key, _)| d::UpcomingCursor {
            scheduled_at: *at,
            identity_key: key.clone(),
        })
    } else {
        None
    };
    let items = rows
        .into_iter()
        .map(|(_, _, value)| {
            serde_json::from_value::<d::Explanation>(value)
                .map(|explanation| d::UpcomingItem { explanation })
                .map_err(|e| e.to_string())
        })
        .collect::<Result<_, _>>()?;
    Ok(d::UpcomingPage {
        items,
        next_cursor,
        total_count,
    })
}
fn overview(
    store: &Store,
    policy: &PolicySnapshot,
    revision: u64,
    until: Option<f64>,
    now: f64,
) -> Result<d::Overview, String> {
    let (active, preview, active_soon) = store.decision_counts(now, now + 86400.0)?;
    let counts = d::DeadlineSummary {
        active,
        preview,
        active_soon,
    };
    let mut stats: Vec<_> = policy
        .rules
        .iter()
        .map(|r| d::RuleStats {
            rule_id: r.id.to_string(),
            matches: 0,
            due: 0,
        })
        .collect();
    for (rule_id, matches, due) in store.decision_rule_stats(now)? {
        if let Some(s) = stats.iter_mut().find(|s| s.rule_id == rule_id) {
            s.matches = matches;
            s.due = due;
        }
    }
    let totals = store.reclaim_totals()?;
    let today = (now / 86400.0).floor();
    let days = store.reclaim_days((today - 13.0) * 86400.0, (today + 1.0) * 86400.0)?;
    let days: Vec<_> = (0..14)
        .map(|index| {
            let day = today as i64 - 13 + index;
            let totals = days.iter().find(|d| d.utc_day == day).map(|d| &d.totals);
            d::ReclaimedDay {
                day: day as f64 * 86400.0,
                items: totals.map_or(0, |v| v.items.max(0) as u64),
                bytes: totals.map_or(0, |v| v.bytes.max(0) as u64),
            }
        })
        .collect();
    let reclaimed = d::ReclaimedSummary {
        lifetime_items: totals.items.max(0) as u64,
        lifetime_bytes: totals.bytes.max(0) as u64,
        items_with_known_size: totals.known_items.max(0) as u64,
        first_moved_at: totals.first_at,
        last_moved_at: totals.last_at,
        week_items: days[7..].iter().map(|d| d.items).sum(),
        week_bytes: days[7..].iter().map(|d| d.bytes).sum(),
        days,
    };
    let root_statuses = policy
        .managed_roots
        .iter()
        .map(|root| d::RootStatus {
            root_id: codec::root(root).id,
            path: root.clone(),
            state: if fs::read_dir(root).is_ok() {
                d::RootState::Watching
            } else {
                d::RootState::Offline
            },
            detail: None,
        })
        .collect();
    Ok(d::Overview {
        policy: codec::snapshot(policy, revision, until),
        upcoming: upcoming(store, None, None, None, 50)?.items,
        rule_stats: stats,
        indexed_items: store.candidate_count()?,
        database_bytes: store.database_bytes()?,
        root_statuses,
        reclaimed: Some(reclaimed),
        deadline_summary: Some(counts),
    })
}
fn activity(store: &Store, count: u32) -> Result<Vec<d::ActivityItem>, String> {
    let count = limit(count)?;
    // Index/deadline bookkeeping rows are not user activity; over-fetch so they cannot crowd it out.
    let records =
        store.audit_recent(NonZeroUsize::new(count.saturating_mul(8).min(8000)).unwrap())?;
    records
        .into_iter()
        .filter(|record| {
            matches!(
                record.kind.as_str(),
                "previewMatch"
                    | "previewSkipped"
                    | "notDue"
                    | "safetySkipped"
                    | "schedulingDecision"
                    | "trashAttempted"
                    | "movedToTrash"
                    | "trashFailed"
                    | "settingsMutation"
                    | "ruleRemoved"
                    | "ruleMutation"
                    | "overrideMutation"
                    | "overrideRemoved"
                    | "policyReplaced"
            )
        })
        .take(count)
        .map(|record| {
            let value: serde_json::Value =
                serde_json::from_str(&record.payload).map_err(|e| e.to_string())?;
            let event = record.event()?;
            let compact = value.get("version").and_then(serde_json::Value::as_u64) == Some(1)
                && value.get("identityKey").is_some();
            let compact_identity = if compact {
                value.get("item").cloned().map(serde_json::from_value::<d::Identity>)
                    .transpose().map_err(|e| e.to_string())?
            } else {
                None
            };
            let explanation =
                if matches!(record.kind.as_str(), "previewMatch" | "schedulingDecision") && !compact {
                    Some(
                        serde_json::from_value::<d::Explanation>(value.clone())
                            .map_err(|e| e.to_string())?,
                    )
                } else if let Some(identity) = event.as_ref().and_then(|e| e.identity.as_ref()) {
                    store
                        .latest_decision(identity)?
                        .map(serde_json::from_value::<d::Explanation>)
                        .transpose()
                        .map_err(|e| e.to_string())?
                } else {
                    None
                };
            let kind = match record.kind.as_str() {
                "previewMatch" | "previewSkipped" => d::ActivityKind::PreviewSkipped,
                "notDue" => d::ActivityKind::NotDue,
                "safetySkipped" | "schedulingDecision" => d::ActivityKind::SafetySkipped,
                "trashAttempted" => d::ActivityKind::TrashAttempted,
                "movedToTrash" => d::ActivityKind::MovedToTrash,
                "trashFailed" => d::ActivityKind::TrashFailed,
                "settingsMutation" => d::ActivityKind::SettingsChanged,
                "ruleRemoved" => d::ActivityKind::RuleDeleted,
                "ruleMutation" => d::ActivityKind::RuleEdited,
                "overrideMutation" => d::ActivityKind::ExpiryChanged,
                "overrideRemoved" => d::ActivityKind::ItemUnprotected,
                _ => d::ActivityKind::PolicyReplaced,
            };
            Ok(d::ActivityItem {
                id: record.id.to_string(),
                occurred_at: record.occurred_at,
                kind,
                identity: event
                    .as_ref()
                    .and_then(|e| e.identity.as_ref().map(codec::identity))
                    .or_else(|| explanation.as_ref().map(|e| e.item.clone()))
                    .or(compact_identity),
                rule_id: event
                    .as_ref()
                    .and_then(|e| e.rule_id.map(|id| id.to_string()))
                    .or_else(|| value.get("ruleID").and_then(serde_json::Value::as_str).map(str::to_owned))
                    .or_else(|| {
                        explanation
                            .as_ref()
                            .and_then(|e| e.rule.as_ref().map(|r| r.id.clone()))
                    }),
                detail: event.as_ref().and_then(|e| e.detail.clone()),
                bytes: event
                    .as_ref()
                    .and_then(|e| e.bytes.and_then(|v| u64::try_from(v).ok())),
                item_count: event.as_ref().and_then(|e| e.item_count.map(|v| v as u64)),
                explanation,
            })
        })
        .collect()
}
