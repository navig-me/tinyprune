# Changelog

## Unreleased

## 0.2.2 - 2026-10-22

- Fix the app crashing on launch after a Homebrew upgrade. Re-registering the background agent trapped in `SMAppSystemServices.restartAgent()`: the `unregister` completion handler inherited `@MainActor` isolation inside a `@MainActor` class, and ServiceManagement calls it on an XPC queue, so Swift's isolation assertion aborted the app (`_dispatch_assert_queue_fail`). The handler is now `@Sendable`. The 0.2.1 change made this path run for an agent removed by the cask, which exposed the crash; 0.2.0 crashed in the same call after an upgrade.
- Verified by launching a local build on a Mac in the failing state: the app stayed running, re-registered the agent, and the agent answered `status`. No automated test reproduces the trap; it needs a real ServiceManagement reply.
- macOS-only patch. The Linux and Windows Rust developer preview stays at 0.2.0 (build 29); its crates carry the 0.2.2 version number but were not rebuilt or republished.

## 0.2.1 - 2026-10-22

- Fix `brew upgrade` leaving "Agent unavailable": the cask's `uninstall launchctl:` step removes the background agent job, and the app only repaired agents macOS still listed as enabled. An agent this Mac registered before is now registered again on launch; a first launch still waits for "Install background agent".
- **Known defect:** on that path the app crashed on launch (fixed in 0.2.2). Upgrade to 0.2.2 with `brew upgrade --cask tinyprune`.
- macOS-only patch. The Linux and Windows Rust developer preview stays at 0.2.0 (build 29); its crates carry the 0.2.1 version number but were not rebuilt or republished.

## 0.2.0 - 2026-10-22

**Initially prepared 2026-10-21; published 2026-10-22.** Version 0.2.0 adds the Linux and Windows Rust runtime as an unsigned developer preview, available from the [preview release](https://github.com/navig-me/tinyprune/releases/tag/rust-preview-0.2.0). macOS remains the only supported product; its [0.2.0 release](https://github.com/navig-me/tinyprune/releases/tag/v0.2.0) app, agent, Finder extension, CLI and Sparkle updater are unchanged from 0.1.13 apart from the version number. Publication dates, artifacts and verification evidence are recorded in [RELEASES.md](https://github.com/navig-me/tinyprune/blob/main/RELEASES.md#020).

- Align the Swift version defaults, all Rust crates and the Tauri shell at 0.2.0. Add `Scripts/check-versions.py` to CI, the authoritative `RELEASES.md` history, [ADR 0013](ADRs/0013-release-process-and-signing-custody.md) and the `.github/RELEASING.md` runbook.
- Simplify the landing page by removing its redundant introductory summary. Keep compatibility and licensing in the FAQ and download area. Update README, documentation and machine-readable references to distinguish published macOS downloads from the available Linux/Windows developer preview.
- Port rule matching, precedence, protection, configuration and scheduling decisions to Rust against 577 Swift-reference golden cases in 13 fixture files. Add Windows path and hidden-attribute handling with separate Rust-only tests.
- Add the Rust runtime ([ADR 0011](ADRs/0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md)): SQLite stores, bounded metadata-only traversal, native Linux/Windows watchers, incremental scheduling, local socket/named-pipe IPC, daemon, CLI and a Tauri UI. The SQLite schema and IPC protocol are separate from the Swift app.
- Exercise native watchers, Trash/Recycle Bin adapters, daemon/CLI smokes, developer installs and the Windows managed updater in CI. Exercise the Tauri webview against the real agent in Linux Docker and Windows WebView2. These are developer checks, not general desktop or screen-reader acceptance.
- Reduce per-event work through incremental scheduling, and bound SQLite WAL checkpoint work between decision pages while retaining `synchronous=FULL`. Platform benchmark results and their limits are linked from the release log.
- Add the user-confirmed Rust updater ([ADR 0012](ADRs/0012-rust-runtime-signed-updates.md)): Ed25519-authenticated manifests, size-capped and SHA-256-verified artifacts, monotonic builds, staged installs, health checks, rollback and the Trash/update interlock. Linux Docker and Windows CI update tests use throwaway keys. The production signed Rust feed publishes 0.2.0 build 29, and its protected public-verification workflow passed against the live feed signature and both public release archives. Package-manager and hand-copied installs are not updated by it. macOS keeps Sparkle; its live 0.2.0 feed publishes build 23, retaining build 22, and protected public verification passed for the live XML, release notes and DMG hash/signature. Both feeds use their existing keys; production OS update installation remains unverified.
- Embed the production Rust update public key only in `rust-artifacts.yml` dispatch builds on `main`, never in pull-request builds. Production signing remains a separate reviewed release step using the existing key.
- Publish the Homebrew 0.2.0 cask: the tap update is merged and the public cask points to the published macOS DMG.
- Known limits: Windows config import/export is unsupported; Rust on macOS uses periodic reconciliation rather than a native watcher. POSIX rename and Windows Shell cannot atomically condition a move on file identity. Volumes without durable identity or creation time are re-observed after restart. Screen-reader acceptance, broad desktop testing and production update installation remain unverified.

## 0.1.13 - 2026-10-13

- Preserve first-observed deadlines through parent-folder renames and restarts. Replayed filesystem hints reconcile durable timestamps and metadata rather than restarting inactivity timers at replay time.
- Keep published schedules visible while indexing or when a managed folder is unavailable. Successful scans publish a coherent replacement; unreadable locations retain known schedules. Cleanup waits for available roots and completed wake-event replay, with the existing final safety preflight unchanged.
- Show complete Active, Preview, and moving-soon counts independently of sampled detail rows. Upcoming filters before pagination and offers Load more; the CLI reads every bounded page without truncating at 200 items.
- Index project metadata in one filesystem pass with bounded SQLite staging. Unchanged roots keep their watchers; ordinary project-marker edits and meaningful source changes update only relevant deadlines, with batched writes and indexed project ancestry.
- Ignore Git directory bookkeeping as an inactivity signal during restart scans. Due Preview/deferred candidates are processed in bounded keyset pages instead of repeatedly decoding an expanding prefix.
- Finish rule and item actions after their authoritative overview refresh, without waiting for Activity, Settings, or notification work. Remove the artificial Refresh delay and keep bounded agent-repair process waits off the main actor.
- Clear stale inspector actions during selection or policy changes. Settings edits read authoritative values, preserve unrelated safety preferences, reject delayed pre-save replies, and offer an explicit retry when settings are unavailable.
- Maintain transactional lifetime Trash totals and indexed local-day summaries instead of decoding all successful-move history on each refresh. SQLite schema 10 migrates existing records; XPC protocol 3 adds filtered Upcoming pages and complete count summaries.

## 0.1.12 - 2026-10-09

- Fixed the "Only items with certain names" and "More options" toggles in the New Rule editor. They were stock macOS disclosure groups that only react to their tiny chevron; the whole header row is now the button.

## 0.1.11 - 2026-10-09

- Stronger recovery when the background agent does not start after an upgrade. After `brew upgrade`, launchd can keep a job that fails to spawn (exit 78) and back off for a long time, so re-registering once was not enough. TinyPrune now restarts the job directly with `launchctl kickstart -k` (which also clears launchd's back-off), then re-registers it, then restarts it again, telling you what it is doing at each step. The menu-bar popover also gained a **Restart background agent** button when the agent cannot be reached.

## 0.1.10 - 2026-10-09

- Fixed the long "Connecting to the local agent" screen after an upgrade. The app now probes the agent for a few seconds, re-registers the background agent right away if it does not answer, and says "Starting the background agent after the update…" instead of waiting out a 30 second timeout.
- Header and icons no longer flicker: background refreshes (every 30 seconds, every 2 seconds while indexing, on page change) are silent, the Activity and Overview icons no longer bounce on each refresh, and **Refresh** shows its own brief "Refreshing" state.
- New Rule is simpler: a **Fill from…** menu and **Browse all templates…** link sit at the top, name filters are tucked into "Only items with certain names (optional)", and the grace period and exceptions moved into **More options**.
- New templates for the clutter AI coding agents leave behind: **AI Agent Session Logs** (transcripts, 60 days), **AI Agent Edit Backups** (30 days) and **AI Agent Debug Logs** (`.log` and `.trace`, 14 days). All start in Preview.

## 0.1.9 - 2026-10-09

- Menu-bar popover: **Open TinyPrune** now reliably brings the main window to the front, including when it is minimized, behind other apps, or closed.
- Menu-bar popover redesigned to be simpler: one card with the count of items due, the next item and its lifetime ring (click it to open Upcoming), then **Open TinyPrune**, **Templates** and **Pause**. With no rules yet it offers **Start from a template** instead.
- Overview: a quiet reclaim ledger with what has moved to Trash (lifetime and last 14 days), what moves soon and what is scheduled, with sizes measured from file metadata only. It says "Moved to Trash", never "freed": space returns when you empty the Trash.
- Upcoming and Overview no longer sit empty until you press Refresh: the app refreshes when you change pages and polls every 2 seconds while the agent is still indexing a folder.

## 0.1.8 - 2026-10-09

- Fixed the app sitting on "Connecting to the local agent" after an upgrade. When the installed build differs from the one that last registered the background agent, TinyPrune now re-registers the agent before its first request, instead of waiting for a request that never answers.

## 0.1.7 - 2026-10-09

- The app now recovers from "Agent unavailable" by itself after a Homebrew upgrade. `brew upgrade` unloads the background agent while macOS still lists it as enabled; TinyPrune re-registers it once at launch and retries. A **Restart background agent** button covers the case where that does not work.

## 0.1.6 - 2026-10-09

- Fixed a first-run dead end: on current macOS the never-registered background agent is reported as "not found", which hid the Install button. The Overview and Settings now offer **Install background agent** in that state.
- Rules list: Preview matches and Edit sit on the left, the Preview/Active control on the right, and Pause, Duplicate and Delete moved into a "more" menu, so a rule is one tidy row and Delete is no longer beside everyday actions.
- Menu-bar popover redesigned: status badge, a count of items that will move to Trash with the next one, a full-width Open TinyPrune button, a Pause menu, and Refresh and Quit as quiet links.

## 0.1.5 - 2026-10-09

- The menu-bar mark is larger: the plum now fills a 22 pt status item instead of sitting small inside padding.
- The "agent not found" message now says to open /Applications/TinyPrune.app instead of referring to a development executable.
- tinyprune.com and the docs explain how to open TinyPrune after installing and what to do on first run.

## 0.1.4 - 2026-10-09

### App
- Design upgrade across the native app: a stone sidebar with an animated selection and live count badges (Command-1 to 6 switch sections), a calmer Overview, Upcoming rows with deadline rings and a Why inspector, an animated Preview/Active control, a plain-language sentence that updates as you edit a rule, staggered Preview results, tactile press and hover states, and a redesigned menu-bar popover and onboarding.
- Motion honors Reduce Motion; Dynamic Type, VoiceOver labels and increased contrast are preserved. No change to rule evaluation, safety checks, Trash behavior or IPC.
- Rule sentences read "an item" instead of "a item".

### Website and docs
- tinyprune.com is rebuilt around real app screenshots and an interactive sample (simulated time, Preview vs Active, Keep) with self-hosted fonts and no third-party CDN. docs.tinyprune.com shares the new design, with copyable commands, deep links, a scrollspy guide and a template filter.

## 0.1.3 - 2026-10-08

- Fix the menu-bar plum's Retina drawing scale and increase its image size to 20 points.
- Wrap update notes in the Sparkle dialog instead of clipping long lines; show install instructions above the release details.

## 0.1.2 - 2026-10-08

### Updates
- Key-enabled direct builds now support EdDSA-authenticated Sparkle updates without an Apple account, including ad-hoc releases. Signed feed XML, release notes and immutable direct DMGs remain required; Homebrew never constructs Sparkle. The existing Trash/update interlock also permits pending resume and matching-target recovery for key-enabled ad-hoc direct builds.
- Automatic checks follow Settings > General > Check for new versions (on by default). Update Now opens Sparkle's native user-confirmation dialog; installation is never automatic. Release build numbers use `github.run_number` for both channels, and the stable feed accepts key-enabled ad-hoc GitHub prereleases.
- New-version notice for builds that cannot update in-app (Homebrew and direct copies without a public key): "Check for Updates…" asks github.com for the public release list, and, on by default (Settings > General > Check for new versions), it does so once a day. A banner and menu-bar item offer Download (direct), Copy Upgrade Command (Homebrew), Release Notes, Skip This Version and Later. Nothing is downloaded or installed automatically by this fallback, only links on this repository are ever offered, and no identifiers are sent.
- First-install Gatekeeper approval for ad-hoc downloads is unchanged. Sparkle replacements are expected not to repeat browser quarantine approval, but end-to-end installation remains unverified. ADR 0009 documents private-key custody/loss/rotation and the acceptance boundary.

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
