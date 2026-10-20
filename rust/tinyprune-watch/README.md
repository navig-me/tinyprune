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

## Windows implementation

`WindowsEventSource::new(roots)` exists only on Windows. It opens one overlapped directory handle per root and immediately arms recursive `ReadDirectoryChangesW` (`bWatchSubtree=TRUE`). Roots must be absolute, nonoverlapping real directories without reparse-point ancestors; canonical paths preserve native UTF-16 spelling, and overlap checks use Windows ordinal case-insensitive component comparison. This watcher is implemented but **compile-checked only on the development Mac**; configured Windows CI is not evidence of native execution or released support.

- The notification mask includes file/directory names, attributes, size, last write, and creation. No file contents are read and nothing is mutated. Construction does not enumerate existing items; perform the initial metadata index separately.
- Each root retains one DWORD-aligned 64 KiB buffer and stable boxed `OVERLAPPED` storage. A shared manual-reset completion event supports any number of roots without the 64-handle wait limit. Polling waits only up to the supplied timeout, rounded up to milliseconds, and checks root availability at most one second apart while waiting. Zero timeout does not wait. Completion/availability probes are proportional to the number of managed roots; raw parsing and output remain bounded by the supplied limit.
- The platform-independent parser bounds-checks headers, UTF-16 lengths, record offsets and relative paths without aligned pointer reads or lossy Unicode conversion. Malformed/truncated records conservatively request a rescan rather than yielding untrusted paths.
- Adjacent old/new rename names receive a source-generated nonzero cookie and pair within a root across bounded polls. Unmatched names become remove/create hints when the completion queue drains; cross-root moves remain independent. Attribute/size/timestamp notifications are `Modified` hints because Windows does not distinguish these in the returned action. Removed paths have an unknown/false directory hint; consumers must use their existing index and fresh metadata, not rely on that bit to authorize effects.
- Zero-byte completions, `ERROR_NOTIFY_ENUM_DIR`, and malformed/overflowed buffers clear outstanding rename pairing and request a root rescan. New/moved-in directories also request reconciliation because they may contain existing descendants. Other completion/rearm failures and unavailable roots request a rescan and disable that watch; recreate the source with freshly validated roots to recover coverage. A later empty poll does not establish recovery.
- Drop uses `CancelIoEx`, observes cancellation/completion before freeing any pending buffer or `OVERLAPPED`, and closes every owned handle. Paths can still race namespace replacement and changes through aliases; this is an invalidation adapter, not a security boundary or complete activity history.

The target-only locked `windows` 0.62 dependency fills std's concrete gaps: recursive notifications, overlapped I/O/cancellation, waitable events, and ordinal path comparison. No asynchronous runtime or new crates.io package is needed.

## Other targets

macOS and targets other than Linux/Windows compile the portable trait, event types, coalescer, and scripted source only. There is deliberately **no native watcher stub pretending to observe changes**, and no kqueue/FSEvents implementation. Consumers must select an actual platform adapter explicitly.

## Verification

From `rust/`:

```sh
rustup target add x86_64-unknown-linux-gnu
cargo check --locked -p tinyprune-watch --target x86_64-unknown-linux-gnu --all-targets
cargo clippy --locked -p tinyprune-watch --target x86_64-unknown-linux-gnu --all-targets -- -D warnings
rustup target add x86_64-pc-windows-msvc
cargo check --locked -p tinyprune-watch --target x86_64-pc-windows-msvc --all-targets
cargo clippy --locked -p tinyprune-watch --target x86_64-pc-windows-msvc --all-targets -- -D warnings
cargo test --locked -p tinyprune-watch
```

The portable tests exercise coalescing, cookie pairing across bounded polls, unmatched and cross-root moves, overflow/watch-limit rescan signals, bounded retained cookies, and watch-table deletion/rename bookkeeping using the scripted source. macOS can run these tests and cross-check Linux compilation, but that does **not** execute inotify. Real Linux inotify behavior requires a Linux runtime and is not established by these checks.

Portable tests additionally execute synthetic Windows buffers (including unaligned input, malformed/truncated records, UTF-16 preservation, chained records, and rename pairing/reset) on macOS. Windows-only tests use real disposable temporary directories for recursive create/modify/rename/delete, root unavailability, bounded output, pending-I/O drop, root validation, and an injected overflow through the production loss handler. `cargo test --locked -p tinyprune-watch` on the Windows CI runner includes those tests. Overflow injection verifies recovery signaling, not actual kernel-buffer exhaustion. Native Windows tests have not been executed on this Mac.
