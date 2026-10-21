//! Deterministic, synchronous agent orchestration. Unreleased infrastructure, not platform support.
use std::cmp::Ordering;
use std::collections::{BTreeMap, VecDeque};
use std::num::NonZeroUsize;
use std::time::Duration;
use tinyprune_core::resolve::{Disposition, Resolution};
use tinyprune_core::rule::*;
use tinyprune_core::scheduler::{
    self, ActivityEvent, Decision, Delta, MetadataSource, ObservationStore, ScanPolicy,
    SnapshotIndex,
};
use tinyprune_core::trash::*;
use tinyprune_core::uuid::Uuid;
use tinyprune_watch::{EventKind, EventSource};

/// Enumeration must inspect metadata only, never follow symlinks, and return at most `limit`
/// entries. An error is not an empty tree. `begin` replaces any abandoned cursor.
pub trait IndexSource {
    fn available(&mut self, root: &str) -> Result<bool, String>;
    fn begin(&mut self, path: &str) -> Result<(), String>;
    fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String>;
    /// Called when an incremental pass learned of paths that left the snapshot (`removed`, whole subtrees)
    /// and of single items whose own metadata changed (`refreshed`) without a subtree enumeration, so an
    /// embedder that mirrors the snapshot can mirror these too. Enumerated subtrees were already reported
    /// by `next_batch`. Embedders without a mirror need not implement it.
    fn publish_delta(
        &mut self,
        _removed: &[String],
        _refreshed: &[RuleCandidate],
    ) -> Result<(), String> {
        Ok(())
    }
}
#[derive(Default)]
pub struct IndexBatch {
    pub candidates: Vec<RuleCandidate>,
    pub complete: bool,
}
/// Transactional durable scheduling belongs to the embedding store, not this engine.
/// Replacing a root's deadlines must be atomic; failed writes leave the old set intact.
pub trait AgentStore: ObservationStore {
    fn load_deadlines(&mut self) -> Result<Vec<TrashRequest>, String>;
    fn replace_deadlines(&mut self, root: &str, deadlines: &[TrashRequest]) -> Result<(), String>;
    /// Incremental form of `replace_deadlines`: afterwards `deadlines` are scheduled and no `evaluated`
    /// identity has any other deadline. Deadlines of identities that are not named stay untouched.
    fn update_deadlines(
        &mut self,
        root: &str,
        evaluated: &[FilesystemIdentity],
        deadlines: &[TrashRequest],
    ) -> Result<(), String>;
    fn remove_deadline(&mut self, request: &TrashRequest) -> Result<(), String>;
}
/// A dangling attempt is ambiguous: recovery records a safety skip, never invents a
/// successful move. The subsequent scan may reschedule a still-present identity.
/// `finish_recovery` must atomically close the attempt and append the supplied audit.
pub trait AgentAudit: AuditSink {
    fn dangling_attempts(&mut self) -> Result<Vec<FilesystemIdentity>, String>;
    fn finish_recovery(
        &mut self,
        identity: &FilesystemIdentity,
        event: AuditEvent,
    ) -> Result<(), String>;
}
#[derive(Clone, Copy)]
pub struct Limits {
    pub index_entries: NonZeroUsize,
    pub events: NonZeroUsize,
    pub due_items: NonZeroUsize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            index_entries: NonZeroUsize::new(256).unwrap(),
            events: NonZeroUsize::new(256).unwrap(),
            due_items: NonZeroUsize::new(64).unwrap(),
        }
    }
}
#[derive(Default, Debug)]
pub struct TickReport {
    pub indexed: usize,
    pub executed: usize,
    pub trashed: usize,
    pub skipped: usize,
    pub deferred: usize,
    pub previewed: usize,
    pub recovered: usize,
    pub cancelled: bool,
    pub pending_work: bool,
    pub failures: Vec<String>,
}
#[derive(Clone, Copy, Debug)]
struct Time(f64);
impl PartialEq for Time {
    fn eq(&self, other: &Self) -> bool {
        self.0.total_cmp(&other.0) == Ordering::Equal
    }
}
impl Eq for Time {}
impl PartialOrd for Time {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Time {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.total_cmp(&other.0)
    }
}
type IdentityKey = (Uuid, Vec<u8>);
fn key(identity: &FilesystemIdentity) -> IdentityKey {
    (identity.volume, identity.resource.clone())
}
#[cfg(test)]
fn within(path: &str, root: &str) -> bool {
    PathFlavor::Posix.equal(path, root) || PathFlavor::Posix.is_descendant(path, root)
}
struct Entry {
    request: TrashRequest,
    failures: u32,
}
/// Hints of one event batch for one root, resolved against the filesystem.
#[derive(Default)]
struct Hints {
    scan: Vec<String>,
    removed: Vec<String>,
    parents: Vec<String>,
    events: Vec<ActivityEvent>,
}
struct Job {
    root: String,
    removed: Vec<String>,
    events: Vec<ActivityEvent>,
    /// Existing subtrees still to enumerate for an incremental pass; `None` is a complete pass over the root.
    pending: Option<VecDeque<String>>,
    scanned: Vec<(String, Vec<RuleCandidate>)>,
    refreshed: Vec<RuleCandidate>,
    /// Subtree being enumerated (incremental passes only).
    current: Option<String>,
    candidates: Vec<RuleCandidate>,
    started: bool,
    /// Whether the cached snapshot was checked against the current policy.
    validated: bool,
}
impl Job {
    fn full(root: String, removed: Vec<String>, events: Vec<ActivityEvent>) -> Self {
        Self {
            root,
            removed,
            events,
            pending: None,
            scanned: Vec::new(),
            refreshed: Vec::new(),
            current: None,
            candidates: Vec::new(),
            started: false,
            validated: false,
        }
    }
    fn delta(
        root: String,
        scan: Vec<String>,
        removed: Vec<String>,
        refreshed: Vec<RuleCandidate>,
        events: Vec<ActivityEvent>,
    ) -> Self {
        Self {
            pending: Some(scan.into()),
            refreshed,
            ..Self::full(root, removed, events)
        }
    }
    fn mergeable(&self, root: &str, flavor: PathFlavor) -> bool {
        self.pending.is_some()
            && !self.started
            && self.current.is_none()
            && self.scanned.is_empty()
            && same_path(&self.root, root, flavor)
    }
    /// Folds a later delta into this unstarted one. A later removal supersedes earlier scans below it and
    /// a later scan supersedes earlier parent refreshes it covers, so the merged job equals running both.
    fn merge(&mut self, later: Job, flavor: PathFlavor) {
        let pending = self.pending.get_or_insert_with(VecDeque::new);
        pending.retain(|path| {
            !later
                .removed
                .iter()
                .any(|gone| contains(path, gone, flavor))
        });
        for path in later.pending.unwrap_or_default() {
            if !pending.iter().any(|base| contains(&path, base, flavor)) {
                pending.retain(|existing| !contains(existing, &path, flavor));
                pending.push_back(path);
            }
        }
        for path in later.removed {
            if !self
                .removed
                .iter()
                .any(|base| contains(&path, base, flavor))
            {
                self.removed.push(path);
            }
        }
        let covered = |candidate: &RuleCandidate| {
            pending
                .iter()
                .any(|base| contains(&candidate.identity.path_hint, base, flavor))
        };
        self.refreshed.retain(|existing| {
            !covered(existing)
                && !later.refreshed.iter().any(|fresh| {
                    same_path(
                        &fresh.identity.path_hint,
                        &existing.identity.path_hint,
                        flavor,
                    )
                })
        });
        self.refreshed
            .extend(later.refreshed.into_iter().filter(|fresh| !covered(fresh)));
        self.events.extend(later.events);
    }
}
fn contains(path: &str, base: &str, flavor: PathFlavor) -> bool {
    same_path(path, base, flavor) || flavor.is_descendant(path, base)
}
fn parent_of(path: &str) -> String {
    path.rsplit_once(['/', '\\']).map_or_else(
        || path.to_owned(),
        |(parent, _)| {
            if parent.is_empty() {
                "/".to_owned()
            } else {
                parent.to_owned()
            }
        },
    )
}
fn schedule(
    decision: Decision,
    identity: &FilesystemIdentity,
    report: &mut TickReport,
) -> Option<TrashRequest> {
    if decision.protected_descendant {
        return None;
    }
    let (source, scheduled_at, disposition) = match decision.resolution {
        Resolution::Scheduled(e) => (
            e.custom_override_id.map_or(
                ScheduledSource::Rule(e.rule_id),
                ScheduledSource::CustomOverride,
            ),
            e.scheduled_at,
            e.disposition,
        ),
        Resolution::CustomExpiry {
            override_id,
            expires_at,
            disposition,
        } => (
            ScheduledSource::CustomOverride(override_id),
            expires_at,
            disposition,
        ),
        _ => return None,
    };
    if disposition == Disposition::Preview {
        report.previewed += 1;
        return None;
    }
    scheduled_at.is_finite().then(|| TrashRequest {
        candidate_identity: identity.clone(),
        source,
        scheduled_at,
    })
}
struct Snapshot(Vec<RuleCandidate>);
impl MetadataSource for Snapshot {
    fn candidates(&self) -> Result<&[RuleCandidate], String> {
        Ok(&self.0)
    }
}
struct At(f64);
impl Clock for At {
    fn now(&self) -> f64 {
        self.0
    }
}
/// Per-execution Trash gate. While an update lease is live `acquire_trash_permit` is `Ok(false)`, which the
/// coordinator records as a safety skip and a transient block. The guard it takes is held until this value
/// is dropped, i.e. after the filesystem move and audit, so the updater can never quiesce mid-move.
struct Permit {
    interlock: Option<std::sync::Arc<tinyprune_update::interlock::Interlock>>,
    /// Never read: held only so its `Drop` ends the interlock hold after the move.
    _guard: Option<tinyprune_update::interlock::TrashGuard>,
}
impl UpdateGate for Permit {
    fn acquire_trash_permit(&mut self) -> Result<bool, String> {
        let Some(interlock) = &self.interlock else {
            return Ok(true);
        };
        match interlock.begin_trash() {
            Ok(guard) => {
                self._guard = Some(guard);
                Ok(true)
            }
            Err(_) => Ok(false),
        }
    }
}
struct NoSizes;
impl SizeMeasurer for NoSizes {
    fn measure(&mut self, _: &str) -> Option<SizeMeasurement> {
        None
    }
}
struct Hydrator<'a, S>(&'a S, PathFlavor);
fn same_path(a: &str, b: &str, flavor: PathFlavor) -> bool {
    match flavor {
        PathFlavor::Posix => flavor.equal(a, b),
        PathFlavor::Windows => flavor.equal(&flavor.normalize(a), &flavor.normalize(b)),
    }
}
impl<S: ObservationStore> CandidateHydrator for Hydrator<'_, S> {
    fn hydrate(
        &mut self,
        candidate: &RuleCandidate,
        _: &[LifetimeRule],
        _: f64,
    ) -> Result<RuleCandidate, String> {
        let mut candidate = candidate.clone();
        if let Some(observation) = self.0.observation(&candidate.identity)? {
            candidate.timestamps.first_observed = Some(observation.first);
            candidate.timestamps.observed_activity = Some(observation.last);
        }
        candidate.timestamps.project_activity = self
            .0
            .projects()?
            .iter()
            .filter(|p| {
                same_path(&candidate.identity.path_hint, &p.identity.path_hint, self.1)
                    || self
                        .1
                        .is_descendant(&candidate.identity.path_hint, &p.identity.path_hint)
            })
            .max_by_key(|p| self.1.normalize(&p.identity.path_hint).len())
            .map(|p| p.activity);
        Ok(candidate)
    }
}
/// All work is driven explicitly. No threads, timers, sleeps, filesystem or database
/// implementation is hidden here. `cancel` stops both indexing and execution until `resume`.
pub struct Agent<F, P, S, A, E, I> {
    pub files: F,
    pub policy: P,
    pub store: S,
    pub audit: A,
    pub events: E,
    pub index: I,
    /// Trash/update interlock shared with the updater (ADR 0012). `None` = no updater (tests, library use).
    pub update_interlock: Option<std::sync::Arc<tinyprune_update::interlock::Interlock>>,
    pub limits: Limits,
    jobs: VecDeque<Job>,
    snapshots: BTreeMap<String, SnapshotIndex>,
    queue: BTreeMap<(Time, IdentityKey), Entry>,
    positions: BTreeMap<IdentityKey, Time>,
    initialized: bool,
    cancelled: bool,
}
impl<
        F: FileAccess,
        P: PolicyStore,
        S: AgentStore,
        A: AgentAudit,
        E: EventSource,
        I: IndexSource,
    > Agent<F, P, S, A, E, I>
{
    pub fn new(files: F, policy: P, store: S, audit: A, events: E, index: I) -> Self {
        Self {
            files,
            policy,
            store,
            audit,
            events,
            index,
            update_interlock: None,
            limits: Limits::default(),
            jobs: VecDeque::new(),
            snapshots: BTreeMap::new(),
            queue: BTreeMap::new(),
            positions: BTreeMap::new(),
            initialized: false,
            cancelled: false,
        }
    }
    pub fn cancel(&mut self) {
        self.cancelled = true;
    }
    pub fn resume(&mut self) {
        self.cancelled = false;
    }
    pub fn queued(&self) -> usize {
        self.queue.len()
    }
    pub fn tick_clock(&mut self, clock: &impl Clock) -> Result<TickReport, String> {
        self.tick(clock.now())
    }
    fn enqueue(&mut self, request: TrashRequest, at: f64, failures: u32) {
        let identity = key(&request.candidate_identity);
        if let Some(old) = self.positions.insert(identity.clone(), Time(at)) {
            self.queue.remove(&(old, identity.clone()));
        }
        self.queue
            .insert((Time(at), identity), Entry { request, failures });
    }
    fn delta_job(&mut self, root: String, hint: Hints, flavor: PathFlavor) -> Result<(), String> {
        let prune = |mut paths: Vec<String>| {
            paths.sort_by_key(|path| flavor.normalize(path));
            let mut kept: Vec<String> = Vec::new();
            for path in paths {
                if !kept.iter().any(|base| contains(&path, base, flavor)) {
                    kept.push(path);
                }
            }
            kept
        };
        let scan = prune(hint.scan);
        let removed = prune(hint.removed);
        let mut refreshed = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for parent in hint.parents {
            if !contains(&parent, &root, flavor)
                || scan.iter().any(|base| contains(&parent, base, flavor))
                || !seen.insert(flavor.normalize(&parent))
            {
                continue;
            }
            if let Some(candidate) = self.files.inspect(&parent)? {
                refreshed.push(candidate);
            }
        }
        let mut job = Job::delta(root, scan, removed, refreshed, hint.events);
        // Bursts coalesce: a delta that has not started absorbs the next one for the same root.
        if let Some(back) = self.jobs.back_mut() {
            if back.mergeable(&job.root, flavor) {
                back.merge(job, flavor);
                return Ok(());
            }
        }
        job.validated = false;
        self.jobs.push_back(job);
        Ok(())
    }
    /// Request bounded recovery after policy changes or wake. Polling/replay always
    /// completes before cleanup, including across multiple event-source polls.
    pub fn reconcile(&mut self, root: &str) {
        self.jobs.push_back(Job::full(root.into(), vec![], vec![]));
    }
    /// Replaces the scheduled requests of `obsolete` queue entries with `requests`, keeping retry state
    /// while identity and deadline agree.
    fn requeue(&mut self, obsolete: Vec<(Time, IdentityKey)>, requests: Vec<TrashRequest>) {
        let mut old = BTreeMap::new();
        for k in obsolete {
            if let Some(e) = self.queue.remove(&k) {
                self.positions.remove(&k.1);
                old.insert(k.1, (k.0, e));
            }
        }
        for request in requests {
            let prior = old
                .remove(&key(&request.candidate_identity))
                .filter(|(_, e)| {
                    e.request.candidate_identity == request.candidate_identity
                        && e.request.scheduled_at == request.scheduled_at
                });
            let (at, failures) =
                prior.map_or((request.scheduled_at, 0), |(at, e)| (at.0, e.failures));
            self.enqueue(request, at, failures);
        }
    }
    /// One bounded turn of an indexing job: at most one enumeration batch, then (once complete) the
    /// decision pass, either over the whole root or over the delta only.
    fn step(
        &mut self,
        mut job: Job,
        now: f64,
        policy: &PolicySnapshot,
        report: &mut TickReport,
    ) -> Result<(), String> {
        let flavor = policy.settings.path_flavor;
        let root = job.root.clone();
        let scan_policy = ScanPolicy {
            root: &root,
            rules: &policy.rules,
            overrides: &policy.overrides,
            settings: &policy.settings,
        };
        let usable = |agent: &Self| {
            agent
                .snapshots
                .get(&root)
                .is_some_and(|index| index.matches(&scan_policy))
        };
        // An incremental pass needs a snapshot built under the current policy; otherwise recover fully.
        if job.pending.is_some() && !job.validated {
            if usable(self) {
                job.validated = true;
            } else {
                job = Job::full(root.clone(), job.removed, job.events);
            }
        }
        let enumerate = |agent: &mut Self, job: &mut Job, report: &mut TickReport| {
            let batch = agent.index.next_batch(agent.limits.index_entries)?;
            if batch.candidates.len() > agent.limits.index_entries.get() {
                return Err("IndexSource exceeded batch limit".to_string());
            }
            report.indexed += batch.candidates.len();
            job.candidates.extend(batch.candidates);
            Ok(batch.complete)
        };
        let finished = if job.pending.is_none() {
            if !job.started {
                self.index.begin(&root)?;
                job.started = true;
            }
            enumerate(self, &mut job, report)?
        } else {
            while job.current.is_none() {
                let Some(path) = job.pending.as_mut().and_then(VecDeque::pop_front) else {
                    break;
                };
                // A target that vanished since the hint is a removal, never a failed enumeration.
                if self.files.inspect(&path)?.is_none() {
                    job.removed.push(path);
                } else {
                    self.index.begin(&path)?;
                    job.current = Some(path);
                }
            }
            if job.current.is_some() && enumerate(self, &mut job, report)? {
                let path = job.current.take().expect("current path");
                let candidates = std::mem::take(&mut job.candidates);
                job.scanned.push((path, candidates));
            }
            job.current.is_none() && job.pending.as_ref().is_none_or(VecDeque::is_empty)
        };
        if !finished {
            self.jobs.push_front(job);
            return Ok(());
        }
        let mut requests = Vec::new();
        if job.pending.is_none() {
            let source = Snapshot(std::mem::take(&mut job.candidates));
            let decisions = scheduler::scan(
                &source,
                &mut self.store,
                &At(now),
                &scan_policy,
                &job.events,
                &job.removed,
            )?;
            for (candidate, decision) in source.0.iter().zip(decisions) {
                requests.extend(schedule(decision, &candidate.identity, report));
            }
            self.store.replace_deadlines(&root, &requests)?;
            self.snapshots
                .insert(root.clone(), SnapshotIndex::build(source.0, &scan_policy));
            let within = |path: &str, base: &str| contains(path, base, flavor);
            let obsolete = self
                .queue
                .iter()
                .filter(|(_, e)| within(&e.request.candidate_identity.path_hint, &root))
                .map(|(k, _)| k.clone())
                .collect();
            self.requeue(obsolete, requests);
        } else {
            if !usable(self) {
                // The policy moved while enumerating: the delta is meaningless, recover fully.
                self.jobs
                    .push_front(Job::full(root.clone(), job.removed, job.events));
                return Ok(());
            }
            self.index.publish_delta(&job.removed, &job.refreshed)?;
            let index = self.snapshots.get_mut(&root).expect("usable snapshot");
            let outcome = scheduler::scan_delta(
                index,
                &mut self.store,
                &At(now),
                &scan_policy,
                Delta {
                    rescanned: std::mem::take(&mut job.scanned),
                    removed: &job.removed,
                    refreshed: std::mem::take(&mut job.refreshed),
                    events: &job.events,
                },
            )?;
            let mut evaluated = outcome.replaced;
            for (identity, decision) in outcome.decisions {
                requests.extend(schedule(decision, &identity, report));
                evaluated.push(identity);
            }
            self.store.update_deadlines(&root, &evaluated, &requests)?;
            let obsolete = evaluated
                .iter()
                .filter_map(|identity| {
                    let k = key(identity);
                    self.positions.get(&k).map(|at| (*at, k))
                })
                .collect();
            self.requeue(obsolete, requests);
        }
        Ok(())
    }
    pub fn tick(&mut self, now: f64) -> Result<TickReport, String> {
        let result = self.tick_inner(now);
        if result.is_err() {
            // Unknown readiness requires a complete successful recovery before cleanup.
            self.initialized = false;
            self.jobs.clear();
            self.snapshots.clear();
        }
        result
    }
    fn tick_inner(&mut self, now: f64) -> Result<TickReport, String> {
        if !now.is_finite() {
            return Err("tick time must be finite".into());
        }
        let mut report = TickReport::default();
        if self.cancelled {
            report.cancelled = true;
            return Ok(report);
        }
        let policy = self.policy.load_snapshot()?;
        let flavor = policy.settings.path_flavor;
        let same_path = |a: &str, b: &str| same_path(a, b, flavor);
        let within =
            |path: &str, root: &str| same_path(path, root) || flavor.is_descendant(path, root);
        if !self.initialized {
            for request in self.store.load_deadlines()? {
                let at = request.scheduled_at;
                self.enqueue(request, at, 0);
            }
            for identity in self.audit.dangling_attempts()? {
                self.audit.finish_recovery(&identity, AuditEvent { occurred_at: now, kind: AuditKind::SafetySkipped, identity: Some(identity.clone()), rule_id: None, detail: Some("restart recovered an interrupted Trash attempt; outcome unknown, reinspection required".into()), bytes: None, item_count: None })?;
                report.recovered += 1;
            }
            for root in &policy.managed_roots {
                self.reconcile(root);
            }
            self.initialized = true;
        }
        let batch = self
            .events
            .poll(Duration::ZERO, self.limits.events)
            .map_err(|e| e.to_string())?;
        for root in batch.must_rescan {
            let root = root
                .to_str()
                .ok_or("non-UTF-8 root cannot be represented by the core")?;
            if let Some(root) = policy.managed_roots.iter().find(|r| same_path(r, root)) {
                self.reconcile(root);
            }
        }
        let mut hints: BTreeMap<String, Hints> = BTreeMap::new();
        for event in batch.events {
            let root = event
                .root
                .to_str()
                .ok_or("non-UTF-8 event root")?
                .to_owned();
            let path = event
                .path
                .to_str()
                .ok_or("non-UTF-8 event path")?
                .to_owned();
            let Some(root) = policy
                .managed_roots
                .iter()
                .find(|r| same_path(r, &root))
                .cloned()
            else {
                continue;
            };
            if !within(&path, &root) {
                continue;
            }
            let hint = hints.entry(root).or_default();
            // A hint is resolved against the filesystem as it is now: an existing target is re-enumerated
            // (its subtree only), an absent one (removals, our own Trash moves, stale create/modify hints)
            // leaves the snapshot. Replay uses fresh metadata time, never wake wall time, as activity.
            let candidate = self.files.inspect(&path)?;
            if let EventKind::Renamed { from, .. } = &event.kind {
                let from = from.to_str().ok_or("non-UTF-8 rename source")?.to_owned();
                hint.parents.push(parent_of(&from));
                // A source that exists again is re-enumerated by its own hint; deleting its rows
                // would discard the observations of the item that replaced it.
                if self.files.inspect(&from)?.is_none() {
                    hint.removed.push(from);
                }
            }
            // Entries created, removed or renamed (or vanished before we looked) change the metadata of
            // their parent directory itself, which a complete pass would also observe.
            let entries_changed = candidate.is_none()
                || matches!(
                    event.kind,
                    EventKind::Created | EventKind::Removed | EventKind::Renamed { .. }
                );
            match candidate {
                Some(candidate) => {
                    if let Some(at) = candidate.timestamps.modified {
                        hint.events.push(ActivityEvent {
                            path: path.clone(),
                            at,
                        });
                    }
                    hint.scan.push(path.clone());
                }
                None => hint.removed.push(path.clone()),
            }
            if entries_changed {
                hint.parents.push(parent_of(&path));
            }
        }
        for (root, hint) in hints {
            self.delta_job(root, hint, flavor)?;
        }
        if let Some(job) = self.jobs.pop_front() {
            if !policy
                .managed_roots
                .iter()
                .any(|root| same_path(root, &job.root))
            {
                report.pending_work = true;
                return Ok(report);
            }
            if !self.index.available(&job.root)? {
                self.jobs.push_front(job);
                report.pending_work = true;
                return Ok(report);
            }
            self.step(job, now, &policy, &mut report)?;
        }
        report.pending_work = batch.pending_work || !self.jobs.is_empty();
        if report.pending_work || policy.globally_paused {
            return Ok(report);
        }
        for _ in 0..self.limits.due_items.get() {
            let Some((queue_key, _)) = self.queue.first_key_value() else {
                break;
            };
            if queue_key.0 .0 > now {
                break;
            }
            let (queue_key, entry) = self.queue.pop_first().unwrap();
            self.positions.remove(&queue_key.1);
            let request = &entry.request;
            let root = policy
                .managed_roots
                .iter()
                .filter(|root| within(&request.candidate_identity.path_hint, root))
                .max_by_key(|root| root.len());
            let ready = match root {
                Some(root) => self.index.available(root)?,
                None => false,
            };
            if !ready {
                self.enqueue(entry.request, now + 300.0, entry.failures);
                report.deferred += 1;
                continue;
            }
            let mut hydrator = Hydrator(&self.store, policy.settings.path_flavor);
            let result = TrashCoordinator {
                policy: &mut self.policy,
                files: &mut self.files,
                audit: &mut self.audit,
                clock: &At(now),
                gate: &mut Permit {
                    interlock: self.update_interlock.clone(),
                    _guard: None,
                },
                hydrator: Some(&mut hydrator),
                sizes: &mut NoSizes,
                walk_limits: DescendantWalkLimits::default(),
            }
            .execute(request);
            report.executed += 1;
            if matches!(
                &result,
                Ok(Outcome::MovedToTrash { .. }) | Err(ExecutionError::MovedButAuditFailed { .. })
            ) {
                for snapshot in self.snapshots.values_mut() {
                    snapshot.remove_subtree(&request.candidate_identity.path_hint);
                }
            }
            let (retry, base) = match result {
                Ok(Outcome::MovedToTrash { .. }) => {
                    report.trashed += 1;
                    (false, 0.0)
                }
                Err(ExecutionError::MovedButAuditFailed { path, detail }) => {
                    report.trashed += 1;
                    report
                        .failures
                        .push(format!("moved to {path}, audit failed: {detail}"));
                    (false, 0.0)
                }
                Ok(Outcome::Skipped(_)) => {
                    report.skipped += 1;
                    (false, 0.0)
                }
                Ok(Outcome::NotDue(at)) => {
                    self.enqueue(entry.request, at.max(now + 1.0), 0);
                    continue;
                }
                Ok(Outcome::Previewed) => {
                    report.previewed += 1;
                    (true, 300.0)
                }
                Ok(Outcome::Deferred(_)) => {
                    report.deferred += 1;
                    (true, 300.0)
                }
                Err(error) => {
                    report.failures.push(format!("{error:?}"));
                    (true, 30.0)
                }
            };
            if retry {
                let delay = (base * 2_f64.powi(entry.failures.min(10) as i32)).min(3600.0);
                self.enqueue(entry.request, now + delay, entry.failures.saturating_add(1));
            } else if let Err(error) = self.store.remove_deadline(request) {
                self.enqueue(entry.request, now + 30.0, entry.failures.saturating_add(1));
                return Err(error);
            }
        }
        report.pending_work = self
            .queue
            .first_key_value()
            .is_some_and(|(key, _)| key.0 .0 <= now);
        Ok(report)
    }
}

#[cfg(test)]
mod tests;
