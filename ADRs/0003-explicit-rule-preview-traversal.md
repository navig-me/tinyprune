# ADR 0003: Allow an explicit, bounded rule-preview traversal

- Status: Accepted
- Date: 2026-10-02

## Context

The spec's "Impact preview" (§18) must tell the user, before a rule is saved, how many items it matches, how many would be pruned immediately, and roughly how many bytes that is. The index only knows about already-saved rules, so a candidate rule cannot be previewed from SQLite alone. Until now `AGENTS.md` allowed only initial indexing and recovery to traverse the filesystem. The product owner decided to amend that invariant for a user-requested dry run rather than approximate the answer.

## Decision

`AgentOperation.previewRule(LifetimeRule)` performs a user-initiated dry run that is the only traversal besides initial indexing and recovery. It is:

- **Read-only.** It writes no database rows, deadlines, observed-activity records, audit events, or xattrs, and it never invokes the Trash executor or moves anything.
- **Scope-limited.** It enumerates only the rule's scope, honoring the recursive flag (non-recursive scopes enumerate direct children only; exact-path and item-specific rules inspect the single item). The scope must be inside an available managed root whose bookmark the indexer resolved; anything else is rejected with `invalidRequest`.
- **Metadata-only, symlink-safe.** Only attributes and resource values are read. Symbolic links are neither followed nor evaluated.
- **Evaluated by the indexer's path.** Candidates go through the shared `IndexedCandidateEvaluation` (the same `RuleResolver` call, current overrides and settings, and project/observed-activity overlay the indexer uses), with the previewed rule substituted into the policy in Preview disposition regardless of its requested state. A match is an item whose resolution is scheduled by the previewed rule, so Keep overrides, hidden-file protection, and higher-precedence rules exclude items exactly as saving would. Persisted state is read, never written: stored observed/project activity is used when present; for first-observed and observed-activity bases without a stored record, "first observed" is the injected `now`, exactly what the indexer would persist on first sighting. Project activity that has not yet been indexed is absent, as it is for the indexer before its scan.
- **Bounded.** Enumeration streams in batches of 256. Hard caps: 500,000 entries, a 20 s wall-clock budget, and a shared 200,000-entry budget for measuring matched directories with `ItemSizeMeasurer`. Reaching any cap sets `truncated`, and counts and `estimatedBytes` are then lower bounds. Limits and time source are injectable for tests.
- **Off the scheduling path.** The walk runs on a detached task, not on the indexer, scheduler, runtime, or handler actors, so it cannot delay scheduling. It checks `Task.isCancelled` per entry and stops when the XPC call is cancelled.
- **Non-double-counting.** Bytes are the allocated sizes of matched items; items inside an already-measured matched folder are counted as matches but not re-measured.

`eligibleNow` counts matches whose scheduled time is at or before the injected clock. Results include at most 20 soonest samples.

## Consequences

- A preview can read up to half a million directory entries on demand; this is bounded, user-initiated, and cancellable, and normal operation remains FSEvents- and deadline-driven.
- Preview results are advisory. Every real Trash still goes through the full pre-Trash preflight, and the SQLite index still never authorizes deletion.
- Because the evaluator is shared, rule-evaluation changes apply to both paths automatically.
- Previews of project-inactivity rules may undercount until project activity has been indexed, and a truncated preview understates the impact.
