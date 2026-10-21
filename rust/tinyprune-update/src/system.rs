//! Real collaborators for the installer: the agent over IPC, the service manager, and the staged-binary
//! self-check. All external processes run with a timeout and bounded captured output.

use crate::install::{
    CheckReport, ControlError, DaemonControl, Expected, RestartKind, Restarter, SelfCheck, Sleeper,
};
use crate::interlock::{Phase, Status};
use std::io::{self, Read};
use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};
use tinyprune_ipc::{
    Client, Connection, ErrorCode, Request, Response, UpdatePhase, VersionRange, DEFAULT_MAX_FRAME,
};

pub struct RealSleeper;
impl Sleeper for RealSleeper {
    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// The agent as seen through the local IPC endpoint. One short connection per call: nothing is held
/// across the restart that this tool itself triggers.
pub struct IpcDaemon<'a> {
    pub connect: &'a dyn Fn() -> io::Result<Box<dyn Connection>>,
}
impl IpcDaemon<'_> {
    fn call(&self, request: Request) -> Result<Response, ControlError> {
        let stream = (self.connect)().map_err(|e| match e.kind() {
            io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused => ControlError::NotRunning,
            _ => ControlError::Failed(format!("cannot reach the agent: {e}")),
        })?;
        let mut client = Client::connect(stream, VersionRange::default(), DEFAULT_MAX_FRAME)
            .map_err(|e| ControlError::Failed(format!("agent handshake failed: {e}")))?;
        match client
            .request(request)
            .map_err(|e| ControlError::Failed(format!("agent request failed: {e}")))?
        {
            Response::Failure(e) => Err(match e.code {
                ErrorCode::Busy => ControlError::Busy(e.message),
                // An agent built before the interlock answers "unknown operation".
                ErrorCode::InvalidRequest
                    if e.message.to_ascii_lowercase().contains("unknown operation") =>
                {
                    ControlError::Unsupported
                }
                _ => ControlError::Failed(e.message),
            }),
            other => Ok(other),
        }
    }
    fn status_of(response: Response) -> Result<Status, ControlError> {
        match response {
            Response::UpdateStatus(s) => Ok(Status {
                phase: match s.phase {
                    UpdatePhase::Idle => Phase::Idle,
                    UpdatePhase::Draining => Phase::Draining,
                    UpdatePhase::Quiesced => Phase::Quiesced,
                    // A phase this tool does not know is never treated as quiesced.
                    UpdatePhase::Unknown => Phase::Draining,
                },
                target: s.target,
                trash_in_flight: s.trash_in_flight as usize,
                lease_remaining: s
                    .lease_remaining_seconds
                    .filter(|v| v.is_finite() && *v >= 0.0)
                    .map(Duration::from_secs_f64),
            }),
            _ => Err(ControlError::Unsupported),
        }
    }
}
impl DaemonControl for IpcDaemon<'_> {
    fn quiesce(&self, token: &str, target: &str, lease: Duration) -> Result<Status, ControlError> {
        let lease_seconds = u32::try_from(lease.as_secs()).unwrap_or(u32::MAX);
        Self::status_of(self.call(Request::QuiesceForUpdate {
            token: token.into(),
            target: target.into(),
            lease_seconds,
        })?)
    }
    fn status(&self) -> Result<Status, ControlError> {
        Self::status_of(self.call(Request::LoadUpdateStatus)?)
    }
    fn release(&self, token: &str) -> Result<(), ControlError> {
        Self::status_of(self.call(Request::ReleaseUpdateQuiesce {
            token: token.into(),
        })?)
        .map(|_| ())
    }
    fn health(&self) -> Result<String, ControlError> {
        match self.call(Request::Health)? {
            Response::Health(h) => Ok(h.service_version),
            _ => Err(ControlError::Failed(
                "unexpected reply to health check".into(),
            )),
        }
    }
}

const OUTPUT_LIMIT: u64 = 64 * 1024;
pub struct Captured {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
}
/// Run with null stdin, bounded output and a hard timeout (the child is killed on expiry).
pub fn run_limited(command: &mut Command, timeout: Duration) -> io::Result<Captured> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let read = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut text = Vec::new();
            if let Some(pipe) = pipe {
                let _ = pipe.take(OUTPUT_LIMIT).read_to_end(&mut text);
            }
            String::from_utf8_lossy(&text).into_owned()
        })
    };
    let out = read(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let err = read(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("timed out after {}s", timeout.as_secs()),
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    Ok(Captured {
        status,
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
    })
}

pub const SYSTEMD_UNIT: &str = "tinyprune-agentd.service";
pub const TASK_NAME: &str = "TinyPrune Agent (dev)";

/// Linux: `systemctl --user restart tinyprune-agentd.service` when the unit is running or in a failed /
/// restart-looping state (a rolled-back update must be able to revive a unit that the bad build crashed).
/// An `inactive` unit, or no systemd, means the agent is not ours to restart. The unit's ExecStart
/// resolves `current`, so the restart runs whichever build `current` names.
pub struct SystemdRestarter {
    pub systemctl: String,
}
impl Default for SystemdRestarter {
    fn default() -> Self {
        Self {
            systemctl: "systemctl".into(),
        }
    }
}
impl Restarter for SystemdRestarter {
    fn restart(&self) -> Result<RestartKind, String> {
        let state = match run_limited(
            Command::new(&self.systemctl).args(["--user", "is-active", SYSTEMD_UNIT]),
            Duration::from_secs(15),
        ) {
            Ok(c) => c.stdout.trim().to_owned(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(format!("systemctl is-active: {e}")),
        };
        if !matches!(
            state.as_str(),
            "active" | "activating" | "reloading" | "failed"
        ) {
            return Ok(RestartKind::Unmanaged);
        }
        // A crash-looping unit may have hit its start limit, which would refuse the restart.
        let _ = run_limited(
            Command::new(&self.systemctl).args(["--user", "reset-failed", SYSTEMD_UNIT]),
            Duration::from_secs(15),
        );
        let done = run_limited(
            Command::new(&self.systemctl).args(["--user", "restart", SYSTEMD_UNIT]),
            Duration::from_secs(60),
        )
        .map_err(|e| format!("systemctl restart: {e}"))?;
        if done.status.success() {
            Ok(RestartKind::Restarted)
        } else {
            Err(format!("systemctl restart failed: {}", done.stderr.trim()))
        }
    }
}

/// Status column of `schtasks /Query /FO CSV /NH` for one task: the last quoted field.
pub(crate) fn csv_task_status(output: &str) -> Option<String> {
    let line = output.lines().map(str::trim).find(|l| !l.is_empty())?;
    let field = line.rsplit("\",\"").next()?;
    let status = field.trim_matches('"').trim();
    (!status.is_empty()).then(|| status.to_owned())
}

/// Windows: stop and start the per-user Scheduled Task registered by `install-managed.ps1`. The task
/// runs `tinyprune-launcher`, which resolves `current` at start (ADR 0012).
pub struct ScheduledTaskRestarter {
    pub schtasks: String,
}
impl Default for ScheduledTaskRestarter {
    fn default() -> Self {
        Self {
            schtasks: "schtasks".into(),
        }
    }
}
impl ScheduledTaskRestarter {
    fn task_status(&self) -> Option<String> {
        let query = run_limited(
            Command::new(&self.schtasks).args(["/Query", "/TN", TASK_NAME, "/FO", "CSV", "/NH"]),
            Duration::from_secs(15),
        )
        .ok()?;
        query
            .status
            .success()
            .then(|| csv_task_status(&query.stdout))
            .flatten()
    }
}
impl Restarter for ScheduledTaskRestarter {
    fn restart(&self) -> Result<RestartKind, String> {
        let query = run_limited(
            Command::new(&self.schtasks).args(["/Query", "/TN", TASK_NAME]),
            Duration::from_secs(15),
        );
        if !matches!(&query, Ok(c) if c.status.success()) {
            return Ok(RestartKind::Unmanaged);
        }
        // /End fails when the task is not running; that is fine, /Run is what must succeed.
        let _ = run_limited(
            Command::new(&self.schtasks).args(["/End", "/TN", TASK_NAME]),
            Duration::from_secs(30),
        );
        // The task's instance policy ignores /Run while the previous instance is still shutting down.
        // `schtasks` reports an ended task as "Ready"; wait (bounded) until it is no longer "Running".
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline && self.task_status().as_deref() == Some("Running") {
            std::thread::sleep(Duration::from_millis(250));
        }
        let run = run_limited(
            Command::new(&self.schtasks).args(["/Run", "/TN", TASK_NAME]),
            Duration::from_secs(30),
        )
        .map_err(|e| format!("schtasks /Run: {e}"))?;
        if run.status.success() {
            Ok(RestartKind::Restarted)
        } else {
            Err(format!("schtasks /Run failed: {}", run.stderr.trim()))
        }
    }
}

pub fn native_restarter() -> Box<dyn Restarter> {
    if cfg!(windows) {
        Box::new(ScheduledTaskRestarter::default())
    } else {
        Box::new(SystemdRestarter::default())
    }
}

/// Runs the staged binaries before anything points at them.
pub struct ProcessSelfCheck {
    pub timeout: Duration,
}
impl Default for ProcessSelfCheck {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(20),
        }
    }
}
fn exe_name(base: &str) -> String {
    if cfg!(windows) {
        format!("{base}.exe")
    } else {
        base.to_owned()
    }
}
impl SelfCheck for ProcessSelfCheck {
    fn check(&self, dir: &Path, expected: &Expected<'_>) -> Result<CheckReport, String> {
        let bin = dir.join("bin");
        let run = |program: &str, args: &[&str]| -> Result<Captured, String> {
            let path = bin.join(exe_name(program));
            let captured = run_limited(Command::new(&path).args(args), self.timeout)
                .map_err(|e| format!("{} {}: {e}", program, args.join(" ")))?;
            if !captured.status.success() {
                return Err(format!(
                    "{} {} exited with {}: {}",
                    program,
                    args.join(" "),
                    captured.status,
                    captured.stderr.trim()
                ));
            }
            Ok(captured)
        };
        run("tinyprune", &["--version"])?;
        let agent = run("tinyprune-agentd", &["--version"])?;
        let daemon_version = agent
            .stdout
            .split_whitespace()
            .last()
            .filter(|v| crate::version::Version::parse(v).is_ok())
            .ok_or_else(|| {
                format!(
                    "tinyprune-agentd --version printed {:?}",
                    agent.stdout.trim()
                )
            })?
            .to_owned();
        let build = expected.build.to_string();
        run(
            "tinyprune",
            &[
                "update",
                "self-check",
                "--expect-version",
                expected.version,
                "--expect-build",
                &build,
            ],
        )?;
        Ok(CheckReport { daemon_version })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::test_support::TempDir;
    use std::os::unix::fs::PermissionsExt;

    fn script(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    fn staged(dir: &Path, cli: &str, agentd: &str) {
        script(&dir.join("bin/tinyprune"), cli);
        script(&dir.join("bin/tinyprune-agentd"), agentd);
    }
    const EXPECT: Expected<'static> = Expected {
        version: "0.2.0",
        build: 2,
    };

    #[test]
    fn self_check_runs_the_real_staged_binaries() {
        let d = TempDir::new();
        staged(
            d.path(),
            r#"[ "$1" = "--version" ] && echo "tinyprune 0.2.0" && exit 0
[ "$1 $2 $3 $4 $5" = "update self-check --expect-version 0.2.0 --expect-build" ] && [ "$6" = "2" ] && exit 0
exit 9"#,
            r#"echo "tinyprune-agentd 0.2.0""#,
        );
        let report = ProcessSelfCheck::default()
            .check(d.path(), &EXPECT)
            .unwrap();
        assert_eq!(report.daemon_version, "0.2.0");
    }
    #[test]
    fn self_check_fails_on_crash_wrong_args_garbage_or_hang() {
        let ok_cli = r#"exit 0"#;
        for (cli, agentd, why) in [
            (
                "exit 127",
                r#"echo "tinyprune-agentd 0.2.0""#,
                "cli --version fails",
            ),
            (ok_cli, "exit 1", "agentd fails"),
            (
                ok_cli,
                r#"echo "garbage output""#,
                "agentd prints no version",
            ),
            (
                r#"[ "$1" = "--version" ] && exit 0; exit 3"#,
                r#"echo "tinyprune-agentd 0.2.0""#,
                "self-check subcommand fails",
            ),
        ] {
            let d = TempDir::new();
            staged(d.path(), cli, agentd);
            assert!(
                ProcessSelfCheck::default()
                    .check(d.path(), &EXPECT)
                    .is_err(),
                "{why}"
            );
        }
        let d = TempDir::new();
        staged(d.path(), "sleep 30", r#"echo "tinyprune-agentd 0.2.0""#);
        let started = Instant::now();
        let hung = ProcessSelfCheck {
            timeout: Duration::from_millis(300),
        }
        .check(d.path(), &EXPECT);
        assert!(hung.unwrap_err().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(10));
    }
    #[test]
    fn systemd_restarter_restarts_only_an_active_unit() {
        let d = TempDir::new();
        let log = d.path().join("log");
        let shim = d.path().join("systemctl");
        script(
            &shim,
            &format!(
                r#"echo "$@" >> {log}
if [ "$2" = "is-active" ]; then
  if [ -f {active} ]; then cat {active}; exit 0; fi
  echo inactive; exit 3
fi
[ "$2" = "reset-failed" ] && exit 0
[ "$2" = "restart" ] && exit 0
exit 1"#,
                log = log.display(),
                active = d.path().join("active").display()
            ),
        );
        let restarter = SystemdRestarter {
            systemctl: shim.display().to_string(),
        };
        assert_eq!(
            restarter.restart().unwrap(),
            RestartKind::Unmanaged,
            "inactive unit is not restarted"
        );
        assert!(!std::fs::read_to_string(&log).unwrap().contains("restart"));
        std::fs::write(d.path().join("active"), "active\n").unwrap();
        assert_eq!(restarter.restart().unwrap(), RestartKind::Restarted);
        assert!(std::fs::read_to_string(&log)
            .unwrap()
            .contains("--user restart tinyprune-agentd.service"));
        let missing = SystemdRestarter {
            systemctl: d.path().join("nope").display().to_string(),
        };
        assert_eq!(
            missing.restart().unwrap(),
            RestartKind::Unmanaged,
            "no systemctl at all"
        );
        // A crash-looping / failed unit (the state a bad update leaves) is revived, start limit reset first.
        std::fs::write(d.path().join("active"), "failed\n").unwrap();
        std::fs::write(&log, "").unwrap();
        assert_eq!(restarter.restart().unwrap(), RestartKind::Restarted);
        let calls = std::fs::read_to_string(&log).unwrap();
        assert!(
            calls.find("reset-failed").unwrap() < calls.find("--user restart").unwrap(),
            "{calls}"
        );
    }
    #[test]
    fn systemd_restart_failure_is_an_error() {
        let d = TempDir::new();
        let shim = d.path().join("systemctl");
        script(
            &shim,
            r#"if [ "$2" = "is-active" ]; then echo active; exit 0; fi
[ "$2" = "reset-failed" ] && exit 0
echo "boom" >&2; exit 1"#,
        );
        let err = SystemdRestarter {
            systemctl: shim.display().to_string(),
        }
        .restart()
        .unwrap_err();
        assert!(err.contains("boom"), "{err}");
    }
    #[test]
    fn task_status_is_the_last_csv_column() {
        assert_eq!(
            csv_task_status("\"\\TinyPrune Agent (dev)\",\"N/A\",\"Running\"\r\n").as_deref(),
            Some("Running")
        );
        assert_eq!(
            csv_task_status("\n\"\\TinyPrune Agent (dev)\",\"11/1/2026 3:00:00 AM\",\"Ready\"\n")
                .as_deref(),
            Some("Ready")
        );
        assert_eq!(csv_task_status(""), None);
        assert_eq!(csv_task_status("\"\\x\",\"N/A\",\"\"\n"), None);
    }
    #[test]
    fn output_is_bounded() {
        let d = TempDir::new();
        let big = d.path().join("big");
        script(
            &big,
            "yes AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | head -c 5000000",
        );
        let out = run_limited(&mut Command::new(&big), Duration::from_secs(20)).unwrap();
        assert!(out.stdout.len() as u64 <= OUTPUT_LIMIT);
    }
}
