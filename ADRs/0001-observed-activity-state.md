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
- Project-level inactivity is derived and persisted separately by project-root identity.
- The item explanation, explicit rule dry run, and indexer share read-only candidate hydration so first-observed, observed-activity, and project-activity explanations agree with Upcoming. Missing observation records use the injected current time without writing from an explanation or dry run.
- Explicit custom-expiry overrides produce persisted deadlines even when no lifetime rule matches. Their explanations carry an optional `customOverrideID` (absent on existing saved payloads); the scheduler derives `ScheduledSource.customOverride` from it rather than treating an override as a rule. The custom date is used directly without an inherited grace period. Keep, Inherit, and clearing an override discard that custom schedule; an inherited rule may then schedule the item instead. Rule statistics exclude custom expiries. Trash still re-resolves the current override and Keep protection at every preflight, so a stale deadline cannot authorize a move.
