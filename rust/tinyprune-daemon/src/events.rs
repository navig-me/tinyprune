use crate::index::Pace;
#[cfg(not(any(target_os = "linux", windows)))]
use crate::poll::Poller;
use std::{io, num::NonZeroUsize, path::PathBuf, sync::Arc, time::Duration};
use tinyprune_core::trash::Clock;
use tinyprune_watch::{EventBatch, EventSource};

/// Native watcher where `tinyprune-watch` has one (Linux inotify, Windows); elsewhere (macOS) the bounded
/// polling fallback in `poll.rs`.
pub(crate) struct Events {
    pace: Arc<Pace>,
    #[cfg(any(target_os = "linux", windows))]
    roots: Vec<PathBuf>,
    #[cfg(target_os = "linux")]
    native: tinyprune_watch::InotifyEventSource,
    #[cfg(windows)]
    native: tinyprune_watch::WindowsEventSource,
    #[cfg(not(any(target_os = "linux", windows)))]
    poller: Poller,
}
impl Events {
    pub fn new(
        roots: &[String],
        clock: Arc<dyn Clock + Send + Sync>,
        interval: Duration,
        pace: Arc<Pace>,
    ) -> io::Result<Self> {
        let paths: Vec<PathBuf> = roots.iter().map(PathBuf::from).collect();
        #[cfg(target_os = "linux")]
        {
            let _ = (clock, interval);
            Ok(Self {
                pace,
                native: tinyprune_watch::InotifyEventSource::new(paths.clone())?,
                roots: paths,
            })
        }
        #[cfg(windows)]
        {
            let _ = (clock, interval);
            Ok(Self {
                pace,
                native: tinyprune_watch::WindowsEventSource::new(paths.clone())?,
                roots: paths,
            })
        }
        #[cfg(not(any(target_os = "linux", windows)))]
        {
            Ok(Self {
                poller: Poller::new(paths, clock, interval, pace.clone()),
                pace: pace.clone(),
            })
        }
    }
    fn trace(&self, batch: &EventBatch) {
        if !batch.events.is_empty() || !batch.must_rescan.is_empty() {
            self.pace.delta.store(batch.must_rescan.is_empty(), std::sync::atomic::Ordering::Release);
            crate::phases::record("event_poll_queue", Duration::ZERO, batch.events.len());
        }
    }
}
impl EventSource for Events {
    fn poll(&mut self, timeout: Duration, limit: NonZeroUsize) -> io::Result<EventBatch> {
        #[cfg(any(target_os = "linux", windows))]
        {
            // After overflow/coverage loss rebuild native watches before returning the rescan hint.
            let batch = self.native.poll(timeout, limit)?;
            if !batch.must_rescan.is_empty() {
                #[cfg(target_os = "linux")]
                {
                    self.native = tinyprune_watch::InotifyEventSource::new(self.roots.clone())?;
                }
                #[cfg(windows)]
                {
                    self.native = tinyprune_watch::WindowsEventSource::new(self.roots.clone())?;
                }
            }
            self.trace(&batch);
            Ok(batch)
        }
        #[cfg(not(any(target_os = "linux", windows)))]
        {
            let batch = self.poller.poll(timeout, limit)?;
            self.trace(&batch);
            Ok(batch)
        }
    }
}
