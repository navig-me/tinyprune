//! Synchronous indexing decisions. Schedules are hints, never authorization to Trash.
//! Adapters supply a metadata-only tree snapshot and durable observations; no filesystem I/O occurs here.
use crate::resolve::{resolve, ItemPolicyOverride, Resolution};
use crate::rule::*;
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use crate::swiftstr::{canonical_eq, has_prefix};
use crate::path::{AncestorIndex, ContainerIndex, WindowsKey};
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
fn tracks_projects(policy: &ScanPolicy<'_>) -> bool {
    let flavor = policy.settings.path_flavor;
    policy.rules.iter().any(|rule| rule.expiry_basis == ExpiryBasis::ProjectActivity && rule.state != RuleState::Paused &&
        (rule.match_mode == RuleMatchMode::Template || within(&rule.scope.path, policy.root, flavor) || within(policy.root, &rule.scope.path, flavor)))
}
fn is_marker(candidate: &RuleCandidate, flavor: PathFlavor) -> bool {
    MARKERS.iter().any(|name| flavor.equal(name, &candidate.name))
}
/// Candidates that protect their ancestors (Keep overrides and, when enabled, hidden items).
fn protects_ancestors(child: &RuleCandidate, policy: &ScanPolicy<'_>) -> bool {
    let flavor = policy.settings.path_flavor;
    policy.overrides.iter().any(|item| crate::resolve::keep_covers_with_flavor(Some(&child.identity), &child.identity.path_hint, item, None, flavor))
        || (policy.settings.protect_hidden_files && (child.platform_hidden || child.name.starts_with('.')))
}
fn marker_basis(marker: &RuleCandidate, existing: Option<&Observation>, now: f64, policy: &ScanPolicy<'_>) -> f64 {
    let flavor = policy.settings.path_flavor;
    if meaningful_activity_with_flavor(&marker.identity.path_hint, policy.root, flavor) { marker.timestamps.modified.unwrap_or(now) }
    else { marker.timestamps.created.or(existing.map(|record| record.first)).unwrap_or(now) }
}
/// Windows-only index over a project list answering "which projects contain this path" in O(path depth).
/// It describes one exact project slice: callers ignore it when the slice length no longer matches.
struct ProjectLookup { index: ContainerIndex }
impl ProjectLookup {
    fn new(projects: &[Project], flavor: PathFlavor) -> Option<Self> {
        (flavor == PathFlavor::Windows).then(|| Self { index: ContainerIndex::new(projects.iter().map(|project| WindowsKey::new(&project.identity.path_hint))) })
    }
}
/// Slot of the deepest project containing `path`: the longest path hint wins and the later project wins ties.
fn deepest_project(projects: &[Project], lookup: Option<&ProjectLookup>, scratch: &mut Vec<usize>, path: &str, flavor: PathFlavor) -> Option<usize> {
    match lookup.filter(|lookup| lookup.index.len() == projects.len()) {
        Some(lookup) => {
            lookup.index.containing(&WindowsKey::new(path), scratch);
            scratch.iter().copied().max_by_key(|&slot| projects[slot].identity.path_hint.len())
        }
        None => projects.iter().enumerate().filter(|(_, project)| within(path, &project.identity.path_hint, flavor)).max_by_key(|(_, project)| project.identity.path_hint.len()).map(|(slot, _)| slot),
    }
}
/// Raises the deepest project containing `path` to at least `at`.
fn bump_deepest(projects: &mut [Project], path: &str, at: f64, flavor: PathFlavor) {
    bump_deepest_with(projects, None, &mut Vec::new(), path, at, flavor);
}
fn bump_deepest_with(projects: &mut [Project], lookup: Option<&ProjectLookup>, scratch: &mut Vec<usize>, path: &str, at: f64, flavor: PathFlavor) {
    if let Some(slot) = deepest_project(projects, lookup, scratch, path, flavor) { projects[slot].activity = projects[slot].activity.max(at); }
}
fn apply_event_activity(store: &mut impl ObservationStore, policy: &ScanPolicy<'_>, event: &ActivityEvent) -> Result<(), String> {
    let flavor = policy.settings.path_flavor;
    if meaningful_activity_with_flavor(&event.path, policy.root, flavor) {
        let mut projects = store.projects()?.to_vec();
        bump_deepest(&mut projects, &event.path, event.at, flavor);
        store.publish_projects(policy.root, projects)?;
    }
    Ok(())
}
/// Hydrates one candidate from durable observations and projects and resolves it. Everything a decision depends
/// on besides the candidate itself is passed in, so a full pass and an incremental pass share one definition.
fn decide(candidate: &RuleCandidate, store: &mut impl ObservationStore, now: f64, policy: &ScanPolicy<'_>, events: &[ActivityEvent], protected_descendant: bool) -> Result<Decision, String> {
    decide_with(candidate, store, now, policy, events, protected_descendant, None)
}
fn decide_with(candidate: &RuleCandidate, store: &mut impl ObservationStore, now: f64, policy: &ScanPolicy<'_>, events: &[ActivityEvent], protected_descendant: bool, lookup: Option<&ProjectLookup>) -> Result<Decision, String> {
    let flavor = policy.settings.path_flavor;
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
        let projects = store.projects()?;
        hydrated.timestamps.project_activity = deepest_project(projects, lookup, &mut Vec::new(), &candidate.identity.path_hint, flavor).map(|slot| projects[slot].activity);
    }
    Ok(Decision { path: candidate.identity.path_hint.clone(), resolution: resolve(&hydrated, policy.rules, policy.overrides, false, policy.settings), protected_descendant })
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
    let tracks = tracks_projects(policy);
    if tracks {
        let mut projects: Vec<Project> = Vec::new();
        // Windows: folders by comparison key, so a marker finds its folder with one lookup instead of a scan of
        // the whole snapshot per marker.
        let directories: Option<HashMap<WindowsKey, usize>> = (flavor == PathFlavor::Windows).then(|| {
            let mut map = HashMap::new();
            for (at, candidate) in candidates.iter().enumerate().filter(|(_, candidate)| candidate.kind == ItemKind::Directory) {
                map.entry(WindowsKey::new(&candidate.identity.path_hint)).or_insert(at);
            }
            map
        });
        let mut slots: HashMap<(crate::uuid::Uuid, &[u8]), Vec<usize>> = HashMap::new();
        for marker in candidates.iter().filter(|candidate| is_marker(candidate, flavor) && !ignored(parent(&lexical(&candidate.identity.path_hint, flavor)), policy.root, flavor)) {
            let marker_path = lexical(&marker.identity.path_hint, flavor);
            let path = parent(&marker_path);
            let directory = match &directories {
                Some(map) => map.get(&WindowsKey::from_normalized(path)).map(|&at| &candidates[at]),
                None => candidates.iter().find(|candidate| flavor.equal(&lexical(&candidate.identity.path_hint, flavor), path) && candidate.kind == ItemKind::Directory),
            };
            let Some(directory) = directory else { continue; };
            let existing = store.observation(&marker.identity)?;
            let basis = marker_basis(marker, existing.as_ref(), now, policy);
            let identity_key = (directory.identity.volume, directory.identity.resource.as_slice());
            let known = slots.get(&identity_key).and_then(|found| found.iter().copied().find(|&slot| projects[slot].identity == directory.identity));
            if let Some(slot) = known { projects[slot].activity = projects[slot].activity.max(basis); }
            else {
                slots.entry(identity_key).or_default().push(projects.len());
                projects.push(Project { identity: directory.identity.clone(), activity: basis });
            }
            store.save_observation(Observation { identity: marker.identity.clone(), first: existing.as_ref().map_or(now, |record| record.first), last: existing.as_ref().map_or(now, |record| record.last) })?;
        }
        let lookup = ProjectLookup::new(&projects, flavor);
        let mut scratch = Vec::new();
        for candidate in candidates.iter().filter(|candidate| candidate.kind == ItemKind::File && meaningful_activity_with_flavor(&candidate.identity.path_hint, policy.root, flavor)) {
            if let Some(date) = candidate.timestamps.modified { bump_deepest_with(&mut projects, lookup.as_ref(), &mut scratch, &candidate.identity.path_hint, date, flavor); }
        }
        store.publish_projects(policy.root, projects)?;
    }
    for event in events {
        if tracks { apply_event_activity(store, policy, event)?; }
    }
    // Windows: containing projects are found by walking the candidate's own ancestors (O(depth)) instead of
    // testing every project for every candidate (O(projects)).
    let lookup = if policy.rules.iter().any(|rule| rule.expiry_basis == ExpiryBasis::ProjectActivity) { ProjectLookup::new(store.projects()?, flavor) } else { None };
    // Candidates that protect their ancestors, found once (O(N x overrides)) instead of rescanning every
    // candidate for every directory (O(dirs x N)).
    let protecting: Vec<&RuleCandidate> = candidates.iter().filter(|child| protects_ancestors(child, policy)).collect();
    // Windows: every strict ancestor of a protecting path is recorded once, so each directory is answered by
    // one hash lookup instead of a pairwise `is_descendant` scan over all protecting candidates.
    let ancestors = (flavor == PathFlavor::Windows).then(|| {
        let mut index = AncestorIndex::new();
        for child in &protecting { index.insert(&WindowsKey::new(&child.identity.path_hint)); }
        index
    });
    let mut decisions = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let protected = candidate.kind == ItemKind::Directory && match &ancestors {
            Some(index) => index.has_strict_descendant(&WindowsKey::new(&candidate.identity.path_hint)),
            None => protecting.iter().any(|child| flavor.is_descendant(&child.identity.path_hint, &candidate.identity.path_hint)),
        };
        decisions.push(decide_with(candidate, store, now, policy, events, protected, lookup.as_ref())?);
    }
    for path in removed { store.remove_below(path)?; }
    Ok(decisions)
}

/// Comparison key of a path: equal keys name the same item under the flavor's path rules, and every strict
/// descendant's key sorts in one contiguous range after `key + "/"`.
pub fn path_key(flavor: PathFlavor, path: &str) -> String {
    let normalized = flavor.normalize(path);
    match flavor { PathFlavor::Posix => crate::swiftstr::nfc(&normalized), PathFlavor::Windows => flavor.fold(&normalized) }
}
fn key_parent(flavor: PathFlavor, key: &str) -> Option<String> {
    if flavor.is_root(key) { return None; }
    let index = key.rfind('/')?;
    let parent = &key[..index];
    if parent.is_empty() { return Some("/".into()); }
    if flavor == PathFlavor::Windows && parent.len() == 2 && parent.ends_with(':') { return Some(format!("{parent}/")); }
    Some(parent.into())
}
/// Half-open key range of the strict descendants of `key`.
pub fn descendant_bounds(key: &str) -> (String, String) {
    let base = key.trim_end_matches('/');
    (format!("{base}/"), format!("{base}0"))
}
fn same_candidate(a: &RuleCandidate, b: &RuleCandidate) -> bool {
    a.identity == b.identity && a.identity.path_hint == b.identity.path_hint && a.identity.creation_time == b.identity.creation_time
        && a.identity.generation == b.identity.generation && a.identity.is_persistent == b.identity.is_persistent
        && a.name == b.name && a.kind == b.kind && a.platform_hidden == b.platform_hidden
        && a.timestamps.created == b.timestamps.created && a.timestamps.modified == b.timestamps.modified
        && a.timestamps.first_observed == b.timestamps.first_observed && a.timestamps.observed_activity == b.timestamps.observed_activity
        && a.timestamps.accessed == b.timestamps.accessed && a.timestamps.project_activity == b.timestamps.project_activity
        && a.timestamps.explicit_date == b.timestamps.explicit_date
}
fn policy_print(policy: &ScanPolicy<'_>) -> u64 {
    use std::fmt::Write as _;
    use std::hash::Hasher as _;
    struct Sip(std::collections::hash_map::DefaultHasher);
    impl std::fmt::Write for Sip {
        fn write_str(&mut self, text: &str) -> std::fmt::Result { self.0.write(text.as_bytes()); Ok(()) }
    }
    let mut hasher = Sip(std::collections::hash_map::DefaultHasher::new());
    // Hash semantic inputs only. ItemMatcher's Debug also includes its lazy Windows glob cache:
    // evaluating a rule warms that cache, while decoding the same stored policy constructs a cold
    // cache. Including it made an unchanged Windows policy invalidate every incremental snapshot.
    for rule in policy.rules {
        let _ = write!(hasher, "{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?};",
            rule.id, rule.name, rule.scope, rule.matcher.item_kind,
            rule.matcher.exact_names, rule.matcher.glob_patterns,
            rule.expiry_basis, rule.lifetime, rule.grace_period, rule.action,
            rule.state, rule.match_mode);
    }
    let _ = write!(hasher, "|{:?}|{:?}|{}", policy.overrides, policy.settings, policy.root);
    hasher.0.finish()
}

/// A complete snapshot of one managed root ordered by path, with the dependency indexes that make
/// per-path updates possible: items that protect their ancestors and items whose schedule depends on project
/// activity. It is valid only for the policy it was built under; `matches` detects any change of rules,
/// overrides, settings or root, after which callers must rebuild it from a complete scan.
pub struct SnapshotIndex {
    flavor: PathFlavor,
    print: u64,
    items: BTreeMap<String, RuleCandidate>,
    protecting: BTreeSet<String>,
    project_users: BTreeSet<String>,
}
impl SnapshotIndex {
    pub fn build(candidates: Vec<RuleCandidate>, policy: &ScanPolicy<'_>) -> Self {
        let mut index = Self { flavor: policy.settings.path_flavor, print: policy_print(policy), items: BTreeMap::new(), protecting: BTreeSet::new(), project_users: BTreeSet::new() };
        for candidate in candidates {
            let key = path_key(index.flavor, &candidate.identity.path_hint);
            index.put(key, candidate, policy);
        }
        index
    }
    /// True when this snapshot was built under exactly `policy`.
    pub fn matches(&self, policy: &ScanPolicy<'_>) -> bool {
        self.flavor == policy.settings.path_flavor && self.print == policy_print(policy)
    }
    pub fn len(&self) -> usize { self.items.len() }
    pub fn is_empty(&self) -> bool { self.items.is_empty() }
    /// Candidates in path order.
    pub fn candidates(&self) -> impl Iterator<Item = &RuleCandidate> { self.items.values() }
    /// Drops a path and everything below it, for example after the executor moved it to the Trash.
    pub fn remove_subtree(&mut self, path: &str) {
        let key = path_key(self.flavor, path);
        self.take_subtree(&key);
    }
    fn put(&mut self, key: String, candidate: RuleCandidate, policy: &ScanPolicy<'_>) {
        self.unindex(&key);
        if protects_ancestors(&candidate, policy) { self.protecting.insert(key.clone()); }
        if uses(&candidate, policy.rules, &[ExpiryBasis::ProjectActivity]) { self.project_users.insert(key.clone()); }
        self.items.insert(key, candidate);
    }
    fn unindex(&mut self, key: &str) {
        self.protecting.remove(key);
        self.project_users.remove(key);
    }
    /// Removes `key` and everything below it.
    fn take_subtree(&mut self, key: &str) -> Vec<(String, RuleCandidate)> {
        let (low, high) = descendant_bounds(key);
        let mut keys: Vec<String> = self.items.range(low..high).map(|(k, _)| k.clone()).collect();
        keys.push(key.to_owned());
        let mut taken = Vec::new();
        for key in keys {
            if let Some(candidate) = self.items.remove(&key) {
                self.unindex(&key);
                taken.push((key, candidate));
            }
        }
        taken
    }
    fn has_protecting_descendant(&self, key: &str) -> bool {
        let (low, high) = descendant_bounds(key);
        self.protecting.range(low..high).any(|k| k != key)
    }
    fn project_users_below(&self, key: &str) -> Vec<String> {
        let (low, high) = descendant_bounds(key);
        let mut keys: Vec<String> = self.project_users.range(low..high).cloned().collect();
        if self.project_users.contains(key) && !keys.iter().any(|k| k == key) { keys.push(key.to_owned()); }
        keys
    }
    fn has_marker_child(&self, directory: &RuleCandidate) -> bool {
        let base = directory.identity.path_hint.trim_end_matches(['/', '\\']);
        MARKERS.iter().any(|name| self.items.get(&path_key(self.flavor, &format!("{base}/{name}"))).is_some_and(|c| self.flavor.equal(name, &c.name)))
    }
    fn marker_children(&self, directory: &RuleCandidate) -> Vec<&RuleCandidate> {
        let base = directory.identity.path_hint.trim_end_matches(['/', '\\']);
        MARKERS.iter().filter_map(|name| self.items.get(&path_key(self.flavor, &format!("{base}/{name}"))).filter(|c| self.flavor.equal(name, &c.name))).collect()
    }
}

/// Bounded changes to a [`SnapshotIndex`], produced by watcher hints.
pub struct Delta<'a> {
    /// Complete enumerations of existing subtrees (each path and everything below it).
    pub rescanned: Vec<(String, Vec<RuleCandidate>)>,
    /// Paths confirmed absent (removed, or renamed away); their whole subtrees leave the snapshot.
    pub removed: &'a [String],
    /// Fresh metadata of single existing items whose own metadata a hint may have changed (event parents).
    pub refreshed: Vec<RuleCandidate>,
    pub events: &'a [ActivityEvent],
}
#[derive(Debug, Default)]
pub struct DeltaOutcome {
    /// Decisions of every re-evaluated candidate, with the identity each belongs to.
    pub decisions: Vec<(FilesystemIdentity, Decision)>,
    /// Identities of snapshot items that vanished or were replaced; their schedules must be re-derived.
    pub replaced: Vec<FilesystemIdentity>,
}

/// Applies `delta` to `index` and re-evaluates exactly the candidates whose decision can differ from a complete
/// [`scan`] of the updated snapshot: changed items, their ancestors (protected descendants), items hydrated by a
/// project whose activity changed, and items named by activity events. Store effects match a full pass:
/// observations are refreshed and projects republished before old paths are removed.
pub fn scan_delta(
    index: &mut SnapshotIndex,
    store: &mut impl ObservationStore,
    clock: &impl Clock,
    policy: &ScanPolicy<'_>,
    delta: Delta<'_>,
) -> Result<DeltaOutcome, String> {
    if !index.matches(policy) { return Err("snapshot index was built for a different policy".into()); }
    let flavor = index.flavor;
    let now = clock.now();
    let mut old: HashMap<String, RuleCandidate> = HashMap::new();
    let mut anchors: Vec<String> = Vec::new();
    for path in delta.rescanned.iter().map(|(path, _)| path).chain(delta.removed) {
        let key = path_key(flavor, path);
        for (taken, candidate) in index.take_subtree(&key) { old.insert(taken, candidate); }
        anchors.push(key);
    }
    let mut changed: BTreeSet<String> = BTreeSet::new();
    let mut present: HashSet<String> = HashSet::new();
    for (_, scanned) in delta.rescanned {
        for candidate in scanned {
            let key = path_key(flavor, &candidate.identity.path_hint);
            if !old.get(&key).is_some_and(|previous| same_candidate(previous, &candidate)) { changed.insert(key.clone()); }
            present.insert(key.clone());
            index.put(key, candidate, policy);
        }
    }
    let mut replaced: Vec<FilesystemIdentity> = Vec::new();
    let mut gone: Vec<(String, RuleCandidate)> = Vec::new();
    for (key, previous) in old {
        if !present.contains(&key) { gone.push((key, previous)); }
        else if changed.contains(&key) { replaced.push(previous.identity); }
    }
    replaced.extend(gone.iter().map(|(_, candidate)| candidate.identity.clone()));
    for candidate in delta.refreshed {
        let key = path_key(flavor, &candidate.identity.path_hint);
        if index.items.get(&key).is_some_and(|current| !same_candidate(current, &candidate)) {
            if let Some(current) = index.items.get(&key) { replaced.push(current.identity.clone()); }
            changed.insert(key.clone());
            index.put(key, candidate, policy);
        }
    }
    let mut evaluate: BTreeSet<String> = changed.clone();
    // Ancestors: a protecting descendant appearing or leaving flips their protected-descendant status.
    let climb = |from: &str, evaluate: &mut BTreeSet<String>| {
        let mut next = key_parent(flavor, from);
        while let Some(key) = next {
            if !evaluate.insert(key.clone()) { break; }
            next = key_parent(flavor, &key);
        }
    };
    for key in changed.iter().chain(gone.iter().map(|(key, _)| key)).chain(&anchors) { climb(key, &mut evaluate); }
    for event in delta.events { evaluate.insert(path_key(flavor, &event.path)); }
    if tracks_projects(policy) {
        let changed_gone: Vec<&RuleCandidate> = gone.iter().map(|(_, candidate)| candidate).collect();
        for directory in update_projects(index, store, now, policy, &changed, &changed_gone, delta.events)? {
            evaluate.extend(index.project_users_below(&directory));
        }
    }
    let mut outcome = DeltaOutcome { decisions: Vec::with_capacity(evaluate.len()), replaced };
    for key in &evaluate {
        let Some(candidate) = index.items.get(key) else { continue; };
        let protected = candidate.kind == ItemKind::Directory && index.has_protecting_descendant(key);
        outcome.decisions.push((candidate.identity.clone(), decide(candidate, store, now, policy, delta.events, protected)?));
    }
    for path in delta.removed { store.remove_below(path)?; }
    Ok(outcome)
}

/// Brings the stored projects in line with the changed snapshot as a complete pass would and returns the
/// path keys of every project directory whose identity, path or activity moved (including removed projects).
fn update_projects(
    index: &SnapshotIndex,
    store: &mut impl ObservationStore,
    now: f64,
    policy: &ScanPolicy<'_>,
    changed: &BTreeSet<String>,
    gone: &[&RuleCandidate],
    events: &[ActivityEvent],
) -> Result<Vec<String>, String> {
    let flavor = index.flavor;
    let before = store.projects()?.to_vec();
    let mut list = before.clone();
    let key_of = |project: &Project| path_key(flavor, &project.identity.path_hint);
    let changed_items: Vec<(&String, &RuleCandidate)> = changed.iter().filter_map(|key| index.items.get(key).map(|candidate| (key, candidate))).collect();
    // A renamed or replaced directory keeps its project by identity and refreshes its path hint.
    for (_, candidate) in changed_items.iter().filter(|(_, candidate)| candidate.kind == ItemKind::Directory) {
        for project in list.iter_mut().filter(|project| project.identity == candidate.identity) { project.identity = candidate.identity.clone(); }
    }
    let mut touched: BTreeSet<String> = BTreeSet::new();
    for candidate in gone {
        let key = path_key(flavor, &candidate.identity.path_hint);
        touched.extend(key_parent(flavor, &key));
        touched.insert(key);
    }
    for (key, candidate) in &changed_items {
        if candidate.kind == ItemKind::Directory { touched.insert((*key).clone()); }
        if is_marker(candidate, flavor) { touched.extend(key_parent(flavor, key)); }
    }
    let mut orphaned: Vec<Project> = Vec::new();
    list.retain(|project| {
        let key = key_of(project);
        let valid = !touched.contains(&key) || index.items.get(&key).is_some_and(|directory|
            directory.kind == ItemKind::Directory && directory.identity == project.identity
            && !ignored(&lexical(&directory.identity.path_hint, flavor), policy.root, flavor) && index.has_marker_child(directory));
        if !valid { orphaned.push(project.clone()); }
        valid
    });
    // Projects gained through new or changed markers and replaced directories.
    let mut directories: BTreeSet<String> = BTreeSet::new();
    for (key, candidate) in &changed_items {
        if candidate.kind == ItemKind::Directory { directories.insert((*key).clone()); }
        if is_marker(candidate, flavor) { directories.extend(key_parent(flavor, key)); }
    }
    let mut created: Vec<String> = Vec::new();
    for key in &directories {
        let Some(directory) = index.items.get(key) else { continue; };
        if directory.kind != ItemKind::Directory || ignored(&lexical(&directory.identity.path_hint, flavor), policy.root, flavor) { continue; }
        for marker in index.marker_children(directory) {
            let existing = store.observation(&marker.identity)?;
            let basis = marker_basis(marker, existing.as_ref(), now, policy);
            if let Some(project) = list.iter_mut().find(|project| project.identity == directory.identity) { project.activity = project.activity.max(basis); }
            else {
                list.push(Project { identity: directory.identity.clone(), activity: basis });
                created.push(key.clone());
            }
            store.save_observation(Observation { identity: marker.identity.clone(), first: existing.as_ref().map_or(now, |record| record.first), last: existing.as_ref().map_or(now, |record| record.last) })?;
        }
    }
    // Activity of changed files, and of every file a new project adopts or a removed project releases.
    for (_, candidate) in &changed_items {
        if candidate.kind == ItemKind::File && meaningful_activity_with_flavor(&candidate.identity.path_hint, policy.root, flavor) {
            if let Some(date) = candidate.timestamps.modified { bump_deepest(&mut list, &candidate.identity.path_hint, date, flavor); }
        }
    }
    let reassigned: Vec<String> = created.into_iter().chain(orphaned.iter().map(key_of)).collect();
    for key in reassigned {
        let (low, high) = descendant_bounds(&key);
        for candidate in index.items.range(low..high).map(|(_, candidate)| candidate) {
            if candidate.kind == ItemKind::File && meaningful_activity_with_flavor(&candidate.identity.path_hint, policy.root, flavor) {
                if let Some(date) = candidate.timestamps.modified { bump_deepest(&mut list, &candidate.identity.path_hint, date, flavor); }
            }
        }
    }
    for event in events { if meaningful_activity_with_flavor(&event.path, policy.root, flavor) { bump_deepest(&mut list, &event.path, event.at, flavor); } }
    let mut dirty: Vec<String> = Vec::new();
    for project in &list {
        if !before.iter().any(|old| old.identity == project.identity && old.identity.path_hint == project.identity.path_hint && old.activity == project.activity) { dirty.push(key_of(project)); }
    }
    for old in &before {
        if !list.iter().any(|project| project.identity == old.identity) { dirty.push(key_of(old)); }
    }
    if !dirty.is_empty() { store.publish_projects(policy.root, list)?; }
    Ok(dirty)
}
