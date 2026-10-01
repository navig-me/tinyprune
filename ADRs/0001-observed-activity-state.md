# ADR 0001: Persist observed-activity timestamps by filesystem identity

- Status: Accepted
- Date: 2026-10-01

## Context

Rules may expire items relative to when TinyPrune first observed them or when it last observed filesystem activity. Initial indexing and later FSEvents-driven updates must preserve these timestamps across agent restarts and rescans without treating the SQLite index as authorization to trash.

## Decision

Persist `firstObservedAt` and `lastObservedAt` in a dedicated SQLite table keyed by stable filesystem identity. Store a path hint for subtree cleanup and update that hint during a later scan when the same identity is found at a new path. Initial scans insert missing timestamps without resetting existing observations; filesystem events update the last-observed timestamp. Create records only for candidates matched by rules using first-observed or observed-activity expiry bases. Remove records with managed-root or item-subtree removal.

## Consequences

- Rule evaluation receives durable timestamps while the existing safety preflight remains authoritative for Trash operations.
- Initial traversal batches persistence; event updates remain limited to changed paths.
- The index does not infer project-level inactivity or inspect file contents. Project activity analysis remains separate work.
