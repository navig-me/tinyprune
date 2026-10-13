# ADR 0002: Derive project inactivity from metadata and recover event streams

- Status: Accepted
- Date: 2026-10-01

## Context

Project-inactivity rules need a durable, explainable activity date without inspecting file contents. FSEvents is an incremental hint, not a durable queue: process crashes, dropped events, root changes, sleep, and volume unmounts require reconciliation. A deadline index must not grant deletion permission.

## Decision

Detect project roots from `.git`, `package.json`, `pyproject.toml`, `requirements.txt`, `Cargo.toml`, `go.mod`, `Gemfile`, `pom.xml`, `build.gradle`, and `composer.json`. Persist project activity by filesystem identity and use component-boundary path matching to associate a candidate with its nearest project. During initial/recovery scans, derive activity from meaningful file modification metadata only; ignore generated and dependency trees (`.git`, `node_modules`, virtual environments, caches, build outputs) and `.log` files. Event-driven meaningful file changes advance the project activity time and refresh matching deadlines in bounded pages.

Persist the last successfully reconciled FSEvents ID per managed root. Collapse FSEvents callbacks larger than 512 entries into a single recovery marker and buffer at most 512 event batches per root. Persist at most 256 rows per indexer write batch. A stream drop or FSEvents recovery flag triggers a full reconciliation before committing the recovered cursor; a dropped buffered event restarts the stream from the last committed cursor so changes are replayed. Preview continues to use the same index but never invokes the Trash executor. Every due candidate still receives the normal final safety preflight.

Subscribe to workspace mount, unmount, and wake notifications. Reconfigure watches and reconcile roots on relevant lifecycle changes. Run passive WAL checkpointing and SQLite optimization at agent start and clean stop.

Scans enumerate filesystem metadata once. Roots with applicable project-inactivity rules stage candidate metadata in SQLite; other roots stage evaluated deadlines directly. All staging and evaluation pages are bounded to 256 rows. Project aggregation yields between bounded pages without holding a transaction across suspension, uses indexed ancestor equality lookups for nested ownership, and batches project maxima. A successful scan atomically replaces the published deadline set. Cancellation, root failure, or an incomplete project-activity view preserves prior schedules. Non-project scans can publish readable matches while retaining known schedules below unreadable locations; more than 256 distinct unreadable locations fails closed.

Ordinary edits to known project-marker identities update activity rather than rediscovering the project. Marker creation, removal, replacement or relocation reconciles the affected subtree. Generated-tree exclusion applies to activity, not to other applicable cleanup matches. Noisy directory markers use stable creation metadata (or their durable first observation when creation metadata is absent), not bookkeeping modification dates. Source events refresh only project-activity deadlines and batch changed rows. Per-root ordering and scan generations allow unrelated roots to progress independently; pause and retention changes do not trigger traversal.

Overlapping managed roots share a conservative reconciliation gate so ancestor and descendant scans cannot concurrently prune the same project or deadline state. Lock-domain changes drain existing work before regrouping, and cleanup readiness excludes roots with in-flight reconciliation. Removing an ancestor root preserves identity observations and schedules still covered by a retained nested root.

Watch streams capture a historical event-ID boundary before starting. Wake replay remains non-executable until its FIFO consumer successfully processes preceding batches and `HistoryDone`; the control marker never counts as file activity. Historical source deletions use surviving parent-directory modification metadata as a conservative bound. Available, reconciled roots can execute scheduled work, but current identity, policy, protection, permissions, deadline and update interlock still require final preflight. This barrier does not eliminate normal FSEvents delivery latency.

The due scheduler drains bounded keyset pages and retains per-item backoff across timer wakes. Overview reads policy, samples and complete counts in one store actor turn; detail pagination filters before limiting rows. Successful Trash audit writes maintain lifetime scalar totals and indexed move metadata transactionally. Local calendar intervals produce coherent daily summaries without decoding lifetime audit payloads.

## Consequences

- Project inactivity is based on filesystem metadata, not source parsing; unsupported project markers are not recognized until added deliberately.
- Recovery may perform a full traversal, but normal operation remains event-driven and scheduled-deadline-driven.
- Stable identity and current filesystem state remain authoritative at Trash time; saved event cursors and deadlines are scheduling/recovery state only.
- Local diagnostics report scan duration, CPU time, peak resident memory, entry count, event-queue and persistence-batch high-water marks, and recovery count. They are not uploaded.
- The macOS 15 release benchmark is `swift test -c release --filter PhaseTwoBenchmarkTests/test100kIndexBenchmarkAndSixtySecondIdleSoak`, with a 100,000-file fixture and a 60-second idle soak.
