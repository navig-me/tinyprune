//! `trash.execute` scenarios: the real coordinator against scripted collaborators (see Fixtures/golden/README.md).

use super::*;
use tinyprune_core::trash::*;

struct ScriptedStore {
    entries: Vec<Option<PolicySnapshot>>,
}

impl PolicyStore for ScriptedStore {
    fn load_snapshot(&mut self) -> Result<PolicySnapshot, String> {
        let entry = if self.entries.len() > 1 { self.entries.remove(0) } else { self.entries[0].clone() };
        entry.ok_or_else(|| "policy unavailable".to_string())
    }
}

struct ScriptedFiles {
    candidates: Vec<Option<RuleCandidate>>,
    symlink_ancestor: bool,
    symlink_error: bool,
    inspect_error: bool,
    walk: Vec<String>,
    trash_error: Option<String>,
    now: f64,
    log: Vec<String>,
}

impl FileAccess for ScriptedFiles {
    fn inspect(&mut self, _path: &str) -> Result<Option<RuleCandidate>, String> {
        self.log.push("inspect".into());
        if self.inspect_error {
            return Err("inspect failed".into());
        }
        Ok(if self.candidates.len() > 1 { self.candidates.remove(0) } else { self.candidates[0].clone() })
    }

    fn has_symbolic_link_ancestor(&mut self, _path: &str, _below_root: &str) -> Result<bool, String> {
        self.log.push("symlinkCheck".into());
        if self.symlink_error {
            return Err("symlink check failed".into());
        }
        Ok(self.symlink_ancestor)
    }

    fn has_protected_descendant(
        &mut self,
        _path: &str,
        _overrides: &[ItemPolicyOverride],
        protect_hidden_files: bool,
        budget: WalkBudget,
    ) -> Result<DescendantProtection, String> {
        self.log.push(format!(
            "walk protectHidden={protect_hidden_files} maxEntries={} seconds={}",
            budget.max_entries,
            (budget.deadline - self.now) as i64
        ));
        let value = if self.walk.len() > 1 { self.walk.remove(0) } else { self.walk[0].clone() };
        match value.as_str() {
            "none" => Ok(DescendantProtection::None),
            "protected" => Ok(DescendantProtection::Protected),
            "indeterminate" => Ok(DescendantProtection::Indeterminate),
            _ => Err("walk failed".into()),
        }
    }

    fn move_to_trash(&mut self, path: &str, _expected_identity: &FilesystemIdentity) -> Result<String, String> {
        self.log.push(format!("move {path}"));
        if let Some(error) = &self.trash_error {
            return Err(error.clone());
        }
        Ok(format!("/.Trash/{}", path.rsplit('/').next().unwrap_or(path)))
    }
}

struct RecordingAudit {
    fail_on: Vec<String>,
    events: Vec<AuditEvent>,
}

impl AuditSink for RecordingAudit {
    fn append(&mut self, event: AuditEvent) -> Result<(), String> {
        if self.fail_on.iter().any(|kind| kind == event.kind.as_str()) {
            return Err("audit unavailable".into());
        }
        self.events.push(event);
        Ok(())
    }
}

struct FixedClock(f64);

impl Clock for FixedClock {
    fn now(&self) -> f64 {
        self.0
    }
}

struct StubHydrator(RuleCandidate);

impl CandidateHydrator for StubHydrator {
    fn hydrate(&mut self, _candidate: &RuleCandidate, _rules: &[LifetimeRule], _now: f64) -> Result<RuleCandidate, String> {
        Ok(self.0.clone())
    }
}

struct StubSizes(Option<SizeMeasurement>);

impl SizeMeasurer for StubSizes {
    fn measure(&mut self, _path: &str) -> Option<SizeMeasurement> {
        self.0
    }
}

struct StubGate(bool);

impl UpdateGate for StubGate {
    fn acquire_trash_permit(&mut self) -> Result<bool, String> {
        Ok(!self.0)
    }
}

fn snapshot(object: &Obj) -> Result<PolicySnapshot, RunError> {
    Ok(PolicySnapshot {
        rules: array(object, "rules").iter().map(|value| rule(as_object(value)?)).collect::<Result<_, _>>()?,
        overrides: array(object, "overrides").iter().map(|value| override_item(as_object(value)?)).collect::<Result<_, _>>()?,
        managed_roots: array(object, "roots")
            .iter()
            .map(|value| string(as_object(value)?, "path").map(|path| normalize_path(&path)))
            .collect::<Result<_, _>>()?,
        globally_paused: object.get("globallyPaused").and_then(Value::as_bool).unwrap_or(false),
        settings: settings(object.get("settings").and_then(Value::as_object)),
    })
}

pub fn run(input: &Obj) -> Result<Value, RunError> {
    let now = input.get("now").and_then(Value::as_f64).unwrap_or(0.0);

    let request_object = object(input, "request")?;
    let source_object = object(&request_object, "source")?;
    let source = if source_object.contains_key("rule") {
        ScheduledSource::Rule(uuid(&source_object, "rule")?)
    } else {
        ScheduledSource::CustomOverride(uuid(&source_object, "customOverride")?)
    };
    let request = TrashRequest {
        candidate_identity: identity(&object(&request_object, "identity")?)?,
        source,
        scheduled_at: request_object.get("scheduledAt").and_then(Value::as_f64).unwrap_or(0.0),
    };

    let entries: Vec<Option<PolicySnapshot>> = match input.get("snapshots").and_then(Value::as_array) {
        Some(list) => list
            .iter()
            .map(|value| {
                let object = as_object(value)?;
                if object.get("error").and_then(Value::as_bool) == Some(true) { Ok(None) } else { snapshot(object).map(Some) }
            })
            .collect::<Result<_, _>>()?,
        None => vec![Some(snapshot(&object(input, "snapshot")?)?)],
    };

    let filesystem = optional_object(input, "filesystem").unwrap_or_default();
    let candidates: Vec<Option<RuleCandidate>> = match filesystem.get("candidates").and_then(Value::as_array) {
        Some(list) => list.iter().map(|value| value.as_object().map(candidate).transpose()).collect::<Result<_, _>>()?,
        None => vec![filesystem.get("candidate").and_then(Value::as_object).map(candidate).transpose()?],
    };
    let walk: Vec<String> = match filesystem.get("walk") {
        Some(Value::Array(list)) => list.iter().filter_map(|value| value.as_str().map(str::to_string)).collect(),
        Some(Value::String(value)) => vec![value.clone()],
        _ => vec!["none".into()],
    };
    let flag = |key: &str| filesystem.get(key).and_then(Value::as_bool).unwrap_or(false);

    let mut store = ScriptedStore { entries };
    let mut files = ScriptedFiles {
        candidates,
        symlink_ancestor: flag("symlinkAncestor"),
        symlink_error: flag("symlinkError"),
        inspect_error: flag("inspectError"),
        walk,
        trash_error: optional_string(&filesystem, "trashError"),
        now,
        log: Vec::new(),
    };
    let mut audit = RecordingAudit { fail_on: strings(input, "auditFailsOn"), events: Vec::new() };
    let clock = FixedClock(now);
    let mut gate = StubGate(input.get("updatePending").and_then(Value::as_bool).unwrap_or(false));
    let mut hydrator = optional_object(input, "hydrated").map(|object| candidate(&object)).transpose()?.map(StubHydrator);
    let measure = optional_object(input, "measure").map(|object| SizeMeasurement {
        bytes: object.get("bytes").and_then(Value::as_i64).unwrap_or(0),
        items: object.get("items").and_then(Value::as_u64).unwrap_or(0) as usize,
        truncated: object.get("truncated").and_then(Value::as_bool).unwrap_or(false),
    });
    let mut sizes = StubSizes(measure);
    let limits = optional_object(input, "walkLimits");

    let outcome = {
        let mut coordinator = TrashCoordinator {
            policy: &mut store,
            files: &mut files,
            audit: &mut audit,
            clock: &clock,
            gate: &mut gate,
            hydrator: hydrator.as_mut().map(|hydrator| hydrator as &mut dyn CandidateHydrator),
            sizes: &mut sizes,
            walk_limits: DescendantWalkLimits {
                max_entries: limits.as_ref().and_then(|limits| limits.get("maxEntries")).and_then(Value::as_u64).map_or(250_000, |value| value as usize),
                max_duration: limits.as_ref().and_then(|limits| limits.get("maxSeconds")).and_then(Value::as_f64).unwrap_or(10.0),
            },
        };
        coordinator.execute(&request)
    };

    let mut result = match outcome {
        Ok(Outcome::Previewed) => json!({ "outcome": "previewed" }),
        Ok(Outcome::NotDue(deadline)) => json!({ "outcome": "notDue", "deadline": deadline }),
        Ok(Outcome::Skipped(reason)) => json!({ "outcome": "skipped", "reason": reason }),
        Ok(Outcome::Deferred(reason)) => json!({ "outcome": "deferred", "reason": reason }),
        Ok(Outcome::MovedToTrash { original_path, trashed_path }) => {
            json!({ "outcome": "movedToTrash", "originalPath": original_path, "trashedPath": trashed_path })
        }
        Err(ExecutionError::PolicyReadFailed(_)) => json!({ "error": "policyReadFailed" }),
        Err(ExecutionError::FilesystemReadFailed(_)) => json!({ "error": "filesystemReadFailed" }),
        Err(ExecutionError::AuditWriteFailed(_)) => json!({ "error": "auditWriteFailed" }),
        Err(ExecutionError::FilesystemOperationFailed(_)) => json!({ "error": "filesystemOperationFailed" }),
        Err(ExecutionError::MovedButAuditFailed { path, .. }) => json!({ "error": "movedButAuditFailed", "trashedPath": path }),
        Err(ExecutionError::UpdateInstallationPending) => json!({ "error": "updateInstallationPending" }),
    };
    result["calls"] = json!(files.log);
    result["audit"] = Value::Array(
        audit
            .events
            .iter()
            .map(|event| {
                let mut rendered = json!({ "kind": event.kind.as_str(), "at": event.occurred_at });
                if let Some(id) = event.rule_id {
                    rendered["ruleId"] = json!(id.to_string());
                }
                if let Some(detail) = &event.detail {
                    rendered["detail"] = json!(detail);
                }
                if let Some(bytes) = event.bytes {
                    rendered["bytes"] = json!(bytes);
                }
                if let Some(items) = event.item_count {
                    rendered["itemCount"] = json!(items);
                }
                rendered
            })
            .collect(),
    );
    Ok(result)
}
