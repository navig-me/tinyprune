//! Wire-only DTOs. Unknown variants never imply permission to execute an action.
use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionRange { pub min: u32, pub max: u32 }
impl Default for VersionRange { fn default() -> Self { Self { min: PROTOCOL_VERSION, max: PROTOCOL_VERSION } } }
impl VersionRange {
    pub fn negotiate(self, peer: Self) -> Option<u32> {
        if self.min > self.max || peer.min > peer.max { return None; }
        let version = self.max.min(peer.max);
        (version >= self.min.max(peer.min)).then_some(version)
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Handshake { pub protocol_version: u32, pub versions: VersionRange }
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HandshakeReply { pub protocol_version: Option<u32>, pub versions: VersionRange }

macro_rules! wire_enum {
    ($name:ident { $($variant:ident),* $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(rename_all = "camelCase")]
        pub enum $name { $($variant,)* #[serde(other)] Unknown }
    };
}
wire_enum!(RuleState { Preview, Active, Paused });
wire_enum!(ItemKind { File, Directory, FileOrDirectory });
wire_enum!(ExpiryBasis { Created, Modified, FirstObserved, ObservedActivity, Accessed, ProjectActivity, ExplicitDate });
wire_enum!(FolderAction { TrashItem, EmptyContents, TrashMatchingChildren });
wire_enum!(MatchMode { Scoped, ExactPath, ItemSpecific, Template });
wire_enum!(Disposition { Preview, Active });
wire_enum!(RootState { Watching, Indexing, Recovering, Offline, BookmarkStale, PermissionDenied, Error });
wire_enum!(ActivityKind { PolicyReplaced, RuleCreated, RuleEdited, RulePaused, RuleDeleted, ItemProtected, ItemUnprotected, ExpiryChanged, GlobalPauseChanged, PreviewSkipped, NotDue, SafetySkipped, TrashAttempted, MovedToTrash, TrashFailed, SettingsChanged });
wire_enum!(ErrorCode { UnsupportedProtocol, InvalidRequest, StorageUnavailable, PolicyConflict, RootUnavailable, Busy });
wire_enum!(Suppression { ItemDoesNotMatch, MissingExpiryTimestamp, PausedRule, GlobalPause, PreviewOnly, HiddenProtected, Protected, ProtectedDescendant, NoRule, AmbiguousRules, AmbiguousOverrides });

macro_rules! dto {
    ($name:ident { $($field:ident : $ty:ty),* $(,)? }) => {
        #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
        #[serde(rename_all = "camelCase")]
        pub struct $name { $(pub $field: $ty,)* }
    };
}
// Dates are finite Unix seconds, not Foundation's 2001 reference epoch.
dto!(Identity { volume_identifier: String, resource_identifier: String, path_hint: String, creation_time: Option<f64>, generation: Option<u32>, is_persistent: bool });
dto!(Scope { path: String, recursive: bool });
dto!(Matcher { item_kind: ItemKind, exact_names: Vec<String>, glob_patterns: Vec<String> });
dto!(Rule { id: String, name: String, scope: Scope, matcher: Matcher, expiry_basis: ExpiryBasis, lifetime: f64, grace_period: Option<f64>, action: FolderAction, state: RuleState, match_mode: MatchMode });
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum OverridePolicy {
    Inherit, Keep { protect_descendants: bool }, CustomExpiry { expires_at: f64, state: RuleState }, #[serde(other)] Unknown,
}
dto!(ItemOverride { id: String, identity: Option<Identity>, path: String, policy: OverridePolicy });
dto!(OverrideChange { path: String, policy: Option<OverridePolicy> });
dto!(Root { id: String, path: String, name: String });
dto!(RootStatus { root_id: String, path: String, state: RootState, detail: Option<String> });
dto!(Settings { default_grace_period_seconds: f64, protect_hidden_files: bool, activity_retention_days: u32 });
dto!(PolicySnapshot { rules: Vec<Rule>, overrides: Vec<ItemOverride>, managed_roots: Vec<Root>, globally_paused: bool, paused_until: Option<f64>, revision: u64 });
dto!(ProjectContext { identity: Identity, last_activity: Option<f64> });
// Every decision, including preview samples and suppressed decisions, carries this complete context.
// None means inapplicable/unavailable, never an omitted authorization check.
dto!(Explanation { item: Identity, scheduled_at: Option<f64>, eligible_at: Option<f64>, rule: Option<Rule>, basis: Option<ExpiryBasis>, basis_date: Option<f64>, project_context: Option<ProjectContext>, item_override: Option<ItemOverride>, suppression_reason: Option<Suppression>, disposition: Option<Disposition>, globally_paused: bool });
dto!(UpcomingItem { explanation: Explanation });
dto!(UpcomingCursor { scheduled_at: f64, identity_key: String });
dto!(UpcomingPage { items: Vec<UpcomingItem>, next_cursor: Option<UpcomingCursor>, total_count: u64 });
dto!(DeadlineSummary { active: u64, preview: u64, active_soon: u64 });
dto!(RuleStats { rule_id: String, matches: u64, due: u64 });
dto!(ReclaimedDay { day: f64, items: u64, bytes: u64 });
dto!(ReclaimedSummary { lifetime_items: u64, lifetime_bytes: u64, items_with_known_size: u64, first_moved_at: Option<f64>, last_moved_at: Option<f64>, days: Vec<ReclaimedDay>, week_items: u64, week_bytes: u64 });
dto!(Overview { policy: PolicySnapshot, upcoming: Vec<UpcomingItem>, rule_stats: Vec<RuleStats>, indexed_items: u64, database_bytes: u64, root_statuses: Vec<RootStatus>, reclaimed: Option<ReclaimedSummary>, deadline_summary: Option<DeadlineSummary> });
dto!(ActivityItem { id: String, occurred_at: f64, kind: ActivityKind, identity: Option<Identity>, rule_id: Option<String>, detail: Option<String>, bytes: Option<u64>, item_count: Option<u64>, explanation: Option<Explanation> });
dto!(ItemExplanation { path: String, explanation: Explanation, overrides: Vec<ItemOverride> });
dto!(PreviewSample { explanation: Explanation, bytes: Option<u64> });
dto!(RulePreview { matches: u64, eligible_now: u64, estimated_bytes: u64, scanned_entries: u64, truncated: bool, duration_seconds: f64, samples: Vec<PreviewSample> });
dto!(Health { protocol_version: u32, service_version: String });
dto!(ServiceError { code: ErrorCode, message: String });
dto!(Acknowledgement { revision: u64, audit_event_ids: Vec<String> });

// Serde's adjacent-tag `other` rejects unknown variants with non-unit content.
// Decode the discriminant first so future payloads are ignored, while malformed
// payloads of known operations still fail closed.
macro_rules! rpc {
    ($name:ident, $remote:literal, $tag:literal, $content:literal, {
        $($variant:ident $(($tuple:ty))? $({$($fields:tt)*})?),* $(,)?
    }) => {
        #[derive(Debug, Clone, PartialEq, Serialize)]
        #[serde(tag = $tag, content = $content, rename_all = "camelCase", rename_all_fields = "camelCase")]
        pub enum $name { $($variant $(($tuple))? $({$($fields)*})?,)* Unknown }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                #[derive(Deserialize)]
                #[serde(remote = $remote, tag = $tag, content = $content, rename_all = "camelCase", rename_all_fields = "camelCase")]
                enum Wire { $($variant $(($tuple))? $({$($fields)*})?,)* Unknown }
                let value = serde_json::Value::deserialize(deserializer)?;
                let tag = value.get($tag).and_then(|v| v.as_str())
                    .ok_or_else(|| serde::de::Error::custom("missing RPC discriminant"))?;
                let known = [$(stringify!($variant)),*].iter().any(|name| {
                    tag.len() == name.len() && tag.as_bytes()[0] == name.as_bytes()[0].to_ascii_lowercase()
                        && tag[1..] == name[1..]
                });
                if !known { return Ok(Self::Unknown); }
                Wire::deserialize(value).map_err(serde::de::Error::custom)
            }
        }
    }
}
rpc!(Request, "Request", "operation", "arguments", {
    Health, LoadPolicy, LoadOverview,
    LoadUpcoming { rule_id: Option<String>, disposition: Option<Disposition>, after: Option<UpcomingCursor>, limit: u32 },
    LoadActivity { limit: u32 }, ExplainItem { path: String }, ReplacePolicy(PolicySnapshot),
    SetItemOverride { path: String, policy: OverridePolicy }, ClearItemOverride { path: String },
    SetItemOverrides { changes: Vec<OverrideChange> }, SetGlobalPause { paused: bool }, PauseUntil { until: f64 },
    LoadSettings, UpdateSettings(Settings), ItemSize { path: String }, PreviewRule(Rule), DeleteRule { id: String },
    SaveRule { rule: Rule, roots: Option<Vec<Root>>, keep_paths: Vec<String>, unkeep_paths: Vec<String>, revision: u64 },
    RebuildIndex, LoadRoots, AddRoot(Root), RemoveRoot { id: String }, CancelPreview,
    ImportConfig { text: String, activate: bool, revision: u64 }, ExportConfig,
});
rpc!(Response, "Response", "type", "data", {
    Health(Health), Policy(PolicySnapshot), Overview(Box<Overview>), UpcomingPage(UpcomingPage), Activity(Vec<ActivityItem>),
    ItemExplanation(Box<ItemExplanation>), Settings(Settings), ItemSize { path: String, bytes: u64, items: u64, truncated: bool },
    RulePreview(RulePreview), Acknowledged(Acknowledgement), Failure(ServiceError), Roots(Vec<Root>), Config { text: String },
});
dto!(RequestEnvelope { protocol_version: u32, request: Request });
dto!(ResponseEnvelope { protocol_version: u32, response: Response });
