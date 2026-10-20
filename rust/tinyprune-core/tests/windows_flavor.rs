//! Windows-only semantics have no Swift fixture counterpart; these tests run without native I/O.
use tinyprune_core::{path::PathFlavor, resolve::*, roots::*, rule::*, trash::*, uuid::Uuid};

fn item(path: &str) -> RuleCandidate {
    RuleCandidate::new(FilesystemIdentity { volume: Uuid(1), resource: vec![1], path_hint: path.into(), creation_time: None, generation: None, is_persistent: false }, "Report.TXT".into(), ItemKind::File, CandidateTimestamps { modified: Some(0.0), ..Default::default() })
}
fn rule(path: &str, flavor: PathFlavor) -> LifetimeRule {
    LifetimeRule::new(Uuid(2), "expire", RuleScope::new_with_flavor(path, true, flavor).unwrap(), ItemMatcher::new(ItemKind::File, vec![], vec!["*.txt".into()]).unwrap(), ExpiryBasis::Modified, RuleDuration(1.0), None, FolderAction::TrashItem, RuleState::Active, RuleMatchMode::Scoped).unwrap()
}
fn settings() -> AgentSettings { AgentSettings { path_flavor: PathFlavor::Windows, ..AgentSettings::new(0.0, true) } }

#[test]
fn lexical_windows_roots_and_separators() {
    let f = PathFlavor::Windows;
    for (input, expected) in [(r"C:\Data\a\..\file", "C:/Data/file"), (r"\\?\C:\Data\.\file", "C:/Data/file"), (r"\\?\UNC\Server\Share\..\file", "//Server/Share/file"), (r"C:\..\..", "C:/"), (r"\\server\share\a\..\..", "//server/share")] {
        assert_eq!(f.normalize(input), expected);
    }
    for invalid in [r"C:relative", r"\rooted", "relative", r"\\server", r"\\.\C:\file"] { assert!(!f.is_absolute(invalid), "{invalid}"); }
    assert!(f.equal("Σ/é", "ς/É"));
    assert!(!f.equal("ß", "ss"));
    assert!(!f.equal("é", "e\u{301}"));
    assert_eq!(PathFlavor::default(), PathFlavor::Posix);
    assert_eq!(PathFlavor::Posix.normalize(r"C:\A"), r"/C:\A");
}

#[test]
fn scope_matching_and_keep_use_windows_flavor() {
    let f = PathFlavor::Windows;
    let scoped = rule(r"C:\Data", f);
    let candidate = item(r"\\?\c:\DATA\Report.TXT");
    assert!(matches!(evaluate(&candidate, &scoped, &settings()), Evaluation::Scheduled(_)));
    assert_eq!(scoped.scope.relative_path(r"c:/data/Child/File"), Some("Child/File".into()));
    assert_eq!(scoped.scope.relative_path(r"c:/database/File"), None);
    assert_eq!(scoped.scope.relative_path(r"D:/data/File"), None);
    let scope = RuleScope::new_with_flavor(r"\\SERVER\Share\Data", false, f).unwrap();
    assert_eq!(scope.relative_path(r"//server/share/data/FILE"), Some("FILE".into()));
    assert_eq!(scope.relative_path(r"//server/share/data/sub/FILE"), None);
    let keep = ItemPolicyOverride::new_with_flavor(Uuid(3), None, r"c:\data", ItemOverridePolicy::Keep { protect_descendants: true }, f);
    assert!(matches!(resolve(&candidate, std::slice::from_ref(&scoped), &[keep], false, &settings()), Resolution::Protected { .. }));
    let mut exact = scoped;
    exact.match_mode = RuleMatchMode::ExactPath;
    exact.scope = RuleScope::new_with_flavor(r"C:\Data\REPORT.txt", false, f).unwrap();
    assert!(matches!(resolve(&candidate, &[exact], &[], false, &settings()), Resolution::Scheduled(_)));
    let matcher = ItemMatcher::new(ItemKind::File, vec![], vec![r"SUB\*.TXT".into()]).unwrap();
    assert!(matcher.matches_with_flavor("file.txt", "sub/file.txt", ItemKind::File, f));
}

struct Resolver;
impl PathResolver for Resolver {
    fn canonical_path(&self, path: &str) -> String { if path == "C:/alias" { r"C:\Windows\System32".into() } else { path.into() } }
    fn home_directories(&self) -> &[String] { &[] }
}
struct Homes(Vec<String>);
impl PathResolver for Homes {
    fn canonical_path(&self, path: &str) -> String { path.into() }
    fn home_directories(&self) -> &[String] { &self.0 }
}
#[test]
fn managed_root_safety_uses_windows_and_resolved_paths() {
    let f = PathFlavor::Windows;
    for path in [r"C:\", r"D:\Windows", r"c:\WINDOWS\System32", r"C:\Program Files", r"C:\Program Files (x86)\app", "C:/alias", r"\\server\share"] {
        assert_eq!(validate_root_with_flavor("root", path, b"grant", &Resolver, f), Err("dangerousPath"), "{path}");
    }
    let homes = Homes(vec![r"C:\Users\Person".into()]);
    assert_eq!(validate_root_with_flavor("root", r"c:\USERS\person", b"grant", &homes, f), Err("dangerousPath"));
    assert_eq!(validate_root_with_flavor("root", r"C:\Users\Person\Downloads", b"grant", &homes, f), Ok(()));
    assert_eq!(validate_root_with_flavor("root", r"C:\Windows-old", b"grant", &Resolver, f), Ok(()));
    assert_eq!(validate_root_with_flavor("root", "C:relative", b"grant", &Resolver, f), Err("invalidPath"));
}

struct Store(PolicySnapshot);
impl PolicyStore for Store { fn load_snapshot(&mut self) -> Result<PolicySnapshot, String> { Ok(self.0.clone()) } }
struct Files { candidate: RuleCandidate, inspections: usize, hide_on: usize, moves: usize }
impl FileAccess for Files {
    fn inspect(&mut self, _: &str) -> Result<Option<RuleCandidate>, String> { self.inspections += 1; let mut candidate = self.candidate.clone(); candidate.platform_hidden = self.inspections >= self.hide_on; Ok(Some(candidate)) }
    fn has_symbolic_link_ancestor(&mut self, _: &str, _: &str) -> Result<bool, String> { Ok(false) }
    fn has_protected_descendant(&mut self, _: &str, _: &[ItemPolicyOverride], _: bool, _: WalkBudget) -> Result<DescendantProtection, String> { Ok(DescendantProtection::None) }
    fn move_to_trash(&mut self, _: &str, _: &FilesystemIdentity) -> Result<String, String> { self.moves += 1; Ok("Recycle Bin/item".into()) }
}
struct ClockStub;
impl Clock for ClockStub { fn now(&self) -> f64 { 10.0 } }
struct Gate;
impl UpdateGate for Gate { fn acquire_trash_permit(&mut self) -> Result<bool, String> { Ok(true) } }
struct Audit;
impl AuditSink for Audit { fn append(&mut self, _: AuditEvent) -> Result<(), String> { Ok(()) } }
struct Sizes;
impl SizeMeasurer for Sizes { fn measure(&mut self, _: &str) -> Option<SizeMeasurement> { None } }
struct Hydrator;
impl CandidateHydrator for Hydrator { fn hydrate(&mut self, candidate: &RuleCandidate, _: &[LifetimeRule], _: f64) -> Result<RuleCandidate, String> { let mut candidate = candidate.clone(); candidate.platform_hidden = false; Ok(candidate) } }

#[test]
fn preflight_honors_fresh_hidden_attributes_and_preserves_them_through_hydration() {
    for (protect, hide_on, expected_moves) in [(true, 1, 0), (true, 2, 0), (false, 1, 1), (true, usize::MAX, 1)] {
        let candidate = item(r"c:\DATA\Report.TXT");
        let mut files = Files { candidate: candidate.clone(), inspections: 0, hide_on, moves: 0 };
        let mut settings = settings(); settings.protect_hidden_files = protect;
        let mut store = Store(PolicySnapshot { rules: vec![rule(r"C:\Data", PathFlavor::Windows)], overrides: vec![], managed_roots: vec![r"C:\Data".into()], globally_paused: false, settings });
        let request = TrashRequest { candidate_identity: candidate.identity, source: ScheduledSource::Rule(Uuid(2)), scheduled_at: 1.0 };
        let outcome = TrashCoordinator { policy: &mut store, files: &mut files, audit: &mut Audit, clock: &ClockStub, gate: &mut Gate, hydrator: Some(&mut Hydrator), sizes: &mut Sizes, walk_limits: DescendantWalkLimits::default() }.execute(&request).unwrap();
        assert_eq!(files.moves, expected_moves, "{outcome:?}");
    }
}

#[test]
fn platform_hidden_defaults_false_and_matches_dot_protection() {
    let mut candidate = item("/data/Report.TXT");
    assert!(!candidate.platform_hidden);
    let mut rule = rule("/data", PathFlavor::Posix);
    rule.matcher = ItemMatcher::new(ItemKind::File, vec![], vec![]).unwrap();
    candidate.platform_hidden = true;
    assert_eq!(evaluate(&candidate, &rule, &AgentSettings::new(0.0, true)), Evaluation::Suppressed(Suppression::HiddenProtected));
    candidate.name = ".target".into();
    rule.matcher = ItemMatcher::new(ItemKind::File, vec![".target".into()], vec![]).unwrap();
    assert!(matches!(evaluate(&candidate, &rule, &AgentSettings::new(0.0, true)), Evaluation::Scheduled(_)));
}

struct Metadata(Vec<RuleCandidate>);
impl tinyprune_core::scheduler::MetadataSource for Metadata {
    fn candidates(&self) -> Result<&[RuleCandidate], String> { Ok(&self.0) }
}
#[derive(Default)]
struct Observations { records: Vec<tinyprune_core::scheduler::Observation>, projects: Vec<tinyprune_core::scheduler::Project> }
impl tinyprune_core::scheduler::ObservationStore for Observations {
    fn observation(&self, identity: &FilesystemIdentity) -> Result<Option<tinyprune_core::scheduler::Observation>, String> { Ok(self.records.iter().find(|r| r.identity == *identity).cloned()) }
    fn save_observation(&mut self, observation: tinyprune_core::scheduler::Observation) -> Result<(), String> { self.records.push(observation); Ok(()) }
    fn projects(&self) -> Result<&[tinyprune_core::scheduler::Project], String> { Ok(&self.projects) }
    fn publish_projects(&mut self, _: &str, projects: Vec<tinyprune_core::scheduler::Project>) -> Result<(), String> { self.projects = projects; Ok(()) }
    fn remove_below(&mut self, _: &str) -> Result<(), String> { Ok(()) }
}
#[test]
fn scheduler_windows_scope_and_event_comparisons() {
    use tinyprune_core::scheduler::*;
    let mut rule = rule(r"C:\Data", PathFlavor::Windows);
    rule.expiry_basis = ExpiryBasis::FirstObserved;
    let candidate = item(r"c:\DATA\Report.TXT");
    let mut store = Observations::default();
    let settings = settings();
    let rules = [rule];
    let decisions = scan(&Metadata(vec![candidate]), &mut store, &ClockStub, &ScanPolicy { root: r"C:\Data", rules: &rules, overrides: &[], settings: &settings }, &[ActivityEvent { path: "C:/data/report.txt".into(), at: 4.0 }], &[]).unwrap();
    assert!(matches!(&decisions[0].resolution, Resolution::Scheduled(explanation) if explanation.scheduled_at == 5.0));
    assert!(!meaningful_activity_with_flavor(r"C:\Data\NODE_MODULES\file", r"c:\data", PathFlavor::Windows));
}
