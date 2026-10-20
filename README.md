# TinyPrune

[![Downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Ftinyprune.com%2Fbadge.json&style=for-the-badge&labelColor=302a2e)](https://github.com/navig-me/tinyprune/releases)
[![Latest release](https://img.shields.io/github/v/release/navig-me/tinyprune?include_prereleases&style=for-the-badge&color=4a1f3d&labelColor=302a2e)](https://github.com/navig-me/tinyprune/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-4a1f3d?style=for-the-badge&logo=apple&logoColor=white&labelColor=302a2e)](https://docs.tinyprune.com/#install)

<p align="center"><a href="https://tinyprune.com"><picture><source media="(prefers-color-scheme: dark)" srcset="website/assets/screens/preview-dark.png"><img src="website/assets/screens/preview-light.png" alt="TinyPrune Preview showing which files match a rule, when they expire and why" width="900"></picture></a></p>

A local-first macOS app that gives files and folders a lifetime. You pick folders and rules; when an item expires it is moved to the **macOS Trash**, never permanently deleted. It is not a generic Mac cleaner.

- **Trash only.** Items are moved to Trash, never permanently deleted. Items stay in the Trash until you or macOS empty it; use Finder's *Put Back* to restore, if available.
- **Preview first.** Broad and developer rules start in Preview, and very broad folders (home, `/Users`, `/Volumes`, `/private`, whole volumes) are Preview-only, which schedules and explains matches but never touches a file.
- **Keep always wins.** A kept item is never trashed, and neither is a folder containing one. Keep matches by file identity and falls back to its recorded path.
- **Explained decisions.** Every candidate shows its rule, basis, deadline and overrides.
- **Local and private.** Reads filesystem metadata only (never file contents); no account, and the app has no telemetry. Cleanup needs no network. Once a day it checks github.com for a newer release (you can turn this off in Settings) and only offers a download link or a `brew upgrade` command; it never installs anything on its own. (The tinyprune.com website, separately, uses Google Analytics and PostHog.)
- **Three interfaces, one engine.** The app, a Finder menu and the `tinyprune` CLI all talk to the same background agent.

Docs: <https://docs.tinyprune.com> · Site: <https://tinyprune.com>

## Install

Requires macOS 14 or later (Intel and Apple silicon).

```sh
brew install --cask navig-me/tap/tinyprune
```

Early releases are **unsigned, not notarized pre-releases**. The Homebrew cask clears quarantine for you. If you download the DMG directly, copy `TinyPrune.app` to Applications, try opening it once, then allow it under System Settings → Privacy & Security → **Open Anyway**. Homebrew installs update only with `brew upgrade --cask tinyprune`.

Key-enabled direct builds support Sparkle updates authenticated by EdDSA-signed feeds, release notes and DMGs, including ad-hoc builds without an Apple account. **Check for new versions** is on by default in Settings; **Update Now** opens the native confirmation dialog and installation is never automatic. Homebrew never constructs Sparkle; Homebrew and direct copies without a public key use GitHub release notices and manual download or `brew upgrade`. The Trash/update interlock remains active, including interrupted-update recovery for matching key-enabled ad-hoc direct targets.

EdDSA does not notarize the app or change first-install Gatekeeper approval. Sparkle replacements are expected not to carry browser-download quarantine, but an actual older/newer end-to-end installation remains unverified. See [ADR 0009](ADRs/0009-eddsa-only-updates-for-adhoc-builds.md) for update trust, private-key loss/rotation and acceptance requirements.

On first launch, approve the background agent under System Settings → General → Login Items & Extensions, and enable the Finder extension there if you want the Finder menu.

## Build from source

```sh
git clone https://github.com/navig-me/tinyprune && cd tinyprune
swift Scripts/package-app.swift
open .build/package/TinyPrune.app
```

Tests: see [AGENTS.md](AGENTS.md#running-tests). Architecture and release process: [PLAN.md](PLAN.md), [ADRs/](ADRs), [.github/DEPLOYMENT.md](.github/DEPLOYMENT.md).

## Cross-platform core (in development)

TinyPrune remains a macOS-only product. The Rust effort is internal and unreleased: **no Linux or Windows build is released**. Swift remains the behavioral reference; shared golden fixtures pin parity ([ADR 0010](ADRs/0010-cross-platform-core-and-golden-fixtures.md)).

| Status | Work |
|---|---|
| Implemented | Rust domain decisions, config codec, synchronous trait-based Trash coordinator, and scheduler scan decisions with injected `Clock`, `MetadataSource`, and `ObservationStore`; 577 golden cases across 13 JSONL files, including templates, broadness, roots, plans, and schedule |
| Implemented, limited verification | `tinyprune-unix` FileAccess and freedesktop Trash (tested on macOS); `tinyprune-watch` inotify EventSource (cross-compile-checked only, never executed); `tinyprune-windows` Recycle Bin/IFileOperation adapter (compile-checked only, never executed) |
| Implemented, with limits | `tinyprune-agent` synchronous deterministic engine: bounded indexing, event handling, execution, cancellation/resume, deadline queue, per-item backoff, and restart recovery; 12 tests including a real Unix temporary-tree Trash move |
| Not started | Durable Rust stores, production metadata enumerator, daemon/IPC, UIs and packaging; native Windows/Linux execution |

The Rust engine is not a standalone daemon. Embedding must supply durable stores, a production metadata enumerator, daemon/IPC hosting, and pausing during update installation. Index enumeration and per-tick event/execution work are bounded; full snapshot decision evaluation and retained metadata grow with root size. The core adds a `platform_hidden` candidate flag and explicit Windows `PathFlavor`, covered by Rust-only tests with no Swift counterpart. Default `Posix` behavior leaves the 577 shared golden cases unchanged; the config codec remains POSIX. POSIX rename and Windows Shell cannot atomically condition a move on identity; the crate READMEs document these race boundaries. The existing `rust-core` CI matrix runs workspace tests and Clippy on Ubuntu/Windows/macOS, including target-applicable crate tests; configured CI is not evidence of native execution. See [rust/README.md](rust/README.md) for boundaries and contributor commands.

## License

[MIT](LICENSE). Bundled fonts and Sparkle keep their own licenses; see [NOTICE.md](NOTICE.md).

## Rule and CLI behavior

- Globs without `/` match the item name at any depth (like `.gitignore`); globs with `/` match the path relative to the managed folder. Only `*`, `?` and `**` are supported.
- The Downloads and Temporary Workspace templates act on top-level items only.
- CLI exit codes: `0` ok, `64` usage, `65` invalid data, `69` agent unavailable, `70` agent error, `75` timed out/interrupted/busy (the request may have been applied; check `tinyprune status`), `78` config roots not managed. `--json` errors are JSON too.

See [CHANGELOG.md](CHANGELOG.md) for changes.
