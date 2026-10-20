//! Declarative policy diff. Only deterministic config-owned IDs can be removed.
use crate::config::{rule_id, ConfigDocument};
use crate::resolve::{ItemOverridePolicy, ItemPolicyOverride};
use crate::rule::*;
use crate::swiftstr::{canonical_eq, has_prefix, swift_cmp};

pub fn document_rules(document: &ConfigDocument, state: RuleState) -> Result<Vec<LifetimeRule>, RuleValidationError> {
    document.roots.iter().flat_map(|root| document.rules.iter().map(move |spec| {
        LifetimeRule::new(rule_id(&spec.name, &root.path), &spec.name, RuleScope::new(&root.path, true)?,
            ItemMatcher::new(spec.item_kind, spec.exact_names.clone(), spec.glob_patterns.clone())?, spec.basis, spec.lifetime,
            spec.grace, FolderAction::TrashItem, state, RuleMatchMode::Scoped)
    })).collect()
}

pub struct RuleChange { pub before: LifetimeRule, pub after: LifetimeRule, pub fields: Vec<&'static str> }
pub struct ExceptionChange { pub path: String, pub protect_descendants: bool, pub is_new: bool }
pub struct ConfigPlan {
    pub roots: Vec<String>, pub unmanaged_roots: Vec<String>, pub added: Vec<LifetimeRule>, pub changed: Vec<RuleChange>,
    pub removed: Vec<LifetimeRule>, pub unchanged: usize, pub merged: Vec<LifetimeRule>, pub exceptions: Vec<ExceptionChange>,
}
impl ConfigPlan {
    pub fn make(document: &ConfigDocument, current: &[LifetimeRule], roots: &[String], overrides: &[ItemPolicyOverride], activate: bool) -> Result<Self, RuleValidationError> {
        let mut desired = document_rules(document, RuleState::Preview)?;
        let mut added = Vec::new(); let mut changed = Vec::new(); let mut unchanged = 0;
        for target in &mut desired {
            let old = current.iter().find(|old| old.id == target.id);
            target.state = if activate { RuleState::Active } else { old.map_or(RuleState::Preview, |rule| rule.state) };
            if let Some(old) = old {
                let mut fields = Vec::new();
                if old.matcher != target.matcher { fields.push("match"); }
                if old.expiry_basis != target.expiry_basis { fields.push("since"); }
                if old.lifetime != target.lifetime { fields.push("after"); }
                if old.grace_period != target.grace_period { fields.push("grace"); }
                if old.action != target.action { fields.push("action"); }
                if old.scope != target.scope { fields.push("scope"); }
                if old.match_mode != target.match_mode { fields.push("matchMode"); }
                if old.state != target.state { fields.push("state"); }
                if fields.is_empty() { unchanged += 1; } else { changed.push(RuleChange { before: old.clone(), after: target.clone(), fields }); }
            } else { added.push(target.clone()); }
        }
        let root_paths: Vec<_> = document.roots.iter().map(|root| root.path.clone()).collect();
        let removed: Vec<_> = current.iter().filter(|rule| rule.id == rule_id(&rule.name, &rule.scope.path)
            && root_paths.iter().any(|path| canonical_eq(path, &rule.scope.path)) && !desired.iter().any(|target| target.id == rule.id)).cloned().collect();
        let merged = current.iter().filter(|rule| !removed.iter().any(|old| old.id == rule.id)).map(|rule| {
            changed.iter().find(|change| change.after.id == rule.id).map_or_else(|| rule.clone(), |change| change.after.clone())
        }).chain(added.iter().cloned()).collect();
        let unmanaged_roots = root_paths.iter().filter(|path| !roots.iter().any(|root| canonical_eq(path, root) || has_prefix(path, &format!("{root}/")))).cloned().collect();
        let exceptions = document.exceptions.iter().map(|exception| ExceptionChange {
            path: exception.path.clone(), protect_descendants: exception.protect_descendants,
            is_new: !overrides.iter().any(|old| canonical_eq(&old.path, &exception.path) && old.policy == ItemOverridePolicy::Keep { protect_descendants: exception.protect_descendants }),
        }).collect();
        Ok(Self { roots: root_paths, unmanaged_roots, added, changed, removed, unchanged, merged, exceptions })
    }
    pub fn has_rule_changes(&self) -> bool { !self.added.is_empty() || !self.changed.is_empty() || !self.removed.is_empty() }
    pub fn adds_preview_rules(&self) -> bool { self.added.iter().any(|rule| rule.state == RuleState::Preview) }
    pub fn summary_lines(&self) -> Vec<String> {
        let mut lines = vec!["Roots:".into()];
        for root in &self.roots { lines.push(format!("  {root}  {}", if self.unmanaged_roots.contains(root) { "NOT MANAGED - add this folder in TinyPrune.app before applying" } else { "managed" })); }
        if !self.added.is_empty() { lines.push(format!("Rules to add ({}):", self.added.len())); lines.extend(self.added.iter().map(|rule| format!("  + {}", describe(rule)))); }
        if !self.changed.is_empty() { lines.push(format!("Rules to change ({}):", self.changed.len())); lines.extend(self.changed.iter().map(|change| format!("  ~ {}  [{}]", describe(&change.after), change.fields.join(", ")))); }
        if !self.removed.is_empty() { lines.push(format!("Rules to remove ({}):", self.removed.len())); lines.extend(self.removed.iter().map(|rule| format!("  - {}", describe(rule)))); }
        if !self.has_rule_changes() { lines.push(format!("Rules: no changes ({} already up to date).", self.unchanged)); }
        for exception in &self.exceptions { lines.push(format!("  {} exception {}  {}", if exception.is_new { "+" } else { "=" }, exception.path, if exception.protect_descendants { "keep with descendants" } else { "keep item" })); }
        if !self.unmanaged_roots.is_empty() { lines.push("Apply is blocked until every root is managed.".into()); }
        lines
    }
}
pub fn duration_description(seconds: f64) -> String {
    if seconds % 86400.0 == 0.0 { format!("{}d", (seconds / 86400.0) as i64) }
    else if seconds % 3600.0 == 0.0 { format!("{}h", (seconds / 3600.0) as i64) }
    else { format!("{}s", seconds as i64) }
}
pub fn describe(rule: &LifetimeRule) -> String {
    let mut names = rule.matcher.exact_names.clone(); names.sort_by(|a,b| swift_cmp(a,b));
    let mut globs = rule.matcher.glob_patterns.clone(); globs.sort_by(|a,b| swift_cmp(a,b)); names.extend(globs);
    format!("{}  {}  {}  {} {}  {} for {}", rule.name, rule.scope.path, rule.state.as_str(), rule.matcher.item_kind.as_str(),
        if names.is_empty() { "items".into() } else { names.join(", ") }, rule.expiry_basis.as_str(), duration_description(rule.lifetime.0))
}
