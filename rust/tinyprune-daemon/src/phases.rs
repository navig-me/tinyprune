//! Optional counter-only phase timing, shared with the native watcher.
use std::time::{Duration, Instant};

pub(crate) fn record(phase: &str, elapsed: Duration, items: usize) {
    tinyprune_watch::record_phase(phase, elapsed, items);
}

pub(crate) fn since(phase: &str, started: Instant, items: usize) {
    record(phase, started.elapsed(), items);
}
