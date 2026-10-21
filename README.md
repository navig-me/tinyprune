# TinyPrune — automatic file cleanup rules for macOS

[![Downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Ftinyprune.com%2Fbadge.json&style=for-the-badge&labelColor=302a2e)](https://github.com/navig-me/tinyprune/releases)
[![Latest release](https://img.shields.io/github/v/release/navig-me/tinyprune?include_prereleases&style=for-the-badge&color=4a1f3d&labelColor=302a2e)](https://github.com/navig-me/tinyprune/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-4a1f3d?style=for-the-badge&logo=apple&logoColor=white&labelColor=302a2e)](https://docs.tinyprune.com/#install)

TinyPrune is a free, MIT-licensed macOS app for automatic file cleanup with expiry rules. Choose folders, preview which downloads, screenshots or developer artifacts will expire, and protect important items with Keep. Eligible items move to **macOS Trash**, never permanent deletion.

**macOS 14+ on Intel and Apple silicon.** For Windows and Linux builds, platform-specific installation details, and release notes, see [GitHub Releases](https://github.com/navig-me/tinyprune/releases) and the [cross-platform core](#cross-platform-core).

<p align="center"><a href="https://tinyprune.com"><picture><source media="(prefers-color-scheme: dark)" srcset="website/assets/screens/preview-dark.png"><img src="website/assets/screens/preview-light.png" alt="TinyPrune Preview showing which files match a rule, when they expire and why" width="900"></picture></a></p>

[Website](https://tinyprune.com/) · [Documentation](https://docs.tinyprune.com/) · [Downloads and release notes](https://github.com/navig-me/tinyprune/releases) · [Report a problem](https://github.com/navig-me/tinyprune/issues)

- **Trash only.** Items are moved to Trash, never permanently deleted. Items stay in the Trash until you or macOS empty it; use Finder's *Put Back* to restore, if available.
- **Preview first.** Broad and developer rules start in Preview, and very broad folders (home, `/Users`, `/Volumes`, `/private`, whole volumes) are Preview-only, which schedules and explains matches but never touches a file.
- **Keep always wins.** A kept item is never trashed, and neither is a folder containing one. Keep matches by file identity and falls back to its recorded path.
- **Explained decisions.** Every candidate shows its rule, basis, deadline and overrides.
- **Local and private.** Core cleanup reads filesystem metadata, never file contents, and needs no account or network. The app has no telemetry. Optional update checks use HTTPS and are on by default; the update path depends on how the app was installed, as described below. Installation always requires your confirmation. The website separately uses Google Analytics and PostHog.
- **Three interfaces, one engine.** The app, a Finder menu and the `tinyprune` CLI all talk to the same background agent.

## What can TinyPrune clean up?

| Use case | Starting rule | Important boundary |
|---|---|---|
| Downloads | Top-level DMGs after 7 days, ZIPs after 14, other items after 30 days in the folder | Review files you want to retain and mark them Keep. |
| Screenshots | Screenshot and Screen Shot filenames, 7 days after creation | Choose the folder where your Mac actually saves screenshots. |
| Developer dependencies | `node_modules` and `.venv` after project inactivity | Start in Preview; dependency changes alone do not prove meaningful project activity. |
| Build output | `dist`, `build`, `target`, `coverage`, and `.cache` after 30 days of project inactivity | Match generated folders, not your source or release archives. |
| AI coding-agent leftovers | Dedicated scratch workspace, session logs, edit backups, or debug logs | TinyPrune does not identify which tool created a file. Transcripts and backups may be irreplaceable. |

See the [template reference](https://docs.tinyprune.com/#templates) for defaults, cache risks, and excluded folders, or the [AI agent cleanup guide](https://docs.tinyprune.com/#agents) for scratch work and worktree cautions.

Moving files to Trash does **not** immediately free disk space. TinyPrune does not empty Trash or guarantee recovery after you or macOS empty it. It is a lifecycle-rule utility, not a duplicate finder, antivirus, or system optimizer.

## Install

Requires macOS 14 or later (Intel and Apple silicon).

```sh
brew install --cask navig-me/tap/tinyprune
```

Early releases are **unsigned, not notarized pre-releases**. The Homebrew cask clears quarantine for you. If you download the DMG directly, copy `TinyPrune.app` to Applications, try opening it once, then allow it under System Settings → Privacy & Security → **Open Anyway**. Homebrew installs update only with `brew upgrade --cask tinyprune`.

Key-enabled direct builds support Sparkle updates authenticated by EdDSA-signed feeds, release notes and DMGs, including ad-hoc builds without an Apple account. **Check for new versions** is on by default in Settings; **Update Now** opens the native confirmation dialog and installation is never automatic. Homebrew never constructs Sparkle; Homebrew and direct copies without a public key use GitHub release notices and manual download or `brew upgrade`. The Trash/update interlock remains active, including interrupted-update recovery for matching key-enabled ad-hoc direct targets.

EdDSA does not notarize the app or change first-install Gatekeeper approval. Sparkle replacements are expected not to carry browser-download quarantine, but an actual older/newer end-to-end installation remains unverified. See [ADR 0009](ADRs/0009-eddsa-only-updates-for-adhoc-builds.md) for update trust, private-key loss/rotation and acceptance requirements.

On first launch, approve the background agent under System Settings → General → Login Items & Extensions, and enable the Finder extension there if you want the Finder menu.

### Preview your first cleanup rule

1. Open TinyPrune and authorize a folder you control, such as Downloads.
2. Add a template and leave it in **Preview**.
3. Review **Upcoming** and each item's explanation. Mark anything you want to retain **Keep**.
4. Enable the rule only after the matches and deadlines are right. Pause cleanup whenever needed.

The [installation guide](https://docs.tinyprune.com/#install), [rule guide](https://docs.tinyprune.com/#rules), and [Preview guide](https://docs.tinyprune.com/#preview) explain the workflow. The Finder extension and CLI use the same background agent as the app.

### Inspect and protect from the command line

With the macOS background agent installed and folder access granted:

```sh
tinyprune status
tinyprune upcoming --json
tinyprune why ~/Downloads/example.zip
tinyprune keep ~/Downloads/example.zip
tinyprune pause
tinyprune resume
```

Paths above are examples; use an item inside a folder you already manage. See the [CLI reference](https://docs.tinyprune.com/#cli) for expiry overrides, configuration, JSON output, and exit codes.

## Build from source

```sh
git clone https://github.com/navig-me/tinyprune && cd tinyprune
swift Scripts/package-app.swift
open .build/package/TinyPrune.app
```

Tests: see [AGENTS.md](AGENTS.md#running-tests). Architecture and release process: [PLAN.md](PLAN.md), [ADRs/](ADRs), [.github/DEPLOYMENT.md](.github/DEPLOYMENT.md). Every release (version, artifacts, signing mode, checksums, build number and verification status, including prepared, withdrawn and yanked ones) is recorded in [RELEASES.md](RELEASES.md); the maintainer runbook is [.github/RELEASING.md](.github/RELEASING.md).

## Cross-platform core

The macOS app described above uses Swift. The Rust workspace provides the cross-platform core and runtime for Linux and Windows. See [GitHub Releases](https://github.com/navig-me/tinyprune/releases) for platform-specific downloads and installation requirements. Swift remains the behavioral reference; shared golden fixtures pin parity ([ADR 0010](ADRs/0010-cross-platform-core-and-golden-fixtures.md)). The Rust runtime decisions are in [ADR 0011](ADRs/0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md).

The Rust workspace in [`rust/`](rust/README.md) has crates `core`, `unix`, `windows`, `watch` (Linux inotify, Windows `ReadDirectoryChangesW`), `agent`, `store` (SQLite), `scan`, `ipc` (length-prefixed JSON over a Unix socket or named pipe; not Swift-XPC compatible), `daemon` (`tinyprune-agentd`) and `cli` (`tinyprune`), plus a Tauri UI in a separate workspace (`rust/ui`).

| Component | Linux | Windows | macOS (Rust) |
|---|---|---|---|
| Core, 577 golden cases | tests run in CI | tests run in CI | tests run in CI and locally |
| Filesystem/Trash adapters | `unix` tests run in CI | `windows` tests run in CI | `unix` tests run |
| Native watchers | inotify: compile-checked only, never executed | `ReadDirectoryChangesW`: compile-checked only, never executed | none; the daemon uses a periodic reconcile fallback |
| Agent engine | tests run in CI | tests run in CI | tests run |
| Store, scan, IPC, daemon, CLI | never executed | never executed (named pipes cross-checked only) | tests run on the development Mac |
| UI | never run | never run | frontend tests only (9 Node tests); no webview run |
| Installers/packaging | archive scripts not executed on Linux/systemd in the recorded verification | archive scripts not executed or parse-checked in the recorded verification | not applicable |

“Tests run in CI” means they passed on the pull request's last pushed commit; store, scan, IPC, daemon, CLI, UI and the Windows watcher were added after it and have no CI result yet. The working tree's `ci.yml` additionally configures, but has not yet run on GitHub, a release build plus an end-to-end smoke of the real `tinyprune-agentd` and `tinyprune` binaries (`rust/tests-e2e`), a non-gating 100k-entry benchmark, and a Linux job running the UI's frontend tests and a Tauri compile check. Restart-stable item identity (volume UUID/serial, inode or file ID, creation time) is implemented and tested on the development Mac only. Measured on the development Mac only: `tinyprune-scan` traversed 50,101 entries at 35,761 entries/s; nothing was measured on Linux or Windows. Not verified: real inotify events, the Windows watcher, named pipes, Linux/Windows UI, installers, performance on those systems, and accessibility (no audit, no screen reader run). The full matrix and caveats are in [rust/README.md](rust/README.md#status-matrix).

Known limits: config import/export in the Rust daemon is POSIX-only (Windows returns an error); POSIX rename and Windows Shell cannot atomically condition a move on file identity; items on volumes without a durable id (for example tmpfs, overlayfs, FUSE, network filesystems without a UUID), on filesystems without creation time, or on cloned volumes are not restart-stable and are re-observed after a restart. The Rust agent does not replace the macOS agent.

## License

[MIT](LICENSE). Bundled fonts and Sparkle keep their own licenses; see [NOTICE.md](NOTICE.md).

## Rule and CLI behavior

- Globs without `/` match the item name at any depth (like `.gitignore`); globs with `/` match the path relative to the managed folder. Only `*`, `?` and `**` are supported.
- The Downloads and Temporary Workspace templates act on top-level items only.
- CLI exit codes: `0` ok, `64` usage, `65` invalid data, `69` agent unavailable, `70` agent error, `75` timed out/interrupted/busy (the request may have been applied; check `tinyprune status`), `78` config roots not managed. `--json` errors are JSON too.

See [CHANGELOG.md](CHANGELOG.md) for changes.
