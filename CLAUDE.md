# TinyPrune contributor guide

Read `spec.md` and `PLAN.md` before changing product behavior. `spec.md` is the product contract; `PLAN.md` defines the implementation sequence and release architecture.

## Product invariants

- TinyPrune is a local-first macOS lifecycle-rule tool, not a generic cleaner.
- Normal deletion means moving an item to macOS Trash. Never introduce permanent deletion in v1.
- Re-evaluate current filesystem identity, resolved rule, Keep/protected ancestors or descendants, deadline, pause state, permissions, and volume availability immediately before a Trash operation.
- The SQLite index schedules candidates; it never grants permission to delete.
- `Keep` takes precedence over every other policy. Do not trash a folder that contains a protected descendant.
- Preview runs matching and scheduling but must never invoke the Trash executor.
- Normal operation may read filesystem metadata only. Do not inspect file contents or require network access.
- Scale with FSEvents and scheduled deadlines. Initial indexing and recovery are the only full traversals; they must enumerate in bounded batches.
- CLI and Finder extension are clients of the agent through XPC. Do not duplicate rule evaluation or cleanup logic in frontends.
- Do not add V2 agentic features, cloud sync, telemetry, subscriptions, system optimization, or content analysis.

## Architecture boundaries

- `TinyPruneDomain`: pure deterministic types, validation, rule precedence, and explanations.
- `TinyPrunePersistence`: migrations, SQLite repositories, xattr codec, and identity persistence.
- `TinyPruneEngine`: filesystem events, streaming indexing, project activity, scheduling, safety preflight, and Trash execution.
- `TinyPruneIPC`: versioned XPC contract shared by app, agent, CLI, and Finder extension.
- UI targets must not directly mutate operational state or execute cleanup.

Use stable filesystem identity `(volume UUID, resource identifier, path hint)` rather than paths alone. Persist explicit overrides in SQLite and versioned xattrs only; never write metadata to every inherited child. User-selected roots require security-scoped bookmarks. Reject dangerous roots and force Preview for very broad scopes.

## Engineering conventions

- Swift concurrency: use actors for mutable agent/store coordination. Public cross-process DTOs must be `Codable` and evolution-safe.
- Make time, filesystem access, FSEvents, and Trash execution injectable for deterministic tests. Never use production sleeps in tests.
- Every decision returned to UI/CLI must include a complete explanation: item, scheduled time, rule, basis, project context, override, and suppression reason if any.
- Audit rule mutations, overrides, scheduling decisions, preview matches, safety skips, Trash success, and failures transactionally.
- Explicitly handle renamed/replaced identities, stale bookmarks, missing files, revoked permissions, disconnected volumes, xattr/database disagreement, agent restarts, and protected descendants.
- Do not add a dependency without a concrete platform gap. Pin tool and action versions.

## UI direction

Use the Stitch references in `stitch_tinyprune_macos_app/` as visual direction, interpreted through native SwiftUI/AppKit controls:

- Calm desktop utility: warm stone surfaces, editorial Newsreader titles, Manrope controls/body, JetBrains Mono for paths.
- Deep plum is the primary action/selection color; green represents safe/healthy states; amber represents caution. Preserve macOS accessibility contrast and state clarity.
- Overview remains quiet: managed places and next-to-prune, not charts or inflated storage KPIs.
- Explain safety and reversibility without inventing guarantees beyond the actual engine behavior.
- Use Preview as the primary affordance for broad developer rules.

## Test and release requirements

- Add tests for behavior and invariants, not implementation plumbing. At minimum cover precedence, glob boundaries, protection, preview, stale identity, pause/safety races, project activity noise, recovery, and failed Trash operations when modifying those paths.
- For agent behavior, run a fixture-tree smoke test that observes actual scheduling/preflight/Trash outcomes. For UI, perform a manual/automation smoke of the affected native flow.
- Direct DMG releases use signed, notarized Sparkle updates. Homebrew releases update only through the cask and must disable Sparkle automatic checks in that distribution build.
- Release workflows must use protected GitHub Environments, least-privilege permissions, immutable artifacts, notarization/stapling/Gatekeeper validation, checksums, and a verified appcast/cask update.

## Before opening a pull request

1. Update affected domain, engine, persistence, XPC, app/extension/CLI callers, tests, and user-visible documentation.
2. Run the narrow test/fixture scenario for the changed behavior, then the repository’s prescribed quality command.
3. State the exact verification command and observed result in the PR.
4. Keep scope aligned with `spec.md`; record material architecture decisions as ADRs.
