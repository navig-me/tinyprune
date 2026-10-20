//! Optional per-phase timing for benchmarks. When `TINYPRUNE_PHASE_LOG` names a file, every completed phase appends
//! one JSON line there; unset, `record` does nothing. Lines carry only a phase name, a duration, an item count and a
//! wall-clock end time, never paths or any user data.
use std::{
    io::Write as _,
    sync::{LazyLock, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

static SINK: LazyLock<Option<Mutex<std::fs::File>>> = LazyLock::new(|| {
    let path = std::env::var_os("TINYPRUNE_PHASE_LOG")?;
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .ok()
        .map(Mutex::new)
});

fn sink() -> Option<&'static Mutex<std::fs::File>> {
    SINK.as_ref()
}

/// Records one finished phase of `items` entries that took `elapsed`.
pub(crate) fn record(phase: &str, elapsed: Duration, items: usize) {
    let Some(sink) = sink() else { return };
    let end_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64() * 1000.0);
    if let Ok(mut file) = sink.lock() {
        let _ = writeln!(
            file,
            "{{\"phase\":\"{phase}\",\"ms\":{:.3},\"items\":{items},\"end_ms\":{end_ms:.0}}}",
            elapsed.as_secs_f64() * 1000.0
        );
    }
}

/// Records `phase` from `started` until now.
pub(crate) fn since(phase: &str, started: Instant, items: usize) {
    record(phase, started.elapsed(), items);
}
