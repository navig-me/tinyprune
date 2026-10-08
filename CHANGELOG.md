# Changelog

## 0.1.1 - 2026-10-08

### Safety
- Trash execution re-resolves the item with hydrated activity and re-reads policy immediately before the move; a bounded descendant walk fails closed. Paths must be inside a managed root with no symlinked ancestors.
- Keep protects by identity or normalized path, and protected descendants survive renames. Hidden descendants of a trashed folder are honored when hidden-file protection is on.
- New `deferred` outcome: pause, Preview, a moved deadline, or transient errors keep the deadline and retry; only terminal conditions skip. A failing item backs off and no longer blocks other due items.
- Dangerous-root guard is case-insensitive and resolves symlinks; very broad roots (home, `/Users`, `/Volumes`, `/private`, volumes) may be managed but are Preview-only, and the agent rejects Active rules on them.
- The Trash attempt audit is written after the final checks; dangling attempts are reconciled at startup.
- Filesystem identity gains a creation time; device-number fallback volume ids are not persisted.

### Behavior
- Glob patterns without `/` match the basename at any depth; unsupported syntax is documented.
- Downloads and Temporary Workspace templates are now non-recursive (top-level items only).
- Preview counts only items execution would act on and lists top-most matches only.

### IPC and CLI
- XPC protocol version 2: policy revision compare-and-swap (`policyConflict`), atomic `saveRule`, batched `setItemOverrides`, `loadRoots` without bookmark data, `cancelPreview`, per-root health, client timeouts (ADRs 0007, 0008). Peers are authenticated by code-signing requirement on signed builds.
- CLI exit codes: 64 usage, 65 data, 69 unavailable, 70 agent error, 75 timed out/interrupted/busy, 78 roots not managed. `--json` errors are JSON; unknown flags and extra or swapped arguments are usage errors. `config apply` no longer drops the pause state.
- CLI and Finder share explanation formatting and expiry presets; `tonight` after 23:59 rolls to the next day.

### Documentation
- Removed unbacked claims: ⌘Z undo (restore with Finder's Put Back, if available), a Finder "Keep" tag, and daily summary notifications. "Always recoverable" now states that items stay in the Trash until you or macOS empty it.
- Privacy wording is precise: the app has no telemetry; the tinyprune.com website uses Google Analytics and PostHog.
