# tinyprune-agent (in development)

Unreleased synchronous agent orchestration for the TinyPrune Rust workspace. TinyPrune remains macOS-only; this crate does not release or establish Linux or Windows support.

`Agent::new(files, policy, store, audit, events, index)` connects the core scheduler and `TrashCoordinator` to a `tinyprune-watch::EventSource`. `tick(now)` performs one deterministic bounded turn and returns `TickReport`; `tick_clock(&clock)` reads an injected core `Clock`. Nothing sleeps or starts threads. `ScriptedEventSource` is usable directly in tests. All collaborators are public fields for an embedding application's configuration and lifecycle management.

## Embedding contracts

- Supply core `FileAccess` and `PolicyStore`, an `AgentStore` extending core `ObservationStore`, an `AgentAudit` extending core `AuditSink`, and a metadata-only `IndexSource`.
- `IndexSource::begin` replaces its enumeration cursor. `next_batch` must bound enumeration work, not merely slice an already enumerated tree; never follow symlinks. Return an error for inaccessible/incomplete enumeration, not an empty successful tree. `available` must reflect current root availability/permission.
- The store owns all persistence. Root deadline replacement is atomic; deadline removal is conditional on identity and original scheduled time. Observation identity/path-hint semantics are the core scheduler's contract. Audit recovery atomically closes an interrupted attempt and records an honest unknown-outcome safety skip, never fabricated Trash success.
- Initial indexing and overflow recovery enumerate roots in bounded batches. Ordinary hints enumerate only the affected subtree and reconcile it with the cached metadata snapshot. Complete snapshot decision evaluation is synchronous; its CPU and retained metadata grow with the root size. This is not a constant-memory or hard wall-time-bounded scheduler.
- One active enumeration cursor is used; pending jobs serialize. Each tick polls at most the configured event budget, enumerates at most the entry budget, and executes at most the due-item budget. Snapshot publication waits until the scan completes. Pending event replay and scan jobs prevent cleanup; a continuously busy source may conservatively delay it.
- A wake/policy change can call `reconcile(root)`. Polls always precede cleanup; replayed activity uses current metadata modification time rather than wake wall time. Policy is reloaded every tick and the coordinator rechecks policy and identity twice before moving.
- The deadline queue is ordered by next runnable time and keyed by volume/resource identity. Retry state survives reconciliation only while full identity and original deadline agree. Errors back off from 30 seconds; deferrals/Preview from 300 seconds, doubling to a 3600-second cap. A failed item cannot block other due entries. `NotDue` waits until its corrected deadline (at least one second). Moved/skipped results remove persisted deadlines; moved-but-audit-failed also removes the deadline because the filesystem effect already happened.
- Preview decisions are reported but never submitted for execution. Paused, unavailable, unindexed, recovering, and cancelled states never move anything. `cancel` takes effect between synchronous turns; it pauses an unfinished batch sequence without publishing it. `resume` continues it. Callers must not expect interruption inside a synchronous adapter call.
- A failed tick invalidates readiness and requires a successful full recovery before old schedules can execute. Interrupted Trash attempts are recovered before initial indexing. The engine cannot recover a Trash destination absent a durable platform receipt; it explicitly reports outcome unknown and only a fresh scan can schedule surviving items.

All actual moves go through the core safety coordinator, including descendant protection, final policy and identity checks, metadata hydration, and audit-before-move. The engine persists nothing itself. Native IPC, daemon/process hosting, update-installation interlocks, production durable stores, and production metadata enumerators are outside this crate. The coordinator's always-open update gate here means an embedding app must pause the engine while installing updates. Platform adapter residual identity/move races remain documented in their READMEs.

## Verification

From `rust/`:

```sh
cargo test --locked -p tinyprune-agent
cargo clippy --locked -p tinyprune-agent --all-targets -- -D warnings
```

Tests cover deadline execution, Preview/pause/unavailable roots, Keep descendants, stable-identity rename deadlines, overflow reconciliation, bounded processing, per-item retry, restart/wake replay, cancellation mid-index, and (on Unix) an actual temporary-tree move through `tinyprune-unix::UnixFileAccess` to an injected temporary Trash. The Unix test uses a fake clock, reads metadata only for engine decisions, and does not touch the user's Trash.
