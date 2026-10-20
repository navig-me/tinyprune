//! Differential tests: `scan_delta` on a `SnapshotIndex` must leave the store and every decision exactly as a
//! complete `scan` of the updated tree does. A deterministic model filesystem is mutated by random operations;
//! after every step the incremental state is compared with a full pass over a clone of the previous store.
use std::collections::BTreeMap;
use tinyprune_core::resolve::{ItemOverridePolicy, ItemPolicyOverride};
use tinyprune_core::rule::*;
use tinyprune_core::scheduler::*;
use tinyprune_core::uuid::Uuid;

fn within(path: &str, base: &str) -> bool {
    path == base || path.starts_with(&format!("{}/", base.trim_end_matches('/')))
}
fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("/", |(p, _)| p)
}

type StoreView = (Vec<(Vec<u8>, String, f64, f64)>, Vec<(Vec<u8>, String, f64)>);
#[derive(Clone, Default, Debug, PartialEq)]
struct Mem {
    observations: BTreeMap<Vec<u8>, Observation>,
    projects: Vec<Project>,
}
impl Mem {
    /// Order-independent view for equality (hints included, unlike `FilesystemIdentity` equality).
    fn view(&self) -> StoreView {
        let observations = self.observations.iter().map(|(k, o)| (k.clone(), o.identity.path_hint.clone(), o.first, o.last)).collect();
        let mut projects: Vec<_> = self.projects.iter().map(|p| (p.identity.resource.clone(), p.identity.path_hint.clone(), p.activity)).collect();
        projects.sort_by(|a, b| a.0.cmp(&b.0));
        (observations, projects)
    }
}
impl ObservationStore for Mem {
    fn observation(&self, identity: &FilesystemIdentity) -> Result<Option<Observation>, String> {
        Ok(self.observations.get(&identity.resource).filter(|o| o.identity == *identity).cloned())
    }
    fn save_observation(&mut self, o: Observation) -> Result<(), String> {
        let merged = match self.observations.get(&o.identity.resource) {
            Some(old) if old.identity == o.identity => Observation { identity: o.identity.clone(), first: old.first.min(o.first), last: old.last.max(o.last) },
            _ => o,
        };
        self.observations.insert(merged.identity.resource.clone(), merged);
        Ok(())
    }
    fn projects(&self) -> Result<&[Project], String> { Ok(&self.projects) }
    fn publish_projects(&mut self, root: &str, projects: Vec<Project>) -> Result<(), String> {
        let old = std::mem::take(&mut self.projects);
        for p in old.iter().filter(|p| !within(&p.identity.path_hint, root)) { self.projects.push(p.clone()); }
        for p in projects {
            let previous = old.iter().find(|q| q.identity == p.identity).map(|q| q.activity);
            self.projects.retain(|q| q.identity != p.identity);
            self.projects.push(Project { identity: p.identity, activity: previous.map_or(p.activity, |a| a.max(p.activity)) });
        }
        Ok(())
    }
    fn remove_below(&mut self, path: &str) -> Result<(), String> {
        self.observations.retain(|_, o| !within(&o.identity.path_hint, path));
        self.projects.retain(|p| !within(&p.identity.path_hint, path));
        Ok(())
    }
}
struct At(f64);
impl Clock for At {
    fn now(&self) -> f64 { self.0 }
}
struct Snap(Vec<RuleCandidate>);
impl MetadataSource for Snap {
    fn candidates(&self) -> Result<&[RuleCandidate], String> { Ok(&self.0) }
}

#[derive(Clone)]
struct Node { id: u32, dir: bool, modified: f64 }
#[derive(Debug)]
enum Hint { Created(String), Modified(String), Removed(String), Renamed(String, String) }

struct Model {
    fs: BTreeMap<String, Node>,
    next: u32,
    t: f64,
}
impl Model {
    fn new() -> Self {
        let mut model = Self { fs: BTreeMap::new(), next: 1, t: 1.0 };
        model.fs.insert("/r".into(), Node { id: 0, dir: true, modified: 0.0 });
        model
    }
    fn candidate(&self, path: &str) -> Option<RuleCandidate> {
        let node = self.fs.get(path)?;
        Some(RuleCandidate::new(
            FilesystemIdentity { volume: Uuid(1), resource: node.id.to_be_bytes().to_vec(), path_hint: path.into(), creation_time: Some(0.0), generation: None, is_persistent: true },
            path.rsplit('/').next().unwrap().into(),
            if node.dir { ItemKind::Directory } else { ItemKind::File },
            CandidateTimestamps { created: Some(0.0), modified: Some(node.modified), ..Default::default() },
        ))
    }
    fn subtree(&self, path: &str) -> Vec<RuleCandidate> {
        self.fs.keys().filter(|p| within(p, path)).filter_map(|p| self.candidate(p)).collect()
    }
    fn tick(&mut self) -> f64 { self.t += 1.0; self.t }
    fn touch_dir(&mut self, path: &str) {
        let t = self.t;
        if let Some(node) = self.fs.get_mut(parent(path)) { node.modified = t; }
    }
    fn create(&mut self, path: &str, dir: bool) -> Option<Hint> {
        if self.fs.contains_key(path) || !self.fs.get(parent(path)).is_some_and(|n| n.dir) { return None; }
        self.tick();
        let id = self.next;
        self.next += 1;
        self.fs.insert(path.into(), Node { id, dir, modified: self.t });
        self.touch_dir(path);
        Some(Hint::Created(path.into()))
    }
    fn modify(&mut self, path: &str) -> Option<Hint> {
        self.tick();
        let t = self.t;
        let node = self.fs.get_mut(path).filter(|n| !n.dir)?;
        node.modified = t;
        Some(Hint::Modified(path.into()))
    }
    fn remove(&mut self, path: &str) -> Option<Hint> {
        if path == "/r" || !self.fs.contains_key(path) { return None; }
        self.tick();
        self.fs.retain(|p, _| !within(p, path));
        self.touch_dir(path);
        Some(Hint::Removed(path.into()))
    }
    fn rename(&mut self, from: &str, to: &str) -> Option<Hint> {
        if from == "/r" || !self.fs.contains_key(from) || self.fs.contains_key(to) || within(to, from) || !self.fs.get(parent(to)).is_some_and(|n| n.dir) { return None; }
        self.tick();
        let moved: Vec<(String, Node)> = self.fs.iter().filter(|(p, _)| within(p, from)).map(|(p, n)| (p.clone(), n.clone())).collect();
        self.fs.retain(|p, _| !within(p, from));
        for (p, n) in moved { self.fs.insert(format!("{to}{}", &p[from.len()..]), n); }
        self.touch_dir(from);
        self.touch_dir(to);
        Some(Hint::Renamed(from.into(), to.into()))
    }
}

struct Harness {
    model: Model,
    store: Mem,
    index: SnapshotIndex,
    /// Decisions of the incremental side, keyed by item id; must equal a complete pass at every step.
    decisions: BTreeMap<Vec<u8>, Decision>,
    rules: Vec<LifetimeRule>,
    overrides: Vec<ItemPolicyOverride>,
    settings: AgentSettings,
    evaluated: usize,
    log: Vec<String>,
}
fn rule(n: u128, basis: ExpiryBasis, kind: ItemKind, exact: &[&str], globs: &[&str], lifetime: f64) -> LifetimeRule {
    LifetimeRule::new(
        Uuid(n), "rule", RuleScope::new("/r", true).unwrap(),
        ItemMatcher::new(kind, exact.iter().map(|s| s.to_string()).collect(), globs.iter().map(|s| s.to_string()).collect()).unwrap(),
        basis, RuleDuration::new(lifetime).unwrap(), None, FolderAction::TrashItem, RuleState::Active, RuleMatchMode::Scoped,
    ).unwrap()
}
impl Harness {
    fn new(protect_hidden: bool) -> Self {
        let rules = vec![
            rule(1, ExpiryBasis::Modified, ItemKind::File, &[], &["*.tmp"], 50.0),
            rule(2, ExpiryBasis::FirstObserved, ItemKind::FileOrDirectory, &[], &["*.obs"], 40.0),
            rule(3, ExpiryBasis::ObservedActivity, ItemKind::File, &[], &["*.act"], 30.0),
            rule(4, ExpiryBasis::ProjectActivity, ItemKind::Directory, &["node_modules", "build"], &[], 60.0),
            rule(5, ExpiryBasis::Modified, ItemKind::Directory, &[], &["d*"], 70.0),
            rule(6, ExpiryBasis::ProjectActivity, ItemKind::File, &[], &["*.gen"], 80.0),
        ];
        let keep = |id, path: &str| ItemPolicyOverride::new(Uuid(id), None, path, ItemOverridePolicy::Keep { protect_descendants: true });
        let overrides = vec![keep(100, "/r/a/keep"), keep(101, "/r/b/keep")];
        let model = Model::new();
        let mut harness = Self {
            store: Mem::default(),
            index: SnapshotIndex::build(vec![], &ScanPolicy { root: "/r", rules: &rules, overrides: &overrides, settings: &AgentSettings::new(0.0, protect_hidden) }),
            decisions: BTreeMap::new(),
            settings: AgentSettings::new(0.0, protect_hidden),
            rules,
            overrides,
            model,
            evaluated: 0,
            log: vec![],
        };
        harness.rebuild();
        harness
    }
    fn policy(&self) -> ScanPolicy<'_> {
        ScanPolicy { root: "/r", rules: &self.rules, overrides: &self.overrides, settings: &self.settings }
    }
    fn full_candidates(&self) -> Vec<RuleCandidate> { self.model.subtree("/r") }
    /// Complete pass: also the recovery path the agent uses when the policy changes.
    fn rebuild(&mut self) {
        let candidates = self.full_candidates();
        let policy = ScanPolicy { root: "/r", rules: &self.rules, overrides: &self.overrides, settings: &self.settings };
        let decisions = scan(&Snap(candidates.clone()), &mut self.store, &At(self.model.t), &policy, &[], &[]).unwrap();
        self.decisions = candidates.iter().zip(decisions).map(|(c, d)| (c.identity.resource.clone(), d)).collect();
        self.index = SnapshotIndex::build(candidates, &self.policy());
    }
    /// Applies watcher hints both ways and asserts the incremental state equals the complete pass.
    fn step(&mut self, hints: Vec<Hint>) {
        self.log.push(format!("{hints:?} markers={:?}", self.model.fs.keys().filter(|p| p.ends_with(".git") || p.ends_with("package.json") || p.ends_with("Cargo.toml")).collect::<Vec<_>>()));
        let mut scan_paths: Vec<String> = vec![];
        let mut removed: Vec<String> = vec![];
        let mut parents: Vec<String> = vec![];
        let mut events: Vec<ActivityEvent> = vec![];
        for hint in &hints {
            let (path, from) = match hint {
                Hint::Created(p) | Hint::Modified(p) => (p.clone(), None),
                Hint::Removed(p) => (p.clone(), None),
                Hint::Renamed(from, to) => {
                    if self.model.candidate(from).is_none() { removed.push(from.clone()); }
                    parents.push(parent(from).into());
                    (to.clone(), Some(from.clone()))
                }
            };
            let _ = from;
            match self.model.candidate(&path) {
                Some(c) => {
                    events.push(ActivityEvent { path: path.clone(), at: c.timestamps.modified.unwrap() });
                    scan_paths.push(path.clone());
                }
                None => if !removed.contains(&path) { removed.push(path.clone()) },
            }
            if !matches!(hint, Hint::Modified(_)) || self.model.candidate(&path).is_none() { parents.push(parent(&path).into()); }
        }
        scan_paths.sort();
        scan_paths.dedup();
        let kept: Vec<String> = scan_paths.iter().filter(|p| !scan_paths.iter().any(|q| *q != **p && within(p, q))).cloned().collect();
        let refreshed: Vec<RuleCandidate> = parents.iter().filter(|p| within(p, "/r") && !kept.iter().any(|k| within(p, k))).collect::<std::collections::BTreeSet<_>>().into_iter().filter_map(|p| self.model.candidate(p)).collect();

        // Reference: a complete pass over the current tree with the same events and removals.
        let mut reference = self.store.clone();
        let full = self.full_candidates();
        let expected = scan(&Snap(full.clone()), &mut reference, &At(self.model.t), &self.policy(), &events, &removed).unwrap();
        let expected: BTreeMap<Vec<u8>, Decision> = full.iter().zip(expected).map(|(c, d)| (c.identity.resource.clone(), d)).collect();

        // Incremental.
        let rescanned: Vec<(String, Vec<RuleCandidate>)> = kept.iter().map(|p| (p.clone(), self.model.subtree(p))).collect();
        let policy = ScanPolicy { root: "/r", rules: &self.rules, overrides: &self.overrides, settings: &self.settings };
        let outcome = scan_delta(&mut self.index, &mut self.store, &At(self.model.t), &policy, Delta { rescanned, removed: &removed, refreshed, events: &events }).unwrap();
        for identity in &outcome.replaced { self.decisions.remove(&identity.resource); }
        self.evaluated += outcome.decisions.len();
        for (identity, decision) in outcome.decisions { self.decisions.insert(identity.resource, decision); }

        assert_eq!(self.store.view(), reference.view(), "store diverged after {hints:?}; history {:?}", self.log);
        assert_eq!(self.decisions, expected, "decisions diverged");
        let fresh = SnapshotIndex::build(full, &self.policy());
        assert_eq!(format!("{:?}", self.index.candidates().collect::<Vec<_>>()), format!("{:?}", fresh.candidates().collect::<Vec<_>>()));
    }
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize { (self.next() % n as u64) as usize }
}
const FILES: &[&str] = &["f1.tmp", "f2.obs", "f3.act", "keep", "package.json", ".git", "x.log", "note.txt", ".hid", "g.gen", "Cargo.toml"];
const DIRS: &[&str] = &["a", "b", "c", "d1", "d2", "node_modules", "build", "p.obs"];

fn random_ops(seed: u64, steps: usize, protect_hidden: bool) -> usize {
    let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
    let mut h = Harness::new(protect_hidden);
    for _ in 0..steps {
        let mut hints = vec![];
        for _ in 0..=rng.below(3) {
            let dirs: Vec<String> = h.model.fs.iter().filter(|(_, n)| n.dir).map(|(p, _)| p.clone()).collect();
            let all: Vec<String> = h.model.fs.keys().cloned().collect();
            let files: Vec<String> = h.model.fs.iter().filter(|(_, n)| !n.dir).map(|(p, _)| p.clone()).collect();
            let hint = match rng.below(10) {
                0..=3 => {
                    let dir = dirs[rng.below(dirs.len())].clone();
                    let (name, is_dir) = if rng.below(2) == 0 { (DIRS[rng.below(DIRS.len())], true) } else { (FILES[rng.below(FILES.len())], rng.below(8) == 0) };
                    let path = format!("{dir}/{name}");
                    let hint = h.model.create(&path, is_dir);
                    // Burst: a new directory arrives with children.
                    if is_dir && hint.is_some() {
                        for _ in 0..rng.below(4) {
                            let child = format!("{path}/{}", FILES[rng.below(FILES.len())]);
                            h.model.create(&child, false);
                        }
                    }
                    hint
                }
                4..=5 if !files.is_empty() => { let p = files[rng.below(files.len())].clone(); h.model.modify(&p) }
                6..=7 => { let p = all[rng.below(all.len())].clone(); h.model.remove(&p) }
                _ => {
                    let from = all[rng.below(all.len())].clone();
                    let dir = dirs[rng.below(dirs.len())].clone();
                    let name = if rng.below(2) == 0 { DIRS[rng.below(DIRS.len())] } else { FILES[rng.below(FILES.len())] };
                    h.model.rename(&from, &format!("{dir}/{name}"))
                }
            };
            hints.extend(hint);
        }
        h.step(hints);
    }
    h.evaluated
}

#[test]
fn random_event_sequences_match_a_complete_pass() {
    for seed in 1..=24 {
        random_ops(seed, 60, seed % 2 == 0);
    }
}

#[test]
fn incremental_passes_evaluate_far_fewer_candidates_than_a_full_pass() {
    let mut h = Harness::new(false);
    let mut hints = vec![];
    for d in 0..20 {
        hints.extend(h.model.create(&format!("/r/dir{d}"), true));
        for f in 0..50 {
            h.model.create(&format!("/r/dir{d}/f{f}.tmp"), false);
        }
    }
    h.step(hints);
    let before = h.evaluated;
    let hint = h.model.modify("/r/dir3/f7.tmp").unwrap();
    h.step(vec![hint]);
    assert!(h.evaluated - before <= 3, "one modified file evaluated {} candidates", h.evaluated - before);
    let hint = h.model.remove("/r/dir4/f9.tmp").unwrap();
    h.step(vec![hint]);
    assert!(h.evaluated - before <= 8);
}

fn scheduled<'a>(h: &'a Harness, path: &str) -> &'a Decision {
    let id = h.model.fs[path].id.to_be_bytes().to_vec();
    let decision = h.decisions.get(&id).expect("decision");
    assert_eq!(decision.path, path);
    decision
}

#[test]
fn keep_descendant_added_and_removed_flips_ancestor_suppression() {
    let mut h = Harness::new(false);
    let hints: Vec<Hint> = ["/r/a", "/r/a/inner"].iter().flat_map(|p| h.model.create(p, true)).collect();
    h.step(hints);
    assert!(!scheduled(&h, "/r/a").protected_descendant);
    let hint = h.model.create("/r/a/inner/deep", true).unwrap();
    h.step(vec![hint]);
    // The Keep override names /r/a/keep: nothing protects /r/a yet.
    let hint = h.model.create("/r/a/keep", false).unwrap();
    h.step(vec![hint]);
    assert!(scheduled(&h, "/r/a").protected_descendant);
    assert!(!scheduled(&h, "/r/a/inner").protected_descendant);
    let hint = h.model.remove("/r/a/keep").unwrap();
    h.step(vec![hint]);
    assert!(!scheduled(&h, "/r/a").protected_descendant);
    // Renaming a protected item into another directory moves the suppression with it.
    let hint = h.model.create("/r/b", true).unwrap();
    h.step(vec![hint]);
    let hint = h.model.create("/r/b/keep", false).unwrap();
    h.step(vec![hint]);
    assert!(scheduled(&h, "/r/b").protected_descendant);
    let hint = h.model.rename("/r/b/keep", "/r/a/inner/keep").unwrap();
    h.step(vec![hint]);
    assert!(!scheduled(&h, "/r/b").protected_descendant);
}

#[test]
fn hidden_items_protect_ancestors_when_enabled() {
    let mut h = Harness::new(true);
    let hint = h.model.create("/r/c", true).unwrap();
    h.step(vec![hint]);
    let hint = h.model.create("/r/c/.hid", false).unwrap();
    h.step(vec![hint]);
    assert!(scheduled(&h, "/r/c").protected_descendant);
    assert!(scheduled(&h, "/r").protected_descendant);
    let hint = h.model.remove("/r/c/.hid").unwrap();
    h.step(vec![hint]);
    assert!(!scheduled(&h, "/r/c").protected_descendant);
}

fn project_activity(h: &Harness, path: &str) -> Option<f64> {
    h.store.projects.iter().find(|p| p.identity.path_hint == path).map(|p| p.activity)
}

#[test]
fn git_internals_and_logs_are_not_project_activity() {
    let mut h = Harness::new(false);
    let mut hints = vec![];
    for (path, dir) in [("/r/p", true), ("/r/p/package.json", false), ("/r/p/.git", true), ("/r/p/.git/index", false), ("/r/p/src", true), ("/r/p/src/main.gen", false), ("/r/p/x.log", false)] {
        hints.extend(h.model.create(path, dir));
    }
    h.step(hints);
    let base = project_activity(&h, "/r/p").expect("project");
    let hint = h.model.modify("/r/p/.git/index").unwrap();
    h.step(vec![hint]);
    assert_eq!(project_activity(&h, "/r/p"), Some(base), "work inside .git is noise");
    let hint = h.model.modify("/r/p/x.log").unwrap();
    h.step(vec![hint]);
    assert_eq!(project_activity(&h, "/r/p"), Some(base), "log files are noise");
    let hint = h.model.modify("/r/p/src/main.gen").unwrap();
    let at = h.model.t;
    h.step(vec![hint]);
    assert_eq!(project_activity(&h, "/r/p"), Some(at), "source edits move the project");
    // The project-activity file is rescheduled by the move; the stale one is not left behind.
    assert!(matches!(scheduled(&h, "/r/p/src/main.gen").resolution, tinyprune_core::resolve::Resolution::Scheduled(ref e) if e.scheduled_at == at + 80.0));
    // Removing the marker ends the project; recreating it starts a new one from the files below.
    let hint = h.model.remove("/r/p/package.json").unwrap();
    h.step(vec![hint]);
    assert!(project_activity(&h, "/r/p").is_some(), ".git still marks the project");
    let hint = h.model.remove("/r/p/.git").unwrap();
    h.step(vec![hint]);
    assert_eq!(project_activity(&h, "/r/p"), None);
}

#[test]
fn directory_rename_keeps_first_observed_of_descendants() {
    let mut h = Harness::new(false);
    let mut hints = vec![];
    for (path, dir) in [("/r/d1", true), ("/r/d1/inner", true), ("/r/d1/inner/a.obs", false), ("/r/d1/b.obs", false)] {
        hints.extend(h.model.create(path, dir));
    }
    h.step(hints);
    let first = |h: &Harness, path: &str| h.store.observations[&h.model.fs[path].id.to_be_bytes().to_vec()].first;
    let originally = first(&h, "/r/d1/inner/a.obs");
    h.model.t += 500.0;
    let hint = h.model.rename("/r/d1", "/r/d2").unwrap();
    h.step(vec![hint]);
    assert_eq!(first(&h, "/r/d2/inner/a.obs"), originally);
    assert_eq!(h.store.observations[&h.model.fs["/r/d2/b.obs"].id.to_be_bytes().to_vec()].identity.path_hint, "/r/d2/b.obs");
}

#[test]
fn a_policy_change_invalidates_the_index() {
    let mut h = Harness::new(false);
    assert!(h.index.matches(&h.policy()));
    h.settings.protect_hidden_files = true;
    assert!(!h.index.matches(&h.policy()));
    let mut rules = h.rules.clone();
    rules[0].lifetime = RuleDuration(51.0);
    let changed = ScanPolicy { root: "/r", rules: &rules, overrides: &h.overrides, settings: &h.settings };
    assert!(scan_delta(&mut h.index, &mut h.store.clone(), &At(1.0), &changed, Delta { rescanned: vec![], removed: &[], refreshed: vec![], events: &[] }).is_err());
}
