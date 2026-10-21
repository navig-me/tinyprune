use crate::Result;
use serde::{Deserialize, Serialize};
use tinyprune_core::{resolve::*, rule::*, trash::*, uuid::Uuid};

#[derive(Serialize, Deserialize)]
pub(crate) struct Identity {
    volume: String,
    resource: Vec<u8>,
    path: String,
    created: Option<f64>,
    generation: Option<u32>,
    persistent: bool,
}
impl From<&FilesystemIdentity> for Identity {
    fn from(i: &FilesystemIdentity) -> Self {
        Self {
            volume: i.volume.to_string(),
            resource: i.resource.clone(),
            path: i.path_hint.clone(),
            created: i.creation_time,
            generation: i.generation,
            persistent: i.is_persistent,
        }
    }
}
impl Identity {
    pub fn decode(self) -> Result<FilesystemIdentity> {
        Ok(FilesystemIdentity {
            volume: uuid(&self.volume)?,
            resource: self.resource,
            path_hint: self.path,
            creation_time: self.created,
            generation: self.generation,
            is_persistent: self.persistent,
        })
    }
}
pub(crate) fn uuid(s: &str) -> Result<Uuid> {
    Uuid::parse(s).ok_or_else(|| "Invalid persisted UUID".into())
}
pub(crate) fn encode<T: Serialize>(v: &T) -> Result<String> {
    serde_json::to_string(v).map_err(|e| e.to_string())
}
pub(crate) fn decode<T: serde::de::DeserializeOwned>(s: &str) -> Result<T> {
    serde_json::from_str(s).map_err(|e| e.to_string())
}
fn invalid() -> String {
    "Invalid persisted enum".into()
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Rule {
    id: String,
    name: String,
    path: String,
    recursive: bool,
    windows: bool,
    kind: String,
    names: Vec<String>,
    globs: Vec<String>,
    basis: String,
    lifetime: f64,
    grace: Option<f64>,
    action: String,
    state: String,
    mode: String,
}
impl From<&LifetimeRule> for Rule {
    fn from(r: &LifetimeRule) -> Self {
        Self {
            id: r.id.to_string(),
            name: r.name.clone(),
            path: r.scope.path.clone(),
            recursive: r.scope.recursive,
            windows: r.scope.path_flavor == PathFlavor::Windows,
            kind: r.matcher.item_kind.as_str().into(),
            names: r.matcher.exact_names.clone(),
            globs: r.matcher.glob_patterns.clone(),
            basis: r.expiry_basis.as_str().into(),
            lifetime: r.lifetime.0,
            grace: r.grace_period.map(|g| g.0),
            action: r.action.as_str().into(),
            state: r.state.as_str().into(),
            mode: r.match_mode.as_str().into(),
        }
    }
}
impl Rule {
    pub fn decode(self) -> Result<LifetimeRule> {
        LifetimeRule::new(
            uuid(&self.id)?,
            &self.name,
            RuleScope::new_with_flavor(
                &self.path,
                self.recursive,
                if self.windows {
                    PathFlavor::Windows
                } else {
                    PathFlavor::Posix
                },
            )
            .map_err(|e| e.name())?,
            ItemMatcher::new(
                ItemKind::parse(&self.kind).ok_or_else(invalid)?,
                self.names,
                self.globs,
            )
            .map_err(|e| e.name())?,
            ExpiryBasis::parse(&self.basis).ok_or_else(invalid)?,
            RuleDuration::new(self.lifetime).map_err(|e| e.name())?,
            self.grace
                .map(RuleDuration::new)
                .transpose()
                .map_err(|e| e.name())?,
            FolderAction::parse(&self.action).ok_or_else(invalid)?,
            RuleState::parse(&self.state).ok_or_else(invalid)?,
            RuleMatchMode::parse(&self.mode).ok_or_else(invalid)?,
        )
        .map_err(|e| e.name().into())
    }
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Override {
    id: String,
    identity: Option<Identity>,
    path: String,
    policy: String,
    descendants: bool,
    expires: Option<f64>,
    state: Option<String>,
}
impl From<&ItemPolicyOverride> for Override {
    fn from(o: &ItemPolicyOverride) -> Self {
        let (policy, descendants, expires, state) = match o.policy {
            ItemOverridePolicy::Inherit => ("inherit", false, None, None),
            ItemOverridePolicy::Keep {
                protect_descendants,
            } => ("keep", protect_descendants, None, None),
            ItemOverridePolicy::CustomExpiry { expires_at, state } => (
                "customExpiry",
                false,
                Some(expires_at),
                Some(state.as_str().to_owned()),
            ),
        };
        Self {
            id: o.id.to_string(),
            identity: o.identity.as_ref().map(Identity::from),
            path: o.path.clone(),
            policy: policy.into(),
            descendants,
            expires,
            state,
        }
    }
}
impl Override {
    pub fn decode(self) -> Result<ItemPolicyOverride> {
        let policy = match self.policy.as_str() {
            "inherit" => ItemOverridePolicy::Inherit,
            "keep" => ItemOverridePolicy::Keep {
                protect_descendants: self.descendants,
            },
            "customExpiry" => ItemOverridePolicy::CustomExpiry {
                expires_at: self.expires.ok_or_else(invalid)?,
                state: RuleState::parse(self.state.as_deref().ok_or_else(invalid)?)
                    .ok_or_else(invalid)?,
            },
            _ => return Err(invalid()),
        };
        Ok(ItemPolicyOverride {
            id: uuid(&self.id)?,
            identity: self.identity.map(Identity::decode).transpose()?,
            path: self.path,
            policy,
        })
    }
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Candidate {
    identity: Identity,
    name: String,
    kind: String,
    times: [Option<f64>; 7],
    hidden: bool,
}
impl From<&RuleCandidate> for Candidate {
    fn from(c: &RuleCandidate) -> Self {
        let t = &c.timestamps;
        Self {
            identity: Identity::from(&c.identity),
            name: c.name.clone(),
            kind: c.kind.as_str().into(),
            times: [
                t.created,
                t.modified,
                t.first_observed,
                t.observed_activity,
                t.accessed,
                t.project_activity,
                t.explicit_date,
            ],
            hidden: c.platform_hidden,
        }
    }
}
impl Candidate {
    pub fn decode(self) -> Result<RuleCandidate> {
        let [created, modified, first_observed, observed_activity, accessed, project_activity, explicit_date] =
            self.times;
        Ok(RuleCandidate {
            identity: self.identity.decode()?,
            name: self.name,
            kind: ItemKind::parse(&self.kind).ok_or_else(invalid)?,
            timestamps: CandidateTimestamps {
                created,
                modified,
                first_observed,
                observed_activity,
                accessed,
                project_activity,
                explicit_date,
            },
            platform_hidden: self.hidden,
        })
    }
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Request {
    identity: Identity,
    source: String,
    custom: bool,
    at: f64,
}
impl From<&TrashRequest> for Request {
    fn from(r: &TrashRequest) -> Self {
        let (id, custom) = match r.source {
            ScheduledSource::Rule(id) => (id, false),
            ScheduledSource::CustomOverride(id) => (id, true),
        };
        Self {
            identity: Identity::from(&r.candidate_identity),
            source: id.to_string(),
            custom,
            at: r.scheduled_at,
        }
    }
}
impl Request {
    pub fn decode(self) -> Result<TrashRequest> {
        let id = uuid(&self.source)?;
        Ok(TrashRequest {
            candidate_identity: self.identity.decode()?,
            source: if self.custom {
                ScheduledSource::CustomOverride(id)
            } else {
                ScheduledSource::Rule(id)
            },
            scheduled_at: self.at,
        })
    }
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Event {
    at: f64,
    kind: String,
    identity: Option<Identity>,
    rule: Option<String>,
    detail: Option<String>,
    bytes: Option<i64>,
    items: Option<usize>,
}
impl From<&AuditEvent> for Event {
    fn from(e: &AuditEvent) -> Self {
        Self {
            at: e.occurred_at,
            kind: e.kind.as_str().into(),
            identity: e.identity.as_ref().map(Identity::from),
            rule: e.rule_id.map(|id| id.to_string()),
            detail: e.detail.clone(),
            bytes: e.bytes,
            items: e.item_count,
        }
    }
}
impl Event {
    pub fn decode(self) -> Result<AuditEvent> {
        Ok(AuditEvent {
            occurred_at: self.at,
            kind: match self.kind.as_str() {
                "previewSkipped" => AuditKind::PreviewSkipped,
                "notDue" => AuditKind::NotDue,
                "safetySkipped" => AuditKind::SafetySkipped,
                "trashAttempted" => AuditKind::TrashAttempted,
                "movedToTrash" => AuditKind::MovedToTrash,
                "trashFailed" => AuditKind::TrashFailed,
                _ => return Err(invalid()),
            },
            identity: self.identity.map(Identity::decode).transpose()?,
            rule_id: self.rule.map(|s| uuid(&s)).transpose()?,
            detail: self.detail,
            bytes: self.bytes,
            item_count: self.items,
        })
    }
}
