//! Rule model: kinds, scope, matcher, lifetime rule, identity, candidates.

use crate::glob::Glob;
use crate::swiftstr::{canonical_eq, char_count, contains_slash, drop_first, has_prefix, is_blank};
use crate::uuid::Uuid;
pub use crate::path::PathFlavor;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleValidationError {
    InvalidDuration,
    InvalidScope,
    EmptyMatcherPattern,
    EmptyRuleName,
}

impl RuleValidationError {
    /// The Swift case name, used by the golden fixtures.
    pub fn name(self) -> &'static str {
        match self {
            RuleValidationError::InvalidDuration => "invalidDuration",
            RuleValidationError::InvalidScope => "invalidScope",
            RuleValidationError::EmptyMatcherPattern => "emptyMatcherPattern",
            RuleValidationError::EmptyRuleName => "emptyRuleName",
        }
    }
}

macro_rules! string_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident = $text:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum $name { $($variant),+ }
        impl $name {
            pub fn parse(text: &str) -> Option<Self> {
                match text { $($text => Some(Self::$variant),)+ _ => None }
            }
            pub fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $text),+ }
            }
        }
    };
}

string_enum!(ItemKind { File = "file", Directory = "directory", FileOrDirectory = "fileOrDirectory" });
string_enum!(RuleState { Preview = "preview", Active = "active", Paused = "paused" });
string_enum!(ExpiryBasis {
    Created = "created", Modified = "modified", FirstObserved = "firstObserved", ObservedActivity = "observedActivity",
    Accessed = "accessed", ProjectActivity = "projectActivity", ExplicitDate = "explicitDate",
});
string_enum!(FolderAction { TrashItem = "trashItem", EmptyContents = "emptyContents", TrashMatchingChildren = "trashMatchingChildren" });
string_enum!(RuleMatchMode { Scoped = "scoped", ExactPath = "exactPath", ItemSpecific = "itemSpecific", Template = "template" });

impl ItemKind {
    pub fn accepts(self, candidate: ItemKind) -> bool {
        self == ItemKind::FileOrDirectory || self == candidate
    }
}

/// Lexical path normalization equivalent to `URL(fileURLWithPath:).standardizedFileURL.path` for absolute
/// paths: collapses `//`, `.`, `..` (never above `/`) and trailing slashes. Symlinks are never resolved.
pub fn normalize_path(path: &str) -> String {
    let mut stack: Vec<&str> = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                stack.pop();
            }
            other => stack.push(other),
        }
    }
    format!("/{}", stack.join("/"))
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RuleDuration(pub f64);

impl RuleDuration {
    pub fn new(seconds: f64) -> Result<RuleDuration, RuleValidationError> {
        if seconds.is_finite() && seconds > 0.0 {
            Ok(RuleDuration(seconds))
        } else {
            Err(RuleValidationError::InvalidDuration)
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RuleScope {
    pub path: String,
    pub recursive: bool,
    pub path_flavor: PathFlavor,
}

impl RuleScope {
    pub fn new(path: &str, recursive: bool) -> Result<RuleScope, RuleValidationError> {
        Self::new_with_flavor(path, recursive, PathFlavor::Posix)
    }

    pub fn new_with_flavor(path: &str, recursive: bool, path_flavor: PathFlavor) -> Result<Self, RuleValidationError> {
        if is_blank(path) || !path_flavor.is_absolute(path) || path_flavor.is_root(path) {
            return Err(RuleValidationError::InvalidScope);
        }
        Ok(RuleScope { path: path_flavor.normalize(path), recursive, path_flavor })
    }

    pub fn relative_path(&self, candidate_path: &str) -> Option<String> {
        let candidate = self.path_flavor.normalize(candidate_path);
        if !self.path_flavor.is_descendant(&candidate, &self.path) {
            return None;
        }
        let relative = if self.path_flavor == PathFlavor::Posix {
            drop_first(&candidate, char_count(&self.path) + 1)
        } else {
            candidate.chars().skip(self.path.chars().count() + 1).collect()
        };
        if self.recursive || !contains_slash(&relative) {
            Some(relative)
        } else {
            None
        }
    }
}

/// Set semantics like Swift's `Set<String>` members: canonical equivalence, order ignored.
impl PartialEq for ItemMatcher {
    fn eq(&self, other: &Self) -> bool {
        fn same_set(a: &[String], b: &[String]) -> bool {
            a.iter().all(|x| b.iter().any(|y| canonical_eq(x, y))) && b.iter().all(|y| a.iter().any(|x| canonical_eq(x, y)))
        }
        self.item_kind == other.item_kind
            && same_set(&self.exact_names, &other.exact_names)
            && same_set(&self.glob_patterns, &other.glob_patterns)
    }
}

#[derive(Debug, Clone)]
pub struct ItemMatcher {
    pub item_kind: ItemKind,
    pub exact_names: Vec<String>,
    pub glob_patterns: Vec<String>,
    globs: Vec<Glob>,
    windows_globs: std::sync::OnceLock<Vec<Glob>>,
}

impl ItemMatcher {
    pub fn new(item_kind: ItemKind, exact_names: Vec<String>, glob_patterns: Vec<String>) -> Result<ItemMatcher, RuleValidationError> {
        if exact_names.iter().any(|name| is_blank(name)) || glob_patterns.iter().any(|pattern| is_blank(pattern)) {
            return Err(RuleValidationError::EmptyMatcherPattern);
        }
        let globs = glob_patterns.iter().map(|pattern| Glob::new(pattern)).collect();
        let windows_globs = std::sync::OnceLock::new();
        Ok(ItemMatcher { item_kind, exact_names, glob_patterns, globs, windows_globs })
    }

    pub fn matches(&self, name: &str, relative_path: &str, kind: ItemKind) -> bool {
        self.specificity(name, relative_path, kind).is_some()
    }

    pub fn matches_with_flavor(&self, name: &str, relative_path: &str, kind: ItemKind, flavor: PathFlavor) -> bool {
        self.specificity_with_flavor(name, relative_path, kind, flavor).is_some()
    }

    pub fn specificity_with_flavor(&self, name: &str, relative_path: &str, kind: ItemKind, flavor: PathFlavor) -> Option<u8> {
        if flavor == PathFlavor::Posix { return self.specificity(name, relative_path, kind); }
        if !self.item_kind.accepts(kind) { return None; }
        if self.exact_names.iter().any(|exact| flavor.equal(exact, name)) { return Some(2); }
        if !self.glob_patterns.is_empty() {
            let globs = self.windows_globs.get_or_init(|| self.glob_patterns.iter().map(|pattern| Glob::new(&flavor.fold(&pattern.replace('\\', "/")))).collect());
            let name = flavor.fold(name);
            let relative = flavor.fold(&relative_path.replace('\\', "/"));
            if globs.iter().any(|glob| glob.matches_item(&name, &relative)) { return Some(1); }
        }
        if self.exact_names.is_empty() && self.glob_patterns.is_empty() { Some(0) } else { None }
    }

    /// 2 exact name, 1 glob, 0 empty matcher (matches everything of the kind), `None` no match.
    pub fn specificity(&self, name: &str, relative_path: &str, kind: ItemKind) -> Option<u8> {
        if !self.item_kind.accepts(kind) {
            return None;
        }
        if self.exact_names.iter().any(|exact| canonical_eq(exact, name)) {
            return Some(2);
        }
        if self.globs.iter().any(|glob| glob.matches_item(name, relative_path)) {
            return Some(1);
        }
        if self.exact_names.is_empty() && self.glob_patterns.is_empty() {
            return Some(0);
        }
        None
    }

    /// True when the matcher names a dot-item on purpose (exact name or glob final component starting `.`).
    pub fn explicitly_targets_dot_name(&self) -> bool {
        if self.exact_names.iter().any(|name| has_prefix(name, ".")) {
            return true;
        }
        self.glob_patterns.iter().any(|pattern| {
            let last = crate::swiftstr::split_slash(pattern).pop().unwrap_or_else(|| pattern.clone());
            has_prefix(&last, ".")
        })
    }
}

pub fn is_hidden_name(name: &str) -> bool {
    has_prefix(name, ".")
}

#[derive(Debug, Clone, PartialEq)]
pub struct LifetimeRule {
    pub id: Uuid,
    pub name: String,
    pub scope: RuleScope,
    pub matcher: ItemMatcher,
    pub expiry_basis: ExpiryBasis,
    pub lifetime: RuleDuration,
    pub grace_period: Option<RuleDuration>,
    pub action: FolderAction,
    pub state: RuleState,
    pub match_mode: RuleMatchMode,
}

impl LifetimeRule {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: Uuid,
        name: &str,
        scope: RuleScope,
        matcher: ItemMatcher,
        expiry_basis: ExpiryBasis,
        lifetime: RuleDuration,
        grace_period: Option<RuleDuration>,
        action: FolderAction,
        state: RuleState,
        match_mode: RuleMatchMode,
    ) -> Result<LifetimeRule, RuleValidationError> {
        if is_blank(name) {
            return Err(RuleValidationError::EmptyRuleName);
        }
        Ok(LifetimeRule {
            id,
            name: name.to_string(),
            scope,
            matcher,
            expiry_basis,
            lifetime,
            grace_period,
            action,
            state,
            match_mode,
        })
    }
}

#[derive(Debug, Clone)]
pub struct FilesystemIdentity {
    pub volume: Uuid,
    pub resource: Vec<u8>,
    pub path_hint: String,
    pub creation_time: Option<f64>,
    pub generation: Option<u32>,
    pub is_persistent: bool,
}

/// Equal when volume and resource ids match and, for creation time and generation, either side lacks the value
/// or both agree. `path_hint` and `is_persistent` never participate.
impl PartialEq for FilesystemIdentity {
    fn eq(&self, other: &Self) -> bool {
        self.volume == other.volume
            && self.resource == other.resource
            && match (self.creation_time, other.creation_time) {
                (Some(a), Some(b)) => a == b,
                _ => true,
            }
            && match (self.generation, other.generation) {
                (Some(a), Some(b)) => a == b,
                _ => true,
            }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CandidateTimestamps {
    pub created: Option<f64>,
    pub modified: Option<f64>,
    pub first_observed: Option<f64>,
    pub observed_activity: Option<f64>,
    pub accessed: Option<f64>,
    pub project_activity: Option<f64>,
    pub explicit_date: Option<f64>,
}

impl CandidateTimestamps {
    pub fn value(&self, basis: ExpiryBasis) -> Option<f64> {
        match basis {
            ExpiryBasis::Created => self.created,
            ExpiryBasis::Modified => self.modified,
            ExpiryBasis::FirstObserved => self.first_observed,
            ExpiryBasis::ObservedActivity => self.observed_activity,
            ExpiryBasis::Accessed => self.accessed,
            ExpiryBasis::ProjectActivity => self.project_activity,
            ExpiryBasis::ExplicitDate => self.explicit_date,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RuleCandidate {
    pub identity: FilesystemIdentity,
    pub name: String,
    pub kind: ItemKind,
    pub timestamps: CandidateTimestamps,
    /// Fresh metadata flag; adapters without a platform hidden attribute must set false.
    pub platform_hidden: bool,
}

impl RuleCandidate {
    /// Portable metadata defaults to no platform hidden attribute.
    pub fn new(identity: FilesystemIdentity, name: String, kind: ItemKind, timestamps: CandidateTimestamps) -> Self {
        Self { identity, name, kind, timestamps, platform_hidden: false }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AgentSettings {
    pub default_grace_period_seconds: f64,
    pub protect_hidden_files: bool,
    pub path_flavor: PathFlavor,
}

impl AgentSettings {
    pub fn new(default_grace_period_seconds: f64, protect_hidden_files: bool) -> AgentSettings {
        let grace = if default_grace_period_seconds.is_finite() { default_grace_period_seconds.max(0.0) } else { 0.0 };
        AgentSettings { default_grace_period_seconds: grace, protect_hidden_files, path_flavor: PathFlavor::Posix }
    }
}

impl Default for AgentSettings {
    fn default() -> Self {
        AgentSettings::new(0.0, false)
    }
}
