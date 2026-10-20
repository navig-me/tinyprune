//! Synchronous indexing decisions. Schedules are hints, never authorization to Trash.
//! Adapters supply a metadata-only tree snapshot and durable observations; no filesystem I/O occurs here.
use crate::resolve::{resolve, ItemPolicyOverride, Resolution};
use crate::rule::*;
use std::borrow::Cow;
use crate::swiftstr::{canonical_eq, has_prefix};
pub use crate::trash::Clock;

#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    pub identity: FilesystemIdentity,
    pub first: f64,
    pub last: f64,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Project {
    pub identity: FilesystemIdentity,
    pub activity: f64,
}
/// A complete metadata-only snapshot. Enumeration errors must fail the scan, not imply inactivity.
pub trait MetadataSource {
    fn candidates(&self) -> Result<&[RuleCandidate], String>;
}
/// Implementations retain dates by stable identity while refreshing mutable path hints.
/// Publishing projects replaces missing projects inside the scan root and preserves activity maxima.
pub trait ObservationStore {
    fn observation(&self, identity: &FilesystemIdentity) -> Result<Option<Observation>, String>;
    fn save_observation(&mut self, observation: Observation) -> Result<(), String>;
    fn projects(&self) -> Result<&[Project], String>;
    fn publish_projects(&mut self, root: &str, projects: Vec<Project>) -> Result<(), String>;
    fn remove_below(&mut self, path: &str) -> Result<(), String>;
}
#[derive(Clone, Debug)]
pub struct ActivityEvent {
    pub path: String,
    /// Historical replay supplies metadata time, not the wall-clock time of replay.
    pub at: f64,
}
pub struct ScanPolicy<'a> {
    pub root: &'a str,
    pub rules: &'a [LifetimeRule],
    pub overrides: &'a [ItemPolicyOverride],
    pub settings: &'a AgentSettings,
}
#[derive(Debug, PartialEq)]
pub struct Decision {
    pub path: String,
    pub resolution: Resolution,
    /// Separate from resolution: the index does not authorize deleting protected descendants.
    pub protected_descendant: bool,
}
const MARKERS: &[&str] = &[".git", "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "Gemfile", "pom.xml", "build.gradle", "composer.json"];
const IGNORED: &[&str] = &[".git", "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".cache", "dist", "build", "target"];
fn lexical(path: &str, flavor: PathFlavor) -> Cow<'_, str> {
    if flavor == PathFlavor::Posix { Cow::Borrowed(path) } else { Cow::Owned(flavor.normalize(path)) }
}
fn within(path: &str, root: &str, flavor: PathFlavor) -> bool {
    if flavor == PathFlavor::Posix { return canonical_eq(path, root) || has_prefix(path, &(root.to_owned() + "/")); }
    flavor.equal(&flavor.normalize(path), &flavor.normalize(root)) || flavor.is_descendant(path, root)
}
fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("/", |(parent, _)| if parent.is_empty() { "/" } else { parent })
}
fn ignored(path: &str, root: &str, flavor: PathFlavor) -> bool {
    let normalized;
    let normalized_root;
    let (path, root) = if flavor == PathFlavor::Windows {
        normalized = flavor.normalize(path);
        normalized_root = flavor.normalize(root);
        (normalized.as_str(), normalized_root.as_str())
    } else { (path, root) };
    let offset = if within(path, root, flavor) { path.char_indices().nth(root.chars().count()).map_or(path.len(), |(offset, _)| offset) } else { 0 };
    let relative = &path[offset..];
    let mut previous = "";
    for part in relative.split('/') {
        if IGNORED.iter().any(|ignored| flavor.equal(part, ignored)) || (flavor.equal(previous, ".next") && flavor.equal(part, "cache")) { return true; }
        previous = part;
    }
    false
}
pub fn meaningful_activity(path: &str, root: &str) -> bool {
    meaningful_activity_with_flavor(path, root, PathFlavor::Posix)
}
pub fn meaningful_activity_with_flavor(path: &str, root: &str, flavor: PathFlavor) -> bool {
    !ignored(path, root, flavor) && !path.rsplit('/').next().unwrap_or("").to_lowercase().ends_with(".log")
}
fn applies(candidate: &RuleCandidate, rule: &LifetimeRule) -> bool {
    if rule.state == RuleState::Paused { return false; }
    match rule.match_mode {
        RuleMatchMode::Scoped => rule.scope.relative_path(&candidate.identity.path_hint)
            .is_some_and(|relative| rule.matcher.matches_with_flavor(&candidate.name, &relative, candidate.kind, rule.scope.path_flavor)),
        RuleMatchMode::ExactPath | RuleMatchMode::ItemSpecific =>
            rule.scope.path_flavor.equal(&rule.scope.path_flavor.normalize(&candidate.identity.path_hint), &rule.scope.path) &&
            rule.matcher.matches_with_flavor(&candidate.name, &candidate.name, candidate.kind, rule.scope.path_flavor),
        RuleMatchMode::Template => rule.matcher.matches_with_flavor(&candidate.name, &candidate.name, candidate.kind, rule.scope.path_flavor),
    }
}
fn uses(candidate: &RuleCandidate, rules: &[LifetimeRule], bases: &[ExpiryBasis]) -> bool {
    rules.iter().any(|rule| bases.contains(&rule.expiry_basis) && applies(candidate, rule))
}
/// Reconcile a complete scan, then apply ordered activity events and old-path removals.
/// On rename callers scan the new subtree before removing the old path, so refreshed hints survive.
/// Global pause intentionally does not affect indexing; the execution loop must idle while paused.
pub fn scan(
    source: &impl MetadataSource,
    store: &mut impl ObservationStore,
    clock: &impl Clock,
    policy: &ScanPolicy<'_>,
    events: &[ActivityEvent],
    removed: &[String],
) -> Result<Vec<Decision>, String> {
    let candidates = source.candidates()?;
    let now = clock.now();
    let flavor = policy.settings.path_flavor;
    let tracks = policy.rules.iter().any(|rule| rule.expiry_basis == ExpiryBasis::ProjectActivity && rule.state != RuleState::Paused &&
        (rule.match_mode == RuleMatchMode::Template || within(&rule.scope.path, policy.root, flavor) || within(policy.root, &rule.scope.path, flavor)));
    if tracks {
        let mut projects: Vec<Project> = Vec::new();
        for marker in candidates.iter().filter(|candidate| MARKERS.iter().any(|name| flavor.equal(name, &candidate.name)) && !ignored(parent(&lexical(&candidate.identity.path_hint, flavor)), policy.root, flavor)) {
            let marker_path = lexical(&marker.identity.path_hint, flavor);
            let path = parent(&marker_path);
            let Some(directory) = candidates.iter().find(|candidate| flavor.equal(&lexical(&candidate.identity.path_hint, flavor), path) && candidate.kind == ItemKind::Directory) else { continue; };
            let existing = store.observation(&marker.identity)?;
            let basis = if meaningful_activity_with_flavor(&marker.identity.path_hint, policy.root, flavor) { marker.timestamps.modified.unwrap_or(now) }
                else { marker.timestamps.created.or(existing.as_ref().map(|record| record.first)).unwrap_or(now) };
            if let Some(project) = projects.iter_mut().find(|project| project.identity == directory.identity) { project.activity = project.activity.max(basis); }
            else { projects.push(Project { identity: directory.identity.clone(), activity: basis }); }
            store.save_observation(Observation { identity: marker.identity.clone(), first: existing.as_ref().map_or(now, |record| record.first), last: existing.as_ref().map_or(now, |record| record.last) })?;
        }
        for candidate in candidates.iter().filter(|candidate| candidate.kind == ItemKind::File && meaningful_activity_with_flavor(&candidate.identity.path_hint, policy.root, flavor)) {
            if let Some(date) = candidate.timestamps.modified {
                if let Some(project) = projects.iter_mut().filter(|project| within(&candidate.identity.path_hint, &project.identity.path_hint, flavor)).max_by_key(|project| project.identity.path_hint.len()) { project.activity = project.activity.max(date); }
            }
        }
        store.publish_projects(policy.root, projects)?;
    }
    for event in events {
        if tracks && meaningful_activity_with_flavor(&event.path, policy.root, flavor) {
            let mut projects = store.projects()?.to_vec();
            if let Some(project) = projects.iter_mut().filter(|project| within(&event.path, &project.identity.path_hint, flavor)).max_by_key(|project| project.identity.path_hint.len()) { project.activity = project.activity.max(event.at); }
            store.publish_projects(policy.root, projects)?;
        }
    }
    // Candidates that protect their ancestors, found once (O(N x overrides)) instead of rescanning every
    // candidate for every directory (O(dirs x N)).
    let protecting: Vec<&RuleCandidate> = candidates.iter().filter(|child|
        policy.overrides.iter().any(|item| crate::resolve::keep_covers_with_flavor(Some(&child.identity), &child.identity.path_hint, item, None, flavor))
        || (policy.settings.protect_hidden_files && (child.platform_hidden || child.name.starts_with('.')))).collect();
    let mut decisions = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let mut hydrated = candidate.clone();
        if uses(candidate, policy.rules, &[ExpiryBasis::FirstObserved, ExpiryBasis::ObservedActivity]) {
            let old = store.observation(&candidate.identity)?;
            let is_new = old.is_none();
            let mut observation = old.unwrap_or(Observation { identity: candidate.identity.clone(), first: now, last: now });
            observation.identity = candidate.identity.clone();
            let event = events.iter().filter(|event| flavor.equal(&lexical(&event.path, flavor), &lexical(&candidate.identity.path_hint, flavor))).map(|event| event.at).reduce(f64::max);
            if let Some(date) = event { observation.last = observation.last.max(date); }
            else if let Some(date) = candidate.timestamps.modified { observation.last = observation.last.max(date); }
            // A first scan starts at observation time, not historical/future mtime.
            if is_new {
                observation.first = event.unwrap_or(now);
                observation.last = observation.first;
            }
            hydrated.timestamps.first_observed = Some(observation.first);
            hydrated.timestamps.observed_activity = Some(observation.last);
            store.save_observation(observation)?;
        }
        if uses(candidate, policy.rules, &[ExpiryBasis::ProjectActivity]) {
            hydrated.timestamps.project_activity = store.projects()?.iter().filter(|project| within(&candidate.identity.path_hint, &project.identity.path_hint, flavor)).max_by_key(|project| project.identity.path_hint.len()).map(|project| project.activity);
        }
        let protected_descendant = candidate.kind == ItemKind::Directory && protecting.iter().any(|child| flavor.is_descendant(&child.identity.path_hint, &candidate.identity.path_hint));
        decisions.push(Decision { path: candidate.identity.path_hint.clone(), resolution: resolve(&hydrated, policy.rules, policy.overrides, false, policy.settings), protected_descendant });
    }
    for path in removed { store.remove_below(path)?; }
    Ok(decisions)
}
