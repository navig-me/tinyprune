# tinyprune-scan (in development)

Unreleased metadata-only filesystem traversal for the Rust agent. TinyPrune remains a macOS-only product; this crate does not establish or release Linux or Windows support.

## Interfaces

- `ScanCursor` uses an explicit depth-first stack of directory iterators. `next_batch` bounds attempted entries **and directory-pop work**, not just the number of successful candidates. Defaults: 256 operations and 50 ms between OS calls per batch, at most 256 simultaneously open directory cursors. Memory is proportional to depth plus one batch, not tree size. No sorting, content reads, persistence, or Trash calls occur.
- `CancellationToken` is cloneable and thread-safe. Cancellation is checked between entries. Entry and total/batch elapsed-time budgets are injectable (`TimeSource`); no sleeps are needed in tests. OS metadata/directory calls are synchronous and cannot themselves be interrupted or given a hard wall-time deadline.
- Batches contain native `PathBuf` paths and per-entry outcomes: metadata candidate, vanished, unreadable, symlink/reparse point, or other volume. `partial` is cumulative; cancellation and hard caps have separate flags. `finished` means cursor exhaustion **or stopping**, not a successful complete scan. Never publish an incomplete batch sequence as a replacement tree. Retain previous schedules under failed subtrees; project inactivity requires a complete successful view.
- `ScanSnapshot` optionally collects batches for the core `MetadataSource` trait, which requires a complete in-memory slice. It rejects incomplete, cancelled, truncated, or unfinished snapshots. Unlike the cursor, collecting a snapshot consumes memory proportional to tree size.
- `ProductionIndexSource` plugs into `tinyprune-agent::IndexSource`. The existing agent contract has no partial-subtree publication facility, so this adapter conservatively returns an error for any partial scan. The agent retains **all** previous schedules and blocks execution until complete recovery rather than clearing unseen entries. Its entry limit is the smaller of the configured batch limit and the agent-supplied limit. `begin` replaces the previous cursor; use a fresh cancellation token after cancelling a cursor.

Paths are absolute without lexical dot components. The caller supplies an authorized, resolved managed-root path; traversal is not managed-root authorization. Symlinks and Windows reparse points (including junctions) are not evaluated or descended into, and link ancestors are rejected. Unix volume identity and Windows volume/file identity come from the existing `tinyprune-unix` and `tinyprune-windows` adapters, not a second identity implementation. Other-volume entries are skipped unless explicitly enabled. Windows reparse mounts remain excluded even when other volumes are enabled. Special objects fail closed.

Hidden items and noisy directories such as `.git`, `node_modules`, and `target` are **enumerated**, matching the Swift indexer's complete-candidate traversal. Skipping their descendants would miss Keep protection and explicit rules. The shared core handles hidden protection and ignores bookkeeping for project activity (`meaningful_activity`); the scanner does not duplicate policy logic.

Native path case and Unicode spelling are never normalized by this crate. The core and platform helpers currently accept UTF-8 strings: unrepresentable native names are returned as `Unreadable` with their original `PathBuf`, mark the scan partial, and are never converted lossily. A filesystem may itself canonicalize names; its returned spelling is preserved.

### Filesystem races

Metadata inspection is not an atomic snapshot. Vanishing entries are partial outcomes, not proof that a complete directory was scanned. Like the existing platform adapters, portable `std::fs` checks/open calls cannot atomically condition subsequent operations on a previously checked identity: a hostile concurrent directory-to-symlink replacement can race the ancestor/entry rechecks before `read_dir`. Static links are never followed, but this is not a capability-secure walk against adversarial namespace mutation. Enumeration never authorizes a Trash operation; the coordinator must recheck identity, ancestors, policy, availability, and Keep immediately before any actual move. See the platform adapter READMEs for their move races.

## User-initiated dry run

`preview(path, options, cancellation)` creates an independent read-only cursor with caps no greater than 256 operations/batch, 500,000 attempted entries, and 20 seconds. Smaller supplied caps are honored. Use `max_depth: Some(0)` for exact/item-specific scopes, `Some(1)` plus `include_root: false` for nonrecursive scoped rules, and `None` for recursive scopes. See [ADR 0003](../../ADRs/0003-explicit-rule-preview-traversal.md).

This is a traversal API, not a separate rule evaluator or scheduler. The embedding caller must validate scope containment and managed-root access, run it off the scheduling path, evaluate candidates using the shared core resolver in Preview disposition with read-only persisted observations, and report truncated counts as lower bounds. Directory size measurement has its own shared budget and belongs to the existing size-measurer/evaluator. The scanner has no store, audit sink, policy writer, xattr writer, or executor parameter, so it cannot persist or Trash anything.

## Dependencies

Only workspace dependencies are added: core for candidates/snapshot protocol, agent for its enumerator protocol, and target-gated Unix/Windows adapters for their production identity and metadata implementations. No new third-party dependency is introduced by this crate. Resolution is pinned in the workspace `Cargo.lock`.

## Verification

From `rust/`:

```sh
cargo test --locked -p tinyprune-scan
cargo clippy --locked -p tinyprune-scan --all-targets -- -D warnings
cargo check --locked -p tinyprune-scan --target x86_64-unknown-linux-gnu --all-targets
cargo check --locked -p tinyprune-scan --target x86_64-pc-windows-msvc --all-targets
cargo test --locked -p tinyprune-scan --release -- --ignored bench --nocapture
```

Tests use real disposable temp trees for batch bounds, cancellation before/during enumeration, injected time, vanishing entries, hidden/noise handling, native Unicode spelling, depth limits, snapshot rejection, read-only Preview, and directory-resource budgets. Unix tests add permission denial, invalid UTF-8 paths, and symlink loops/ancestors. Privileged runners explicitly report when they bypass permission mode bits. The ignored benchmark creates 50,000 files in 100 directories, times only metadata traversal, prints entries/sec, and requires the 50,101-item traversal to finish in under 10 seconds. Neither cross-compilation nor this Mac's tests establish native Linux/Windows runtime acceptance.

Observed on the development Mac (Darwin 25.5.0, x86_64), 2026-10-20: release traversal visited **50,101 entries in 1.401 s, 35,761 entries/sec**. Fixture creation and teardown are excluded from throughput (the complete benchmark test took 13.61 s). The focused test suite passed 13 tests with this benchmark ignored; Clippy with warnings denied and both Linux/Windows all-target cross-checks passed. Linux and Windows were not executed natively. On this Mac the filesystem rejects invalid-byte names, so that test covers preservation of an explicitly supplied unrepresentable path; actual enumeration of such names requires a filesystem that permits them.
