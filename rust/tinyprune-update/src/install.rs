//! Staged, interlocked, health-checked installation (ADR 0012).
//!
//! 1. Download (size cap, SHA-256) and extract into a staging directory under `versions/`.
//! 2. Run the staged binaries (`--version` plus a self-check). A bad build never reaches the pointer
//!    and never touches the running agent.
//! 3. Move the staged directory to `versions/<version>-b<build>`.
//! 4. Quiesce the agent: Trash is blocked and any in-flight move is allowed to finish. Fail closed: if
//!    the agent is reachable but will not quiesce (busy, unsupported, error) nothing is swapped.
//! 5. Atomically repoint `current`, restart the service, require the new agent to answer a health
//!    check. On failure repoint to the previous build and restart it (rollback).
//! 6. Keep exactly the new and the previous build; prune the rest.

use crate::archive::{self, ArchiveError, Limits};
use crate::crypto::random_hex;
use crate::download::{download, DownloadError};
use crate::interlock::{Phase, Status};
use crate::layout::{self, InstallFs, Layout, SwapError};
use crate::manifest::{Installed, Offer, Platform};
use crate::state::StateFile;
use crate::transport::Transport;
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlError {
    /// No agent is listening (socket absent or refused).
    NotRunning,
    /// The agent answered but does not implement the update interlock.
    Unsupported,
    /// The agent refused: another updater holds the lease.
    Busy(String),
    Failed(String),
}
impl std::fmt::Display for ControlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotRunning => f.write_str("the agent is not running"),
            Self::Unsupported => f.write_str(
                "the running agent does not support the update interlock; stop it and retry",
            ),
            Self::Busy(m) | Self::Failed(m) => f.write_str(m),
        }
    }
}

/// The running agent, as the updater sees it (real implementation: IPC; see `system`).
pub trait DaemonControl {
    fn quiesce(&self, token: &str, target: &str, lease: Duration) -> Result<Status, ControlError>;
    fn status(&self) -> Result<Status, ControlError>;
    fn release(&self, token: &str) -> Result<(), ControlError>;
    /// The agent's `service_version`.
    fn health(&self) -> Result<String, ControlError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestartKind {
    Restarted,
    /// The agent is not supervised by a unit/task this tool manages; it keeps running the old binary
    /// until restarted by the user.
    Unmanaged,
}
pub trait Restarter {
    fn restart(&self) -> Result<RestartKind, String>;
}

pub struct Expected<'a> {
    pub version: &'a str,
    pub build: u64,
}
#[derive(Debug)]
pub struct CheckReport {
    /// Version printed by the staged `tinyprune-agentd --version`.
    pub daemon_version: String,
}
/// Runs the staged binaries. `dir` is the (staging) version directory.
pub trait SelfCheck {
    fn check(&self, dir: &Path, expected: &Expected<'_>) -> Result<CheckReport, String>;
}
pub trait Sleeper {
    fn sleep(&self, duration: Duration);
}

#[derive(Debug)]
pub enum InstallError {
    Download(DownloadError),
    Extract(ArchiveError),
    BadPackage(String),
    SelfCheck(String),
    /// Trash could not be quiesced; nothing was changed.
    Interlock(String),
    Swap(SwapError),
    Restart(String),
    /// The new build failed its health check; the previous build was restored and is running.
    RolledBack(String),
    /// Health failed AND restoring the previous build failed: needs the user.
    RollbackFailed(String),
    State(String),
}
impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Download(e) => e.fmt(f),
            Self::Extract(e) => e.fmt(f),
            Self::BadPackage(m) => write!(f, "release package rejected: {m}"),
            Self::SelfCheck(m) => write!(f, "downloaded build failed its self-check; nothing was installed: {m}"),
            Self::Interlock(m) => write!(f, "update not started, pruning is unaffected: {m}"),
            Self::Swap(e) => e.fmt(f),
            Self::Restart(m) => write!(f, "could not restart the agent: {m}"),
            Self::RolledBack(m) => write!(f, "the new build failed its health check; the previous build was restored: {m}"),
            Self::RollbackFailed(m) => write!(f, "the new build failed and the previous build could not be restored automatically: {m}"),
            Self::State(m) => write!(f, "could not record update state: {m}"),
        }
    }
}
impl std::error::Error for InstallError {}

pub struct InstallContext<'a> {
    pub layout: &'a Layout,
    pub fs: &'a dyn InstallFs,
    pub transport: &'a dyn Transport,
    pub platform: &'a Platform,
    pub installed: &'a Installed,
    pub daemon: &'a dyn DaemonControl,
    pub restarter: &'a dyn Restarter,
    pub checker: &'a dyn SelfCheck,
    pub sleeper: &'a dyn Sleeper,
    pub state: &'a StateFile,
    pub limits: Limits,
    /// Lease requested from the agent. Must cover drain time plus the swap.
    pub lease: Duration,
    pub drain_timeout: Duration,
    /// Required lease time left right before the swap.
    pub min_lease_remaining: Duration,
    pub health_timeout: Duration,
    pub poll_interval: Duration,
}
impl InstallContext<'_> {
    pub const DEFAULT_LEASE: Duration = Duration::from_secs(120);
    pub const DEFAULT_DRAIN: Duration = Duration::from_secs(45);
    pub const DEFAULT_MIN_LEASE: Duration = Duration::from_secs(20);
    pub const DEFAULT_HEALTH: Duration = Duration::from_secs(30);
    pub const DEFAULT_POLL: Duration = Duration::from_millis(250);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentOutcome {
    /// No agent was running: the new build starts the next time the agent starts.
    NotRunning,
    Restarted,
    /// An agent is running but not under a unit/task this tool controls: it still runs the old binary.
    ManualRestartRequired,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Installation {
    pub from: String,
    pub to: String,
    pub agent: AgentOutcome,
    pub previous_kept: Option<String>,
    pub prune_failures: Vec<(String, String)>,
}

fn exe(name: &str, platform: &Platform) -> String {
    if platform.key.starts_with("windows") {
        format!("{name}.exe")
    } else {
        name.to_owned()
    }
}

pub fn install(ctx: &InstallContext<'_>, offer: &Offer) -> Result<Installation, InstallError> {
    let name = layout::version_dir_name(&offer.version, offer.build);
    let update_dir = ctx.layout.update_dir();

    // 1. Verified bytes on disk (deleted on drop, success or failure).
    let archive_file =
        download(ctx.transport, &offer.artifact, &update_dir).map_err(InstallError::Download)?;

    // 2. Extract into a staging directory next to the final location (same filesystem => atomic move).
    ctx.fs
        .create_dir_all(&ctx.layout.versions())
        .map_err(|e| InstallError::Swap(SwapError::Io(e.to_string())))?;
    let staged = ctx
        .layout
        .versions()
        .join(format!(".stage-{}", random_hex(6)));
    archive::extract(
        ctx.platform.archive,
        archive_file.path(),
        &staged,
        ctx.limits,
    )
    .map_err(InstallError::Extract)?;
    drop(archive_file);
    let discard = |why: InstallError| {
        let _ = ctx.fs.remove_dir_all(&staged);
        why
    };
    for binary in ["tinyprune", "tinyprune-agentd"] {
        if !staged.join("bin").join(exe(binary, ctx.platform)).is_file() {
            return Err(discard(InstallError::BadPackage(format!(
                "bin/{} is missing",
                exe(binary, ctx.platform)
            ))));
        }
    }

    // 3. The new build must run before anything points at it.
    let report = ctx
        .checker
        .check(
            &staged,
            &Expected {
                version: &offer.version,
                build: offer.build,
            },
        )
        .map_err(|m| discard(InstallError::SelfCheck(m)))?;

    layout::place(ctx.fs, ctx.layout, &staged, &name)
        .map_err(|e| discard(InstallError::Swap(e)))?;
    let remove_placed = |why: InstallError| {
        let _ = ctx.fs.remove_dir_all(&ctx.layout.version_path(&name));
        why
    };

    // Version of the agent that is running now, for rollback verification.
    let old_daemon_version = ctx.daemon.health().ok();

    // 4. Quiesce (fail closed).
    let token = random_hex(16);
    let quiesced = quiesce(ctx, &token, &offer.version).map_err(remove_placed)?;
    let holds_lease = quiesced;
    let release = |ctx: &InstallContext<'_>| {
        if holds_lease {
            let _ = ctx.daemon.release(&token);
        }
    };

    // 5. Swap. The lease must still be live: nothing may kill the agent mid-Trash.
    if holds_lease {
        match ctx.daemon.status() {
            Ok(s)
                if s.phase == Phase::Quiesced
                    && s.lease_remaining
                        .is_some_and(|r| r >= ctx.min_lease_remaining) => {}
            other => {
                release(ctx);
                return Err(remove_placed(InstallError::Interlock(format!(
                    "update lease no longer held ({other:?})"
                ))));
            }
        }
    }
    let previous = match layout::activate(ctx.fs, ctx.layout, &name) {
        Ok(previous) => previous,
        Err(e) => {
            release(ctx);
            return Err(remove_placed(InstallError::Swap(e)));
        }
    };
    // Nothing to restart when no agent was running: the new build starts with it.
    let restart = if holds_lease {
        ctx.restarter.restart()
    } else {
        Ok(RestartKind::Unmanaged)
    };
    let kind = match restart {
        Ok(kind) => kind,
        Err(m) => {
            let rolled = rollback(
                ctx,
                &name,
                previous.as_deref(),
                old_daemon_version.as_deref(),
                holds_lease,
            );
            release(ctx);
            return Err(rolled.map_or_else(
                |e| InstallError::RollbackFailed(format!("restart failed ({m}); {e}")),
                |()| InstallError::RolledBack(format!("restart failed: {m}")),
            ));
        }
    };

    // Health check only when there is an agent to check: it was running before, and we restarted it.
    if holds_lease && kind == RestartKind::Restarted {
        if let Err(why) = wait_healthy(ctx, &report.daemon_version) {
            let rolled = rollback(
                ctx,
                &name,
                previous.as_deref(),
                old_daemon_version.as_deref(),
                true,
            );
            return Err(rolled.map_or_else(
                |e| InstallError::RollbackFailed(format!("{why}; {e}")),
                |()| InstallError::RolledBack(why.clone()),
            ));
        }
    } else {
        // Agent not restarted by us (not running, or unmanaged): release so pruning is not stuck.
        release(ctx);
    }

    ctx.state
        .update(|s| s.previous = previous.clone())
        .map_err(|e| InstallError::State(e.to_string()))?;

    // 6. Retain the previous build for rollback; drop everything older.
    let mut keep = vec![name.as_str()];
    if let Some(p) = previous.as_deref() {
        keep.push(p);
    }
    let prune_failures = layout::prune(ctx.fs, ctx.layout, &keep);
    Ok(Installation {
        from: format!("{}-b{}", ctx.installed.version, ctx.installed.build),
        to: name.clone(),
        agent: match (holds_lease, kind) {
            (false, _) => AgentOutcome::NotRunning,
            (true, RestartKind::Restarted) => AgentOutcome::Restarted,
            (true, RestartKind::Unmanaged) => AgentOutcome::ManualRestartRequired,
        },
        previous_kept: previous,
        prune_failures,
    })
}

/// Returns whether an agent holds our lease. `Ok(false)` = no agent running (nothing to quiesce).
fn quiesce(ctx: &InstallContext<'_>, token: &str, target: &str) -> Result<bool, InstallError> {
    let fail = |m: String| InstallError::Interlock(m);
    match ctx.daemon.quiesce(token, target, ctx.lease) {
        Err(ControlError::NotRunning) => return Ok(false),
        Err(e) => return Err(fail(e.to_string())),
        Ok(s) if s.phase == Phase::Quiesced => return Ok(true),
        Ok(_) => {}
    }
    // Draining: an in-flight Trash is finishing; new Trash is already blocked. Never cancel it.
    let mut waited = Duration::ZERO;
    while waited < ctx.drain_timeout {
        ctx.sleeper.sleep(ctx.poll_interval);
        waited += ctx.poll_interval;
        match ctx.daemon.status() {
            Ok(s) if s.phase == Phase::Quiesced => return Ok(true),
            Ok(s) if s.phase == Phase::Draining => {}
            Ok(_) => return Err(fail("the update lease was lost while draining".into())),
            Err(e) => {
                let _ = ctx.daemon.release(token);
                return Err(fail(e.to_string()));
            }
        }
    }
    let _ = ctx.daemon.release(token);
    Err(fail(
        "a Trash operation is still in flight; try again shortly".into(),
    ))
}

fn wait_healthy(ctx: &InstallContext<'_>, expected: &str) -> Result<(), String> {
    let mut waited = Duration::ZERO;
    let mut last: String;
    loop {
        last = match ctx.daemon.health() {
            Ok(v) if v == expected => return Ok(()),
            Ok(v) => format!("agent reports version {v}, expected {expected}"),
            Err(e) => e.to_string(),
        };
        if waited >= ctx.health_timeout {
            return Err(format!(
                "health check failed after {}s: {last}",
                ctx.health_timeout.as_secs()
            ));
        }
        ctx.sleeper.sleep(ctx.poll_interval);
        waited += ctx.poll_interval;
    }
}

/// Restore the previous build; on success the failed build's directory is removed (best effort: on
/// Windows a directory whose executable is still running stays and is pruned later).
fn rollback(
    ctx: &InstallContext<'_>,
    failed: &str,
    previous: Option<&str>,
    old_version: Option<&str>,
    had_agent: bool,
) -> Result<(), String> {
    restore(ctx, previous, old_version, had_agent)?;
    let _ = ctx.fs.remove_dir_all(&ctx.layout.version_path(failed));
    Ok(())
}

/// Repoint at the previous build and restart it. Best-effort verification of the old agent.
fn restore(
    ctx: &InstallContext<'_>,
    previous: Option<&str>,
    old_version: Option<&str>,
    had_agent: bool,
) -> Result<(), String> {
    let previous = previous.ok_or("there is no previous build to restore")?;
    ctx.fs
        .set_current(ctx.layout, previous)
        .map_err(|e| format!("cannot repoint to {previous}: {e}"))?;
    if !had_agent {
        return Ok(());
    }
    match ctx.restarter.restart() {
        Ok(RestartKind::Restarted) => {
            if let Some(old) = old_version {
                wait_healthy(ctx, old)
                    .map_err(|e| format!("restored {previous} but its agent is unhealthy: {e}"))?;
            }
            Ok(())
        }
        Ok(RestartKind::Unmanaged) => Ok(()),
        Err(e) => Err(format!(
            "restored the pointer to {previous} but could not restart it: {e}"
        )),
    }
}

#[cfg(test)]
mod tests;
