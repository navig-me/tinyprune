//! The pre-Trash safety sequence, mirroring `TrashCoordinator`.
//!
//! The scheduler index never grants permission to delete. Everything is re-derived from current policy and the
//! current filesystem immediately before a move:
//!
//! ```text
//! update gate -> policy read -> [root/symlink/inspect/hydrate/resolve/deadline] -> descendant walk ->
//! policy re-read -> same checks again -> (walk again if overrides or hidden-file setting changed) ->
//! audit the attempt -> move (identity re-verified by the platform adapter) -> audit the result
//! ```
//!
//! All I/O goes through the traits below so the sequence is deterministic and testable; platform adapters
//! (Trash, symlink checks, walks) live elsewhere. Nothing here performs a permanent delete.

use crate::resolve::*;
use crate::rule::*;
use crate::swiftstr::has_prefix;
use crate::uuid::Uuid;

#[derive(Debug, Clone)]
pub struct PolicySnapshot {
    pub rules: Vec<LifetimeRule>,
    pub overrides: Vec<ItemPolicyOverride>,
    /// Normalized managed-root paths.
    pub managed_roots: Vec<String>,
    pub globally_paused: bool,
    pub settings: AgentSettings,
}

pub trait PolicyStore {
    fn load_snapshot(&mut self) -> Result<PolicySnapshot, String>;
}

/// Overlays persisted activity on a freshly inspected candidate so evaluation sees the indexer's timestamps.
pub trait CandidateHydrator {
    fn hydrate(&mut self, candidate: &RuleCandidate, rules: &[LifetimeRule], now: f64) -> Result<RuleCandidate, String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DescendantProtection {
    None,
    Protected,
    /// The walk hit its entry or time budget before it could prove the folder is free of protected content.
    Indeterminate,
}

#[derive(Debug, Clone, Copy)]
pub struct WalkBudget {
    pub max_entries: usize,
    pub deadline: f64,
}

#[derive(Debug, Clone, Copy)]
pub struct DescendantWalkLimits {
    pub max_entries: usize,
    pub max_duration: f64,
}

impl Default for DescendantWalkLimits {
    fn default() -> Self {
        DescendantWalkLimits { max_entries: 250_000, max_duration: 10.0 }
    }
}

pub trait FileAccess {
    fn inspect(&mut self, path: &str) -> Result<Option<RuleCandidate>, String>;
    /// True when any directory between `root_path` (exclusive) and `path` (exclusive) is a symbolic link.
    fn has_symbolic_link_ancestor(&mut self, path: &str, below_root: &str) -> Result<bool, String>;
    fn has_protected_descendant(
        &mut self,
        path: &str,
        overrides: &[ItemPolicyOverride],
        protect_hidden_files: bool,
        budget: WalkBudget,
    ) -> Result<DescendantProtection, String>;
    /// Moves to the platform Trash, checking `expected_identity` immediately before and after the move.
    /// POSIX rename cannot atomically condition a move on inode identity; adapters must detect races
    /// and report mismatches rather than claim an atomic identity guarantee. Returns the trashed path.
    fn move_to_trash(&mut self, path: &str, expected_identity: &FilesystemIdentity) -> Result<String, String>;
}

pub trait Clock {
    fn now(&self) -> f64;
}

/// Best-effort size metadata; never grants or revokes permission to move.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SizeMeasurement {
    pub bytes: i64,
    pub items: usize,
    /// True when the walk stopped early, so `bytes` is only a lower bound.
    pub truncated: bool,
}

pub trait SizeMeasurer {
    fn measure(&mut self, path: &str) -> Option<SizeMeasurement>;
}

/// Blocks Trash while an app update is being installed. `Ok(false)` means installation is pending.
pub trait UpdateGate {
    fn acquire_trash_permit(&mut self) -> Result<bool, String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuditKind {
    PreviewSkipped,
    NotDue,
    SafetySkipped,
    TrashAttempted,
    MovedToTrash,
    TrashFailed,
}

impl AuditKind {
    pub fn as_str(self) -> &'static str {
        match self {
            AuditKind::PreviewSkipped => "previewSkipped",
            AuditKind::NotDue => "notDue",
            AuditKind::SafetySkipped => "safetySkipped",
            AuditKind::TrashAttempted => "trashAttempted",
            AuditKind::MovedToTrash => "movedToTrash",
            AuditKind::TrashFailed => "trashFailed",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AuditEvent {
    pub occurred_at: f64,
    pub kind: AuditKind,
    pub identity: Option<FilesystemIdentity>,
    pub rule_id: Option<Uuid>,
    pub detail: Option<String>,
    pub bytes: Option<i64>,
    pub item_count: Option<usize>,
}

pub trait AuditSink {
    fn append(&mut self, event: AuditEvent) -> Result<(), String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScheduledSource {
    Rule(Uuid),
    CustomOverride(Uuid),
}

#[derive(Debug, Clone)]
pub struct TrashRequest {
    pub candidate_identity: FilesystemIdentity,
    pub source: ScheduledSource,
    pub scheduled_at: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Previewed,
    NotDue(f64),
    /// Terminal: the candidate must not be trashed under this deadline.
    Skipped(String),
    /// Not terminal: keep the deadline and retry later.
    Deferred(String),
    MovedToTrash { original_path: String, trashed_path: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExecutionError {
    PolicyReadFailed(String),
    FilesystemReadFailed(String),
    AuditWriteFailed(String),
    FilesystemOperationFailed(String),
    /// The item is already in the Trash; `path` is where. The audit record for it could not be written.
    MovedButAuditFailed { path: String, detail: String },
    UpdateInstallationPending,
}

struct Authorization {
    deadline: f64,
    disposition: Disposition,
    rule: Option<LifetimeRule>,
}

struct Cleared {
    candidate: RuleCandidate,
    authorization: Authorization,
}

enum Preflight {
    Cleared(Box<Cleared>),
    Finished(Outcome),
}

pub struct TrashCoordinator<'a> {
    pub policy: &'a mut dyn PolicyStore,
    pub files: &'a mut dyn FileAccess,
    pub audit: &'a mut dyn AuditSink,
    pub clock: &'a dyn Clock,
    pub gate: &'a mut dyn UpdateGate,
    pub hydrator: Option<&'a mut dyn CandidateHydrator>,
    pub sizes: &'a mut dyn SizeMeasurer,
    pub walk_limits: DescendantWalkLimits,
}

impl TrashCoordinator<'_> {
    pub fn execute(&mut self, request: &TrashRequest) -> Result<Outcome, ExecutionError> {
        match self.gate.acquire_trash_permit() {
            Err(error) => return Err(ExecutionError::PolicyReadFailed(format!("update installation gate: {error}"))),
            Ok(false) => {
                self.record_skip("app update installation is pending", request, None)?;
                // A transient installation block is not terminal: the scheduler must retain this deadline.
                return Err(ExecutionError::UpdateInstallationPending);
            }
            Ok(true) => {}
        }

        let snapshot = self.load_snapshot()?;
        let path = snapshot.settings.path_flavor.normalize(&request.candidate_identity.path_hint);
        let initial = match self.preflight(request, &path, &snapshot)? {
            Preflight::Finished(outcome) => return Ok(outcome),
            Preflight::Cleared(cleared) => *cleared,
        };
        if initial.candidate.kind == ItemKind::Directory {
            if let Some(blocked) = self.descendant_outcome(&initial, request, &path, &snapshot)? {
                return Ok(blocked);
            }
        }

        let final_snapshot = self.load_snapshot()?;
        if final_snapshot.settings.path_flavor != snapshot.settings.path_flavor {
            return Ok(Outcome::Deferred("path flavor changed while preparing to move".into()));
        }
        let confirmed = match self.preflight(request, &path, &final_snapshot)? {
            Preflight::Finished(outcome) => return Ok(outcome),
            Preflight::Cleared(cleared) => *cleared,
        };
        if confirmed.authorization.deadline != initial.authorization.deadline || confirmed.authorization.rule != initial.authorization.rule {
            return Ok(Outcome::Deferred("policy or deadline changed while preparing to move".into()));
        }
        if confirmed.candidate.kind == ItemKind::Directory
            && (final_snapshot.overrides != snapshot.overrides || final_snapshot.settings.protect_hidden_files != snapshot.settings.protect_hidden_files)
        {
            if let Some(blocked) = self.descendant_outcome(&confirmed, request, &path, &final_snapshot)? {
                return Ok(blocked);
            }
        }

        let rule_id = confirmed.authorization.rule.as_ref().map(|rule| rule.id);
        let measurement = self.sizes.measure(&path).filter(|measurement| !measurement.truncated);
        self.append(AuditEvent {
            occurred_at: self.clock.now(),
            kind: AuditKind::TrashAttempted,
            identity: Some(request.candidate_identity.clone()),
            rule_id,
            detail: None,
            bytes: None,
            item_count: None,
        })?;
        let trashed_path = match self.files.move_to_trash(&path, &request.candidate_identity) {
            Ok(trashed) => trashed,
            Err(error) => {
                let failed = self.append(AuditEvent {
                    occurred_at: self.clock.now(),
                    kind: AuditKind::TrashFailed,
                    identity: Some(request.candidate_identity.clone()),
                    rule_id,
                    detail: Some(error.clone()),
                    bytes: None,
                    item_count: None,
                });
                if let Err(ExecutionError::AuditWriteFailed(detail)) = failed {
                    return Err(ExecutionError::AuditWriteFailed(format!("Trash failed and failure audit could not be written: {detail}")));
                }
                return Err(ExecutionError::FilesystemOperationFailed(error));
            }
        };
        let moved = AuditEvent {
            occurred_at: self.clock.now(),
            kind: AuditKind::MovedToTrash,
            identity: Some(request.candidate_identity.clone()),
            rule_id,
            detail: Some(trashed_path.clone()),
            bytes: measurement.map(|measurement| measurement.bytes),
            item_count: Some(measurement.map_or(1, |measurement| measurement.items)),
        };
        if let Err(ExecutionError::AuditWriteFailed(detail)) = self.append(moved) {
            return Err(ExecutionError::MovedButAuditFailed { path: trashed_path, detail });
        }
        Ok(Outcome::MovedToTrash { original_path: path, trashed_path })
    }

    /// One complete eligibility decision against a given policy snapshot and the current filesystem state.
    fn preflight(&mut self, request: &TrashRequest, path: &str, snapshot: &PolicySnapshot) -> Result<Preflight, ExecutionError> {
        let finished = |outcome| Ok(Preflight::Finished(outcome));
        if snapshot.globally_paused {
            return finished(Outcome::Deferred("pruning is paused".into()));
        }
        match request.source {
            ScheduledSource::Rule(rule_id) => {
                let Some(rule) = snapshot.rules.iter().find(|rule| rule.id == rule_id) else {
                    return finished(self.record_skip("rule no longer exists", request, None)?);
                };
                if rule.state == RuleState::Paused {
                    return finished(Outcome::Deferred("rule is paused".into()));
                }
            }
            ScheduledSource::CustomOverride(override_id) => {
                let Some(item) = snapshot.overrides.iter().find(|item| item.id == override_id) else {
                    return finished(self.record_skip("custom expiry no longer exists", request, None)?);
                };
                if matches!(item.policy, ItemOverridePolicy::CustomExpiry { state: RuleState::Paused, .. }) {
                    return finished(Outcome::Deferred("custom expiry is paused".into()));
                }
            }
        }

        let flavor = snapshot.settings.path_flavor;
        let Some(root) = snapshot.managed_roots.iter().find(|root| flavor.is_descendant(path, root)) else {
            return finished(self.record_skip("item is outside every managed root", request, None)?);
        };
        match self.files.has_symbolic_link_ancestor(path, &flavor.normalize(root)) {
            Err(error) => return Err(ExecutionError::FilesystemReadFailed(error)),
            Ok(true) => return finished(self.record_skip("item is reached through a symbolic link", request, None)?),
            Ok(false) => {}
        }

        let observed = match self.files.inspect(path) {
            Err(error) => return Err(ExecutionError::FilesystemReadFailed(error)),
            Ok(None) => return finished(self.record_skip("candidate is unavailable", request, None)?),
            Ok(Some(observed)) => observed,
        };
        if observed.identity != request.candidate_identity {
            return finished(self.record_skip("filesystem identity changed", request, None)?);
        }
        let platform_hidden = observed.platform_hidden;
        let now = self.clock.now();
        let mut evaluated = match self.hydrator.as_mut() {
            Some(hydrator) => hydrator
                .hydrate(&observed, &snapshot.rules, now)
                .map_err(|error| ExecutionError::PolicyReadFailed(format!("candidate activity: {error}")))?,
            None => observed,
        };
        evaluated.platform_hidden = platform_hidden;

        let resolution = resolve(&evaluated, &snapshot.rules, &snapshot.overrides, snapshot.globally_paused, &snapshot.settings);
        let Some(authorization) = authorization(request.source, &resolution, snapshot) else {
            let reason = if matches!(resolution, Resolution::Protected { .. }) { "item is protected by Keep" } else { "candidate is no longer eligible" };
            return finished(self.record_skip(reason, request, None)?);
        };
        if authorization.disposition == Disposition::Preview {
            self.append(AuditEvent {
                occurred_at: self.clock.now(),
                kind: AuditKind::PreviewSkipped,
                identity: Some(request.candidate_identity.clone()),
                rule_id: authorization.rule.as_ref().map(|rule| rule.id),
                detail: None,
                bytes: None,
                item_count: None,
            })?;
            return finished(Outcome::Previewed);
        }
        if authorization.deadline != request.scheduled_at {
            return finished(Outcome::Deferred("scheduled deadline changed; waiting for re-index".into()));
        }
        let now = self.clock.now();
        if now < authorization.deadline {
            self.append(AuditEvent {
                occurred_at: now,
                kind: AuditKind::NotDue,
                identity: Some(request.candidate_identity.clone()),
                rule_id: authorization.rule.as_ref().map(|rule| rule.id),
                detail: None,
                bytes: None,
                item_count: None,
            })?;
            return finished(Outcome::NotDue(authorization.deadline));
        }
        if let Some(rule) = &authorization.rule {
            if rule.action != FolderAction::TrashItem {
                return finished(self.record_skip("folder action requires a dedicated executor", request, Some(rule.id))?);
            }
        }
        Ok(Preflight::Cleared(Box::new(Cleared { candidate: evaluated, authorization })))
    }

    /// Returns a terminal/deferred outcome when the folder must not be trashed whole, `None` when it is clear.
    fn descendant_outcome(
        &mut self,
        cleared: &Cleared,
        request: &TrashRequest,
        path: &str,
        snapshot: &PolicySnapshot,
    ) -> Result<Option<Outcome>, ExecutionError> {
        let budget = WalkBudget {
            max_entries: self.walk_limits.max_entries,
            deadline: self.clock.now() + self.walk_limits.max_duration,
        };
        // A dot-named candidate can only reach this point through a rule that targets dot items explicitly.
        let protect_hidden = snapshot.settings.protect_hidden_files && !has_prefix(&cleared.candidate.name, ".");
        match self.files.has_protected_descendant(path, &snapshot.overrides, protect_hidden, budget) {
            Err(error) => Err(ExecutionError::FilesystemReadFailed(error)),
            Ok(DescendantProtection::None) => Ok(None),
            Ok(DescendantProtection::Protected) => {
                Ok(Some(self.record_skip("folder contains a protected descendant", request, cleared.authorization.rule.as_ref().map(|rule| rule.id))?))
            }
            Ok(DescendantProtection::Indeterminate) => Ok(Some(Outcome::Deferred("folder is too large to verify before moving to Trash".into()))),
        }
    }

    fn load_snapshot(&mut self) -> Result<PolicySnapshot, ExecutionError> {
        self.policy.load_snapshot().map_err(ExecutionError::PolicyReadFailed)
    }

    fn record_skip(&mut self, reason: &str, request: &TrashRequest, rule_id: Option<Uuid>) -> Result<Outcome, ExecutionError> {
        self.append(AuditEvent {
            occurred_at: self.clock.now(),
            kind: AuditKind::SafetySkipped,
            identity: Some(request.candidate_identity.clone()),
            rule_id,
            detail: Some(reason.to_string()),
            bytes: None,
            item_count: None,
        })?;
        Ok(Outcome::Skipped(reason.to_string()))
    }

    fn append(&mut self, event: AuditEvent) -> Result<(), ExecutionError> {
        self.audit.append(event).map_err(ExecutionError::AuditWriteFailed)
    }
}

fn authorization(source: ScheduledSource, resolution: &Resolution, snapshot: &PolicySnapshot) -> Option<Authorization> {
    match (source, resolution) {
        (ScheduledSource::Rule(rule_id), Resolution::Scheduled(explanation)) if explanation.rule_id == rule_id => {
            let rule = snapshot.rules.iter().find(|rule| rule.id == rule_id)?;
            Some(Authorization { deadline: explanation.scheduled_at, disposition: explanation.disposition, rule: Some(rule.clone()) })
        }
        (ScheduledSource::CustomOverride(override_id), Resolution::CustomExpiry { override_id: resolved, expires_at, disposition })
            if *resolved == override_id =>
        {
            Some(Authorization { deadline: *expires_at, disposition: *disposition, rule: None })
        }
        _ => None,
    }
}
