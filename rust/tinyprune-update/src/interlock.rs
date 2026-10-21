//! Trash/update interlock (ADR 0012, mirroring ADR 0006). Dependency-free so the daemon can embed it.
//!
//! * A Trash operation holds a [`TrashGuard`] from before preflight until after the filesystem move
//!   and audit. `begin_trash` fails while an update lease exists, so a new move never starts.
//! * `request_quiesce` installs a time-limited lease. New Trash is blocked immediately; the lease is
//!   `Draining` while guards are outstanding and `Quiesced` once none remain. An in-flight move is
//!   never cancelled.
//! * The updater swaps binaries and restarts the agent only after observing `Quiesced`. A lease expires
//!   by itself so an updater that died cannot leave pruning stopped forever, and the updater re-checks
//!   `remaining` immediately before restarting. The state is in memory on purpose: the restart that
//!   completes an update replaces the process, and a crashed agent restarts un-quiesced (nothing is
//!   half-installed because the pointer swap is atomic).
//! * Any internal failure (poisoned lock) blocks Trash: the interlock fails closed.

use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Longest lease an updater may request.
pub const MAX_LEASE: Duration = Duration::from_secs(600);
const MAX_TOKEN_LEN: usize = 64;
const MAX_TARGET_LEN: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    Idle,
    /// Trash is blocked; waiting for in-flight operations to finish.
    Draining,
    /// Trash is blocked and none is in flight: binaries may be replaced.
    Quiesced,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub phase: Phase,
    pub target: Option<String>,
    pub trash_in_flight: usize,
    pub lease_remaining: Option<Duration>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QuiesceError {
    /// Another updater already holds the lease.
    AlreadyQuiescing,
    /// Token or target missing, too long, or contains non-token characters; lease zero or too long.
    Invalid(&'static str),
    /// `release` with a token that does not match the live lease.
    UnknownToken,
}

impl fmt::Display for QuiesceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyQuiescing => f.write_str("an update is already quiescing this agent"),
            Self::Invalid(why) => write!(f, "invalid quiesce request: {why}"),
            Self::UnknownToken => f.write_str("no update lease matches that token"),
        }
    }
}
impl std::error::Error for QuiesceError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrashBlocked;
impl fmt::Display for TrashBlocked {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("app update installation is pending")
    }
}
impl std::error::Error for TrashBlocked {}

struct Lease {
    token: String,
    target: String,
    expires: Duration,
}
struct State {
    in_flight: usize,
    lease: Option<Lease>,
}

type Clock = Box<dyn Fn() -> Duration + Send + Sync>;

pub struct Interlock {
    now: Clock,
    state: Mutex<State>,
}

/// Held for the whole Trash operation; dropping it ends the shared hold.
#[must_use = "dropping the guard immediately ends the interlock hold"]
pub struct TrashGuard {
    interlock: Arc<Interlock>,
}
impl Drop for TrashGuard {
    fn drop(&mut self) {
        // A poisoned lock is already fail-closed for new work; the counter no longer matters.
        if let Ok(mut state) = self.interlock.state.lock() {
            state.in_flight = state.in_flight.saturating_sub(1);
        }
    }
}

fn token_ok(value: &str, max: usize) -> bool {
    !value.is_empty()
        && value.len() <= max
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'+'))
}

impl Interlock {
    pub fn new() -> Arc<Self> {
        let start = Instant::now();
        Self::with_clock(move || start.elapsed())
    }
    /// Injectable monotonic clock (time since an arbitrary origin) for deterministic tests.
    pub fn with_clock(clock: impl Fn() -> Duration + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            now: Box::new(clock),
            state: Mutex::new(State {
                in_flight: 0,
                lease: None,
            }),
        })
    }

    fn expire(&self, state: &mut State) {
        if state
            .lease
            .as_ref()
            .is_some_and(|lease| (self.now)() >= lease.expires)
        {
            state.lease = None;
        }
    }

    /// Start a Trash operation. Fails while an update lease is live or the interlock is broken.
    pub fn begin_trash(self: &Arc<Self>) -> Result<TrashGuard, TrashBlocked> {
        let mut state = self.state.lock().map_err(|_| TrashBlocked)?;
        self.expire(&mut state);
        if state.lease.is_some() {
            return Err(TrashBlocked);
        }
        state.in_flight += 1;
        Ok(TrashGuard {
            interlock: Arc::clone(self),
        })
    }

    /// Block new Trash and begin draining. Idempotent for the same token (refreshes nothing).
    pub fn request_quiesce(
        &self,
        token: &str,
        target: &str,
        lease: Duration,
    ) -> Result<Status, QuiesceError> {
        if !token_ok(token, MAX_TOKEN_LEN) {
            return Err(QuiesceError::Invalid("token"));
        }
        if !token_ok(target, MAX_TARGET_LEN) {
            return Err(QuiesceError::Invalid("target"));
        }
        if lease.is_zero() || lease > MAX_LEASE {
            return Err(QuiesceError::Invalid("lease duration"));
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| QuiesceError::Invalid("interlock unavailable"))?;
        self.expire(&mut state);
        match &state.lease {
            Some(existing) if existing.token != token => {
                return Err(QuiesceError::AlreadyQuiescing)
            }
            Some(_) => {}
            None => {
                state.lease = Some(Lease {
                    token: token.to_owned(),
                    target: target.to_owned(),
                    expires: (self.now)() + lease,
                });
            }
        }
        Ok(self.snapshot(&state))
    }

    /// Finish or abort an update: Trash may resume. Only the lease holder can release it.
    pub fn release(&self, token: &str) -> Result<(), QuiesceError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| QuiesceError::Invalid("interlock unavailable"))?;
        self.expire(&mut state);
        match &state.lease {
            Some(lease) if lease.token == token => {
                state.lease = None;
                Ok(())
            }
            _ => Err(QuiesceError::UnknownToken),
        }
    }

    pub fn status(&self) -> Status {
        match self.state.lock() {
            Ok(mut state) => {
                self.expire(&mut state);
                self.snapshot(&state)
            }
            // Fail closed: report a lease-like state with nothing resumable.
            Err(_) => Status {
                phase: Phase::Draining,
                target: None,
                trash_in_flight: 0,
                lease_remaining: None,
            },
        }
    }

    fn snapshot(&self, state: &State) -> Status {
        let now = (self.now)();
        match &state.lease {
            None => Status {
                phase: Phase::Idle,
                target: None,
                trash_in_flight: state.in_flight,
                lease_remaining: None,
            },
            Some(lease) => Status {
                phase: if state.in_flight == 0 {
                    Phase::Quiesced
                } else {
                    Phase::Draining
                },
                target: Some(lease.target.clone()),
                trash_in_flight: state.in_flight,
                lease_remaining: Some(lease.expires.saturating_sub(now)),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn clocked() -> (Arc<Interlock>, Arc<AtomicU64>) {
        let ms = Arc::new(AtomicU64::new(0));
        let c = ms.clone();
        (
            Interlock::with_clock(move || Duration::from_millis(c.load(Ordering::SeqCst))),
            ms,
        )
    }
    const LEASE: Duration = Duration::from_secs(60);

    #[test]
    fn trash_in_flight_defers_quiesce_without_cancelling_and_blocks_new_trash() {
        let (gate, _) = clocked();
        let guard = gate.begin_trash().unwrap();
        let status = gate.request_quiesce("tok", "1.2.3", LEASE).unwrap();
        assert_eq!(status.phase, Phase::Draining);
        assert_eq!(status.trash_in_flight, 1);
        assert_eq!(
            gate.begin_trash().err(),
            Some(TrashBlocked),
            "no new Trash while draining"
        );
        assert_eq!(
            gate.status().phase,
            Phase::Draining,
            "in-flight move is not cancelled"
        );
        drop(guard);
        assert_eq!(gate.status().phase, Phase::Quiesced);
    }

    #[test]
    fn quiesced_blocks_trash_until_released_by_owner_only() {
        let (gate, _) = clocked();
        assert_eq!(
            gate.request_quiesce("tok", "t", LEASE).unwrap().phase,
            Phase::Quiesced
        );
        assert!(gate.begin_trash().is_err());
        assert_eq!(gate.release("other"), Err(QuiesceError::UnknownToken));
        assert!(
            gate.begin_trash().is_err(),
            "a stranger cannot reopen Trash"
        );
        assert_eq!(
            gate.request_quiesce("other", "t", LEASE),
            Err(QuiesceError::AlreadyQuiescing)
        );
        gate.release("tok").unwrap();
        assert!(gate.begin_trash().is_ok());
    }

    #[test]
    fn lease_expiry_reopens_trash_and_status_reports_remaining() {
        let (gate, ms) = clocked();
        gate.request_quiesce("tok", "t", Duration::from_secs(10))
            .unwrap();
        ms.store(4_000, Ordering::SeqCst);
        assert_eq!(gate.status().lease_remaining, Some(Duration::from_secs(6)));
        assert!(gate.begin_trash().is_err());
        ms.store(10_000, Ordering::SeqCst);
        assert_eq!(gate.status().phase, Phase::Idle);
        assert!(gate.begin_trash().is_ok());
    }

    #[test]
    fn rejects_malformed_requests() {
        let (gate, _) = clocked();
        for (t, g, d) in [
            ("", "t", LEASE),
            ("a b", "t", LEASE),
            ("tok", "", LEASE),
            ("tok", "t", Duration::ZERO),
            ("tok", "t", MAX_LEASE + Duration::from_secs(1)),
        ] {
            assert!(
                matches!(gate.request_quiesce(t, g, d), Err(QuiesceError::Invalid(_))),
                "{t:?} {g:?} {d:?}"
            );
        }
        assert_eq!(gate.status().phase, Phase::Idle);
    }

    #[test]
    fn poisoned_lock_fails_closed() {
        let (gate, _) = clocked();
        let g2 = gate.clone();
        let _ = std::thread::spawn(move || {
            let _held = g2.state.lock().unwrap();
            panic!("poison");
        })
        .join();
        assert!(gate.begin_trash().is_err());
        assert_ne!(gate.status().phase, Phase::Idle);
    }
}
