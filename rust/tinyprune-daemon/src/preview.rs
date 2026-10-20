use crate::{codec, explanation};
use std::{collections::HashMap, fs, time::Instant};
use tinyprune_core::{
    resolve::ItemOverridePolicy,
    rule::*,
    scheduler::{self, MetadataSource, Observation, ObservationStore, Project, ScanPolicy},
    trash::{Clock, DescendantProtection, FileAccess, PolicySnapshot, WalkBudget},
};
use tinyprune_ipc as d;
use tinyprune_scan::{CancellationToken, EntryOutcome, ScanOptions};
use tinyprune_store::Store;
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
// A read-only durable handle plus in-memory writes: Preview cannot mutate SQLite.
struct ReadOnly {
    store: Store,
    observations: HashMap<(tinyprune_core::uuid::Uuid, Vec<u8>), Observation>,
    projects: Vec<Project>,
}
impl ObservationStore for ReadOnly {
    fn observation(&self, identity: &FilesystemIdentity) -> Result<Option<Observation>, String> {
        match self
            .observations
            .get(&(identity.volume, identity.resource.clone()))
        {
            Some(value) => Ok(Some(value.clone())),
            None => self.store.observation(identity),
        }
    }
    fn save_observation(&mut self, value: Observation) -> Result<(), String> {
        self.observations.insert(
            (value.identity.volume, value.identity.resource.clone()),
            value,
        );
        Ok(())
    }
    fn projects(&self) -> Result<&[Project], String> {
        Ok(&self.projects)
    }
    fn publish_projects(&mut self, root: &str, projects: Vec<Project>) -> Result<(), String> {
        self.projects.retain(|p| {
            !codec::flavor().equal(&p.identity.path_hint, root)
                && !codec::flavor().is_descendant(&p.identity.path_hint, root)
        });
        self.projects.extend(projects);
        Ok(())
    }
    fn remove_below(&mut self, _: &str) -> Result<(), String> {
        Err("Preview cannot remove observations".into())
    }
}
pub(crate) fn run(
    mut rule: LifetimeRule,
    mut policy: PolicySnapshot,
    store: Store,
    now: f64,
    cancellation: CancellationToken,
) -> Result<d::RulePreview, String> {
    let start = Instant::now();
    rule.state = RuleState::Preview;
    let options = ScanOptions {
        include_root: matches!(
            rule.match_mode,
            RuleMatchMode::ExactPath | RuleMatchMode::ItemSpecific
        ),
        max_depth: match rule.match_mode {
            RuleMatchMode::ExactPath | RuleMatchMode::ItemSpecific => Some(0),
            RuleMatchMode::Scoped if !rule.scope.recursive => Some(1),
            _ => None,
        },
        ..ScanOptions::default()
    };
    let mut cursor = tinyprune_scan::preview(&rule.scope.path, options, cancellation)?;
    let mut candidates = vec![];
    let mut scanned_entries = 0;
    let truncated;
    loop {
        let batch = cursor.next_batch();
        if batch.partial {
            return Err(
                "Preview traversal incomplete; check permissions and root availability".into(),
            );
        }
        scanned_entries += batch.entries.len() as u64;
        for entry in batch.entries {
            if let EntryOutcome::Candidate(candidate) = entry.outcome {
                candidates.push(candidate);
            }
        }
        if batch.finished {
            truncated = batch.truncated || batch.cancelled;
            break;
        }
    }
    let projects = store.projects()?.to_vec();
    let mut observations = ReadOnly {
        store,
        observations: HashMap::new(),
        projects,
    };
    policy.rules = vec![rule.clone()];
    for value in &mut policy.overrides {
        if let ItemOverridePolicy::CustomExpiry { state, .. } = &mut value.policy {
            *state = RuleState::Preview;
        }
    }
    let snapshot = Snapshot(candidates);
    let decisions = scheduler::scan(
        &snapshot,
        &mut observations,
        &At(now),
        &ScanPolicy {
            root: &rule.scope.path,
            rules: &policy.rules,
            overrides: &policy.overrides,
            settings: &policy.settings,
        },
        &[],
        &[],
    )?;
    let mut result = d::RulePreview {
        matches: 0,
        eligible_now: 0,
        estimated_bytes: 0,
        scanned_entries,
        truncated,
        duration_seconds: 0.0,
        samples: vec![],
    };
    #[cfg(unix)]
    let mut files = crate::NativeFiles::new(std::env::temp_dir());
    #[cfg(windows)]
    let mut files = crate::NativeFiles::default();
    for (candidate, decision) in snapshot.0.iter().zip(decisions) {
        let project = observations
            .projects
            .iter()
            .filter(|p| {
                codec::flavor().equal(&candidate.identity.path_hint, &p.identity.path_hint)
                    || codec::flavor()
                        .is_descendant(&candidate.identity.path_hint, &p.identity.path_hint)
            })
            .max_by_key(|p| p.identity.path_hint.len());
        let mut e = explanation(candidate, &policy, decision.resolution, project)?;
        let mut protected = decision.protected_descendant;
        // A depth-limited scan does not enumerate children; ask the platform walker (read-only).
        if !protected && e.scheduled_at.is_some() && candidate.kind == ItemKind::Directory {
            protected = files.has_protected_descendant(
                &candidate.identity.path_hint,
                &policy.overrides,
                policy.settings.protect_hidden_files,
                WalkBudget {
                    max_entries: 250_000,
                    deadline: now + 10.0,
                },
            )? != DescendantProtection::None;
        }
        if protected {
            e.suppression_reason = Some(d::Suppression::ProtectedDescendant);
        }
        if let Some(at) = e.scheduled_at {
            result.matches += 1;
            if at <= now && e.suppression_reason.is_none() {
                result.eligible_now += 1;
            }
            let bytes = fs::symlink_metadata(&candidate.identity.path_hint)
                .ok()
                .filter(|m| m.is_file())
                .map(|m| m.len());
            result.estimated_bytes = result.estimated_bytes.saturating_add(bytes.unwrap_or(0));
            if result.samples.len() < 100 {
                result.samples.push(d::PreviewSample {
                    explanation: e,
                    bytes,
                });
            }
        }
    }
    result.duration_seconds = start.elapsed().as_secs_f64();
    Ok(result)
}
pub(crate) fn size(path: &str) -> Result<(u64, u64, bool), String> {
    let mut cursor = tinyprune_scan::preview(
        path,
        ScanOptions {
            total_entries: Some(250_000),
            ..ScanOptions::default()
        },
        CancellationToken::default(),
    )?;
    let mut bytes: u64 = 0;
    let mut items = 0;
    loop {
        let batch = cursor.next_batch();
        if batch.partial {
            return Err("Size traversal incomplete".into());
        }
        for entry in batch.entries {
            if matches!(entry.outcome, EntryOutcome::Candidate(_)) {
                let metadata = fs::symlink_metadata(entry.path).map_err(|e| e.to_string())?;
                items += 1;
                if metadata.is_file() {
                    bytes = bytes.saturating_add(metadata.len());
                }
            }
        }
        if batch.finished {
            return Ok((bytes, items, batch.truncated || batch.cancelled));
        }
    }
}
