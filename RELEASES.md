# Release log

This file is the authoritative record of every TinyPrune release. [CHANGELOG.md](CHANGELOG.md) says what changed; this file says what was built, how it was signed, what its checksums are, which update-feed build number it carries and what was verified. The step-by-step procedure is [.github/RELEASING.md](.github/RELEASING.md) and the decision record is [ADR 0013](ADRs/0013-release-process-and-signing-custody.md).

## The rule

**Every release MUST be recorded in this file in the same pull request that bumps the version.** That includes prereleases, dry-run tags, releases that are later withdrawn or yanked, and releases that were prepared but never published. A release is never deleted from this file: a withdrawal or yank is a new status line on its entry. `Scripts/check-versions.py` (CI job `versions`) fails if the version declared in `Scripts/package-app.swift` has no `## X.Y.Z` entry here, or if a CHANGELOG release has none.

Facts below were taken from `git tag`, `git log -1 --format=%cs <tag>`, `gh release view <tag>` (assets, prerelease flag, `publishedAt`), each release's `TinyPrune-X.Y.Z.json` metadata and `.sha256` sidecars, `website/updates/appcast.xml` and `gh run list --workflow release.yml`, read on 2026-10-21. Where a value could not be recovered it says so instead of guessing.

## Index

| Version | Status | Date | Channel |
| --- | --- | --- | --- |
| [0.2.0](#020) | **prepared, not published** | 2026-10-21 (prepared) | macOS (unchanged code) and Rust developer preview (Linux x86_64, Windows x86_64) |
| 0.1.13 | published prerelease | 2026-10-13 | macOS ad-hoc |
| 0.1.12 | published prerelease, not in the update feed | 2026-10-09 | macOS ad-hoc |
| 0.1.11 .. 0.1.2 | published prereleases | 2026-10-08 .. 2026-10-09 | macOS ad-hoc |
| 0.1.1, 0.1.0 | published prereleases, predate in-app updates | 2026-10-08, 2026-10-06 | macOS ad-hoc |
| 0.0.1 | tag only, never released | 2026-10-02 | none |

Every published release so far is a **GitHub prerelease** with ad-hoc signed, **not notarized** DMGs: the `release` Environment holds no Apple credentials, so `signing=auto` selects the ad-hoc mode ([.github/DEPLOYMENT.md](.github/DEPLOYMENT.md), ADR 0004/0005/0009). No Developer ID release has ever been produced. First-install Gatekeeper approval is therefore required, as the release notes explain.

## 0.2.0

**Status: prepared, not published.** No version tag, GitHub release or signed feed has been published for 0.2.0. Preparation [PR #17](https://github.com/navig-me/tinyprune/pull/17) is merged as `18407d26e2188265d9b97037f16c5c8b478b9d76`; its website and documentation changes deploy independently of release publication. The latest published macOS release remains **0.1.13**; no Linux or Windows release downloads are available.

**Why a minor bump.** It adds the cross-platform Rust runtime as a **developer preview**. The macOS application code is unchanged since 0.1.13 apart from the version number; macOS is the only supported product. Linux and Windows archives are unsigned developer-preview builds and carry **no supported-platform claim** (AGENTS.md, ADR 0012).

**Versions.** Marketing version 0.2.0 everywhere: `Scripts/package-app.swift`, the Swift agent's `serviceVersion` default and its two tests, all eleven workspace crates, `rust/ui` (`Cargo.toml`, `tauri.conf.json`) and both `Cargo.lock` files. `tinyprune --version` prints `tinyprune 0.2.0` and `tinyprune-agentd --version` prints `tinyprune-agentd 0.2.0` (both read `CARGO_PKG_VERSION`).

**Signing configuration.** The existing ADR 0009 key is reused, not rotated. On 2026-10-21, the nonsecret repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` was set and verified equal to both Environments' public keys. `release` and `update-feed` now require `mihirkhandekar` approval and are restricted to branch `main` and tags `v*`. Self-approval is permitted for the sole maintainer; no two-person-review claim is made. No private key was retrieved or exported.

**Build numbers (monotonic, per channel, never shared).**

- macOS/Sparkle: `CFBundleVersion` is `github.run_number` of the `release.yml` run for the tag. The last published build is **22** (0.1.13); the number for 0.2.0 is fixed only when the tag run starts and will be greater than 22. `Scripts/package-app.swift` defaults `TINYPRUNE_BUILD` to `1` for local builds only. The feed generator refuses a build not greater than retained entries (ADR 0009).
- Rust preview: `TINYPRUNE_BUILD` is the `github.run_number` of the `rust-artifacts.yml` run (a counter separate from `release.yml`), stamped into the binaries and each archive's `VERSION`. `rust-update-feed.yml` reads the same number from the artifacts run (`gh run view --json number`) and `tinyprune-feed generate` refuses a build not above the retained feed entries; clients refuse downgrades and replayed feeds (ADR 0012). Pull-request runs also consume numbers, so the published number is whatever the chosen dispatch run on `main` has; the last pull-request run seen is #25.

**Intended artifacts.**

| Channel | Artifact | Signing | Source workflow |
| --- | --- | --- | --- |
| macOS | `TinyPrune-0.2.0.dmg`, `TinyPrune-0.2.0-homebrew.dmg`, their `.sha256` sidecars, `TinyPrune-0.2.0.json` | ad-hoc, not notarized (the `release` Environment has no Apple secrets), GitHub prerelease; Sparkle EdDSA-signed appcast entry for the direct DMG | `release.yml` on tag `v0.2.0`, then `publish-update-feed.yml` |
| Linux (Rust preview) | `tinyprune-dev-0.2.0-g<sha12>-linux-x86_64.tar.gz`, `.sha256`, `SHA256SUMS` | **unsigned archive**; the feed is EdDSA-signed with the ADR 0009 key | `rust-artifacts.yml` (dispatch on `main`), `rust-update-feed.yml` |
| Windows (Rust preview) | `tinyprune-dev-0.2.0-g<sha12>-windows-x86_64.zip`, `.sha256`, `SHA256SUMS` | **unsigned archive** (SmartScreen may warn); signed feed as above | same |

The Rust archives will be hosted on a separate GitHub **prerelease** (not the macOS release), created before `rust-update-feed.yml` attaches the archives. Names and VERSION stamps retain `tinyprune-dev` and `status=unreleased-development-artifact`; the release notes must identify them as developer previews.

**Built candidate (not published).** [Rust artifacts run 39589828202](https://github.com/navig-me/tinyprune/actions/runs/39589828202), dispatch build **29**, succeeded on `main` commit `18407d26e2188265d9b97037f16c5c8b478b9d76`. Both platform archives include the 0.2.0 UI, daemon and CLI. Linux Docker installation, Windows Scheduled Task installation and the Windows throwaway-key managed-update job passed. Downloaded archive hashes were verified against the workflow manifests; the Windows manifest uses CRLF, so cross-platform verification must normalize line endings. The packaged Linux CLI self-check ran offline in an x86_64 Ubuntu container and reported version 0.2.0, build 29 and a public key matching both release Environments.

| Candidate artifact | Verified SHA-256 |
| --- | --- |
| `tinyprune-dev-0.2.0-g18407d26e218-linux-x86_64.tar.gz` | `1b972b38025d2dfc5155912e62bc50de263d60c2c7d601501a57ad2b4f223432` |
| `tinyprune-dev-0.2.0-g18407d26e218-windows-x86_64.zip` | `2ae730ce1ee58275c18cc2e3c1830d7cd02cda4ae90ebefd6882a0b341ae72eb` |

These are expiring workflow artifacts, not immutable published release assets. No macOS 0.2.0 DMG, public Rust feed or version tag has been created.

**Verification status** (what CI actually proved; nothing else is claimed).

| Item | Result | Evidence |
| --- | --- | --- |
| Swift behavior, golden fixtures (577 cases), native acceptance on macOS 14/15/15-intel, packaging of both channels, Homebrew smoke | passed for the Swift/Rust tree as merged in PR #15 | [CI run 39541522007](https://github.com/navig-me/tinyprune/actions/runs/39541522007) (head `878a1e6`) |
| Rust dev artifacts build matrix (Linux, Windows, macOS), Linux Docker install test, Windows Scheduled Task install/run/uninstall | passed on PR #15 and PR #16 heads | [run 39541522001](https://github.com/navig-me/tinyprune/actions/runs/39541522001) (#15), [run 39555906929](https://github.com/navig-me/tinyprune/actions/runs/39555906929) (#16, head `007bb92`) |
| `rust-core` (tests, clippy, release build, end-to-end smoke) on Ubuntu, Windows, macOS; Rust UI frontend tests + Tauri check; `rust-ui-windows` (non-gating) | passed on PR #16 head | [CI run 39555907074](https://github.com/navig-me/tinyprune/actions/runs/39555907074) |
| Windows managed-update end-to-end (`windows-update-e2e`, real Scheduled Task, launcher, agent, throwaway key) | passed once on `windows-2022` | [dispatch run 39550764775](https://github.com/navig-me/tinyprune/actions/runs/39550764775) (commit `c25ee1f`); also a job in run 39555906929 |
| `main` after merging PR #16 (`7d30795`) | CI run was still in progress when this entry was written | [run 39559192807](https://github.com/navig-me/tinyprune/actions/runs/39559192807); re-check before tagging |
| Preparation PR #17 (`2a49601`) | all 17 checks passed, including Windows UI and managed-update end-to-end | [CI run 39580285014](https://github.com/navig-me/tinyprune/actions/runs/39580285014), [artifact/install/update run 39580285020](https://github.com/navig-me/tinyprune/actions/runs/39580285020) |
| Benchmark numbers | **not recorded here**; the 100k-entry and store benchmarks are non-gating and write to each CI run's job summary | record the figures from the chosen `main` run before publishing |

**Evidence and remaining limits.** Native Linux inotify and Windows `ReadDirectoryChangesW`, filesystem/Trash adapters, stores, sockets/pipes, daemon/CLI and developer installs have recorded CI or container coverage. The Tauri UI ran against the real agent in Linux aarch64 Docker and on a Windows CI runner; Windows managed updates ran end to end with a throwaway key (runs above). The [Rust workspace status matrix](https://github.com/navig-me/tinyprune/blob/main/rust/README.md#status-matrix) records the detailed environments, measurements and remaining limits. These checks do not establish general desktop or screen-reader accessibility, Windows 100k-file performance acceptance, logon/reboot-trigger behavior, non-administrator behavior or coverage of other Windows editions. **No production Rust feed exists**: `rust-update-feed.yml` has never been run, and the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` that `rust-artifacts.yml` reads to embed the production public key is **unset** (checked 2026-10-21), so a dispatch build today would have updates disabled and `rust-update-feed.yml` would reject it. The existing ADR 0009 key is intended to be reused, not rotated. Sparkle `sign_update` interoperability with that key for the Rust feed has not been run. macOS in-app installation of a Sparkle update remains end-to-end unverified (ADR 0009).

## Per-release template

Copy this block to the top of the version sections, fill every field in the version-bump PR, and keep it up to date as the release moves from prepared to published (or withdrawn). Leave no field blank; write `unknown` or `n/a` with a reason.

```markdown
## X.Y.Z

**Status:** prepared, not published | published | published prerelease | withdrawn (date, reason, replacement) | yanked (date, reason, replacement) | never released
**Date:** YYYY-MM-DD (tag date) / published YYYY-MM-DD
**Tag and commit:** vX.Y.Z at <sha>
**Why this version number:** ...
**Artifacts and signing:** file names; ad-hoc | Developer ID + notarized | unsigned archive; GitHub prerelease or release; link
**SHA-256:** per artifact (from the `.sha256` sidecars / `SHA256SUMS`)
**Build numbers:** Sparkle `CFBundleVersion`; Rust `TINYPRUNE_BUILD`; present in which feed (appcast / Rust feed)
**Highlights:** one paragraph plus a link to the CHANGELOG section
**Verification:** each claim with a workflow run link or "not verified"
**Workflow runs:** release.yml, publish-update-feed.yml, rust-artifacts.yml, rust-update-feed.yml run IDs and approvals
**Known issues / not verified:** ...
**Rollback or withdrawal:** n/a, or what was done and the higher version that supersedes it
```

## Published releases

Newest first. "Build" is the Sparkle `CFBundleVersion` (`github.run_number` of the `release.yml` run). Checksums are the contents of the published `.sha256` sidecars.

| Version | Date | Kind | Artifacts and signing | Build (Sparkle `CFBundleVersion`) | In appcast | CHANGELOG | Highlights |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0.1.13 | 2026-10-13 (published 2026-10-13) | GitHub prerelease | `TinyPrune-0.1.13.dmg` (direct), `TinyPrune-0.1.13-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.13.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 22 | yes, build 22 | [0.1.13](CHANGELOG.md#0113---2026-10-13) | First-observed deadlines survive parent renames and restarts, complete Active/Preview counts, bounded project indexing, SQLite schema 10 and XPC protocol 3. |
| 0.1.12 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.12.dmg` (direct), `TinyPrune-0.1.12-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.12.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 21 | **no** | [0.1.12](CHANGELOG.md#0112---2026-10-09) | Whole-row New Rule disclosure toggles. Not in the update feed: its feed PR #12 was closed unmerged, so Sparkle users move from 0.1.11 straight to 0.1.13. The GitHub prerelease itself was not withdrawn. |
| 0.1.11 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.11.dmg` (direct), `TinyPrune-0.1.11-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.11.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 20 | yes, build 20 | [0.1.11](CHANGELOG.md#0111---2026-10-09) | Stronger agent recovery after an upgrade (`launchctl kickstart -k`, re-register, restart) and a menu-bar Restart button. |
| 0.1.10 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.10.dmg` (direct), `TinyPrune-0.1.10-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.10.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 19 | yes, build 19 | [0.1.10](CHANGELOG.md#0110---2026-10-09) | Faster agent re-registration after an upgrade, no header/icon flicker, simpler New Rule, AI agent clutter templates. |
| 0.1.9 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.9.dmg` (direct), `TinyPrune-0.1.9-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.9.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 18 | yes, build 18 | [0.1.9](CHANGELOG.md#019---2026-10-09) | Menu-bar popover redesign, reclaim ledger on Overview, silent refreshes while indexing. |
| 0.1.8 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.8.dmg` (direct), `TinyPrune-0.1.8-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.8.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 17 | yes, build 17 | [0.1.8](CHANGELOG.md#018---2026-10-09) | Re-registers the background agent when the installed build differs from the last registered one. |
| 0.1.7 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.7.dmg` (direct), `TinyPrune-0.1.7-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.7.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 16 | yes, build 16 | [0.1.7](CHANGELOG.md#017---2026-10-09) | Automatic recovery from "Agent unavailable" after a Homebrew upgrade, plus a Restart background agent button. |
| 0.1.6 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.6.dmg` (direct), `TinyPrune-0.1.6-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.6.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 15 | yes, build 15 | [0.1.6](CHANGELOG.md#016---2026-10-09) | Install-background-agent button in the first-run state, rules-list layout, redesigned menu-bar popover. |
| 0.1.5 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.5.dmg` (direct), `TinyPrune-0.1.5-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.5.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 13 | yes, build 13 | [0.1.5](CHANGELOG.md#015---2026-10-09) | Larger menu-bar mark, clearer "agent not found" message, first-run documentation. |
| 0.1.4 | 2026-10-09 (published 2026-10-09) | GitHub prerelease | `TinyPrune-0.1.4.dmg` (direct), `TinyPrune-0.1.4-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.4.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 12 | yes, build 12 | [0.1.4](CHANGELOG.md#014---2026-10-09) | Native app design upgrade (sidebar, Upcoming rows with deadline rings, Why inspector, Preview/Active control); rebuilt tinyprune.com and docs. |
| 0.1.3 | 2026-10-08 (published 2026-10-08) | GitHub prerelease | `TinyPrune-0.1.3.dmg` (direct), `TinyPrune-0.1.3-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.3.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 11 | yes, build 11 | [0.1.3](CHANGELOG.md#013---2026-10-08) | Menu-bar icon drawing fix; Sparkle dialog note wrapping and install instructions above the release details. |
| 0.1.2 | 2026-10-08 (published 2026-10-08) | GitHub prerelease | `TinyPrune-0.1.2.dmg` (direct), `TinyPrune-0.1.2-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.2.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 10 | yes, build 10 | [0.1.2](CHANGELOG.md#012---2026-10-08) | Sparkle EdDSA-authenticated updates for key-enabled direct builds, including ad-hoc ones (ADR 0009); `github.run_number` as build number; new-version notice for Homebrew/no-key copies. |
| 0.1.1 | 2026-10-08 (published 2026-10-08) | GitHub prerelease | `TinyPrune-0.1.1.dmg` (direct), `TinyPrune-0.1.1-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.1.json`; ad-hoc signed, not notarized (`signing: unsigned`) | not recorded in release metadata; `release.yml` run #9 [INFERENCE] | no (predates in-app updates) | [0.1.1](CHANGELOG.md#011---2026-10-08) | Safety hardening before Trash (re-resolve and re-read policy immediately before the move), `deferred` outcome, case-insensitive dangerous-root guard, XPC protocol 2 (policy revision compare-and-swap), CLI exit codes, documentation claims corrected. |
| 0.1.0 | 2026-10-06 (published 2026-10-06) | GitHub prerelease | `TinyPrune-0.1.0.dmg` (direct), `TinyPrune-0.1.0-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.1.0.json`; ad-hoc signed, not notarized (`signing: unsigned`) | not recorded in release metadata; `release.yml` run #8 [INFERENCE] | no (predates in-app updates) | none | First public ad-hoc macOS preview. No CHANGELOG entry was written for it. |
| 0.0.1 | 2026-10-02 | tag only | none | n/a | no | none | Dry-run marker tag (`Dry-run marker 2 [skip ci]`) used to exercise the release pipeline. No GitHub Release, no artifacts, no CHANGELOG entry. Not a product release. |

### Checksums (SHA-256)

| Version | `TinyPrune-X.dmg` (direct) SHA-256 | `TinyPrune-X-homebrew.dmg` SHA-256 |
| --- | --- | --- |
| 0.1.13 | `c14204c8a7abf61262ec18852c846bf58d4cbbaf33f3790467e0a50b2966fee0` | `4af74ce20d6758332c17f5347ff2836e96b9816f25a263c0dfb7eb14d9edf8a4` |
| 0.1.12 | `ffdb837f60af405feec03e08de86e0a896c586f039bc9683d5c9594526d9a99b` | `dee6e71b70845fbb5b792be5dace6ca5cddb69c9a15ae9fd1676b2c427196dd6` |
| 0.1.11 | `b2715ee3a723931210d78109b8faa74033ec727c6db06348c6e6d5d2381377b3` | `ec373274b93aa06ca450c61223614d56ea4bb28a1f9734ec488e0df30627e9e2` |
| 0.1.10 | `108ba25568da0192170e8c4987559c13e5702d3a16e71b7d92742981331219d3` | `7bf84ae11d70d72fcbe219183d640678c824a6aeb23d42292916d9e7db6046bc` |
| 0.1.9 | `b46a5ae3da9297348b8ec18288ea55fd0e7fcc1f9e9f9de71052d0162b135097` | `20ba0cbce0b0e4c53ffcf87f76bd6a42fb69dd6397bf52343ae1ca2092a75363` |
| 0.1.8 | `69669a566967e26112caf4ff0f4b1406aa55707215a00a37c3c8ab8a6c75f714` | `8cbf022e10552a1a0ef42260c8526e70f46f13abad43a649c1a7b7322b387a24` |
| 0.1.7 | `bab09366fb7db8fdcef649e8b58b722f8ca396bac417f7177d0949b369c45290` | `c3259f61957fa4e08ee52c04270563d670a0f0ba37dcc1aa87738bf4977ce5b9` |
| 0.1.6 | `c6ec717031715801c182037d290fbe62a761cc360bac52833d8864cb3d05abe5` | `8a436730d8e12d3c8e20f0414eab57c371036163c46733530f923398f50550f1` |
| 0.1.5 | `bbece8aa5033811e76b8bc0a378ff89c6a71fab5789e9de93eb097fa706ab99c` | `dc6cdb18b8344fa4e190ef9ce4666e208bb2bb9f8d5a47e80ac4e5f2ccf7f030` |
| 0.1.4 | `2c5180e390bb79ca06f015ad861a821a818f07379dbbf1e79d3fe8b1171de5d7` | `fc738f6a27b6f4c21dc355e47d2360c2b7fcb16363488a790f6db124da9bfbb4` |
| 0.1.3 | `0351f85e4396fb9973108b9e26b0c087a69d1f159906bffd38ff31cee7987e09` | `1935c7c81ff562d95152a45fdf1e035a3cbd16b892a73d6b2c0f95f04a16e7e5` |
| 0.1.2 | `8a0a4d994ced43e37dc12eac3b27e66572ebdcc93e24b229ad9cf0089c8905fa` | `111edbf4b11505e596a7d62bc2ad5fa3c6d05c9b8e95d043d797792448a89edf` |
| 0.1.1 | `d727bd60331e27078bc506ff04b411fef1d4d8d581199e4b12881a1c1d028662` | `ead5c3a32516d3fcb8a70fd85e1f1f390bcb0f95b14a2282f997460ec6920c5b` |
| 0.1.0 | `ec244c81ec8279fce4dc691a449a68a6c68c495a147a680f89a91ad005dc7976` | `00bc4206e4c2e039d49548deedb718d62674e423eaa576f0a34a2d37f1fa29a4` |

Verify a download with `shasum -a 256 -c TinyPrune-X.Y.Z.dmg.sha256` against the sidecar attached to the same release.

### Notes on the history

- **Build numbers are not contiguous.** `github.run_number` increments on every run of `release.yml`. Run #14 (a cancelled run for `v0.1.6`) consumed build 14, so 0.1.5 is build 13 and 0.1.6 is build 15. Only strict increase matters.
- **Feed publication for 0.1.2 to 0.1.4.** The `release.yml` runs for `v0.1.2`, `v0.1.3` and `v0.1.4` (runs 37741805899, 37743626408, 37877412643) show the `update-feed / publish` job as failed while the packaging/release job and the Homebrew cask job succeeded. Their entries are present in `website/updates/appcast.xml` today; how each was published afterwards was not investigated here. The assets and prerelease flags in the table are as published.
- **Release notes for ad-hoc prereleases** state that Gatekeeper cannot verify the developer and give the Open Anyway procedure; in-app update wording changed with 0.1.2 (key-enabled direct builds update through Sparkle; Homebrew and no-key copies use the notifier).
- **v0.0.1** is a dry-run marker (`Dry-run marker 2 [skip ci]`); `gh release view v0.0.1` reports no release.
