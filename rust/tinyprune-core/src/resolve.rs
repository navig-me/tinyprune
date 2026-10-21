//! Rule evaluation and precedence resolution, mirroring `RuleEvaluator` and `RuleResolver`.

use crate::rule::*;
use crate::swiftstr::{char_count, has_prefix, split_slash};
use crate::uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Suppression {
    ItemDoesNotMatch,
    MissingExpiryTimestamp,
    PausedRule,
    GlobalPause,
    PreviewOnly,
    HiddenProtected,
}

impl Suppression {
    pub fn as_str(self) -> &'static str {
        match self {
            Suppression::ItemDoesNotMatch => "itemDoesNotMatch",
            Suppression::MissingExpiryTimestamp => "missingExpiryTimestamp",
            Suppression::PausedRule => "pausedRule",
            Suppression::GlobalPause => "globalPause",
            Suppression::PreviewOnly => "previewOnly",
            Suppression::HiddenProtected => "hiddenProtected",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disposition {
    Preview,
    Active,
}

impl Disposition {
    pub fn as_str(self) -> &'static str {
        match self {
            Disposition::Preview => "preview",
            Disposition::Active => "active",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Explanation {
    pub rule_id: Uuid,
    pub rule_name: String,
    pub basis: ExpiryBasis,
    pub basis_date: f64,
    pub eligible_at: f64,
    pub scheduled_at: f64,
    pub disposition: Disposition,
    /// Set for an explicit item expiry rather than an inherited lifetime rule.
    pub custom_override_id: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Evaluation {
    Scheduled(Explanation),
    Suppressed(Suppression),
}

pub fn evaluate(candidate: &RuleCandidate, rule: &LifetimeRule, settings: &AgentSettings) -> Evaluation {
    if rule.state == RuleState::Paused {
        return Evaluation::Suppressed(Suppression::PausedRule);
    }
    let flavor = rule.scope.path_flavor;
    let path = flavor.normalize(&candidate.identity.path_hint);
    let matches = match rule.match_mode {
        RuleMatchMode::ItemSpecific | RuleMatchMode::ExactPath => {
            flavor.equal(&path, &rule.scope.path) && rule.matcher.matches_with_flavor(&candidate.name, &candidate.name, candidate.kind, flavor)
        }
        RuleMatchMode::Scoped => rule
            .scope
            .relative_path(&path)
            .is_some_and(|relative| rule.matcher.matches_with_flavor(&candidate.name, &relative, candidate.kind, flavor)),
        RuleMatchMode::Template => rule.matcher.matches_with_flavor(&candidate.name, &candidate.name, candidate.kind, flavor),
    };
    if !matches {
        return Evaluation::Suppressed(Suppression::ItemDoesNotMatch);
    }
    if settings.protect_hidden_files && is_hidden_protected(&path, candidate, rule) {
        return Evaluation::Suppressed(Suppression::HiddenProtected);
    }
    let Some(basis_date) = candidate.timestamps.value(rule.expiry_basis) else {
        return Evaluation::Suppressed(Suppression::MissingExpiryTimestamp);
    };
    let eligible_at = basis_date + rule.lifetime.0;
    let grace = rule.grace_period.map_or(settings.default_grace_period_seconds, |grace| grace.0);
    Evaluation::Scheduled(Explanation {
        rule_id: rule.id,
        rule_name: rule.name.clone(),
        basis: rule.expiry_basis,
        basis_date,
        eligible_at,
        scheduled_at: eligible_at + grace,
        disposition: if rule.state == RuleState::Preview { Disposition::Preview } else { Disposition::Active },
        custom_override_id: None,
    })
}

fn is_hidden_protected(path: &str, candidate: &RuleCandidate, rule: &LifetimeRule) -> bool {
    if rule.matcher.explicitly_targets_dot_name() {
        return false;
    }
    if candidate.platform_hidden { return true; }
    let components = match rule.match_mode {
        RuleMatchMode::Scoped => match rule.scope.relative_path(path) {
            Some(relative) => split_slash(&relative),
            None => return false,
        },
        _ => vec![candidate.name.clone()],
    };
    components.iter().any(|component| is_hidden_name(component))
}

#[derive(Debug, Clone, PartialEq)]
pub enum ItemOverridePolicy {
    Inherit,
    Keep { protect_descendants: bool },
    CustomExpiry { expires_at: f64, state: RuleState },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ItemPolicyOverride {
    pub id: Uuid,
    pub identity: Option<FilesystemIdentity>,
    /// Normalized.
    pub path: String,
    pub policy: ItemOverridePolicy,
}

impl ItemPolicyOverride {
    pub fn new(id: Uuid, identity: Option<FilesystemIdentity>, path: &str, policy: ItemOverridePolicy) -> Self {
        Self::new_with_flavor(id, identity, path, policy, PathFlavor::Posix)
    }

    pub fn new_with_flavor(id: Uuid, identity: Option<FilesystemIdentity>, path: &str, policy: ItemOverridePolicy, flavor: PathFlavor) -> Self {
        ItemPolicyOverride { id, identity, path: flavor.normalize(path), policy }
    }

    fn applies_exactly_to(&self, candidate: &RuleCandidate, flavor: PathFlavor) -> bool {
        match &self.identity {
            Some(identity) => *identity == candidate.identity,
            None => flavor.equal(&flavor.normalize(&self.path), &flavor.normalize(&candidate.identity.path_hint)),
        }
    }

    fn protects(&self, candidate: &RuleCandidate, flavor: PathFlavor) -> bool {
        keep_covers_with_flavor(Some(&candidate.identity), &candidate.identity.path_hint, self, None, flavor)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Resolution {
    Scheduled(Explanation),
    CustomExpiry { override_id: Uuid, expires_at: f64, disposition: Disposition },
    Protected { override_id: Uuid, protected_path: String, protects_descendants: bool },
    Suppressed(Suppression),
    NoRule,
    AmbiguousRules(Vec<Uuid>),
    AmbiguousOverrides(Vec<Uuid>),
}

pub fn resolve(
    candidate: &RuleCandidate,
    rules: &[LifetimeRule],
    overrides: &[ItemPolicyOverride],
    globally_paused: bool,
    settings: &AgentSettings,
) -> Resolution {
    // Keep protection: longest recorded path (in Characters) wins; equal length goes to the lowest uuid.
    let mut protection: Option<&ItemPolicyOverride> = None;
    for item in overrides.iter().filter(|item| item.protects(candidate, settings.path_flavor)) {
        protection = match protection {
            None => Some(item),
            Some(current) => {
                let (new_len, current_len) = (char_count(&item.path), char_count(&current.path));
                if new_len > current_len || (new_len == current_len && item.id < current.id) {
                    Some(item)
                } else {
                    Some(current)
                }
            }
        };
    }
    if let Some(protection) = protection {
        let protects_descendants = matches!(protection.policy, ItemOverridePolicy::Keep { protect_descendants: true });
        return Resolution::Protected {
            override_id: protection.id,
            protected_path: protection.path.clone(),
            protects_descendants,
        };
    }

    let mut exact: Vec<&ItemPolicyOverride> = overrides
        .iter()
        .filter(|item| item.applies_exactly_to(candidate, settings.path_flavor) && !matches!(item.policy, ItemOverridePolicy::Inherit))
        .collect();
    if exact.len() > 1 {
        let mut ids: Vec<Uuid> = exact.iter().map(|item| item.id).collect();
        ids.sort();
        return Resolution::AmbiguousOverrides(ids);
    }
    if let Some(item) = exact.pop() {
        if let ItemOverridePolicy::CustomExpiry { expires_at, state } = item.policy {
            if state == RuleState::Paused {
                return Resolution::Suppressed(Suppression::PausedRule);
            }
            if globally_paused {
                return Resolution::Suppressed(Suppression::GlobalPause);
            }
            return Resolution::CustomExpiry {
                override_id: item.id,
                expires_at,
                disposition: if state == RuleState::Preview { Disposition::Preview } else { Disposition::Active },
            };
        }
    }
    if globally_paused {
        return Resolution::Suppressed(Suppression::GlobalPause);
    }

    let mut applicable: Vec<RankedMatch> = Vec::new();
    for rule in rules.iter().filter(|rule| rule.state != RuleState::Paused) {
        let name = &candidate.name;
        let flavor = rule.scope.path_flavor;
        let hinted = flavor.normalize(&candidate.identity.path_hint);
        let ranked = match rule.match_mode {
            RuleMatchMode::ItemSpecific | RuleMatchMode::ExactPath => {
                if !flavor.equal(&hinted, &rule.scope.path) {
                    continue;
                }
                let Some(specificity) = rule.matcher.specificity_with_flavor(name, name, candidate.kind, flavor) else { continue };
                let tier = if rule.match_mode == RuleMatchMode::ItemSpecific { 4 } else { 3 };
                RankedMatch { rule, tier, scope_depth: char_count(&rule.scope.path), specificity }
            }
            RuleMatchMode::Scoped => {
                let Some(relative) = rule.scope.relative_path(&candidate.identity.path_hint) else { continue };
                let Some(specificity) = rule.matcher.specificity_with_flavor(name, &relative, candidate.kind, flavor) else { continue };
                RankedMatch { rule, tier: 2, scope_depth: char_count(&rule.scope.path), specificity }
            }
            RuleMatchMode::Template => {
                let Some(specificity) = rule.matcher.specificity_with_flavor(name, name, candidate.kind, flavor) else { continue };
                RankedMatch { rule, tier: 1, scope_depth: 0, specificity }
            }
        };
        applicable.push(ranked);
    }
    let Some(best) = applicable.iter().max_by_key(|ranked| ranked.key()) else { return Resolution::NoRule };
    let best_key = best.key();
    let tied: Vec<&RankedMatch> = applicable.iter().filter(|ranked| ranked.key() == best_key).collect();
    if tied.len() != 1 {
        let mut ids: Vec<Uuid> = tied.iter().map(|ranked| ranked.rule.id).collect();
        ids.sort();
        return Resolution::AmbiguousRules(ids);
    }
    match evaluate(candidate, tied[0].rule, settings) {
        Evaluation::Scheduled(explanation) => Resolution::Scheduled(explanation),
        Evaluation::Suppressed(reason) => Resolution::Suppressed(reason),
    }
}

struct RankedMatch<'a> {
    rule: &'a LifetimeRule,
    tier: u8,
    scope_depth: usize,
    specificity: u8,
}

impl RankedMatch<'_> {
    fn key(&self) -> (u8, usize, u8) {
        (self.tier, self.scope_depth, self.specificity)
    }
}

/// Whether a Keep override protects the item. Fails toward protection: matches by identity OR by path, and with
/// `protect_descendants` also anything under the recorded path (or under `kept_item_current_path`).
pub fn keep_covers(
    candidate_identity: Option<&FilesystemIdentity>,
    candidate_path: &str,
    item: &ItemPolicyOverride,
    kept_item_current_path: Option<&str>,
) -> bool {
    keep_covers_with_flavor(candidate_identity, candidate_path, item, kept_item_current_path, PathFlavor::Posix)
}

pub fn keep_covers_with_flavor(
    candidate_identity: Option<&FilesystemIdentity>,
    candidate_path: &str,
    item: &ItemPolicyOverride,
    kept_item_current_path: Option<&str>,
    flavor: PathFlavor,
) -> bool {
    let ItemOverridePolicy::Keep { protect_descendants } = item.policy else { return false };
    let path = flavor.normalize(candidate_path);
    if let (Some(candidate), Some(identity)) = (candidate_identity, &item.identity) {
        if candidate == identity {
            return true;
        }
    }
    if flavor.equal(&path, &flavor.normalize(&item.path)) {
        return true;
    }
    let current = kept_item_current_path.map(|path| flavor.normalize(path));
    if current.as_deref().is_some_and(|current| flavor.equal(&path, current)) {
        return true;
    }
    if !protect_descendants {
        return false;
    }
    if flavor.is_descendant(&path, &item.path) {
        return true;
    }
    current.is_some_and(|current| flavor.is_descendant(&path, &current))
}

/// Whether a Keep override protects an item inside the folder at `ancestor_path` that is about to be removed whole.
pub fn keep_protects_descendant(
    ancestor_path: &str,
    item: &ItemPolicyOverride,
    child_identity: Option<&FilesystemIdentity>,
    child_path: &str,
    kept_item_current_path: Option<&str>,
) -> bool {
    let ancestor = normalize_path(ancestor_path);
    if !has_prefix(&normalize_path(child_path), &format!("{ancestor}/")) {
        return false;
    }
    keep_covers(child_identity, child_path, item, kept_item_current_path)
}
