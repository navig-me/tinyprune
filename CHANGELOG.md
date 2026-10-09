# Changelog

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
