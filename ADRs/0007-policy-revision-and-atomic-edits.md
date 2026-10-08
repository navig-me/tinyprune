# ADR 0007 — policy revision and atomic edits

Status: accepted.

## Problem

`replacePolicy` was last-writer-wins. App, CLI, and Finder each loaded a snapshot, transformed it, and wrote it back, so a stale client silently dropped Keep overrides, `pausedUntil`, and rules added meanwhile. Rule save plus Keep changes took several separate calls, and a failure midway left a partial result. Every override change triggered a full reindex.

## Decision

The store keeps a `policy_revision` counter (migration 8). Every policy mutation bumps it inside its own transaction. `AgentPolicySnapshot` carries `revision` (decoded with a default of 0).

- `replacePolicy` compares the client's revision with the store's inside `BEGIN IMMEDIATE`. A mismatch fails with `policyConflict` and changes nothing. Clients reload, reapply their transform, and retry up to three times.
- `saveRule` upserts a rule, optionally merges roots, and applies Keep/unkeep paths in one transaction with an expected revision. Keep paths must resolve inside available managed roots, otherwise the whole operation fails and nothing is saved.
- `setItemOverrides` applies a batch in one transaction without a revision, since overrides are per-item and idempotent.
- The handler serializes mutating operations so read-modify-write cannot interleave across awaits.
- Override-only changes reconcile only the affected subtrees (`overridesDidChange(paths:)`), not all roots.
- `loadRoots` returns id, path, and name only. Bookmark data is never exposed to frontends.
- Rules in Active state with a very broad scope are rejected by the shared validator for `replacePolicy` and `saveRule`.

## Consequences

- Protocol version is 2; there is no compatibility path for version 1 clients.
- A conflict after three retries is surfaced to the user. An interrupted or timed-out request may have been applied, so the CLI reports exit code 75 and advises `tinyprune status`.
