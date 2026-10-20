use serde::{de::DeserializeOwned, Serialize};
use tinyprune_core::{resolve as r, rule as c, trash::PolicySnapshot, uuid::Uuid};
use tinyprune_ipc as d;

fn text<T: Serialize>(value: &T) -> Result<String, String> {
    serde_json::to_value(value)
        .map_err(|e| e.to_string())?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "Invalid enum".into())
}
fn wire<T: DeserializeOwned>(value: &str) -> T {
    // All callers pass a closed core enum's canonical spelling.
    serde_json::from_value(serde_json::Value::String(value.into()))
        .expect("core enum has wire equivalent")
}
pub fn uuid(value: &str) -> Result<Uuid, String> {
    Uuid::parse(value).ok_or_else(|| "Invalid UUID".into())
}
pub fn flavor() -> c::PathFlavor {
    if cfg!(windows) {
        c::PathFlavor::Windows
    } else {
        c::PathFlavor::Posix
    }
}
pub fn rule(value: &d::Rule) -> Result<c::LifetimeRule, String> {
    macro_rules! parse {
        ($ty:ty, $v:expr) => {
            <$ty>::parse(&text($v)?).ok_or("Unknown policy enum")?
        };
    }
    c::LifetimeRule::new(
        uuid(&value.id)?,
        &value.name,
        c::RuleScope::new_with_flavor(&value.scope.path, value.scope.recursive, flavor())
            .map_err(|e| e.name())?,
        c::ItemMatcher::new(
            parse!(c::ItemKind, &value.matcher.item_kind),
            value.matcher.exact_names.clone(),
            value.matcher.glob_patterns.clone(),
        )
        .map_err(|e| e.name())?,
        parse!(c::ExpiryBasis, &value.expiry_basis),
        c::RuleDuration::new(value.lifetime).map_err(|e| e.name())?,
        value
            .grace_period
            .map(c::RuleDuration::new)
            .transpose()
            .map_err(|e| e.name())?,
        parse!(c::FolderAction, &value.action),
        parse!(c::RuleState, &value.state),
        parse!(c::RuleMatchMode, &value.match_mode),
    )
    .map_err(|e| e.name().into())
}
pub fn rule_wire(v: &c::LifetimeRule) -> d::Rule {
    d::Rule {
        id: v.id.to_string(),
        name: v.name.clone(),
        scope: d::Scope {
            path: v.scope.path.clone(),
            recursive: v.scope.recursive,
        },
        matcher: d::Matcher {
            item_kind: wire(v.matcher.item_kind.as_str()),
            exact_names: v.matcher.exact_names.clone(),
            glob_patterns: v.matcher.glob_patterns.clone(),
        },
        expiry_basis: wire(v.expiry_basis.as_str()),
        lifetime: v.lifetime.0,
        grace_period: v.grace_period.map(|v| v.0),
        action: wire(v.action.as_str()),
        state: wire(v.state.as_str()),
        match_mode: wire(v.match_mode.as_str()),
    }
}
pub fn identity(v: &c::FilesystemIdentity) -> d::Identity {
    d::Identity {
        volume_identifier: v.volume.to_string(),
        resource_identifier: v.resource.iter().map(|b| format!("{b:02x}")).collect(),
        path_hint: v.path_hint.clone(),
        creation_time: v.creation_time,
        generation: v.generation,
        is_persistent: v.is_persistent,
    }
}
pub fn policy(v: &d::OverridePolicy) -> Result<r::ItemOverridePolicy, String> {
    Ok(match v {
        d::OverridePolicy::Inherit => r::ItemOverridePolicy::Inherit,
        d::OverridePolicy::Keep {
            protect_descendants,
        } => r::ItemOverridePolicy::Keep {
            protect_descendants: *protect_descendants,
        },
        d::OverridePolicy::CustomExpiry { expires_at, state } if expires_at.is_finite() => {
            r::ItemOverridePolicy::CustomExpiry {
                expires_at: *expires_at,
                state: c::RuleState::parse(&text(state)?).ok_or("Unknown override state")?,
            }
        }
        _ => return Err("Unknown or invalid override".into()),
    })
}
pub fn override_wire(v: &r::ItemPolicyOverride) -> d::ItemOverride {
    d::ItemOverride {
        id: v.id.to_string(),
        identity: v.identity.as_ref().map(identity),
        path: v.path.clone(),
        policy: match v.policy {
            r::ItemOverridePolicy::Inherit => d::OverridePolicy::Inherit,
            r::ItemOverridePolicy::Keep {
                protect_descendants,
            } => d::OverridePolicy::Keep {
                protect_descendants,
            },
            r::ItemOverridePolicy::CustomExpiry { expires_at, state } => {
                d::OverridePolicy::CustomExpiry {
                    expires_at,
                    state: wire(state.as_str()),
                }
            }
        },
    }
}
pub fn root(path: &str) -> d::Root {
    d::Root {
        id: tinyprune_core::config::rule_id("root", path).to_string(),
        path: path.into(),
        name: std::path::Path::new(path)
            .file_name()
            .and_then(|v| v.to_str())
            .unwrap_or(path)
            .into(),
    }
}
pub fn snapshot(v: &PolicySnapshot, revision: u64, paused_until: Option<f64>) -> d::PolicySnapshot {
    d::PolicySnapshot {
        rules: v.rules.iter().map(rule_wire).collect(),
        overrides: v.overrides.iter().map(override_wire).collect(),
        managed_roots: v.managed_roots.iter().map(|v| root(v)).collect(),
        globally_paused: v.globally_paused,
        paused_until,
        revision,
    }
}
pub fn settings(v: c::AgentSettings, retention: u32) -> d::Settings {
    d::Settings {
        default_grace_period_seconds: v.default_grace_period_seconds,
        protect_hidden_files: v.protect_hidden_files,
        activity_retention_days: retention,
    }
}
pub fn disposition(v: r::Disposition) -> d::Disposition {
    wire(v.as_str())
}
pub fn suppression(v: r::Suppression) -> d::Suppression {
    wire(v.as_str())
}
pub fn basis(v: c::ExpiryBasis) -> d::ExpiryBasis {
    wire(v.as_str())
}
