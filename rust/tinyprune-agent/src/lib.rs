//! Deterministic, synchronous agent orchestration. Unreleased infrastructure, not platform support.
use std::cmp::Ordering;
use std::collections::{BTreeMap, VecDeque};
use std::num::NonZeroUsize;
use std::time::Duration;
use tinyprune_core::resolve::{Disposition, Resolution};
use tinyprune_core::rule::*;
use tinyprune_core::scheduler::{
    self, ActivityEvent, MetadataSource, ObservationStore, ScanPolicy,
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
struct Job {
    root: String,
    path: String,
    removed: Vec<String>,
    events: Vec<ActivityEvent>,
    candidates: Vec<RuleCandidate>,
    started: bool,
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
struct Permit;
impl UpdateGate for Permit {
    fn acquire_trash_permit(&mut self) -> Result<bool, String> {
        Ok(true)
    }
}
struct NoSizes;
impl SizeMeasurer for NoSizes {
    fn measure(&mut self, _: &str) -> Option<SizeMeasurement> {
        None
    }
}
struct Hydrator<'a, S>(&'a S, PathFlavor);
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
                self.1
                    .equal(&candidate.identity.path_hint, &p.identity.path_hint)
                    || self
                        .1
                        .is_descendant(&candidate.identity.path_hint, &p.identity.path_hint)
            })
            .max_by_key(|p| p.identity.path_hint.len())
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
    pub limits: Limits,
    jobs: VecDeque<Job>,
    snapshots: BTreeMap<String, Snapshot>,
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
    fn job(
        &mut self,
        root: String,
        path: String,
        removed: Vec<String>,
        events: Vec<ActivityEvent>,
    ) {
        self.jobs.push_back(Job {
            root,
            path,
            removed,
            events,
            candidates: Vec::new(),
            started: false,
        });
    }
    /// Request bounded recovery after policy changes or wake. Polling/replay always
    /// completes before cleanup, including across multiple event-source polls.
    pub fn reconcile(&mut self, root: &str) {
        self.job(root.into(), root.into(), vec![], vec![]);
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
        let within = |path: &str, root: &str| {
            policy.settings.path_flavor.equal(path, root)
                || policy.settings.path_flavor.is_descendant(path, root)
        };
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
            if policy.managed_roots.iter().any(|r| r == root) {
                self.reconcile(root);
            }
        }
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
            if !policy.managed_roots.contains(&root) || !within(&path, &root) {
                continue;
            }
            let removed = match event.kind {
                EventKind::Removed => vec![path.clone()],
                EventKind::Renamed { from, .. } => {
                    vec![from.to_str().ok_or("non-UTF-8 rename source")?.to_owned()]
                }
                _ => vec![],
            };
            // Replay uses fresh metadata time, never wake wall time as activity.
            let candidate = self.files.inspect(&path)?;
            let events = candidate
                .as_ref()
                .and_then(|c| c.timestamps.modified)
                .map(|at| ActivityEvent {
                    path: path.clone(),
                    at,
                })
                .into_iter()
                .collect();
            // Removal hints (including our own Trash moves) and stale create/modify hints
            // can name an absent item. Enumerating it would turn an expected removal into
            // a partial-scan failure. Reconcile the root instead; only a complete scan may
            // remove schedules, and missing/inaccessible managed roots still defer cleanup.
            let scan_path = if candidate.is_some() {
                path
            } else {
                root.clone()
            };
            self.job(root, scan_path, removed, events);
        }
        if let Some(mut job) = self.jobs.pop_front() {
            if !policy.managed_roots.contains(&job.root) {
                report.pending_work = true;
                return Ok(report);
            }
            if !self.index.available(&job.root)? {
                self.jobs.push_front(job);
                report.pending_work = true;
                return Ok(report);
            }
            if !job.started {
                self.index.begin(&job.path)?;
                job.started = true;
            }
            let batch = self.index.next_batch(self.limits.index_entries)?;
            if batch.candidates.len() > self.limits.index_entries.get() {
                return Err("IndexSource exceeded batch limit".into());
            }
            report.indexed = batch.candidates.len();
            job.candidates.extend(batch.candidates);
            if !batch.complete {
                self.jobs.push_front(job);
            } else {
                let snapshot = self
                    .snapshots
                    .entry(job.root.clone())
                    .or_insert_with(|| Snapshot(vec![]));
                snapshot.0.retain(|c| {
                    !within(&c.identity.path_hint, &job.path)
                        && !job.removed.iter().any(|p| within(&c.identity.path_hint, p))
                });
                snapshot.0.extend(job.candidates);
                let decisions = scheduler::scan(
                    snapshot,
                    &mut self.store,
                    &At(now),
                    &ScanPolicy {
                        root: &job.root,
                        rules: &policy.rules,
                        overrides: &policy.overrides,
                        settings: &policy.settings,
                    },
                    &job.events,
                    &job.removed,
                )?;
                let mut requests = Vec::new();
                for (candidate, decision) in snapshot.0.iter().zip(decisions) {
                    if decision.protected_descendant {
                        continue;
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
                        _ => continue,
                    };
                    if disposition == Disposition::Preview {
                        report.previewed += 1;
                        continue;
                    }
                    if scheduled_at.is_finite() {
                        requests.push(TrashRequest {
                            candidate_identity: candidate.identity.clone(),
                            source,
                            scheduled_at,
                        });
                    }
                }
                self.store.replace_deadlines(&job.root, &requests)?;
                let obsolete: Vec<_> = self
                    .queue
                    .iter()
                    .filter(|(_, e)| within(&e.request.candidate_identity.path_hint, &job.root))
                    .map(|(k, _)| k.clone())
                    .collect();
                // Preserve retry state when identity and deadline have not changed.
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
                gate: &mut Permit,
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
                    snapshot.0.retain(|candidate| {
                        !within(
                            &candidate.identity.path_hint,
                            &request.candidate_identity.path_hint,
                        )
                    });
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
