//! `tinyprune-launcher <program> [args...]`: starts `<root>/versions/<current>/bin/<program>`.
//!
//! The Windows Scheduled Task (and any shim) runs this instead of a versioned binary, so an update only
//! has to move the `current` pointer; a running `.exe` is never overwritten. It resolves the pointer
//! once at start (retrying briefly, because Windows can refuse a read while the pointer file is being
//! replaced). On Unix it `exec`s so the service manager supervises the real process. On Windows it
//! waits for the program and returns its exit code. For the background programs (`tinyprune-agentd`,
//! `tinyprune-ui`) it also detaches from the task's console (no window) and places the program in a
//! kill-on-close job object, so ending the task never leaves an orphaned agent that would hold the
//! pipe and database while a new one starts. The CLI keeps the caller's console and signals.
//! It does not interpret arguments beyond the program name, and only launches the TinyPrune programs.

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
            Err(e) if attempt >= 20 => fail(format!("cannot resolve the current version: {e}")),
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
    #[cfg(windows)]
    {
        let background = program != "tinyprune";
        let job = background.then(background::prepare);
        if background {
            use std::os::windows::process::CommandExt;
            use std::process::Stdio;
            // The program gets a hidden console of its own; with no console of ours its stdio is null.
            command
                .creation_flags(background::CREATE_NO_WINDOW)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => fail(format!("cannot start {}: {error}", target.display())),
        };
        if let Some(job) = &job {
            if let Err(error) = background::adopt(job, &child) {
                let _ = child.kill();
                fail(format!("cannot place the program in its job: {error}"));
            }
        }
        match child.wait() {
            Ok(status) => exit(status.code().unwrap_or(1)),
            Err(error) => fail(format!("cannot wait for {}: {error}", target.display())),
        }
    }
}

#[cfg(windows)]
mod background {
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::Console::FreeConsole;
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    /// A job whose handle lives as long as this process; when the launcher dies (including being
    /// terminated by the task scheduler), the OS kills everything in the job.
    pub struct Job(HANDLE);

    /// Detach from the console the task gave us (it would otherwise be a visible window) and create
    /// the kill-on-close job. A job that cannot be created is fatal: an unsupervised agent is worse
    /// than none.
    pub fn prepare() -> Job {
        // Fails harmlessly when there is no console (for example when started with no window).
        let _ = unsafe { FreeConsole() };
        let job = unsafe { CreateJobObjectW(None, PCWSTR::null()) }
            .unwrap_or_else(|e| super::fail(format!("cannot create the job object: {e}")));
        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                std::ptr::addr_of!(info).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        }
        .unwrap_or_else(|e| super::fail(format!("cannot configure the job object: {e}")));
        Job(job)
    }

    pub fn adopt(job: &Job, child: &Child) -> windows::core::Result<()> {
        unsafe { AssignProcessToJobObject(job.0, HANDLE(child.as_raw_handle())) }
    }
}
