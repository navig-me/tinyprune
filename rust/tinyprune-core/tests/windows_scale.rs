//! Windows-flavor scaling: synthetic `C:\Root\DirNNNN\FileNNNNNN.DAT` candidate sets run through the real scheduler.
//!
//! Ignored benchmark: cargo test --release --locked -p tinyprune-core --test windows_scale -- --ignored --nocapture
//! The regular tests assert near-linear growth (time for 2x input stays well below 4x) and that the protected
//! descendant decisions equal a brute-force pairwise `PathFlavor::Windows.is_descendant` reference.
use std::time::Instant;
use tinyprune_core::{path::PathFlavor, rule::*, scheduler::*, uuid::Uuid};

fn candidate(n: usize, path: String, name: String, kind: ItemKind) -> RuleCandidate {
    RuleCandidate::new(
        FilesystemIdentity { volume: Uuid(1), resource: (n as u64).to_be_bytes().to_vec(), path_hint: path, creation_time: None, generation: None, is_persistent: false },
        name,
        kind,
        CandidateTimestamps { modified: Some(0.0), ..Default::default() },
    )
}

#[derive(Clone, Copy, Default)]
struct Shape {
    /// The first file of every directory carries `FILE_ATTRIBUTE_HIDDEN` (protects its ancestors).
    hidden: bool,
    /// Every directory also holds a `package.json` project marker.
    marker: bool,
}

/// `dirs` directories of `per` files each, spelled with backslashes and mixed case.
fn tree(dirs: usize, per: usize, shape: Shape) -> Vec<RuleCandidate> {
    let mut all = Vec::with_capacity(dirs * (per + 2));
    for d in 0..dirs {
        all.push(candidate(all.len(), format!(r"C:\Root\Dir{d:04}"), format!("Dir{d:04}"), ItemKind::Directory));
        if shape.marker {
            all.push(candidate(all.len(), format!(r"C:\Root\Dir{d:04}\Package.JSON"), "Package.JSON".into(), ItemKind::File));
        }
        for f in 0..per {
            let mut item = candidate(all.len(), format!(r"C:\Root\Dir{d:04}\File{f:06}.DAT"), format!("File{f:06}.DAT"), ItemKind::File);
            item.platform_hidden = shape.hidden && f == 0;
            all.push(item);
        }
    }
    all
}

struct Metadata(Vec<RuleCandidate>);
impl MetadataSource for Metadata {
    fn candidates(&self) -> Result<&[RuleCandidate], String> { Ok(&self.0) }
}
#[derive(Default)]
struct Observations { projects: Vec<Project> }
impl ObservationStore for Observations {
    fn observation(&self, _: &FilesystemIdentity) -> Result<Option<Observation>, String> { Ok(None) }
    fn save_observation(&mut self, _: Observation) -> Result<(), String> { Ok(()) }
    fn projects(&self) -> Result<&[Project], String> { Ok(&self.projects) }
    fn publish_projects(&mut self, _: &str, projects: Vec<Project>) -> Result<(), String> { self.projects = projects; Ok(()) }
    fn remove_below(&mut self, _: &str) -> Result<(), String> { Ok(()) }
}
struct At;
impl Clock for At { fn now(&self) -> f64 { 1.0e9 } }

fn rule(basis: ExpiryBasis) -> LifetimeRule {
    LifetimeRule::new(Uuid(2), "bench", RuleScope::new_with_flavor(r"C:\Root", true, PathFlavor::Windows).unwrap(), ItemMatcher::new(ItemKind::File, vec![], vec!["**/*.dat".into()]).unwrap(), basis, RuleDuration(86400.0), None, FolderAction::TrashItem, RuleState::Active, RuleMatchMode::Scoped).unwrap()
}

fn run(candidates: Vec<RuleCandidate>, basis: ExpiryBasis, hidden: bool) -> (Vec<Decision>, f64) {
    let source = Metadata(candidates);
    let rules = [rule(basis)];
    let settings = AgentSettings { path_flavor: PathFlavor::Windows, protect_hidden_files: hidden, ..AgentSettings::new(0.0, true) };
    let mut store = Observations::default();
    let start = Instant::now();
    let decisions = scan(&source, &mut store, &At, &ScanPolicy { root: r"C:\Root", rules: &rules, overrides: &[], settings: &settings }, &[], &[]).unwrap();
    (decisions, start.elapsed().as_secs_f64() * 1000.0)
}

/// Runs the real scan and returns elapsed milliseconds.
fn scan_ms(dirs: usize, per: usize, basis: ExpiryBasis, shape: Shape) -> f64 {
    let (decisions, ms) = run(tree(dirs, per, shape), basis, shape.hidden);
    assert!(decisions.len() >= dirs * (per + 1));
    ms
}

fn best_of(runs: usize, mut f: impl FnMut() -> f64) -> f64 {
    (0..runs).map(|_| f()).fold(f64::INFINITY, f64::min)
}

#[test]
fn windows_scan_with_many_protecting_items_grows_near_linearly() {
    // One hidden file per ten items: the number of protecting items grows with the tree, so a pairwise
    // directory x protecting scan is quadratic (2x input -> ~4x time) while an index stays linear.
    let shape = Shape { hidden: true, marker: false };
    let small = best_of(2, || scan_ms(1_000, 9, ExpiryBasis::Modified, shape));
    let large = best_of(2, || scan_ms(2_000, 9, ExpiryBasis::Modified, shape));
    assert!(large < small * 3.0 + 50.0, "10k items {small:.0} ms, 20k items {large:.0} ms");
}

#[test]
fn windows_protected_descendants_match_pairwise_reference_on_varied_spellings() {
    // The same logical tree with randomly respelled directories and hidden files at mixed depths.
    let spellings = [r"C:\Root", "c:/root", r"\\?\C:\ROOT", r"\\?\c:\Root\.\x\.."];
    let mut all = Vec::new();
    for d in 0..40usize {
        let root = spellings[d % spellings.len()];
        let dir = format!(r"{root}\Group{}\Dir{d}", d % 5);
        all.push(candidate(all.len(), format!(r"{root}\Group{}", d % 5), format!("Group{}", d % 5), ItemKind::Directory));
        all.push(candidate(all.len(), dir.clone(), format!("Dir{d}"), ItemKind::Directory));
        let mut file = candidate(all.len(), format!(r"{dir}\file{d}.dat"), format!("file{d}.dat"), ItemKind::File);
        file.platform_hidden = d % 7 == 0;
        all.push(file);
    }
    let (decisions, _) = run(all.clone(), ExpiryBasis::Modified, true);
    let flavor = PathFlavor::Windows;
    let mut protected = 0;
    for (item, decision) in all.iter().zip(&decisions) {
        let expected = item.kind == ItemKind::Directory
            && all.iter().any(|other| (other.platform_hidden || other.name.starts_with('.')) && flavor.is_descendant(&other.identity.path_hint, &item.identity.path_hint));
        assert_eq!(decision.protected_descendant, expected, "{}", item.identity.path_hint);
        protected += expected as usize;
    }
    assert!(protected > 5 && protected < decisions.len(), "{protected}");
}

#[test]
#[ignore = "benchmark"]
fn bench_windows_scan() {
    let shapes = [("Modified", ExpiryBasis::Modified, Shape::default()), ("Modified+hidden", ExpiryBasis::Modified, Shape { hidden: true, marker: false }), ("FirstObserved", ExpiryBasis::FirstObserved, Shape::default()), ("ProjectActivity+markers", ExpiryBasis::ProjectActivity, Shape { hidden: false, marker: true })];
    for (name, basis, shape) in shapes {
        for total in [25_000usize, 50_000, 100_000] {
            // Fewer, larger directories for the project shape would hide per-project costs; keep ~100 items per directory.
            let per = if shape.marker { 99 } else { 999 };
            println!("windows scan {name:>24} {total:>7} candidates: {:9.1} ms", scan_ms(total / (per + 1), per, basis, shape));
        }
    }
}

#[test]
fn windows_project_activity_matches_pairwise_reference_on_varied_spellings() {
    use tinyprune_core::resolve::Resolution;
    let spell = |k: usize, rest: &str| match k % 4 {
        0 => format!(r"C:\Root\{rest}"),
        1 => format!("c:/ROOT/{}", rest.replace('\\', "/")),
        2 => format!(r"\\?\C:\Root\{rest}"),
        _ => format!(r"C:\ROOT\.\{rest}"),
    };
    let mut all: Vec<RuleCandidate> = Vec::new();
    let push = |all: &mut Vec<RuleCandidate>, path: String, name: &str, kind: ItemKind, modified: f64| {
        let mut item = candidate(all.len(), path, name.into(), kind);
        item.timestamps.modified = Some(modified);
        all.push(item);
    };
    for i in 0..30usize {
        let (a, sub) = (format!("A{i}"), format!(r"A{i}\Sub"));
        push(&mut all, spell(i, &a), &a, ItemKind::Directory, 0.0);
        push(&mut all, spell(i + 1, &sub), "Sub", ItemKind::Directory, 0.0);
        push(&mut all, spell(i + 2, &format!(r"{a}\package.json")), "package.json", ItemKind::File, 100.0 + i as f64);
        push(&mut all, spell(i + 3, &format!(r"{sub}\Cargo.toml")), "Cargo.toml", ItemKind::File, 50.0 + i as f64);
        push(&mut all, spell(i, &format!(r"{a}\x.dat")), "x.dat", ItemKind::File, 1000.0 + 3.0 * i as f64);
        push(&mut all, spell(i + 1, &format!(r"{sub}\y.dat")), "y.dat", ItemKind::File, 10.0 + i as f64);
        push(&mut all, spell(i + 2, &format!(r"{sub}\deep\z.dat")), "z.dat", ItemKind::File, 5000.0 - i as f64);
    }
    push(&mut all, spell(0, r"B\w.dat"), "w.dat", ItemKind::File, 7.0);

    // Reference: pairwise containment with the original rule (longest hint wins, later project wins ties).
    let flavor = PathFlavor::Windows;
    let within = |path: &str, root: &str| flavor.equal(&flavor.normalize(path), &flavor.normalize(root)) || flavor.is_descendant(path, root);
    let mut projects: Vec<(String, f64)> = Vec::new();
    for marker in all.iter().filter(|c| c.name == "package.json" || c.name == "Cargo.toml") {
        let parent = flavor.normalize(&marker.identity.path_hint).rsplit_once('/').unwrap().0.to_owned();
        let directory = all.iter().find(|c| c.kind == ItemKind::Directory && flavor.equal(&flavor.normalize(&c.identity.path_hint), &parent)).expect("marker folder");
        let basis = marker.timestamps.modified.unwrap();
        match projects.iter_mut().find(|(path, _)| *path == directory.identity.path_hint) {
            Some(project) => project.1 = project.1.max(basis),
            None => projects.push((directory.identity.path_hint.clone(), basis)),
        }
    }
    let deepest = |projects: &[(String, f64)], path: &str| projects.iter().enumerate().filter(|(_, (root, _))| within(path, root)).max_by_key(|(_, (root, _))| root.len()).map(|(slot, _)| slot);
    for file in all.iter().filter(|c| c.kind == ItemKind::File) {
        if let Some(slot) = deepest(&projects, &file.identity.path_hint) { projects[slot].1 = projects[slot].1.max(file.timestamps.modified.unwrap()); }
    }

    let mut rule = rule(ExpiryBasis::ProjectActivity);
    rule.scope = RuleScope::new_with_flavor(r"C:\Root", true, flavor).unwrap();
    let settings = AgentSettings { path_flavor: flavor, ..AgentSettings::new(0.0, true) };
    let mut store = Observations::default();
    let source = Metadata(all.clone());
    let rules = [rule];
    let decisions = scan(&source, &mut store, &At, &ScanPolicy { root: r"C:\Root", rules: &rules, overrides: &[], settings: &settings }, &[], &[]).unwrap();
    assert_eq!(store.projects.len(), projects.len());
    let mut compared = 0;
    for (item, decision) in all.iter().zip(&decisions).filter(|(item, _)| item.name.ends_with(".dat")) {
        match (deepest(&projects, &item.identity.path_hint), &decision.resolution) {
            (Some(slot), Resolution::Scheduled(e)) => {
                assert_eq!(e.basis_date, projects[slot].1, "{}", item.identity.path_hint);
                compared += 1;
            }
            (None, resolution) => assert!(!matches!(resolution, Resolution::Scheduled(_)), "{} {resolution:?}", item.identity.path_hint),
            (Some(_), resolution) => panic!("{} {resolution:?}", item.identity.path_hint),
        }
    }
    assert_eq!(compared, 90);
}
