//! IPC-only frontend. All validation, policy decisions and mutations belong to the agent.
use chrono::{Days, Local, TimeZone};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    io::{self, Read, Write},
    path::{Component, PathBuf},
};
use tinyprune_ipc::*;

pub const USAGE: &str = "usage: tinyprune [command] [--json]\n  status | rules [list] | upcoming | activity | doctor\n  rules add <rule.json|-> | rules edit <id> <rule.json|->\n  rules remove|activate|preview <id>\n  keep <path> [--descendants] | unkeep <path> | inherit <path>\n  expire <path> <7d|12h|30m|2w|tonight|tomorrow>\n  explain <path> | why <path>\n  pause [1h|today|tomorrow] | resume\n  roots [list|add <id> <path> [name]|remove <id>]\n  config export | config import|apply <file|-> [--active]\n  delete-rule <id> | rebuild-index\n  --socket <path> overrides TINYPRUNE_SOCKET and the default local endpoint";

#[derive(Debug)]
struct Failure {
    code: String,
    message: String,
    exit: i32,
    uncertain: bool,
}
impl Failure {
    fn new(code: &str, message: impl Into<String>, exit: i32) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            exit,
            uncertain: false,
        }
    }
    fn usage(message: impl Into<String>) -> Self {
        Self::new("usage", message, 64)
    }
}
type Result<T> = std::result::Result<T, Failure>;
fn transport(error: io::Error, sent: bool) -> Failure {
    if error.kind() == io::ErrorKind::InvalidData && error.to_string().contains("protocol") {
        return Failure::new("unsupportedProtocol", "Protocol mismatch: this tool and agent use incompatible versions. Update TinyPrune and restart its background agent.", 69);
    }
    if sent {
        Failure { code: "interrupted".into(), message: format!("The agent connection failed: {error}. The request may have been applied; check the current state before retrying."), exit: 75, uncertain: true }
    } else {
        Failure::new("unavailable", format!("The TinyPrune agent is not running or is unreachable ({error}). Start tinyprune-agent with the same endpoint, or open TinyPrune and enable its background agent."), 69)
    }
}
fn rpc<C: Read + Write>(client: &mut Client<C>, request: Request) -> Result<Response> {
    match client.request(request).map_err(|e| transport(e, true))? {
        Response::Failure(e) => {
            let (code, exit) = match e.code {
                ErrorCode::UnsupportedProtocol => ("unsupportedProtocol", 69),
                ErrorCode::InvalidRequest => ("invalidRequest", 65),
                ErrorCode::PolicyConflict => ("policyConflict", 75),
                ErrorCode::RootUnavailable => ("rootUnavailable", 69),
                ErrorCode::Busy => ("busy", 75),
                _ => ("storageUnavailable", 70),
            };
            let message = if e.code == ErrorCode::UnsupportedProtocol {
                format!(
                    "Protocol mismatch: {}. Update TinyPrune and restart its background agent.",
                    e.message
                )
            } else {
                e.message
            };
            Err(Failure::new(code, message, exit))
        }
        response => Ok(response),
    }
}
fn unexpected() -> Failure {
    Failure::new(
        "unexpectedResponse",
        "TinyPrune agent returned an unexpected response.",
        70,
    )
}
fn value<T: Serialize>(v: T) -> Value {
    serde_json::to_value(v).expect("wire DTO serialization")
}
fn enum_text<T: Serialize>(v: T) -> String {
    value(v).as_str().unwrap_or("unknown").to_owned()
}
fn stamp(v: Option<f64>) -> String {
    v.map(|v| format!("{v} (Unix seconds)"))
        .unwrap_or_else(|| "none".into())
}
/// Full wire explanation, including null contexts and the complete matched rule.
pub fn explanation_text(e: &Explanation) -> String {
    format!("{}\nScheduled: {}\nEligible: {}\nRule: {}\nBasis: {}\nBasis date: {}\nProject context: {}\nOverride: {}\nSuppression: {}\nDisposition: {}\nGlobally paused: {}\nIdentity: {}", e.item.path_hint, stamp(e.scheduled_at), stamp(e.eligible_at), value(&e.rule), value(e.basis), stamp(e.basis_date), value(&e.project_context), value(&e.item_override), value(e.suppression_reason), value(e.disposition), e.globally_paused, value(&e.item))
}
fn path(raw: &str) -> Result<String> {
    if raw.is_empty() {
        return Err(Failure::usage("A path must not be empty."));
    }
    let input = PathBuf::from(raw);
    let input = if input.is_absolute() {
        input
    } else {
        std::env::current_dir()
            .map_err(|e| Failure::new("invalidPath", e.to_string(), 65))?
            .join(input)
    };
    let mut out = PathBuf::new();
    for part in input.components() {
        match part {
            Component::CurDir => (),
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out.into_os_string()
        .into_string()
        .map_err(|_| Failure::new("invalidPath", "Path is not UTF-8.", 65))
}
fn operands(
    args: &[String],
    min: usize,
    max: usize,
    flags: &[&str],
) -> Result<(Vec<String>, Vec<String>)> {
    let mut values = Vec::new();
    let mut found = Vec::new();
    let mut ended = false;
    for arg in args {
        if !ended && arg == "--" {
            ended = true;
        } else if !ended && arg.starts_with('-') && arg != "-" {
            if !flags.contains(&arg.as_str()) {
                return Err(Failure::usage(format!("Unknown option '{arg}'.")));
            }
            found.push(arg.clone());
        } else {
            values.push(arg.clone());
        }
    }
    if values.len() < min || values.len() > max {
        return Err(Failure::usage("Missing or extra command arguments."));
    }
    Ok((values, found))
}
fn read_input(file: &str, stdin: &mut dyn Read) -> Result<String> {
    if file == "-" {
        let mut text = String::new();
        stdin
            .read_to_string(&mut text)
            .map_err(|e| Failure::new("invalidData", e.to_string(), 65))?;
        Ok(text)
    } else {
        std::fs::read_to_string(file)
            .map_err(|e| Failure::new("invalidData", format!("Cannot read {file}: {e}"), 65))
    }
}
fn deadline(spec: &str, pause: bool) -> Result<f64> {
    let now = Local::now();
    let normalized = spec.trim().to_ascii_lowercase();
    let spec = normalized.as_str();
    if spec == "tomorrow" && !pause {
        return now
            .checked_add_days(Days::new(1))
            .map(|v| v.timestamp() as f64)
            .ok_or_else(|| Failure::usage("Date is out of range."));
    }
    let calendar = match spec {
        "today" if pause => Some((true, 0, 0)),
        "tomorrow" => Some((true, 8, 0)),
        "tonight" => Some((now.hour() == 23 && now.minute() >= 59, 23, 59)),
        _ => None,
    };
    if let Some((tomorrow, hour, minute)) = calendar {
        let date = if tomorrow {
            now.date_naive().checked_add_days(Days::new(1))
        } else {
            Some(now.date_naive())
        }
        .ok_or_else(|| Failure::usage("Date is out of range."))?;
        let time = date
            .and_hms_opt(hour, minute, 0)
            .ok_or_else(|| Failure::usage("Invalid calendar date."))?;
        let at = Local
            .from_local_datetime(&time)
            .earliest()
            .ok_or_else(|| Failure::usage("The selected local time does not exist."))?;
        return Ok(at.timestamp() as f64);
    }
    let split = spec.char_indices().next_back().map(|(i, _)| i).unwrap_or(0);
    let (amount, unit) = spec.split_at(split);
    let factor = match unit {
        "m" => 60,
        "h" => 3600,
        "d" => 86400,
        "w" => 604800,
        _ => 0,
    };
    let seconds = amount
        .parse::<i64>()
        .ok()
        .filter(|v| *v > 0)
        .and_then(|v| v.checked_mul(factor))
        .filter(|v| *v > 0)
        .ok_or_else(|| {
            Failure::usage(format!(
                "Unrecognized time '{spec}'. Use 7d, 12h, 30m, 2w, tonight or tomorrow."
            ))
        })?;
    if unit == "d" || unit == "w" {
        let days = (seconds / 86400) as u64;
        return now
            .checked_add_days(Days::new(days))
            .map(|v| v.timestamp() as f64)
            .ok_or_else(|| Failure::usage("Date is out of range."));
    }
    now.timestamp()
        .checked_add(seconds)
        .map(|v| v as f64)
        .ok_or_else(|| Failure::usage("Date is out of range."))
}
use chrono::Timelike;
fn policy<C: Read + Write>(client: &mut Client<C>) -> Result<PolicySnapshot> {
    match rpc(client, Request::LoadPolicy)? {
        Response::Policy(p) => Ok(p),
        _ => Err(unexpected()),
    }
}
fn acknowledged<C: Read + Write>(
    client: &mut Client<C>,
    request: Request,
    summary: String,
) -> Result<(Value, String)> {
    match rpc(client, request)? {
        Response::Acknowledged(_) => Ok((
            json!({"schemaVersion":1,"status":"ok","summary":summary}),
            summary,
        )),
        _ => Err(unexpected()),
    }
}
fn execute<C: Read + Write>(
    args: &[String],
    client: &mut Client<C>,
    stdin: &mut dyn Read,
) -> Result<(Value, String)> {
    let command = args.first().map(String::as_str).unwrap_or("status");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    match command {
        "status" => {
            operands(rest, 0, 0, &[])?;
            match rpc(client, Request::Health)? {
                Response::Health(h) => Ok((
                    json!({"schemaVersion":1,"status":"available","protocolVersion":h.protocol_version,"serviceVersion":h.service_version}),
                    format!(
                        "TinyPrune agent available (protocol {}, service {})",
                        h.protocol_version, h.service_version
                    ),
                )),
                _ => Err(unexpected()),
            }
        }
        "rules" => rules(rest, client, stdin),
        "upcoming" => {
            operands(rest, 0, 0, &[])?;
            let mut items = Vec::new();
            let mut cursor = None;
            loop {
                match rpc(
                    client,
                    Request::LoadUpcoming {
                        rule_id: None,
                        disposition: None,
                        after: cursor.clone(),
                        limit: 200,
                    },
                )? {
                    Response::UpcomingPage(page) => {
                        items.extend(page.items.into_iter().map(|i| i.explanation));
                        if page.next_cursor.is_some() && page.next_cursor == cursor {
                            return Err(unexpected());
                        }
                        cursor = page.next_cursor;
                        if cursor.is_none() {
                            break;
                        }
                    }
                    _ => return Err(unexpected()),
                }
            }
            let text = if items.is_empty() {
                "No scheduled items.".into()
            } else {
                items
                    .iter()
                    .map(explanation_text)
                    .collect::<Vec<_>>()
                    .join("\n\n")
            };
            Ok((json!({"schemaVersion":1,"items":items}), text))
        }
        "activity" => {
            operands(rest, 0, 0, &[])?;
            match rpc(client, Request::LoadActivity { limit: 50 })? {
                Response::Activity(events) => {
                    let text = if events.is_empty() {
                        "No activity recorded.".into()
                    } else {
                        events
                            .iter()
                            .map(|e| {
                                format!(
                                    "{}  {}  {}{}",
                                    e.occurred_at,
                                    enum_text(e.kind),
                                    e.identity
                                        .as_ref()
                                        .map(|i| i.path_hint.as_str())
                                        .or(e.detail.as_deref())
                                        .unwrap_or(""),
                                    e.explanation
                                        .as_ref()
                                        .map(|e| format!("\n{}", explanation_text(e)))
                                        .unwrap_or_default()
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("\n")
                    };
                    Ok((json!({"schemaVersion":1,"events":events}), text))
                }
                _ => Err(unexpected()),
            }
        }
        "why" | "explain" => {
            let (p, _) = operands(rest, 1, 1, &[])?;
            match rpc(client, Request::ExplainItem { path: path(&p[0])? })? {
                Response::ItemExplanation(e) => Ok((
                    json!({"schemaVersion":1,"explanation":e}),
                    format!(
                        "{}\nOverrides: {}",
                        explanation_text(&e.explanation),
                        value(&e.overrides)
                    ),
                )),
                _ => Err(unexpected()),
            }
        }
        "keep" => {
            let (p, f) = operands(rest, 1, 1, &["--descendants"])?;
            let p = path(&p[0])?;
            acknowledged(
                client,
                Request::SetItemOverride {
                    path: p.clone(),
                    policy: OverridePolicy::Keep {
                        protect_descendants: f.iter().any(|f| f == "--descendants"),
                    },
                },
                format!("Keeping {p}"),
            )
        }
        "inherit" | "unkeep" => {
            let (p, _) = operands(rest, 1, 1, &[])?;
            let p = path(&p[0])?;
            acknowledged(
                client,
                Request::ClearItemOverride { path: p.clone() },
                format!("{p} now inherits its rule"),
            )
        }
        "expire" => {
            let (p, _) = operands(rest, 2, 2, &[])?;
            let at = deadline(&p[1], false)?;
            let p = path(&p[0])?;
            acknowledged(
                client,
                Request::SetItemOverride {
                    path: p.clone(),
                    policy: OverridePolicy::CustomExpiry {
                        expires_at: at,
                        state: RuleState::Active,
                    },
                },
                format!("{p} expires {at} (Unix seconds)"),
            )
        }
        "pause" => {
            let (p, _) = operands(rest, 0, 1, &[])?;
            if let Some(spec) = p.first() {
                let until = deadline(spec, true)?;
                acknowledged(
                    client,
                    Request::PauseUntil { until },
                    format!("TinyPrune is paused until {until} (Unix seconds)"),
                )
            } else {
                acknowledged(
                    client,
                    Request::SetGlobalPause { paused: true },
                    "TinyPrune is paused".into(),
                )
            }
        }
        "resume" => {
            operands(rest, 0, 0, &[])?;
            acknowledged(
                client,
                Request::SetGlobalPause { paused: false },
                "TinyPrune resumed".into(),
            )
        }
        "delete-rule" => {
            let (p, _) = operands(rest, 1, 1, &[])?;
            acknowledged(
                client,
                Request::DeleteRule { id: p[0].clone() },
                format!("Deleted rule {}", p[0]),
            )
        }
        "rebuild-index" => {
            operands(rest, 0, 0, &[])?;
            acknowledged(
                client,
                Request::RebuildIndex,
                "Index rebuild requested".into(),
            )
        }
        "roots" => roots(rest, client),
        "config" => {
            let sub = rest
                .first()
                .map(String::as_str)
                .ok_or_else(|| Failure::usage("config needs export or import."))?;
            match sub {
            "export"=>{operands(&rest[1..],0,0,&[])?;match rpc(client,Request::ExportConfig)?{Response::Config{text}=>Ok((json!({"schemaVersion":1,"config":text}),text)),_=>Err(unexpected())}},
            "import"|"apply"=>{let(p,f)=operands(&rest[1..],1,1,&["--active"])?;let text=read_input(&p[0],stdin)?;let revision=policy(client)?.revision;acknowledged(client,Request::ImportConfig{text,activate:f.iter().any(|f|f=="--active"),revision},"Configuration imported".into())},
            _=>Err(Failure::usage("Unsupported config command. The IPC supports config export and import, not local validate/plan."))
        }
        }
        "doctor" => {
            operands(rest, 0, 0, &[])?;
            let health = match rpc(client, Request::Health)? {
                Response::Health(h) => h,
                _ => return Err(unexpected()),
            };
            let overview = match rpc(client, Request::LoadOverview)? {
                Response::Overview(o) => o,
                _ => return Err(unexpected()),
            };
            let settings = match rpc(client, Request::LoadSettings)? {
                Response::Settings(s) => s,
                _ => return Err(unexpected()),
            };
            let text=format!("TinyPrune agent available (protocol {}, service {})\nIndexed items: {}\nGlobally paused: {}\nRoots: {}\nSettings: {}\nUpcoming decisions:\n{}",health.protocol_version,health.service_version,overview.indexed_items,overview.policy.globally_paused,value(&overview.root_statuses),value(&settings),overview.upcoming.iter().map(|i|explanation_text(&i.explanation)).collect::<Vec<_>>().join("\n\n"));
            Ok((
                json!({"schemaVersion":1,"health":health,"overview":overview,"settings":settings}),
                text,
            ))
        }
        _ => Err(Failure::usage(format!("Unknown command '{command}'."))),
    }
}
fn rules<C: Read + Write>(
    rest: &[String],
    client: &mut Client<C>,
    stdin: &mut dyn Read,
) -> Result<(Value, String)> {
    let sub = rest.first().map(String::as_str).unwrap_or("list");
    let args = if rest.is_empty() { &[][..] } else { &rest[1..] };
    match sub {
        "list" => {
            operands(args, 0, 0, &[])?;
            let p = policy(client)?;
            let text = if p.rules.is_empty() {
                "No rules configured.".into()
            } else {
                format!(
                    "{}{}",
                    if p.globally_paused {
                        "All rules are paused.\n"
                    } else {
                        ""
                    },
                    p.rules
                        .iter()
                        .map(|r| format!(
                            "{}  {}  {}  {}  {}  {} for {} seconds",
                            r.id,
                            r.name,
                            enum_text(r.state),
                            r.scope.path,
                            value(&r.matcher),
                            enum_text(r.expiry_basis),
                            r.lifetime
                        ))
                        .collect::<Vec<_>>()
                        .join("\n")
                )
            };
            Ok((
                json!({"schemaVersion":1,"globallyPaused":p.globally_paused,"rules":p.rules}),
                text,
            ))
        }
        "remove" => {
            let (p, _) = operands(args, 1, 1, &[])?;
            acknowledged(
                client,
                Request::DeleteRule { id: p[0].clone() },
                format!("Deleted rule {}", p[0]),
            )
        }
        "add" | "edit" => {
            let count = if sub == "edit" { 2 } else { 1 };
            let (p, _) = operands(args, count, count, &[])?;
            let mut rule: Rule = serde_json::from_str(&read_input(&p[count - 1], stdin)?)
                .map_err(|e| Failure::new("invalidData", format!("Invalid rule JSON: {e}"), 65))?;
            if sub == "edit" {
                rule.id = p[0].clone();
            }
            let revision = policy(client)?.revision;
            let summary = format!("Saved rule {}", rule.id);
            acknowledged(
                client,
                Request::SaveRule {
                    rule,
                    roots: None,
                    keep_paths: vec![],
                    unkeep_paths: vec![],
                    revision,
                },
                summary,
            )
        }
        "activate" | "preview" => {
            let (p, _) = operands(args, 1, 1, &[])?;
            let snapshot = policy(client)?;
            let mut rule = snapshot
                .rules
                .into_iter()
                .find(|r| r.id == p[0])
                .ok_or_else(|| {
                    Failure::new("invalidData", format!("No rule with id {}", p[0]), 65)
                })?;
            if sub == "activate" {
                rule.state = RuleState::Active;
                acknowledged(
                    client,
                    Request::SaveRule {
                        rule,
                        roots: None,
                        keep_paths: vec![],
                        unkeep_paths: vec![],
                        revision: snapshot.revision,
                    },
                    format!("Activated rule {}", p[0]),
                )
            } else {
                match rpc(client, Request::PreviewRule(rule))? {
                    Response::RulePreview(preview) => {
                        let text=format!("Preview: {} matches, {} eligible now, {} estimated bytes, {} scanned entries{}\nNothing was changed or moved to Trash.{}",preview.matches,preview.eligible_now,preview.estimated_bytes,preview.scanned_entries,if preview.truncated{" (truncated; counts are lower bounds)"}else{""},preview.samples.iter().map(|s|format!("\n\n{}\nBytes: {}",explanation_text(&s.explanation),value(s.bytes))).collect::<String>());
                        Ok((json!({"schemaVersion":1,"preview":preview}), text))
                    }
                    _ => Err(unexpected()),
                }
            }
        }
        _ => Err(Failure::usage(format!("Unknown rules command '{sub}'."))),
    }
}
fn roots<C: Read + Write>(rest: &[String], client: &mut Client<C>) -> Result<(Value, String)> {
    let sub = rest.first().map(String::as_str).unwrap_or("list");
    let args = if rest.is_empty() { &[][..] } else { &rest[1..] };
    match sub {
        "list" => {
            operands(args, 0, 0, &[])?;
            match rpc(client, Request::LoadRoots)? {
                Response::Roots(roots) => {
                    let text = if roots.is_empty() {
                        "No managed folders.".into()
                    } else {
                        roots
                            .iter()
                            .map(|r| format!("{}  {}  {}", r.id, r.name, r.path))
                            .collect::<Vec<_>>()
                            .join("\n")
                    };
                    Ok((json!({"schemaVersion":1,"roots":roots}), text))
                }
                _ => Err(unexpected()),
            }
        }
        "add" => {
            let (p, _) = operands(args, 2, 3, &[])?;
            let root = Root {
                id: p[0].clone(),
                path: path(&p[1])?,
                name: p.get(2).cloned().unwrap_or_else(|| p[1].clone()),
            };
            acknowledged(
                client,
                Request::AddRoot(root),
                format!("Added managed folder {}", p[1]),
            )
        }
        "remove" => {
            let (p, _) = operands(args, 1, 1, &[])?;
            acknowledged(
                client,
                Request::RemoveRoot { id: p[0].clone() },
                format!("Removed managed folder {}", p[0]),
            )
        }
        _ => Err(Failure::usage("Unknown roots command.")),
    }
}

/// Runs one CLI invocation. The connector is injectable; tests use the real IPC framing/server.
pub fn run(
    args: &[String],
    stdin: &mut dyn Read,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
    connect: impl FnOnce(Option<&str>) -> io::Result<Box<dyn Connection>>,
) -> i32 {
    let json_mode = args.iter().any(|a| a == "--json");
    let result = (|| {
        let mut args: Vec<String> = args
            .iter()
            .filter(|a| a.as_str() != "--json")
            .cloned()
            .collect();
        if args.iter().any(|a| a == "--version") {
            return Ok((
                json!({"schemaVersion":1,"version":env!("CARGO_PKG_VERSION")}),
                format!("tinyprune {}", env!("CARGO_PKG_VERSION")),
            ));
        }
        if args.iter().any(|a| a == "--help" || a == "-h")
            || args.first().is_some_and(|a| a == "help")
        {
            return Ok((Value::Null, USAGE.to_owned()));
        }
        let mut endpoint = None;
        let mut i = 0;
        while i < args.len() {
            if args[i] == "--socket" {
                if i + 1 == args.len() {
                    return Err(Failure::usage("--socket needs a path."));
                }
                endpoint = Some(args.remove(i + 1));
                args.remove(i);
            } else {
                i += 1;
            }
        }
        // Validate command syntax before attempting a connection, without evaluating policy.
        validate_syntax(&args)?;
        let stream = connect(endpoint.as_deref()).map_err(|e| transport(e, false))?;
        let mut client = Client::connect(stream, VersionRange::default(), DEFAULT_MAX_FRAME)
            .map_err(|e| transport(e, false))?;
        execute(&args, &mut client, stdin)
    })();
    match result {
        Ok((json, text)) => {
            if json_mode && !json.is_null() {
                let _ = writeln!(stdout, "{json}");
            } else {
                let _ = write!(
                    stdout,
                    "{text}{}",
                    if text.ends_with('\n') { "" } else { "\n" }
                );
            }
            0
        }
        Err(e) => {
            if json_mode {
                if e.code == "unavailable" {
                    let _ = writeln!(stdout, "{{\"schemaVersion\":1,\"status\":\"unavailable\"}}");
                } else {
                    let _ = writeln!(
                        stdout,
                        "{}",
                        json!({"schemaVersion":1,"status":"error","code":e.code,"message":e.message,"exitCode":e.exit,"mayHaveApplied":e.uncertain})
                    );
                }
            } else {
                let _ = writeln!(stderr, "tinyprune: {}", e.message);
                if e.exit == 64 {
                    let _ = writeln!(stderr, "{USAGE}");
                }
            }
            e.exit
        }
    }
}
fn validate_syntax(args: &[String]) -> Result<()> {
    let command = args.first().map(String::as_str).unwrap_or("status");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    match command {
        "status" | "upcoming" | "activity" | "doctor" | "resume" | "rebuild-index" => {
            operands(rest, 0, 0, &[])?;
        }
        "keep" => {
            operands(rest, 1, 1, &["--descendants"])?;
        }
        "inherit" | "unkeep" | "why" | "explain" | "delete-rule" => {
            operands(rest, 1, 1, &[])?;
        }
        "expire" => {
            operands(rest, 2, 2, &[])?;
        }
        "pause" => {
            operands(rest, 0, 1, &[])?;
        }
        "rules" => {
            let sub = rest.first().map(String::as_str).unwrap_or("list");
            let count = match sub {
                "list" => 0,
                "edit" => 2,
                "add" | "remove" | "activate" | "preview" => 1,
                _ => return Err(Failure::usage("Unknown rules command.")),
            };
            operands(rest.get(1..).unwrap_or(&[]), count, count, &[])?;
        }
        "roots" => {
            let sub = rest.first().map(String::as_str).unwrap_or("list");
            let (min, max) = match sub {
                "list" => (0, 0),
                "add" => (2, 3),
                "remove" => (1, 1),
                _ => return Err(Failure::usage("Unknown roots command.")),
            };
            operands(rest.get(1..).unwrap_or(&[]), min, max, &[])?;
        }
        "config" => {
            let sub = rest.first().map(String::as_str).unwrap_or("");
            let count = match sub {
                "export" => 0,
                "import" | "apply" => 1,
                _ => {
                    return Err(Failure::usage(
                        "The IPC supports config export and import, not local validate/plan.",
                    ))
                }
            };
            operands(
                &rest[1..],
                count,
                count,
                if count == 1 { &["--active"] } else { &[] },
            )?;
        }
        _ => return Err(Failure::usage(format!("Unknown command '{command}'."))),
    }
    Ok(())
}

pub fn connect_local(endpoint: Option<&str>) -> io::Result<Box<dyn Connection>> {
    let endpoint = endpoint
        .map(PathBuf::from)
        .map(Ok)
        .unwrap_or_else(tinyprune_ipc::default_endpoint)?;
    #[cfg(unix)]
    {
        Ok(Box::new(tinyprune_ipc::unix::connect(endpoint)?))
    }
    #[cfg(windows)]
    {
        Ok(Box::new(tinyprune_ipc::windows::connect(
            endpoint.to_str().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "Pipe path must be UTF-8")
            })?,
        )?))
    }
}
