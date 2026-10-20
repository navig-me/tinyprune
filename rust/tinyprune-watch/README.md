# tinyprune-watch (in development, unreleased)

This crate is internal event-source infrastructure, not a released Linux or Windows product. TinyPrune remains macOS-only. It does not implement the agent loop, scheduling, rule evaluation, or Trash.

## Interface

`EventSource::poll(timeout, NonZeroUsize)` returns an `EventBatch` containing byte-preserving absolute paths, their managed root, directory hints, and created/modified/removed/attribute/paired-rename events. Identical path events in one returned batch are coalesced; different change kinds remain distinct. This is an invalidation stream, not a complete ordered filesystem history. Reinspect metadata and identity before acting on every hint.

`must_rescan` lists roots whose view is incomplete. Never authorize Trash from an event or index entry. Keep wins, Preview never trashes, and all normal pre-Trash policy, identity, permission, and safety checks remain required.

`pending_work` means call again, normally with `Duration::ZERO`. A call bounds raw-event processing, directory-entry/setup/retirement operations, and emitted path events independently by the supplied limit. A kernel read buffer is capped at 64 KiB. Subtree invalidation searches the in-memory watch table, but removal syscalls are deferred in bounded batches. This is bounded work enumeration, not a real-time wall-clock guarantee: metadata operations and directory enumeration can block on the filesystem.

`ScriptedEventSource::new(frames)` is deterministic and portable. Each frame contains `RawEvent`s from one queue drain; empty frames model idle/timeout. Cookie pairing spans bounded polls within a frame. The fake never sleeps, even with a nonzero timeout, and preserves output limits. It can simulate queue overflow and watch-limit exhaustion without a kernel watcher.

## Linux implementation

`InotifyEventSource::new(roots)` exists only on Linux. Roots must be absolute, canonical, nonoverlapping real directories. The source owns a nonblocking, close-on-exec inotify descriptor and uses `poll(2)` with the supplied timeout (rounded up to milliseconds, capped at `i32::MAX` milliseconds). Zero timeout never waits. An interrupted syscall returns its I/O error for the caller to handle; no hidden sleep/retry policy is introduced.

The target-only `libc` dependency fills a concrete gap: Rust's standard library exposes neither inotify nor `poll`. There is no asynchronous runtime. Resolved dependency versions live in the workspace lockfile.

- Recursive setup proceeds incrementally during polling; continue while `pending_work` is set. Install a directory watch before enumerating it, enumerate metadata only, skip symlink entries, and keep at most one enumeration directory handle open. No file contents are read and no filesystem items are removed or modified.
- New and moved-in directories enqueue recursive setup and request a root rescan, because they can already contain files before their watches are installed. Perform an initial index separately; completing watch setup does not emit synthetic create events for preexisting files.
- Deletion and moves out invalidate descendant path mappings immediately, cancel their pending enumeration, and retire their kernel watches in bounded batches. A moved-in directory gets fresh watches at its new paths. A root move or unexpected watch invalidation requests a rescan rather than trusting stale path hints.
- Nonzero rename cookies pair within one root until the kernel queue drains. Unpaired outgoing/incoming moves become removed/created hints. Cross-root moves intentionally become remove/create hints, keeping each root's invalidation self-contained. At most 4096 outgoing cookies are retained; excess cookies request a rescan and degrade to removal hints.
- `IN_Q_OVERFLOW` requests rescanning every managed root and discards outstanding rename cookies. `ENOSPC` from `inotify_add_watch` requests rescanning the affected root instead of pretending coverage is complete. Other setup/enumeration errors also mark the root incomplete and may return an I/O error.

A rescan signal is not proof that kernel coverage recovered. The future agent must reconcile its metadata index and, after overflow, moved roots, or failed watch installation, recreate this source from current validated roots to restore complete coverage (after resolving watch-limit/permission/resource problems). It must never clear the incomplete state just because a later poll is empty. Concurrent filesystem replacement can race path-based enumeration; watcher paths remain hints, not security authority. Mount changes, remote filesystems, hard-link aliases, and changes through unwatched aliases are not a complete activity history.

## Other targets

macOS and other non-Linux targets compile the portable trait, event types, coalescer, and scripted source only. There is deliberately **no native watcher stub pretending to observe changes**, no kqueue/FSEvents implementation, and no platform watcher on Windows. Consumers must select an actual platform adapter explicitly.

## Verification

From `rust/`:

```sh
rustup target add x86_64-unknown-linux-gnu
cargo check --locked -p tinyprune-watch --target x86_64-unknown-linux-gnu --all-targets
cargo clippy --locked -p tinyprune-watch --target x86_64-unknown-linux-gnu --all-targets -- -D warnings
cargo test --locked -p tinyprune-watch
```

The portable tests exercise coalescing, cookie pairing across bounded polls, unmatched and cross-root moves, overflow/watch-limit rescan signals, bounded retained cookies, and watch-table deletion/rename bookkeeping using the scripted source. macOS can run these tests and cross-check Linux compilation, but that does **not** execute inotify. Real Linux inotify behavior requires a Linux runtime and is not established by these checks.
