# TinyPrune

A local-first macOS app that gives files and folders a lifetime. You pick folders and rules; when an item expires it is moved to the **macOS Trash**, never permanently deleted. It is not a generic Mac cleaner.

- **Trash only.** Items are moved to Trash, never permanently deleted. Items stay in the Trash until you or macOS empty it; use Finder's *Put Back* to restore, if available.
- **Preview first.** Broad and developer rules start in Preview, and very broad folders (home, `/Users`, `/Volumes`, `/private`, whole volumes) are Preview-only, which schedules and explains matches but never touches a file.
- **Keep always wins.** A kept item is never trashed, and neither is a folder containing one. Keep matches by file identity and falls back to its recorded path.
- **Explained decisions.** Every candidate shows its rule, basis, deadline and overrides.
- **Local and private.** Reads filesystem metadata only (never file contents); no account, and the app has no telemetry. Cleanup needs no network. An optional, off-by-default setting checks github.com once a day for a newer release and only offers a download link or a `brew upgrade` command; it never installs anything. (The tinyprune.com website, separately, uses Google Analytics and PostHog.)
- **Three interfaces, one engine.** The app, a Finder menu and the `tinyprune` CLI all talk to the same background agent.

Docs: <https://docs.tinyprune.com> · Site: <https://tinyprune.com>

## Install

Requires macOS 14 or later (Intel and Apple silicon).

```sh
brew install --cask navig-me/tap/tinyprune
```

Early releases are **unsigned, not notarized pre-releases**. The Homebrew cask clears quarantine for you. If you download the DMG directly, copy `TinyPrune.app` to Applications, try opening it once, then allow it under System Settings → Privacy & Security → **Open Anyway**. Homebrew installs update only with `brew upgrade --cask tinyprune`.

On first launch, approve the background agent under System Settings → General → Login Items & Extensions, and enable the Finder extension there if you want the Finder menu.

## Build from source

```sh
git clone https://github.com/navig-me/tinyprune && cd tinyprune
swift Scripts/package-app.swift
open .build/package/TinyPrune.app
```

Tests: see [CLAUDE.md](CLAUDE.md#running-tests). Architecture and release process: [PLAN.md](PLAN.md), [ADRs/](ADRs), [.github/DEPLOYMENT.md](.github/DEPLOYMENT.md).

## License

[MIT](LICENSE). Bundled fonts keep their own OFL licenses (see `Resources/Fonts`).

## Rule and CLI behavior

- Globs without `/` match the item name at any depth (like `.gitignore`); globs with `/` match the path relative to the managed folder. Only `*`, `?` and `**` are supported.
- The Downloads and Temporary Workspace templates act on top-level items only.
- CLI exit codes: `0` ok, `64` usage, `65` invalid data, `69` agent unavailable, `70` agent error, `75` timed out/interrupted/busy (the request may have been applied; check `tinyprune status`), `78` config roots not managed. `--json` errors are JSON too.

See [CHANGELOG.md](CHANGELOG.md) for changes.
