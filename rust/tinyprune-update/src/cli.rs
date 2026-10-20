//! `tinyprune update ...`: the user-facing surface (and the contract the UI shells out to).
//!
//! ```text
//! tinyprune update status   [--json]
//! tinyprune update check    [--json] [--auto]            --auto: honors checkForNewVersions and a 24h cadence; never installs
//! tinyprune update install  [--json] [--confirm TOKEN]   without --confirm: shows the offer and its token, installs nothing
//! tinyprune update settings [--json] [--check-for-new-versions on|off]
//! tinyprune update self-check --expect-version V --expect-build N   (run by the updater against a staged build)
//! ```
//! Installation is never automatic: only `install --confirm <token from a check you read>` installs.

use crate::build_info::{self, Disabled, Trust};
use crate::install::AgentOutcome;
use crate::layout::{Layout, StdFs};
use crate::manifest::{Check, Offer, Platform};
use crate::state::{State, StateFile};
use crate::system::{self, IpcDaemon, ProcessSelfCheck, RealSleeper};
use crate::transport::{Transport, UreqTransport};
use crate::updater::{is_managed, InstallParts, UpdateError, Updater};
use serde_json::{json, Value};
use std::io::{self, Write};
use tinyprune_ipc::Connection;

pub const USAGE: &str = "usage: tinyprune update status|check|install|settings [--json]\n  check [--auto]                    look for a newer signed build (never installs)\n  install [--confirm <token>]       install the offer named by the token from `update check`\n  settings [--check-for-new-versions on|off]\n  --socket <path> overrides the agent endpoint (used to quiesce Trash during an install)";

pub type Connect<'a> = &'a dyn Fn(Option<&str>) -> io::Result<Box<dyn Connection>>;

struct Failure {
    code: &'static str,
    message: String,
    exit: i32,
}
fn failure(code: &'static str, message: impl Into<String>, exit: i32) -> Failure {
    Failure {
        code,
        message: message.into(),
        exit,
    }
}
fn from_update_error(e: UpdateError) -> Failure {
    use crate::install::InstallError as I;
    use crate::manifest::FeedError as F;
    let message = e.to_string();
    match e {
        UpdateError::Disabled(_) => failure("disabled", message, 78),
        UpdateError::Feed(F::Transport(_)) => failure("unavailable", message, 69),
        UpdateError::Feed(_) => failure("feedRejected", message, 65),
        UpdateError::ConfirmationMismatch => failure("confirmationMismatch", message, 65),
        UpdateError::NothingToInstall => failure("upToDate", message, 0),
        UpdateError::State(_) => failure("stateUnavailable", message, 70),
        UpdateError::Install(i) => match i {
            I::Interlock(_) => failure("busy", message, 75),
            I::Download(crate::download::DownloadError::Transport(_)) => {
                failure("unavailable", message, 69)
            }
            I::Download(_) | I::Extract(_) | I::BadPackage(_) | I::SelfCheck(_) => {
                failure("packageRejected", message, 65)
            }
            I::RolledBack(_) => failure("rolledBack", message, 70),
            I::RollbackFailed(_) => failure("rollbackFailed", message, 70),
            I::Swap(_) | I::Restart(_) | I::State(_) => failure("installFailed", message, 70),
        },
    }
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn offer_json(offer: &Offer) -> Value {
    json!({
        "version": offer.version, "build": offer.build, "notesUrl": offer.notes_url, "published": offer.published,
        "platform": offer.platform, "sizeBytes": offer.artifact.size,
        "confirmationToken": offer.confirmation_token(),
        "installCommand": format!("tinyprune update install --confirm {}", offer.confirmation_token()),
    })
}
fn offer_text(offer: &Offer, installed: &crate::manifest::Installed) -> String {
    format!(
        "Update available: {} (build {}) — you have {} (build {}).\nSize: {} bytes{}{}\nNothing is installed until you confirm:\n  tinyprune update install --confirm {}",
        offer.version, offer.build, installed.version, installed.build, offer.artifact.size,
        offer.published.as_ref().map(|p| format!("\nPublished: {p}")).unwrap_or_default(),
        offer.notes_url.as_ref().map(|u| format!("\nRelease notes: {u}")).unwrap_or_default(),
        offer.confirmation_token()
    )
}

/// Returns the process exit code.
pub fn run(
    args: &[String],
    connect: Connect<'_>,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> i32 {
    let json_mode = args.iter().any(|a| a == "--json");
    match execute(args, connect) {
        Ok((value, text)) => {
            if json_mode {
                let _ = writeln!(stdout, "{value}");
            } else if !text.is_empty() {
                let _ = writeln!(stdout, "{text}");
            }
            0
        }
        Err(f) => {
            if json_mode {
                let status = if f.code == "disabled" {
                    "disabled"
                } else if f.exit == 0 {
                    "upToDate"
                } else {
                    "error"
                };
                let _ = writeln!(
                    stdout,
                    "{}",
                    json!({"schemaVersion":1,"status":status,"code":f.code,"message":f.message,"exitCode":f.exit})
                );
            } else {
                let target: &mut dyn Write = if f.exit == 0 {
                    &mut *stdout
                } else {
                    &mut *stderr
                };
                let _ = writeln!(target, "tinyprune update: {}", f.message);
                if f.exit == 64 {
                    let _ = writeln!(stderr, "{USAGE}");
                }
            }
            f.exit
        }
    }
}

/// Splits `--flag value` pairs and bare flags; rejects anything unexpected.
struct Args {
    flags: Vec<String>,
    values: Vec<(String, String)>,
    socket: Option<String>,
}
fn parse(rest: &[String], bare: &[&str], valued: &[&str]) -> Result<Args, Failure> {
    let mut out = Args {
        flags: vec![],
        values: vec![],
        socket: None,
    };
    let mut it = rest.iter();
    while let Some(arg) = it.next() {
        if arg == "--json" {
            continue;
        }
        if arg == "--socket" {
            out.socket = Some(
                it.next()
                    .ok_or_else(|| failure("usage", "--socket needs a path", 64))?
                    .clone(),
            );
        } else if bare.contains(&arg.as_str()) {
            out.flags.push(arg.clone());
        } else if valued.contains(&arg.as_str()) {
            out.values.push((
                arg.clone(),
                it.next()
                    .ok_or_else(|| failure("usage", format!("{arg} needs a value"), 64))?
                    .clone(),
            ));
        } else {
            return Err(failure("usage", format!("unknown argument '{arg}'"), 64));
        }
    }
    Ok(out)
}
impl Args {
    fn value(&self, name: &str) -> Option<&str> {
        self.values
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }
}

fn layout() -> Result<Layout, Failure> {
    Layout::from_environment().map_err(|e| failure("stateUnavailable", e.to_string(), 70))
}
fn state_of(layout: &Layout) -> Result<(StateFile, State), Failure> {
    let file = StateFile::new(layout.state_file());
    let state = file
        .load()
        .map_err(|e| failure("stateUnavailable", e.to_string(), 70))?;
    Ok((file, state))
}
fn transport(trust: &Trust) -> Box<dyn Transport> {
    #[cfg(feature = "test-overrides")]
    if trust.allow_loopback_http {
        return Box::new(UreqTransport::new_allowing_loopback_http());
    }
    let _ = trust;
    Box::new(UreqTransport::new())
}
/// Trust is fixed at build time; a copy outside `<data>/versions` is never updated.
fn enabled(layout: &Layout) -> Result<Trust, Failure> {
    let trust = build_info::trust().map_err(|d| failure("disabled", d.to_string(), 78))?;
    let exe = std::env::current_exe().map_err(|e| {
        failure(
            "disabled",
            format!("cannot locate this executable: {e}"),
            78,
        )
    })?;
    if !is_managed(layout, &exe) {
        return Err(failure("disabled", Disabled::NotManaged.to_string(), 78));
    }
    Ok(trust)
}

fn execute(args: &[String], connect: Connect<'_>) -> Result<(Value, String), Failure> {
    let sub = args
        .first()
        .map(String::as_str)
        .filter(|a| !a.starts_with('-'))
        .unwrap_or("status");
    let rest = if args.first().is_some_and(|a| !a.starts_with('-')) {
        &args[1..]
    } else {
        args
    };
    match sub {
        "status" => {
            let a = parse(rest, &[], &[])?;
            let _ = a.socket;
            let layout = layout()?;
            let (_, state) = state_of(&layout)?;
            let exe = std::env::current_exe().ok();
            let managed = exe.as_deref().is_some_and(|e| is_managed(&layout, e));
            let disabled = build_info::trust()
                .err()
                .map(|d| d.to_string())
                .or_else(|| (!managed).then(|| Disabled::NotManaged.to_string()));
            let installed = format!("{} (build {})", build_info::VERSION, build_info::BUILD);
            Ok((
                json!({"schemaVersion":1,"status":"ok","installedVersion":build_info::VERSION,"installedBuild":build_info::BUILD,
                       "updatesEnabled":disabled.is_none(),"disabledReason":disabled,"managedInstall":managed,
                       "checkForNewVersions":state.checks_enabled(),"lastCheck":state.last_check,
                       "platform":Platform::current().map(|p| p.key)}),
                format!(
                    "Installed: {installed}\nUpdates: {}\nCheck for new versions: {}",
                    disabled
                        .as_deref()
                        .map_or("enabled".to_owned(), |d| format!("disabled — {d}")),
                    if state.checks_enabled() { "on" } else { "off" }
                ),
            ))
        }
        "settings" => {
            let a = parse(rest, &[], &["--check-for-new-versions"])?;
            let layout = layout()?;
            let (file, mut state) = state_of(&layout)?;
            if let Some(v) = a.value("--check-for-new-versions") {
                let on = match v {
                    "on" | "true" => true,
                    "off" | "false" => false,
                    _ => {
                        return Err(failure(
                            "usage",
                            "--check-for-new-versions takes on or off",
                            64,
                        ))
                    }
                };
                state.check_for_new_versions = Some(on);
                file.save(&state)
                    .map_err(|e| failure("stateUnavailable", e.to_string(), 70))?;
            }
            Ok((
                json!({"schemaVersion":1,"status":"ok","checkForNewVersions":state.checks_enabled()}),
                format!(
                    "Check for new versions: {}",
                    if state.checks_enabled() { "on" } else { "off" }
                ),
            ))
        }
        "self-check" => {
            let a = parse(rest, &[], &["--expect-version", "--expect-build"])?;
            let version = a
                .value("--expect-version")
                .ok_or_else(|| failure("usage", "--expect-version required", 64))?;
            let build: u64 = a
                .value("--expect-build")
                .and_then(|b| b.parse().ok())
                .ok_or_else(|| failure("usage", "--expect-build must be a number", 64))?;
            if build_info::VERSION != version || build_info::BUILD != build {
                return Err(failure(
                    "selfCheckFailed",
                    format!(
                        "this binary is {} build {}, expected {version} build {build}",
                        build_info::VERSION,
                        build_info::BUILD
                    ),
                    1,
                ));
            }
            // A build that cannot verify the next update would strand its users.
            build_info::trust().map_err(|d| failure("selfCheckFailed", d.to_string(), 1))?;
            Ok((
                json!({"schemaVersion":1,"status":"ok","version":version,"build":build,"publicKey":build_info::embedded_public_key()}),
                format!("self-check ok: {version} build {build}"),
            ))
        }
        "check" => {
            let a = parse(rest, &["--auto"], &[])?;
            let layout = layout()?;
            let (_, state) = state_of(&layout)?;
            let auto = a.flag("--auto");
            if auto && !state.auto_check_due(now()) {
                let reason = if state.checks_enabled() {
                    "notDue"
                } else {
                    "disabled"
                };
                return Ok((
                    json!({"schemaVersion":1,"status":"skipped","reason":reason}),
                    String::new(),
                ));
            }
            let trust = match enabled(&layout) {
                Ok(t) => t,
                Err(f) if auto => {
                    return Ok((
                        json!({"schemaVersion":1,"status":"skipped","reason":"unavailable","message":f.message}),
                        String::new(),
                    ))
                }
                Err(f) => return Err(f),
            };
            let transport = transport(&trust);
            let updater = Updater {
                layout: &layout,
                transport: transport.as_ref(),
                trust: &trust,
                platform: Platform::current(),
                state: StateFile::new(layout.state_file()),
            };
            match updater.check(now()).map_err(from_update_error)? {
                Check::UpToDate => Ok((
                    json!({"schemaVersion":1,"status":"upToDate","installedVersion":trust.installed.version,"installedBuild":trust.installed.build}),
                    format!(
                        "TinyPrune {} (build {}) is up to date.",
                        trust.installed.version, trust.installed.build
                    ),
                )),
                Check::Unsupported { platform } => Ok((
                    json!({"schemaVersion":1,"status":"unsupported","platform":platform}),
                    format!("No build is published for {platform}."),
                )),
                Check::Available(offer) => {
                    let mut value = offer_json(&offer);
                    value["schemaVersion"] = json!(1);
                    value["status"] = json!("available");
                    Ok((value, offer_text(&offer, &trust.installed)))
                }
            }
        }
        "install" => {
            let a = parse(rest, &[], &["--confirm"])?;
            let layout = layout()?;
            let trust = enabled(&layout)?;
            let transport = transport(&trust);
            let updater = Updater {
                layout: &layout,
                transport: transport.as_ref(),
                trust: &trust,
                platform: Platform::current(),
                state: StateFile::new(layout.state_file()),
            };
            let Some(token) = a.value("--confirm") else {
                return match updater.check(now()).map_err(from_update_error)? {
                    Check::Available(offer) => {
                        let mut value = offer_json(&offer);
                        value["schemaVersion"] = json!(1);
                        value["status"] = json!("confirmationRequired");
                        Ok((
                            value,
                            format!(
                                "{}\n(Not installed: confirmation required.)",
                                offer_text(&offer, &trust.installed)
                            ),
                        ))
                    }
                    Check::UpToDate => Ok((
                        json!({"schemaVersion":1,"status":"upToDate"}),
                        "Already up to date.".into(),
                    )),
                    Check::Unsupported { platform } => Err(failure(
                        "unsupported",
                        format!("No build is published for {platform}."),
                        65,
                    )),
                };
            };
            let socket = a.socket.clone();
            let dial = move || connect(socket.as_deref());
            let daemon = IpcDaemon { connect: &dial };
            let restarter = system::native_restarter();
            let fs = StdFs::native();
            let checker = ProcessSelfCheck::default();
            let sleeper = RealSleeper;
            let done = updater
                .install_confirmed(token, now(), |_| InstallParts {
                    fs: &fs,
                    daemon: &daemon,
                    restarter: restarter.as_ref(),
                    checker: &checker,
                    sleeper: &sleeper,
                })
                .map_err(from_update_error)?;
            let (agent, note) = match done.agent {
                AgentOutcome::Restarted => ("restarted", "The agent was restarted and passed its health check."),
                AgentOutcome::NotRunning => ("notRunning", "The agent was not running; the new build starts with it."),
                AgentOutcome::ManualRestartRequired => ("manualRestartRequired", "The agent is running outside a service this tool manages: restart it to run the new build."),
            };
            Ok((
                json!({"schemaVersion":1,"status":"installed","from":done.from,"to":done.to,"agent":agent,"previousKept":done.previous_kept,"pruneFailures":done.prune_failures}),
                format!(
                    "Installed {} (was {}). {note}\nThe previous build is kept for rollback.",
                    done.to, done.from
                ),
            ))
        }
        _ => Err(failure(
            "usage",
            format!("unknown update command '{sub}'"),
            64,
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_args(args: &[&str]) -> (i32, String, String) {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let no_agent: Connect<'_> = &|_| Err(io::Error::new(io::ErrorKind::NotFound, "no agent"));
        let code = run(&args, no_agent, &mut out, &mut err);
        (
            code,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[test]
    fn unknown_commands_and_arguments_are_usage_errors() {
        assert_eq!(run_args(&["bogus"]).0, 64);
        assert_eq!(run_args(&["check", "--wat"]).0, 64);
        assert_eq!(
            run_args(&["settings", "--check-for-new-versions", "maybe"]).0,
            64
        );
        assert_eq!(run_args(&["install", "--confirm"]).0, 64);
    }
    #[test]
    fn a_development_build_reports_disabled_in_json_and_text() {
        let (code, out, _) = run_args(&["check", "--json"]);
        assert_eq!(code, 78);
        let v: Value = serde_json::from_str(out.trim()).unwrap();
        assert_eq!(
            (v["status"].as_str(), v["code"].as_str()),
            (Some("disabled"), Some("disabled"))
        );
        let (code, _, err) = run_args(&["install", "--confirm", "abc"]);
        assert_eq!(code, 78);
        assert!(err.contains("no update key"), "{err}");
    }
    #[test]
    fn auto_check_is_silent_when_the_build_cannot_update() {
        let (code, out, err) = run_args(&["check", "--auto"]);
        assert_eq!((code, out.as_str(), err.as_str()), (0, "", ""));
    }
    #[test]
    fn self_check_rejects_a_mismatched_or_non_updating_build() {
        assert_eq!(
            run_args(&[
                "self-check",
                "--expect-version",
                "9.9.9",
                "--expect-build",
                "9"
            ])
            .0,
            1
        );
        assert_eq!(run_args(&["self-check"]).0, 64);
    }
}
