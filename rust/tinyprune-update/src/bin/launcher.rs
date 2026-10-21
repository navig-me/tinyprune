//! `tinyprune-launcher <program> [args...]`: starts `<root>/versions/<current>/bin/<program>`.
//!
//! The Windows Scheduled Task (and any shim) runs this instead of a versioned binary, so an update only
//! has to move the `current` pointer; a running `.exe` is never overwritten. It resolves the pointer
//! once at start (retrying briefly, because Windows can refuse a read while the pointer file is being
//! replaced). On Unix it `exec`s so the service manager supervises the real process. It does not
//! interpret arguments beyond the program name, and only launches the TinyPrune programs.
//! Unix behavior is tested; the Windows spawn/exit-code path has not been run on Windows.

use std::ffi::OsString;
use std::process::{exit, Command};
use std::time::Duration;
use tinyprune_update::layout::{InstallFs, Layout, StdFs};

const PROGRAMS: [&str; 3] = ["tinyprune-agentd", "tinyprune", "tinyprune-ui"];

fn fail(message: String) -> ! {
    eprintln!("tinyprune-launcher: {message}");
    exit(1);
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    let program: OsString = args.next().unwrap_or_else(|| {
        eprintln!(
            "usage: tinyprune-launcher <{}> [args...]",
            PROGRAMS.join("|")
        );
        exit(64)
    });
    let program = program
        .to_string_lossy()
        .trim_end_matches(".exe")
        .to_owned();
    if !PROGRAMS.contains(&program.as_str()) {
        fail(format!("refusing to launch {program:?}"));
    }
    let layout = Layout::from_environment().unwrap_or_else(|e| fail(e.to_string()));
    let fs = StdFs::native();
    let mut attempt = 0;
    let name = loop {
        match fs.read_current(&layout) {
            Ok(Some(name)) => break name,
            Ok(None) => fail("no current version is installed".into()),
            Err(e) if attempt >= 5 => fail(format!("cannot resolve the current version: {e}")),
            Err(_) => {
                attempt += 1;
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    };
    let suffix = if cfg!(windows) { ".exe" } else { "" };
    let target = layout
        .version_path(&name)
        .join("bin")
        .join(format!("{program}{suffix}"));
    let mut command = Command::new(&target);
    command.args(args);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = command.exec();
        fail(format!("cannot start {}: {error}", target.display()));
    }
    #[cfg(not(unix))]
    {
        match command.status() {
            Ok(status) => exit(status.code().unwrap_or(1)),
            Err(error) => fail(format!("cannot start {}: {error}", target.display())),
        }
    }
}
