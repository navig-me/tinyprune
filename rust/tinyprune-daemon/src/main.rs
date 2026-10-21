use std::{
    io,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tinyprune_daemon::{Daemon, Options, SystemClock};
fn main() {
    if let Err(error) = run() {
        eprintln!("tinyprune-agentd: {error}");
        std::process::exit(1);
    }
}
fn run() -> io::Result<()> {
    let mut options = Options::from_environment()?;
    let mut args = std::env::args().skip(1);
    while let Some(argument) = args.next() {
        if matches!(argument.as_str(), "--version" | "-V") {
            println!("tinyprune-agentd {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        if argument == "--help" {
            println!("tinyprune-agentd [--data-dir PATH] [--endpoint PATH] [--reconcile-seconds N]\nIn development, unreleased. TinyPrune remains macOS-only.");
            return Ok(());
        }
        let value = args.next().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "option requires a value")
        })?;
        match argument.as_str() {
            "--data-dir" => {
                options.paths.data = PathBuf::from(value);
                options.paths.logs = options.paths.data.join("logs");
            }
            "--endpoint" => options.paths.endpoint = PathBuf::from(value),
            "--reconcile-seconds" => {
                let seconds = value
                    .parse::<u64>()
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid interval"))?;
                options.reconcile_interval = Duration::from_secs(seconds);
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unknown option",
                ))
            }
        }
    }
    let shutdown = Arc::new(AtomicBool::new(false));
    let signal = shutdown.clone();
    ctrlc::set_handler(move || signal.store(true, Ordering::Release)).map_err(io::Error::other)?;
    Daemon::open(options, Arc::new(SystemClock))?.run(shutdown)
}
