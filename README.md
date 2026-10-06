# TinyPrune

A local-first macOS app that gives files and folders a lifetime. You pick folders and rules; when an item expires it is moved to the **macOS Trash**, never permanently deleted. It is not a generic Mac cleaner.

- **Trash only.** Items are moved to Trash, so Finder's *Put Back* restores them.
- **Preview first.** Broad and developer rules start in Preview, which schedules and explains matches but never touches a file.
- **Keep always wins.** A kept item is never trashed, and neither is a folder containing one.
- **Explained decisions.** Every candidate shows its rule, basis, deadline and overrides.
- **Local and private.** Reads filesystem metadata only (never file contents); no account, no telemetry. Optional update checks apply to signed direct downloads only.
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
