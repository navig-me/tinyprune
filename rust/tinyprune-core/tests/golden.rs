//! Runs `Fixtures/golden/*.jsonl` against this crate. Mirrors the Swift runner: the same inputs must yield the
//! same `expected` output (numbers compared numerically, object keys unordered).

use serde_json::{json, Map, Value};
use std::path::PathBuf;
use tinyprune_core::glob::Glob;
use tinyprune_core::resolve::*;
use tinyprune_core::rule::*;
use tinyprune_core::uuid::Uuid;

type Obj = Map<String, Value>;

mod trash_ops;
mod schedule_ops;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Fixtures/golden")
}

#[test]
fn golden_fixtures_match() {
    let mut files: Vec<_> = std::fs::read_dir(fixture_dir())
        .expect("Fixtures/golden")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "jsonl"))
        .collect();
    files.sort();
    assert!(!files.is_empty());

    let (mut passed, mut failures) = (0, Vec::new());
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        let label = file.file_name().unwrap().to_string_lossy().to_string();
        for (index, line) in text.lines().filter(|line| !line.trim().is_empty()).enumerate() {
            let case: Value = serde_json::from_str(line).unwrap_or_else(|error| panic!("{label}:{}: {error}", index + 1));
            let name = case["name"].as_str().unwrap().to_string();
            let op = case["op"].as_str().unwrap();
            assert!(!op.is_empty());
            let input = case["input"].as_object().unwrap();
            let actual = match run(op, input) {
                Ok(value) => value,
                Err(RunError::Validation(error)) => json!({ "error": error.name() }),
                Err(RunError::Format(message)) => {
                    failures.push(format!("{label}:{} {name}: fixture format: {message}", index + 1));
                    continue;
                }
            };
            if json_equal(&actual, &case["expected"]) {
                passed += 1;
            } else {
                failures.push(format!("{label}:{} {name}\n    expected {}\n    actual   {}", index + 1, case["expected"], actual));
            }
        }
    }
    eprintln!("golden: {passed} passed, {} failed", failures.len());
    assert!(failures.is_empty(), "{} golden failures:\n{}", failures.len(), failures.join("\n"));
}

fn json_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        // Foundation returns decomposed (NFD) path text from normalization; the core preserves the bytes it is
        // given, which is required on Linux. Swift treats the two spellings as equal everywhere, so the contract
        // compares string values by canonical equivalence.
        (Value::String(x), Value::String(y)) => tinyprune_core::swiftstr::canonical_eq(x, y),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(x, y)| json_equal(x, y)),
        (Value::Object(x), Value::Object(y)) => x.len() == y.len() && x.iter().all(|(key, x)| y.get(key).is_some_and(|y| json_equal(x, y))),
        _ => a == b,
    }
}

enum RunError {
    Validation(RuleValidationError),
    Format(String),
}

impl From<RuleValidationError> for RunError {
    fn from(error: RuleValidationError) -> Self {
        RunError::Validation(error)
    }
}

fn format_error<T>(message: impl Into<String>) -> Result<T, RunError> {
    Err(RunError::Format(message.into()))
}

fn run(op: &str, input: &Obj) -> Result<Value, RunError> {
    match op {
        "schedule.scan" => schedule_ops::run(input),
        "glob" => {
            let relative = string(input, "relativePath")?;
            let name = optional_string(input, "name").unwrap_or_else(|| last_component(&relative));
            Ok(json!({ "matches": Glob::new(&string(input, "pattern")?).matches_item(&name, &relative) }))
        }
        "path.normalize" => Ok(json!({ "path": normalize_path(&string(input, "path")?) })),
        "scope.relative" => {
            let scope = scope(&object(input, "scope")?)?;
            Ok(json!({ "relative": scope.relative_path(&string(input, "path")?) }))
        }
        "matcher.match" => {
            let matcher = matcher(&object(input, "matcher")?)?;
            let relative = string(input, "relativePath")?;
            let name = optional_string(input, "name").unwrap_or_else(|| last_component(&relative));
            let kind = item_kind(&optional_string(input, "kind").unwrap_or_else(|| "file".into()))?;
            let specificity = matcher.specificity(&name, &relative, kind);
            Ok(json!({ "matches": specificity.is_some(), "specificity": specificity }))
        }
        "rule.validate" => {
            rule(&object(input, "rule")?)?;
            Ok(json!({ "valid": true }))
        }
        "identity.equals" => Ok(json!({ "equal": identity(&object(input, "a")?)? == identity(&object(input, "b")?)? })),
        "evaluate" => {
            let evaluation = evaluate(
                &candidate(&object(input, "candidate")?)?,
                &rule(&object(input, "rule")?)?,
                &settings(input.get("settings").and_then(Value::as_object)),
            );
            Ok(match evaluation {
                Evaluation::Scheduled(explanation) => encode_explanation(&explanation),
                Evaluation::Suppressed(reason) => json!({ "result": "suppressed", "reason": reason.as_str() }),
            })
        }
        "resolve" => {
            let rules = array(input, "rules").iter().map(|rule_value| rule(as_object(rule_value)?)).collect::<Result<Vec<_>, _>>()?;
            let overrides = array(input, "overrides").iter().map(|value| override_item(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
            let resolution = resolve(
                &candidate(&object(input, "candidate")?)?,
                &rules,
                &overrides,
                input.get("globallyPaused").and_then(Value::as_bool).unwrap_or(false),
                &settings(input.get("settings").and_then(Value::as_object)),
            );
            Ok(encode_resolution(&resolution))
        }
        "keep.covers" => {
            let covers = keep_covers(
                optional_object(input, "identity").map(|object| identity(&object)).transpose()?.as_ref(),
                &string(input, "path")?,
                &override_item(&object(input, "override")?)?,
                optional_string(input, "keptItemCurrentPath").as_deref(),
            );
            Ok(json!({ "covers": covers }))
        }
        "keep.protectsDescendant" => {
            let protects = keep_protects_descendant(
                &string(input, "ancestor")?,
                &override_item(&object(input, "override")?)?,
                optional_object(input, "childIdentity").map(|object| identity(&object)).transpose()?.as_ref(),
                &string(input, "childPath")?,
                optional_string(input, "keptItemCurrentPath").as_deref(),
            );
            Ok(json!({ "protects": protects }))
        }
        "config.parse" => {
            use tinyprune_core::config::ConfigDocument;
            Ok(match ConfigDocument::parse(&string(input, "text")?, &string(input, "home")?) {
                Err(error) => json!({ "configError": { "line": error.line, "message": error.message } }),
                Ok(document) => json!({
                    "version": document.version,
                    "roots": document.roots.iter().map(|root| json!({ "path": root.path, "line": root.line })).collect::<Vec<_>>(),
                    "rules": document.rules.iter().map(|spec| {
                        let mut rule = json!({
                            "name": spec.name, "kind": spec.item_kind.as_str(), "names": spec.exact_names, "globs": spec.glob_patterns,
                            "basis": spec.basis.as_str(), "afterSeconds": spec.lifetime.0, "line": spec.line,
                        });
                        if let Some(grace) = spec.grace { rule["graceSeconds"] = json!(grace.0); }
                        rule
                    }).collect::<Vec<_>>(),
                    "exceptions": document.exceptions.iter().map(|exception| json!({
                        "path": exception.path, "protectDescendants": exception.protect_descendants, "line": exception.line,
                    })).collect::<Vec<_>>(),
                    "ruleIds": document.roots.iter().flat_map(|root| document.rules.iter().map(move |spec| json!({
                        "root": root.path, "rule": spec.name, "id": tinyprune_core::config::rule_id(&spec.name, &root.path).to_string(),
                    }))).collect::<Vec<_>>(),
                }),
            })
        }
        "config.render" => {
            let rules = array(input, "rules").iter().map(|value| rule(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
            let overrides = array(input, "overrides").iter().map(|value| override_item(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
            Ok(json!({ "text": tinyprune_core::config::render(&rules, &strings(input, "roots"), &overrides) }))
        }
        "template.rules" => {
            let template = tinyprune_core::templates::RuleTemplate::parse(&string(input, "template")?).ok_or_else(|| RunError::Format("invalid template".into()))?;
            let rules = template.rules(&string(input, "path")?, raw(input, "state", RuleState::Active, RuleState::parse)?,
                input.get("temporaryLifetime").and_then(Value::as_f64).unwrap_or(259200.0), || Uuid(0))?;
            Ok(json!({"title": template.title, "summary": template.summary, "suggestedFolder": template.suggested_folder, "isBroad": template.is_broad,
                "rules": rules.iter().map(|rule| { let mut value = encode_rule(rule); value.as_object_mut().unwrap().remove("id"); value }).collect::<Vec<_>>()}))
        }
        "broadness" => {
            let resolver = FixtureResolver(optional_string(input, "resolvedPath"));
            if let Some(value) = input.get("rule") {
                let rule = rule(as_object(value)?)?;
                Ok(json!({"isVeryBroad": tinyprune_core::roots::is_very_broad(&rule.scope.path, &resolver), "isBroad": tinyprune_core::roots::is_broad(&rule, &resolver)}))
            } else {
                Ok(json!({"isVeryBroad": tinyprune_core::roots::is_very_broad(&string(input, "path")?, &resolver)}))
            }
        }
        "root.validate" => {
            let path = string(input, "path")?;
            let bookmark = vec![1; input.get("bookmarkBytes").and_then(Value::as_u64).unwrap_or(1) as usize];
            let resolver = FixtureResolver(optional_string(input, "resolvedPath"));
            Ok(match tinyprune_core::roots::validate_root(&optional_string(input, "name").unwrap_or_else(|| "Root".into()), &path, &bookmark, &resolver) {
                Ok(()) => json!({"valid": true, "path": path, "isVeryBroad": tinyprune_core::roots::is_very_broad(&path, &resolver)}),
                Err(error) => json!({"error": error}),
            })
        }
        "config.plan" => {
            use tinyprune_core::config::ConfigDocument;
            use tinyprune_core::config_plan::{document_rules, ConfigPlan};
            let parse = |text: &str, home: &str| ConfigDocument::parse(text, home).map_err(|error| RunError::Format(error.message));
            let document = parse(&string(input, "text")?, &optional_string(input, "home").unwrap_or_else(|| "/Users/fixture".into()))?;
            let mut current = array(input, "currentRules").iter().map(|value| rule(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
            if let Some(previous) = optional_string(input, "previousText") {
                current.extend(document_rules(&parse(&previous, "/Users/fixture")?, raw(input, "previousState", RuleState::Preview, RuleState::parse)?)?);
            }
            let overrides = array(input, "overrides").iter().map(|value| override_item(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
            let plan = ConfigPlan::make(&document, &current, &strings(input, "managedRoots"), &overrides, input.get("activate").and_then(Value::as_bool).unwrap_or(false))?;
            Ok(json!({"roots": plan.roots, "unmanagedRoots": plan.unmanaged_roots, "added": plan.added.iter().map(encode_rule).collect::<Vec<_>>(),
                "changed": plan.changed.iter().map(|change| json!({"before": encode_rule(&change.before), "after": encode_rule(&change.after), "fields": change.fields})).collect::<Vec<_>>(),
                "removed": plan.removed.iter().map(encode_rule).collect::<Vec<_>>(), "unchanged": plan.unchanged, "merged": plan.merged.iter().map(encode_rule).collect::<Vec<_>>(),
                "exceptions": plan.exceptions.iter().map(|change| json!({"path": change.path, "protectDescendants": change.protect_descendants, "isNew": change.is_new})).collect::<Vec<_>>(),
                "hasRuleChanges": plan.has_rule_changes(), "isApplicable": plan.unmanaged_roots.is_empty(), "addsPreviewRules": plan.adds_preview_rules(),
                "newExceptions": plan.exceptions.iter().filter(|change| change.is_new).map(|change| &change.path).collect::<Vec<_>>(), "summaryLines": plan.summary_lines()}))
        }
        "trash.execute" => trash_ops::run(input),
        other => format_error(format!("unknown op {other}")),
    }
}

// MARK: Decoding

fn as_object(value: &Value) -> Result<&Obj, RunError> {
    value.as_object().map_or_else(|| format_error("expected object"), Ok)
}

fn string(object: &Obj, key: &str) -> Result<String, RunError> {
    object.get(key).and_then(Value::as_str).map(str::to_string).map_or_else(|| format_error(format!("missing string {key}")), Ok)
}

fn optional_string(object: &Obj, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_string)
}

fn object(object: &Obj, key: &str) -> Result<Obj, RunError> {
    object.get(key).and_then(Value::as_object).cloned().map_or_else(|| format_error(format!("missing object {key}")), Ok)
}

fn optional_object(object: &Obj, key: &str) -> Option<Obj> {
    object.get(key).and_then(Value::as_object).cloned()
}

fn array<'a>(object: &'a Obj, key: &str) -> &'a [Value] {
    object.get(key).and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn strings(object: &Obj, key: &str) -> Vec<String> {
    array(object, key).iter().filter_map(|value| value.as_str().map(str::to_string)).collect()
}

fn last_component(path: &str) -> String {
    tinyprune_core::swiftstr::split_slash(path).pop().unwrap_or_else(|| path.to_string())
}

fn uuid(object: &Obj, key: &str) -> Result<Uuid, RunError> {
    Uuid::parse(&string(object, key)?).map_or_else(|| format_error(format!("bad uuid {key}")), Ok)
}

fn item_kind(text: &str) -> Result<ItemKind, RunError> {
    ItemKind::parse(text).map_or_else(|| format_error(format!("bad kind {text}")), Ok)
}

fn raw<T>(object: &Obj, key: &str, fallback: T, parse: fn(&str) -> Option<T>) -> Result<T, RunError> {
    match object.get(key).and_then(Value::as_str) {
        None => Ok(fallback),
        Some(text) => parse(text).map_or_else(|| format_error(format!("bad {key} {text}")), Ok),
    }
}

fn hex(text: &str) -> Result<Vec<u8>, RunError> {
    if !text.len().is_multiple_of(2) {
        return format_error("odd hex");
    }
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).map_err(|_| RunError::Format("bad hex".into())))
        .collect()
}

fn identity(object: &Obj) -> Result<FilesystemIdentity, RunError> {
    Ok(FilesystemIdentity {
        volume: if object.contains_key("volume") { uuid(object, "volume")? } else { Uuid(0xAAAA) },
        resource: hex(&optional_string(object, "resource").unwrap_or_else(|| "01".into()))?,
        path_hint: string(object, "path")?,
        creation_time: object.get("created").and_then(Value::as_f64),
        generation: object.get("generation").and_then(Value::as_u64).map(|value| value as u32),
        is_persistent: object.get("persistent").and_then(Value::as_bool).unwrap_or(true),
    })
}

fn candidate(object: &Obj) -> Result<RuleCandidate, RunError> {
    let identity = identity(object)?;
    let stamps = optional_object(object, "timestamps").unwrap_or_default();
    let stamp = |key: &str| stamps.get(key).and_then(Value::as_f64);
    Ok(RuleCandidate {
        name: optional_string(object, "name").unwrap_or_else(|| last_component(&identity.path_hint)),
        kind: item_kind(&optional_string(object, "kind").unwrap_or_else(|| "directory".into()))?,
        platform_hidden: false,
        timestamps: CandidateTimestamps {
            created: stamp("created"),
            modified: stamp("modified"),
            first_observed: stamp("firstObserved"),
            observed_activity: stamp("observedActivity"),
            accessed: stamp("accessed"),
            project_activity: stamp("projectActivity"),
            explicit_date: stamp("explicitDate"),
        },
        identity,
    })
}

fn scope(object: &Obj) -> Result<RuleScope, RunError> {
    Ok(RuleScope::new(&string(object, "path")?, object.get("recursive").and_then(Value::as_bool).unwrap_or(true))?)
}

fn matcher(object: &Obj) -> Result<ItemMatcher, RunError> {
    let kind = item_kind(&optional_string(object, "kind").unwrap_or_else(|| "fileOrDirectory".into()))?;
    Ok(ItemMatcher::new(kind, dedup(strings(object, "names")), dedup(strings(object, "globs")))?)
}

/// Swift builds `Set<String>`, which de-duplicates by canonical equivalence.
fn dedup(values: Vec<String>) -> Vec<String> {
    tinyprune_core::swiftstr::dedup_canonical(&values)
}

fn rule(object: &Obj) -> Result<LifetimeRule, RunError> {
    let scope = scope(&self::object(object, "scope")?)?;
    let matcher = matcher(&optional_object(object, "matcher").unwrap_or_default())?;
    let lifetime = RuleDuration::new(object.get("lifetime").and_then(Value::as_f64).unwrap_or(86_400.0))?;
    let grace = object.get("grace").and_then(Value::as_f64).map(RuleDuration::new).transpose()?;
    Ok(LifetimeRule::new(
        uuid(object, "id")?,
        &optional_string(object, "name").unwrap_or_else(|| "Rule".into()),
        scope,
        matcher,
        raw(object, "basis", ExpiryBasis::Modified, ExpiryBasis::parse)?,
        lifetime,
        grace,
        raw(object, "action", FolderAction::TrashItem, FolderAction::parse)?,
        raw(object, "state", RuleState::Active, RuleState::parse)?,
        raw(object, "mode", RuleMatchMode::Scoped, RuleMatchMode::parse)?,
    )?)
}

fn override_item(object: &Obj) -> Result<ItemPolicyOverride, RunError> {
    let policy_object = self::object(object, "policy")?;
    let policy = match string(&policy_object, "type")?.as_str() {
        "inherit" => ItemOverridePolicy::Inherit,
        "keep" => ItemOverridePolicy::Keep {
            protect_descendants: policy_object.get("protectDescendants").and_then(Value::as_bool).unwrap_or(false),
        },
        "customExpiry" => ItemOverridePolicy::CustomExpiry {
            expires_at: policy_object.get("expiresAt").and_then(Value::as_f64).map_or_else(|| format_error("missing expiresAt"), Ok)?,
            state: raw(&policy_object, "state", RuleState::Active, RuleState::parse)?,
        },
        _ => return format_error("bad policy type"),
    };
    Ok(ItemPolicyOverride::new(
        uuid(object, "id")?,
        optional_object(object, "identity").map(|object| identity(&object)).transpose()?,
        &string(object, "path")?,
        policy,
    ))
}

fn settings(object: Option<&Obj>) -> AgentSettings {
    AgentSettings::new(
        object.and_then(|object| object.get("defaultGraceSeconds")).and_then(Value::as_f64).unwrap_or(0.0),
        object.and_then(|object| object.get("protectHiddenFiles")).and_then(Value::as_bool).unwrap_or(false),
    )
}

// MARK: Encoding

fn encode_explanation(explanation: &Explanation) -> Value {
    let mut result = json!({
        "result": "scheduled",
        "ruleId": explanation.rule_id.to_string(),
        "ruleName": explanation.rule_name,
        "basis": explanation.basis.as_str(),
        "basisDate": explanation.basis_date,
        "eligibleAt": explanation.eligible_at,
        "scheduledAt": explanation.scheduled_at,
        "disposition": explanation.disposition.as_str(),
    });
    if let Some(id) = explanation.custom_override_id {
        result["customOverrideId"] = json!(id.to_string());
    }
    result
}

fn encode_resolution(resolution: &Resolution) -> Value {
    let ids = |ids: &[Uuid]| ids.iter().map(Uuid::to_string).collect::<Vec<_>>();
    match resolution {
        Resolution::Scheduled(explanation) => encode_explanation(explanation),
        Resolution::CustomExpiry { override_id, expires_at, disposition } => json!({
            "result": "customExpiry",
            "overrideId": override_id.to_string(),
            "expiresAt": expires_at,
            "disposition": disposition.as_str(),
        }),
        Resolution::Protected { override_id, protected_path, protects_descendants } => json!({
            "result": "protected",
            "overrideId": override_id.to_string(),
            "protectedPath": protected_path,
            "protectsDescendants": protects_descendants,
        }),
        Resolution::Suppressed(reason) => json!({ "result": "suppressed", "reason": reason.as_str() }),
        Resolution::NoRule => json!({ "result": "noRule" }),
        Resolution::AmbiguousRules(list) => json!({ "result": "ambiguousRules", "ids": ids(list) }),
        Resolution::AmbiguousOverrides(list) => json!({ "result": "ambiguousOverrides", "ids": ids(list) }),
    }
}

struct FixtureResolver(Option<String>);
impl tinyprune_core::roots::PathResolver for FixtureResolver {
    fn canonical_path(&self, path: &str) -> String { self.0.clone().unwrap_or_else(|| normalize_path(path)) }
    fn home_directories(&self) -> &[String] { &[] }
}

fn encode_rule(rule: &LifetimeRule) -> Value {
    let mut names = rule.matcher.exact_names.clone();
    names.sort_by(|a, b| tinyprune_core::swiftstr::swift_cmp(a, b));
    let mut globs = rule.matcher.glob_patterns.clone();
    globs.sort_by(|a, b| tinyprune_core::swiftstr::swift_cmp(a, b));
    json!({"id": rule.id.to_string(), "name": rule.name, "scope": {"path": rule.scope.path, "recursive": rule.scope.recursive},
        "matcher": {"kind": rule.matcher.item_kind.as_str(), "names": names, "globs": globs}, "basis": rule.expiry_basis.as_str(),
        "lifetime": rule.lifetime.0, "grace": rule.grace_period.map(|duration| duration.0), "action": rule.action.as_str(),
        "state": rule.state.as_str(), "mode": rule.match_mode.as_str()})
}

#[test]
fn domain_fixture_mutations_are_detected() {
    // Mutate one safety-relevant input in each area while retaining the Swift expected result.
    for (file, name, key, mutation) in [
        ("templates.jsonl", "developerCleanup-active", "state", json!("paused")),
        ("broadness.jsonl", "path-0", "path", json!("/Develop")),
        ("roots.jsonl", "root-19", "path", json!("/Develop")),
        ("plans.jsonl", "new-preview", "activate", json!(true)),
    ] {
        let text = std::fs::read_to_string(fixture_dir().join(file)).unwrap();
        let fixture: Value = text.lines().map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|case| case["name"] == name).unwrap();
        let mut input = fixture["input"].as_object().unwrap().clone();
        input.insert(key.into(), mutation);
        let actual = match run(fixture["op"].as_str().unwrap(), &input) {
            Ok(value) => value,
            Err(_) => panic!("mutation must remain processable: {file}:{name}"),
        };
        assert!(!json_equal(&actual, &fixture["expected"]), "undetected mutation: {file}:{name}");
    }
}
