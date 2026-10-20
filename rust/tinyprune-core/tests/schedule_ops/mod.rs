use super::*;
use tinyprune_core::scheduler::*;

struct Tree(Vec<RuleCandidate>);
impl MetadataSource for Tree {
    fn candidates(&self) -> Result<&[RuleCandidate], String> { Ok(&self.0) }
}
#[derive(Default)]
struct Store { observations: Vec<Observation>, projects: Vec<Project> }
fn within(path: &str, root: &str) -> bool { path == root || path.starts_with(&(root.to_owned() + "/")) }
impl ObservationStore for Store {
    fn observation(&self, identity: &FilesystemIdentity) -> Result<Option<Observation>, String> {
        Ok(self.observations.iter().find(|record| record.identity == *identity).cloned())
    }
    fn save_observation(&mut self, record: Observation) -> Result<(), String> {
        if let Some(old) = self.observations.iter_mut().find(|old| old.identity == record.identity) { *old = record; }
        else { self.observations.push(record); }
        Ok(())
    }
    fn projects(&self) -> Result<&[Project], String> { Ok(&self.projects) }
    fn publish_projects(&mut self, root: &str, mut projects: Vec<Project>) -> Result<(), String> {
        for project in &mut projects {
            if let Some(old) = self.projects.iter().find(|old| old.identity == project.identity) { project.activity = project.activity.max(old.activity); }
        }
        self.projects.retain(|project| !within(&project.identity.path_hint, root));
        self.projects.extend(projects);
        Ok(())
    }
    fn remove_below(&mut self, path: &str) -> Result<(), String> {
        self.observations.retain(|record| !within(&record.identity.path_hint, path));
        self.projects.retain(|record| !within(&record.identity.path_hint, path));
        Ok(())
    }
}
struct Time(f64);
impl Clock for Time { fn now(&self) -> f64 { self.0 } }
fn io(error: String) -> RunError { RunError::Format(error) }

pub(super) fn run(input: &Obj) -> Result<Value, RunError> {
    let root = optional_string(input, "root").unwrap_or_else(|| "/Develop".into());
    let rules = array(input, "rules").iter().map(|value| rule(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
    let overrides = array(input, "overrides").iter().map(|value| override_item(as_object(value)?)).collect::<Result<Vec<_>, _>>()?;
    let settings = settings(input.get("settings").and_then(Value::as_object));
    let policy = ScanPolicy { root: &root, rules: &rules, overrides: &overrides, settings: &settings };
    let mut store = Store::default();
    for record in array(input, "observations") {
        let object = as_object(record)?;
        let first = object.get("first").and_then(Value::as_f64).ok_or_else(|| RunError::Format("observation requires first".into()))?;
        let last = object.get("last").and_then(Value::as_f64).ok_or_else(|| RunError::Format("observation requires last".into()))?;
        store.save_observation(Observation { identity: identity(object)?, first, last }).map_err(io)?;
    }
    let steps = input.get("steps").and_then(Value::as_array).cloned().unwrap_or_else(|| vec![Value::Object(input.clone())]);
    let mut outputs = Vec::new();
    for step in steps {
        let step = as_object(&step)?;
        // Restart drops only nonpersistent identities, exactly as Swift connection startup does.
        if step.get("restart").and_then(Value::as_bool).unwrap_or(false) {
            store.observations.retain(|record| record.identity.is_persistent);
            store.projects.retain(|record| record.identity.is_persistent);
        }
        let now = step.get("now").or(input.get("now")).and_then(Value::as_f64).ok_or_else(|| RunError::Format("schedule requires now".into()))?;
        let tree = Tree(array(step, "tree").iter().map(|value| candidate(as_object(value)?)).collect::<Result<Vec<_>, _>>()?);
        let events = array(step, "events").iter().map(|value| {
            let event = as_object(value)?;
            Ok(ActivityEvent { path: string(event, "path")?, at: event.get("at").and_then(Value::as_f64).unwrap_or(now) })
        }).collect::<Result<Vec<_>, RunError>>()?;
        let removed = array(step, "removed").iter().map(|value| value.as_str().map(str::to_owned).ok_or_else(|| RunError::Format("removed path".into()))).collect::<Result<Vec<_>, _>>()?;
        let decisions = scan(&tree, &mut store, &Time(now), &policy, &events, &removed).map_err(io)?;
        let items: Vec<_> = decisions.iter().map(|decision| json!({ "path": decision.path, "resolution": encode_resolution(&decision.resolution), "protectedDescendant": decision.protected_descendant })).collect();
        let mut records: Vec<_> = store.observations.iter().collect();
        records.sort_by(|a, b| tinyprune_core::swiftstr::swift_cmp(&a.identity.path_hint, &b.identity.path_hint).then_with(|| a.identity.resource.cmp(&b.identity.resource)));
        let observations: Vec<_> = records.iter().map(|record| json!({ "path": record.identity.path_hint, "resource": record.identity.resource.iter().map(|byte| format!("{byte:02x}")).collect::<String>(), "first": record.first, "last": record.last })).collect();
        outputs.push(json!({ "items": items, "observations": observations }));
    }
    Ok(json!({ "steps": outputs }))
}
