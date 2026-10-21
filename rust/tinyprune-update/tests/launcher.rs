//! The real `tinyprune-launcher` binary: resolves `current`, starts the versioned program with the
//! caller's arguments and returns its exit code (Unix `exec`, Windows spawn+wait). The "program" is the
//! launcher itself copied to `bin/tinyprune[.exe]` and `bin/tinyprune-agentd[.exe]`, whose exit codes
//! are distinctive: 64 with no arguments (usage) and 1 when asked to launch something it refuses.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use tinyprune_update::layout::{InstallFs, Layout, StdFs};

const LAUNCHER: &str = env!("CARGO_BIN_EXE_tinyprune-launcher");

struct Sandbox {
    base: PathBuf,
}
impl Sandbox {
    fn new(tag: &str) -> Self {
        let base = std::env::temp_dir().join(format!("tp-launcher-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        Self { base }
    }
    /// (environment variable, value) that makes `Layout::from_environment` resolve under `base`.
    fn env(&self) -> (&'static str, PathBuf) {
        if cfg!(windows) {
            ("LOCALAPPDATA", self.base.clone())
        } else if cfg!(target_os = "macos") {
            ("HOME", self.base.clone())
        } else {
            ("XDG_DATA_HOME", self.base.clone())
        }
    }
    fn layout(&self) -> Layout {
        let root = if cfg!(windows) {
            self.base.join("TinyPrune")
        } else if cfg!(target_os = "macos") {
            self.base.join("Library/Application Support/TinyPrune")
        } else {
            self.base.join("tinyprune")
        };
        Layout::new(root)
    }
    fn install(&self, name: &str) {
        let layout = self.layout();
        let bin = layout.version_path(name).join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let suffix = if cfg!(windows) { ".exe" } else { "" };
        for program in ["tinyprune", "tinyprune-agentd"] {
            std::fs::copy(LAUNCHER, bin.join(format!("{program}{suffix}"))).unwrap();
        }
    }
    fn run(&self, args: &[&str]) -> (Option<i32>, String) {
        let (key, value) = self.env();
        let out = Command::new(LAUNCHER)
            .args(args)
            .env(key, value)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        (
            out.status.code(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

#[test]
fn starts_the_current_version_and_propagates_arguments_and_exit_codes() {
    let sb = Sandbox::new("run");
    sb.install("0.1.0-b1");
    sb.install("0.2.0-b2");
    let fs = StdFs::native();
    fs.set_current(&sb.layout(), "0.1.0-b1").unwrap();

    // The CLI path inherits stdio. The inner program (the copied launcher) got no arguments: usage 64.
    let (code, stderr) = sb.run(&["tinyprune"]);
    assert_eq!(code, Some(64), "{stderr}");
    // Arguments reach the program: it refuses `bogus` with exit 1.
    let (code, stderr) = sb.run(&["tinyprune", "bogus"]);
    assert_eq!(code, Some(1), "{stderr}");
    assert!(stderr.contains("refusing to launch"), "{stderr}");
    // `.exe` spelling is accepted (Scheduled Task / shim command lines).
    assert_eq!(sb.run(&["tinyprune.exe"]).0, Some(64));
    // The background path (Windows: hidden console, job object, null stdio) propagates exit codes too.
    assert_eq!(sb.run(&["tinyprune-agentd"]).0, Some(64));
    assert_eq!(sb.run(&["tinyprune-agentd", "bogus"]).0, Some(1));

    // Repointing is honored by the next start, and the pointer is the only thing that moved.
    fs.set_current(&sb.layout(), "0.2.0-b2").unwrap();
    assert_eq!(
        fs.read_current(&sb.layout()).unwrap().as_deref(),
        Some("0.2.0-b2")
    );
    assert_eq!(sb.run(&["tinyprune"]).0, Some(64));
    assert_eq!(sb.run(&["tinyprune-agentd"]).0, Some(64));
}

#[test]
fn refuses_unknown_programs_missing_pointer_and_missing_binaries() {
    let sb = Sandbox::new("refuse");
    assert_eq!(sb.run(&[]).0, Some(64));
    let (code, stderr) = sb.run(&["cmd"]);
    assert_eq!(
        (code, stderr.contains("refusing")),
        (Some(1), true),
        "{stderr}"
    );
    let (code, stderr) = sb.run(&["tinyprune-agentd"]);
    assert_eq!(code, Some(1));
    assert!(stderr.contains("no current version"), "{stderr}");

    // A pointer to a build without the requested program fails cleanly rather than panicking.
    std::fs::create_dir_all(sb.layout().version_path("0.3.0-b3").join("bin")).unwrap();
    StdFs::native()
        .set_current(&sb.layout(), "0.3.0-b3")
        .unwrap();
    let (code, stderr) = sb.run(&["tinyprune-agentd"]);
    assert_eq!(code, Some(1));
    assert!(stderr.contains("cannot start"), "{stderr}");
}
