# tinyprune-daemon (in development, unreleased)

Internal runtime that assembles the Rust workspace into one local agent process (`tinyprune-agentd`). TinyPrune remains a macOS-only product; this is unreleased engineering work, not Linux or Windows support.

## Run

```sh
cd rust
cargo run --locked -p tinyprune-daemon --bin tinyprune-agentd -- [--data-dir PATH] [--endpoint PATH] [--reconcile-seconds N]
```

Stop with Ctrl-C (SIGINT / Windows console Ctrl-C) through the `ctrlc` crate, a tiny dependency for a portable handler that `std` lacks; SIGTERM is not handled. Shutdown cancels the engine and any Preview, stops serving, and releases the lock and socket.

Defaults (all injectable through `Options`/`Paths` and the flags above):

| OS | Data/log directory | Endpoint |
|---|---|---|
| macOS | `~/Library/Application Support/TinyPrune` | `tinyprune_ipc::default_endpoint()` |
| Linux | `$XDG_DATA_HOME/tinyprune` or `~/.local/share/tinyprune` | same |
| Windows | `%LOCALAPPDATA%\TinyPrune` | same (named pipe) |

`TINYPRUNE_ENDPOINT`/`TINYPRUNE_SOCKET` override the endpoint through the IPC crate. The data directory is private (0700 on Unix) and holds `agent.sqlite3`, `agent.lock` (single-instance advisory lock; a second instance fails) and `logs/agent.jsonl` (truncated at 4 MiB; counters only, never paths, requests, config, or contents).

## Assembly

- Store: durable `tinyprune-store` (policy revision compare-and-swap, audit, decisions, reclaim ledger). Every policy mutation goes through `replace_policy`; stale revisions return `PolicyConflict`.
- Engine: `tinyprune-agent` with `ProductionIndexSource` (bounded enumeration; candidate snapshots published to the store after a complete scan), the OS `FileAccess` (`tinyprune-unix` or `tinyprune-windows`), and the core `TrashCoordinator` re-checking policy/identity before every move. The injected `Clock` drives all time; production uses `SystemClock`.
- Watching: Linux uses inotify and Windows `WindowsEventSource` (rebuilt after any rescan signal). Other platforms (macOS) have no native watcher, so `poll.rs` provides a bounded **polling fallback** with two cadences. (1) A directory-change poll walks directory entries incrementally (8192 entries per poll; directory mtimes only, no per-file metadata or contents) no sooner than `max(reconcile_interval / 10, 1 s, 10 x the last walk's real cost)`; a directory whose mtime changed (entry created, removed or renamed) becomes a `Modified` hint, so only the topmost changed subtrees are rescanned. (2) A full rescan of each root no sooner than `max(reconcile_interval, 10 x the real duration of the last scan)` after that scan *finished* (default floor 300 s, injectable), which catches in-place content changes, changes racing the poll baseline, and more than 64 changed directories. Nothing is queued while a scan or decision pass is running. Between full rescans, a file edited in place keeps its previous recorded dates, which is safe: every Trash re-reads current metadata and defers if the item is no longer due. Unchanged candidates, deadlines and decisions are not rewritten. This is a documented fallback, not FSEvents.
- IPC: `Service` implements `AgentService` for every operation. Preview runs `tinyprune-scan::preview` plus the core resolver against a read-only observation overlay; it takes no Trash executor and writes nothing (one at a time, cancellable). Rules are validated by the core (dangerous roots rejected, Active rules on very broad roots rejected); overrides must be inside managed roots and identity-bound. Full explanations are produced by core resolution and persisted with `record_decision` after each published scan; Activity attaches the latest decision to Trash events.
- Native paths cross into the core through a lossless UTF-8 lexical conversion. Windows flavor is selected from `tinyprune-windows::PATH_FLAVOR`, including the store constructor; root authorization and store subtree publication compare normalized drive/UNC paths, including canonical `\\?\` paths and either separator. Watcher event roots are matched to the stored managed-root spelling before jobs are queued. The Windows executor always uses the real Recycle Bin: `Options.trash` only injects the Unix freedesktop Trash location.
- Run loop: the calling thread polls the nonblocking listener (at most 16 accepts per turn, 16 concurrent connections via `Server`) while a separate engine thread ticks continuously while work is pending (yielding to waiting mutations) and parks for `tick_interval` when idle. Accept/dispatch errors (a client that vanished before peer verification, EINVAL/ECONNABORTED/EINTR/EMFILE, Windows pipe errors) are counted and logged, never fatal; only 1000 consecutive failures end the agent. Full decisions are evaluated off the engine lock in bounded steps into an indexed `current_decisions` table (unchanged decisions are neither rewritten nor re-audited). Tests drive `Daemon::tick` directly with a scripted clock; no sleeps.

## Known limits

- Windows config import/export returns `InvalidRequest`: the core config codec is POSIX-only (Windows flavor is a later task).
- Linux workspace tests, Clippy, release binaries and the Unix end-to-end smoke have run in a local Docker Linux/aarch64 container with Rust 1.98.1. That is not Ubuntu x86_64 CI acceptance or released Linux support. Windows runtime changes still require native verification; macOS has no native watcher.
- Audit retention is enforced incrementally (256 rows per tick) while preserving the reclaim ledger and pending attempts.
- Item identity persists across restarts only on volumes with a durable id (macOS volume UUID, Linux filesystem UUID, Windows volume serial) together with inode/file ID and creation time. Other volumes (tmpfs, overlayfs, FUSE, network filesystems without a UUID), filesystems without creation time and cloned volumes are non-persistent: the store discards their schedules on reopen, so a restart re-observes those items and FirstObserved clocks restart. Tested on macOS only.
- Item sizes and estimates are file `len()` metadata only.
- Mutations (rule/override/settings/pause/roots) wait for the engine's current bounded turn (one batch of at most 1024 entries; the final scheduling pass of a scan is synchronous in `tinyprune-agent` and grows with root size). Reads (overview, upcoming, activity, policy, settings, roots, explain, size, export) never take the engine lock and are answered from the store's read path. Each request's decision data lags the last completed scan/decision pass; a policy mutation re-evaluates decisions after its reconcile completes.

## Verification

```sh
cargo test --locked -p tinyprune-daemon
cargo clippy --locked -p tinyprune-daemon --all-targets -- -D warnings
```

Tests: loopback IPC for each operation group with a scripted clock, Preview-never-trashes (audit count unchanged, file intact), pause/pause-until blocking cleanup, Keep, broad-root Active rejection, single-instance lock, and (Unix) a real socket end-to-end run into a temp trash with restart recovery. The abandoned-connection test permits deliberate connection-limit rejection while waiting for capacity, bounds its wait, and signals daemon shutdown even when assertions unwind. The bundled-SQLite dependency prevents `--target` cross-checks on this Mac.

The Windows-only path regression uses real canonical temp paths (`\\?\`), checks normalized rule scopes against native managed roots, clears an override across path spellings, rejects a sibling outside the root, and reopens persisted policy before Preview. The portable fixtures join native `PathBuf`s before converting to core paths; they never append `/` to an extended-length native path. Cleanup tests on Windows exercise the real Recycle Bin rather than the Unix injected Trash directory.
