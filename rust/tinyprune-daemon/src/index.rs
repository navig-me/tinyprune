use crate::{codec, explain_with, phases};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    fmt::Write as _,
    hash::{DefaultHasher, Hasher},
    num::NonZeroUsize,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tinyprune_agent::{AgentStore, IndexBatch, IndexSource};
use tinyprune_core::{
    rule::{ExpiryBasis, FilesystemIdentity, RuleCandidate, RuleState},
    scheduler::{self, Observation, ObservationStore, Project},
    trash::{Clock, PolicySnapshot, PolicyStore, TrashRequest},
    uuid::Uuid,
};
use tinyprune_scan::ProductionIndexSource;
use tinyprune_store::{DecisionRow, Store};

type Key = (Uuid, Vec<u8>);
fn key(identity: &FilesystemIdentity) -> Key {
    (identity.volume, identity.resource.clone())
}
/// More changed candidates than this are not tracked individually: the root is re-evaluated in full.
const DIRTY_CAP: usize = 20_000;

/// Scan/decision progress shared between the engine, the polling fallback and the decision job.
#[derive(Default)]
pub(crate) struct Pace {
    scanning: AtomicBool,
    decisions: AtomicBool,
    last_scan_millis: AtomicU64,
    last_complete_bits: AtomicU64,
    pub(crate) delta: AtomicBool,
}
impl Pace {
    pub fn busy(&self) -> bool {
        self.scanning.load(Ordering::Acquire) || self.decisions.load(Ordering::Acquire)
    }
    pub fn last_scan_seconds(&self) -> f64 {
        self.last_scan_millis.load(Ordering::Relaxed) as f64 / 1000.0
    }
    /// Injected-clock time at which the latest scan finished (0 before the first).
    pub fn last_complete(&self) -> f64 {
        f64::from_bits(self.last_complete_bits.load(Ordering::Relaxed))
    }
}

/// State shared by the engine-side store wrapper and the decision job.
#[derive(Default)]
pub(crate) struct Shared {
    pub pace: Arc<Pace>,
    /// Roots queued for a full decision pass.
    roots: Mutex<BTreeSet<String>>,
    /// Policy revision each root's decisions were last evaluated at.
    evaluated: Mutex<HashMap<String, u64>>,
    /// Last published fingerprint (and path hint) per candidate identity.
    prints: Mutex<Prints>,
    /// Candidates whose published metadata changed since their decision was last written.
    dirty: Mutex<HashMap<Key, RuleCandidate>>,
    /// More than `DIRTY_CAP` candidates changed: queue a full pass at the next scheduling publish.
    overflow: AtomicBool,
    /// When the latest scan was published; `replace_deadlines` reports the evaluation time since then.
    published_at: Mutex<Option<Instant>>,
}

/// Hash of the complete candidate metadata (path hint, dates, kind, flags) without allocating.
fn fingerprint(candidate: &RuleCandidate) -> u64 {
    struct Sip(DefaultHasher);
    impl std::fmt::Write for Sip {
        fn write_str(&mut self, text: &str) -> std::fmt::Result {
            self.0.write(text.as_bytes());
            Ok(())
        }
    }
    let mut hasher = Sip(DefaultHasher::new());
    let _ = write!(hasher, "{candidate:?}");
    hasher.0.finish()
}

/// Last published fingerprint per candidate identity, plus the same items ordered by path key so that a
/// subtree scan only visits the entries below it.
#[derive(Default)]
struct Prints {
    by_key: HashMap<Key, (u64, String)>,
    by_path: BTreeMap<String, Key>,
}
impl Prints {
    fn forget(&mut self, key: &Key) {
        if let Some((_, path)) = self.by_key.remove(key) {
            self.by_path.remove(&path);
        }
    }
}

impl Shared {
    /// Notes `candidate` as changed when its published metadata differs from the last published print.
    fn note(
        prints: &mut Prints,
        dirty: &mut HashMap<Key, RuleCandidate>,
        overflow: &mut bool,
        candidate: &RuleCandidate,
    ) -> Key {
        let k = key(&candidate.identity);
        let print = fingerprint(candidate);
        if prints.by_key.get(&k).is_none_or(|(old, _)| *old != print) {
            prints.forget(&k);
            let path = scheduler::path_key(codec::flavor(), &candidate.identity.path_hint);
            // An identity that held this path before has been replaced by this one.
            if let Some(displaced) = prints.by_path.insert(path.clone(), k.clone()) {
                if displaced != k {
                    prints.by_key.remove(&displaced);
                    dirty.remove(&displaced);
                }
            }
            prints.by_key.insert(k.clone(), (print, path));
            if !*overflow {
                if dirty.len() >= DIRTY_CAP {
                    dirty.clear();
                    *overflow = true;
                } else {
                    dirty.insert(k.clone(), candidate.clone());
                }
            }
        }
        k
    }
    /// Records a completed, already-published subtree scan and notes which candidates changed.
    fn record(&self, path: &str, candidates: &[RuleCandidate]) -> Result<(), String> {
        let mut prints = self.prints.lock().map_err(|_| "Fingerprints poisoned")?;
        let mut dirty = self.dirty.lock().map_err(|_| "Dirty set poisoned")?;
        let mut overflow = self.overflow.load(Ordering::Acquire);
        let mut current: HashSet<Key> = HashSet::with_capacity(candidates.len());
        for candidate in candidates {
            current.insert(Self::note(
                &mut prints,
                &mut dirty,
                &mut overflow,
                candidate,
            ));
        }
        // Everything previously published below `path` that this scan no longer contains is gone.
        let root = scheduler::path_key(codec::flavor(), path);
        let (low, high) = scheduler::descendant_bounds(&root);
        let gone: Vec<Key> = prints
            .by_path
            .range(low..high)
            .map(|(_, k)| k)
            .chain(prints.by_path.get(&root))
            .filter(|k| !current.contains(*k))
            .cloned()
            .collect();
        for k in &gone {
            prints.forget(k);
            dirty.remove(k);
        }
        self.overflow.store(overflow, Ordering::Release);
        if overflow || !dirty.is_empty() {
            self.pace.decisions.store(true, Ordering::Release);
        }
        Ok(())
    }
    /// Records single items rewritten without a subtree enumeration (the parents of event paths).
    fn record_upserts(&self, candidates: &[RuleCandidate]) -> Result<(), String> {
        let mut prints = self.prints.lock().map_err(|_| "Fingerprints poisoned")?;
        let mut dirty = self.dirty.lock().map_err(|_| "Dirty set poisoned")?;
        let mut overflow = self.overflow.load(Ordering::Acquire);
        for candidate in candidates {
            Self::note(&mut prints, &mut dirty, &mut overflow, candidate);
        }
        self.overflow.store(overflow, Ordering::Release);
        if overflow || !dirty.is_empty() {
            self.pace.decisions.store(true, Ordering::Release);
        }
        Ok(())
    }
}

pub(crate) struct DurableIndex {
    source: ProductionIndexSource,
    store: Store,
    path: String,
    candidates: Vec<RuleCandidate>,
    clock: Arc<dyn Clock + Send + Sync>,
    shared: Arc<Shared>,
    started: Option<Instant>,
    /// Time spent inside the enumerator (excluding publication) during the current scan.
    enumerating: Duration,
}
impl DurableIndex {
    pub fn new(store: Store, clock: Arc<dyn Clock + Send + Sync>, shared: Arc<Shared>) -> Self {
        Self {
            source: ProductionIndexSource::default(),
            store,
            path: String::new(),
            candidates: vec![],
            clock,
            shared,
            started: None,
            enumerating: Duration::ZERO,
        }
    }
}
impl IndexSource for DurableIndex {
    fn available(&mut self, root: &str) -> Result<bool, String> {
        self.source.available(root)
    }
    fn begin(&mut self, root: &str) -> Result<(), String> {
        self.source.begin(root)?;
        self.path = root.into();
        self.candidates.clear();
        self.started = Some(Instant::now());
        self.enumerating = Duration::ZERO;
        self.shared.pace.scanning.store(true, Ordering::Release);
        if self.shared.pace.delta.load(Ordering::Acquire) {
            phases::record("delta_scan_start", Duration::ZERO, 0);
        }
        Ok(())
    }
    fn next_batch(&mut self, limit: NonZeroUsize) -> Result<IndexBatch, String> {
        let call = Instant::now();
        let outcome = self.source.next_batch(limit);
        self.enumerating += call.elapsed();
        let batch = match outcome {
            Ok(batch) => batch,
            Err(error) => {
                self.shared.pace.scanning.store(false, Ordering::Release);
                return Err(error);
            }
        };
        self.candidates.extend(batch.candidates.iter().cloned());
        if batch.complete {
            let now = self.clock.now();
            if self.shared.pace.delta.load(Ordering::Acquire) {
                if let Some(started) = self.started {
                    phases::since("delta_scan", started, self.candidates.len());
                }
            }
            // Unchanged candidates are not rewritten by the store and not re-evaluated here.
            let publish_started = Instant::now();
            let stored = self
                .store
                .publish_candidate_subtree(&self.path, &self.candidates, now);
            phases::since("publish", publish_started, self.candidates.len());
            if self.shared.pace.delta.load(Ordering::Acquire) {
                phases::since("delta_publish", publish_started, self.candidates.len());
            }
            let record_started = Instant::now();
            let published = stored.and_then(|_| self.shared.record(&self.path, &self.candidates));
            phases::since("record", record_started, self.candidates.len());
            phases::record("enumerate", self.enumerating, self.candidates.len());
            if let Ok(mut at) = self.shared.published_at.lock() {
                *at = Some(Instant::now());
            }
            let pace = &self.shared.pace;
            if let Some(started) = self.started.take() {
                // Real elapsed time: it paces the polling fallback against actual scan cost.
                pace.last_scan_millis
                    .store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
            }
            pace.last_complete_bits
                .store(now.to_bits(), Ordering::Relaxed);
            pace.scanning.store(false, Ordering::Release);
            self.candidates = Vec::new();
            published?;
        }
        Ok(batch)
    }
    fn publish_delta(
        &mut self,
        removed: &[String],
        refreshed: &[RuleCandidate],
    ) -> Result<(), String> {
        let now = self.clock.now();
        let started = Instant::now();
        for path in removed {
            // An empty subtree deletes its rows and, with them, their fingerprints.
            self.store.publish_candidate_subtree(path, &[], now)?;
            self.shared.record(path, &[])?;
        }
        if !refreshed.is_empty() {
            self.store.upsert_candidates(refreshed, now)?;
            self.shared.record_upserts(refreshed)?;
        }
        phases::since("delta_publish", started, removed.len() + refreshed.len());
        Ok(())
    }
}

/// Bounded, resumable decision evaluation, run off the engine lock in small steps by the tick thread.
/// A full pass pages the published candidate snapshot of a root (first scan, policy change, overflow);
/// otherwise only candidates whose metadata changed are evaluated.
#[derive(Default)]
pub(crate) struct Decisions {
    job: Option<Job>,
}
struct Job {
    root: String,
    after: Option<String>,
    revision: u64,
    policy: PolicySnapshot,
    store: Store,
    /// Containment index over the project snapshot taken when the job was loaded (Windows flavor).
    projects: Option<crate::ProjectIndex>,
    processed: usize,
}
// Keep the same 4096-candidate work bound per turn, but commit once instead of
// eight times: durable WAL flushes dominate explanation publication on Windows.
const PAGE: usize = 4096;
const PAGES_PER_STEP: usize = 1;

impl Decisions {
    /// Evaluates up to a bounded number of candidates; true while more work remains.
    pub fn advance(&mut self, shared: &Shared, reader: &Store, now: f64) -> Result<bool, String> {
        let result = self.advance_inner(shared, reader, now);
        if result.is_err() {
            // Retry the whole root on a later turn rather than trusting a half-evaluated cursor.
            if let Some(job) = self.job.take() {
                if let Ok(mut roots) = shared.roots.lock() {
                    roots.insert(job.root);
                }
            }
        }
        let pending = result?;
        shared.pace.decisions.store(pending, Ordering::Release);
        Ok(pending)
    }
    fn load(root: String, reader: &Store) -> Result<Job, String> {
        let mut store = reader.clone();
        let policy = store.load_snapshot()?;
        let (revision, _, _) = store.runtime_state()?;
        store.refresh_projects()?;
        let projects = crate::ProjectIndex::new(store.projects()?);
        if !root.is_empty() {
            phases::record("decision_job_start", Duration::ZERO, 0);
        }
        Ok(Job {
            root,
            after: None,
            revision,
            policy,
            store,
            projects,
            processed: 0,
        })
    }
    /// Evaluates the candidates and writes changed decisions in one store transaction.
    fn write(job: &Job, candidates: &[&RuleCandidate], now: f64) -> Result<(), String> {
        let explain_started = Instant::now();
        let mut values = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            let e = explain_with(
                candidate,
                &job.policy,
                &job.store,
                now,
                job.projects.as_ref(),
            )?;
            values.push((
                e.scheduled_at,
                e.rule.as_ref().map(|r| r.id.clone()),
                e.disposition == Some(tinyprune_ipc::Disposition::Preview),
                serde_json::to_value(&e).map_err(|e| e.to_string())?,
            ));
        }
        phases::since("explain", explain_started, candidates.len());
        let rows: Vec<DecisionRow<'_>> = candidates
            .iter()
            .zip(&values)
            .map(|(candidate, (at, rule, preview, value))| DecisionRow {
                identity: &candidate.identity,
                scheduled_at: *at,
                rule_id: rule.as_deref(),
                preview: *preview,
                explanation: value,
            })
            .collect();
        // Unchanged decisions are neither rewritten nor re-audited by the store.
        let put_started = Instant::now();
        job.store.put_decisions(now, &rows)?;
        phases::since("decisions_store", put_started, rows.len());
        Ok(())
    }
    fn advance_inner(&mut self, shared: &Shared, reader: &Store, now: f64) -> Result<bool, String> {
        // Never leave a changed candidate behind the remainder of a full-root pass.
        // Pages are fetched fresh after this turn; no candidate snapshot survives a yield.
        if !shared.dirty.lock().map_err(|_| "Dirty set poisoned")?.is_empty() {
            let pending = Self::dirty_step(shared, reader, now)?;
            return Ok(pending || self.job.is_some());
        }
        for _ in 0..PAGES_PER_STEP {
            if self.job.is_none() {
                let next = shared
                    .roots
                    .lock()
                    .map_err(|_| "Decision queue poisoned")?
                    .pop_first();
                let Some(root) = next else {
                    return Self::dirty_step(shared, reader, now);
                };
                self.job = Some(Self::load(root, reader)?);
            }
            let job = self.job.as_mut().expect("job loaded");
            // A newer scan or policy revision of this root restarts its evaluation.
            if shared
                .roots
                .lock()
                .map_err(|_| "Decision queue poisoned")?
                .remove(&job.root)
                || reader.runtime_state()?.0 != job.revision
            {
                *job = Self::load(job.root.clone(), reader)?;
            }
            let page = job.store.candidate_page(
                &job.root,
                job.after.as_deref(),
                NonZeroUsize::new(PAGE).expect("nonzero"),
            )?;
            if page.is_empty() {
                shared
                    .evaluated
                    .lock()
                    .map_err(|_| "Decision state poisoned")?
                    .insert(job.root.clone(), job.revision);
                phases::record("decision_job_complete", Duration::ZERO, job.processed);
                self.job = None;
                continue;
            }
            job.after = page.last().map(|v| v.0.clone());
            let refs: Vec<&RuleCandidate> = page.iter().map(|(_, c)| c).collect();
            Self::write(job, &refs, now)?;
            job.processed += page.len();
        }
        Ok(true)
    }
    /// One bounded batch of changed candidates; true while more remain.
    fn dirty_step(shared: &Shared, reader: &Store, now: f64) -> Result<bool, String> {
        let batch: Vec<(Key, RuleCandidate)> = {
            let mut dirty = shared.dirty.lock().map_err(|_| "Dirty set poisoned")?;
            let keys: Vec<Key> = dirty.keys().take(PAGE).cloned().collect();
            keys.iter().filter_map(|k| dirty.remove_entry(k)).collect()
        };
        if batch.is_empty() {
            return Ok(false);
        }
        let result = (|| {
            let job = Self::load(String::new(), reader)?;
            let refs: Vec<&RuleCandidate> = batch.iter().map(|(_, c)| c).collect();
            Self::write(&job, &refs, now)?;
            // One changed file moves a project's activity, which moves every item below it.
            if job.policy.rules.iter().any(|r| {
                r.expiry_basis == ExpiryBasis::ProjectActivity && r.state != RuleState::Paused
            }) {
                shared
                    .roots
                    .lock()
                    .map_err(|_| "Decision queue poisoned")?
                    .extend(job.policy.managed_roots.iter().cloned());
                return Ok(());
            }
            Ok(())
        })();
        if let Err(error) = result {
            // Keep them for the next turn.
            if let Ok(mut dirty) = shared.dirty.lock() {
                dirty.extend(batch);
            }
            return Err(error);
        }
        let more = !shared
            .dirty
            .lock()
            .map_err(|_| "Dirty set poisoned")?
            .is_empty()
            || !shared
                .roots
                .lock()
                .map_err(|_| "Decision queue poisoned")?
                .is_empty();
        Ok(more)
    }
}

pub(crate) fn wire_roots(paths: &[String]) -> Vec<tinyprune_ipc::Root> {
    paths.iter().map(|v| codec::root(v)).collect()
}

pub(crate) struct DurableStore {
    inner: Store,
    shared: Arc<Shared>,
}
impl DurableStore {
    pub fn new(inner: Store, shared: Arc<Shared>) -> Self {
        Self { inner, shared }
    }
}
impl std::ops::Deref for DurableStore {
    type Target = Store;
    fn deref(&self) -> &Store {
        &self.inner
    }
}
impl std::ops::DerefMut for DurableStore {
    fn deref_mut(&mut self) -> &mut Store {
        &mut self.inner
    }
}
impl ObservationStore for DurableStore {
    fn observation(&self, i: &FilesystemIdentity) -> Result<Option<Observation>, String> {
        self.inner.observation(i)
    }
    fn save_observation(&mut self, value: Observation) -> Result<(), String> {
        self.inner.save_observation(value)
    }
    fn projects(&self) -> Result<&[Project], String> {
        self.inner.projects()
    }
    fn publish_projects(&mut self, root: &str, values: Vec<Project>) -> Result<(), String> {
        self.inner.publish_projects(root, values)
    }
    fn remove_below(&mut self, path: &str) -> Result<(), String> {
        self.inner.remove_below(path)
    }
}
impl DurableStore {
    /// A full decision pass is needed only when the policy moved on since this root was last evaluated or
    /// too many candidates changed to track; otherwise the dirty set is evaluated incrementally.
    fn queue_decisions(&self, root: &str) -> Result<(), String> {
        let (revision, _, _) = self.inner.runtime_state()?;
        let stale = self
            .shared
            .evaluated
            .lock()
            .map_err(|_| "Decision state poisoned")?
            .get(root)
            != Some(&revision);
        if self.shared.overflow.swap(false, Ordering::AcqRel) || stale {
            self.shared
                .roots
                .lock()
                .map_err(|_| "Decision queue poisoned")?
                .insert(root.to_owned());
            self.shared.pace.decisions.store(true, Ordering::Release);
        }
        Ok(())
    }
}
impl AgentStore for DurableStore {
    fn load_deadlines(&mut self) -> Result<Vec<TrashRequest>, String> {
        self.inner.load_deadlines()
    }
    fn replace_deadlines(&mut self, root: &str, deadlines: &[TrashRequest]) -> Result<(), String> {
        // Since the snapshot was published: agent snapshot merge, hydration and scheduler evaluation.
        if let Some(published) = self
            .shared
            .published_at
            .lock()
            .ok()
            .and_then(|mut at| at.take())
        {
            phases::since("evaluate", published, deadlines.len());
        }
        let started = Instant::now();
        self.inner.replace_deadlines(root, deadlines)?;
        phases::since("deadlines", started, deadlines.len());
        self.shared.pace.delta.store(false, Ordering::Release);
        self.queue_decisions(root)
    }
    fn update_deadlines(
        &mut self,
        root: &str,
        evaluated: &[FilesystemIdentity],
        deadlines: &[TrashRequest],
    ) -> Result<(), String> {
        let started = Instant::now();
        self.inner.update_deadlines(root, evaluated, deadlines)?;
        phases::since("deadlines_delta", started, evaluated.len());
        phases::since("delta_update_deadlines", started, evaluated.len());
        self.shared.pace.delta.store(false, Ordering::Release);
        self.queue_decisions(root)
    }
    fn remove_deadline(&mut self, request: &TrashRequest) -> Result<(), String> {
        self.inner.remove_deadline(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tinyprune_core::rule::{CandidateTimestamps, ItemKind};

    #[test]
    fn dirty_decisions_preempt_full_pages_and_full_pages_read_fresh_candidates() {
        let store = Store::memory_with_flavor(codec::flavor()).unwrap();
        let root = if cfg!(windows) { r"C:\Managed\Tree" } else { "/managed/tree" };
        store.replace_roots(&[root.into()], 0.0).unwrap();
        let path = if cfg!(windows) { format!(r"{root}\item") } else { format!("{root}/item") };
        let candidate = RuleCandidate::new(
            FilesystemIdentity {
                volume: Uuid(1), resource: vec![1], path_hint: path,
                creation_time: Some(0.0), generation: Some(1), is_persistent: true,
            },
            "item".into(), ItemKind::File, CandidateTimestamps::default(),
        );
        store.publish_candidate_subtree(root, std::slice::from_ref(&candidate), 0.0).unwrap();
        let shared = Shared::default();
        let mut decisions = Decisions { job: Some(Decisions::load(root.into(), &store).unwrap()) };
        shared.record_upserts(std::slice::from_ref(&candidate)).unwrap();
        assert!(decisions.advance(&shared, &store, 1.0).unwrap());
        assert!(shared.dirty.lock().unwrap().is_empty());
        assert!(decisions.job.as_ref().unwrap().after.is_none(), "dirty turn advanced full cursor");
        assert_eq!(decisions.job.as_ref().unwrap().processed, 0);

        // Publish newer metadata before resuming the full pass. It must fetch the
        // new candidate instead of restoring the explanation from its old job.
        let mut changed = candidate.clone();
        changed.identity.path_hint.push_str("-new");
        changed.name.push_str("-new");
        store.publish_candidate_subtree(root, &[changed.clone()], 2.0).unwrap();
        assert!(decisions.advance(&shared, &store, 2.0).unwrap());
        let actual = store.latest_decision(&candidate.identity).unwrap().unwrap();
        let current = Decisions::load(root.into(), &store).unwrap();
        let expected = explain_with(&changed, &current.policy, &current.store, 2.0, current.projects.as_ref()).unwrap();
        assert_eq!(actual, serde_json::to_value(expected).unwrap());
        assert!(decisions.advance(&shared, &store, 2.0).unwrap());
        assert!(!decisions.advance(&shared, &store, 2.0).unwrap());
    }

    #[test]
    fn full_page_reloads_policy_revision_before_publication() {
        let mut store = Store::memory_with_flavor(codec::flavor()).unwrap();
        let root = if cfg!(windows) { r"C:\Managed\Tree" } else { "/managed/tree" };
        store.replace_roots(&[root.into()], 0.0).unwrap();
        let mut decisions = Decisions { job: Some(Decisions::load(root.into(), &store).unwrap()) };
        let mut policy = store.load_snapshot().unwrap();
        policy.globally_paused = !policy.globally_paused;
        let (revision, until, retention) = store.runtime_state().unwrap();
        store.replace_policy(&policy, revision, until, retention, 1.0).unwrap();
        let shared = Shared::default();
        assert!(decisions.advance(&shared, &store, 1.0).unwrap());
        assert!(!decisions.advance(&shared, &store, 1.0).unwrap());
        assert_eq!(shared.evaluated.lock().unwrap().get(root), Some(&store.runtime_state().unwrap().0));
    }
}
