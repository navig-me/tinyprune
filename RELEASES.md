# Release log

This file is the authoritative record of every TinyPrune release. [CHANGELOG.md](CHANGELOG.md) says what changed; this file says what was built, how it was signed, what its checksums are, which update-feed build number it carries and what was verified. The step-by-step procedure is [.github/RELEASING.md](.github/RELEASING.md) and the decision record is [ADR 0013](ADRs/0013-release-process-and-signing-custody.md).

## The rule

**Every release MUST be recorded in this file in the same pull request that bumps the version.** That includes prereleases, dry-run tags, releases that are later withdrawn or yanked, and releases that were prepared but never published. A release is never deleted from this file: a withdrawal or yank is a new status line on its entry. `Scripts/check-versions.py` (CI job `versions`) fails if the version declared in `Scripts/package-app.swift` has no `## X.Y.Z` entry here, or if a CHANGELOG release has none.

Facts below were taken from `git tag`, `git log -1 --format=%cs <tag>`, `gh release view <tag>` (assets, prerelease flag, `publishedAt`), each release's `TinyPrune-X.Y.Z.json` metadata and `.sha256` sidecars, `website/updates/appcast.xml` and GitHub Actions runs, read through 2026-10-22. Where a value could not be recovered it says so instead of guessing.

## Index

| Version | Status | Date | Channel |
| --- | --- | --- | --- |
| [0.2.0](#020) | **published prereleases; Rust feed live, macOS feed approval pending** | 2026-10-22 | macOS (unchanged code) and Rust developer preview (Linux x86_64, Windows x86_64) |
| 0.1.13 | published prerelease | 2026-10-13 | macOS ad-hoc |
| 0.1.12 | published prerelease, not in the update feed | 2026-10-09 | macOS ad-hoc |
| 0.1.11 .. 0.1.2 | published prereleases | 2026-10-08 .. 2026-10-09 | macOS ad-hoc |
| 0.1.1, 0.1.0 | published prereleases, predate in-app updates | 2026-10-08, 2026-10-06 | macOS ad-hoc |
| 0.0.1 | tag only, never released | 2026-10-02 | none |

Published macOS releases so far are **GitHub prereleases** with ad-hoc signed, **not notarized** DMGs: the `release` Environment holds no Apple credentials, so `signing=auto` selects the ad-hoc mode ([.github/DEPLOYMENT.md](.github/DEPLOYMENT.md), ADR 0004/0005/0009). No Developer ID release has been produced. First-install Gatekeeper approval is required. The Rust preview uses unsigned archives and a separately authenticated feed; a prerelease hosting page alone does not make that feed live.

## 0.2.0

**Status: published prereleases; Rust feed live, macOS feed approval pending.** The [macOS prerelease `v0.2.0`](https://github.com/navig-me/tinyprune/releases/tag/v0.2.0) was published at **2026-10-22T01:16:33Z**, with build **23**. Its tag points to `4975449e6476600439cbbea2cf5ae5dbb73b2cf0`, whose [main CI run 39594441064](https://github.com/navig-me/tinyprune/actions/runs/39594441064) passed. The package and Homebrew jobs in [macOS release run 39598318323](https://github.com/navig-me/tinyprune/actions/runs/39598318323) passed; its `update-feed / publish` job is still waiting for `update-feed` Environment approval, so the live Sparkle appcast remains at **0.1.13 / build 22**. The [Rust developer-preview hosting prerelease](https://github.com/navig-me/tinyprune/releases/tag/rust-preview-0.2.0) now contains both build **29** archives, their `.sha256` sidecars and combined `SHA256SUMS`. [Rust signing run 39598352481](https://github.com/navig-me/tinyprune/actions/runs/39598352481) passed with the existing production key; feed PR [#20](https://github.com/navig-me/tinyprune/pull/20) was reviewed, independently verified and merged as `0fea75e`. [Pages deployment 39704695956](https://github.com/navig-me/tinyprune/actions/runs/39704695956) passed. The live Rust feed and signature were verified locally against the expected production public key and the downloaded public-release archives; both archive hashes matched. Protected [`verify_public` run 39704822483](https://github.com/navig-me/tinyprune/actions/runs/39704822483) is dispatched but **waiting for approval**, not passed.

**Why a minor bump.** It adds the cross-platform Rust runtime as a **developer preview**. The macOS application code is unchanged since 0.1.13 apart from the version number; macOS is the only supported product. Linux and Windows archives are unsigned developer-preview builds and carry **no supported-platform claim** (AGENTS.md, ADR 0012).

**Versions.** Marketing version 0.2.0 everywhere: `Scripts/package-app.swift`, the Swift agent's `serviceVersion` default and its two tests, all eleven workspace crates, `rust/ui` (`Cargo.toml`, `tauri.conf.json`) and both `Cargo.lock` files. `tinyprune --version` prints `tinyprune 0.2.0` and `tinyprune-agentd --version` prints `tinyprune-agentd 0.2.0` (both read `CARGO_PKG_VERSION`).

**Signing configuration.** The existing ADR 0009 key is reused, not rotated. On 2026-10-21, the nonsecret repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` was set and verified equal to both Environments' public keys. `release` and `update-feed` now require `mihirkhandekar` approval and are restricted to branch `main` and tags `v*`. Self-approval is permitted for the sole maintainer; no two-person-review claim is made. No private key was retrieved or exported.

**Build numbers (monotonic, per channel, never shared).**

- macOS/Sparkle: `CFBundleVersion` is the `release.yml` `github.run_number`; the published 0.2.0 DMGs carry **23**, above build **22** (0.1.13), which remains the newest live appcast entry pending feed approval. Local builds default `TINYPRUNE_BUILD` to `1`; the feed generator refuses a build not greater than retained entries (ADR 0009).
- Rust preview: promoted artifact build **29** comes from `github.run_number` of `rust-artifacts.yml`, a counter separate from the macOS channel. It is stamped into both archives and verified against the packaged CLI self-check. Clients refuse downgrade/replayed feeds; subsequent published builds must increase monotonically (ADR 0012).

**Published artifacts.**

| Channel | Artifact | Signing | Source workflow |
| --- | --- | --- | --- |
| macOS | `TinyPrune-0.2.0.dmg`, `TinyPrune-0.2.0-homebrew.dmg`, their `.sha256` sidecars, `TinyPrune-0.2.0.json` | ad-hoc, not notarized (`signing: unsigned` in metadata), GitHub prerelease; Sparkle feed publication still pending | `release.yml` run [39598318323](https://github.com/navig-me/tinyprune/actions/runs/39598318323), `update-feed / publish` awaiting approval |
| Linux (Rust preview) | `tinyprune-dev-0.2.0-g18407d26e218-linux-x86_64.tar.gz`, `.sha256`, combined `SHA256SUMS` | **unsigned archive**; live feed authenticated with the existing ADR 0009 EdDSA key | `rust-artifacts.yml` run [39589828202](https://github.com/navig-me/tinyprune/actions/runs/39589828202), `rust-update-feed.yml` run [39598352481](https://github.com/navig-me/tinyprune/actions/runs/39598352481) |
| Windows (Rust preview) | `tinyprune-dev-0.2.0-g18407d26e218-windows-x86_64.zip`, `.sha256`, combined `SHA256SUMS` | **unsigned archive** (SmartScreen may warn); authenticated feed as above | same |

The Rust archives are hosted on the separate GitHub **prerelease** `rust-preview-0.2.0`, not the macOS release. Names and VERSION stamps retain `tinyprune-dev` and `status=unreleased-development-artifact`; these are developer previews, not supported general-desktop releases. Signing the manifest authenticates feed contents and archive hashes; it does **not** OS-sign the executables or remove platform trust warnings. No new signing key was created or rotated.

**Promoted build.** [Rust artifacts run 39589828202](https://github.com/navig-me/tinyprune/actions/runs/39589828202), dispatch build **29**, succeeded on `main` commit `18407d26e2188265d9b97037f16c5c8b478b9d76`; those archives are now published. Both platform archives include the 0.2.0 UI, daemon and CLI. Linux Docker installation, Windows Scheduled Task installation and the Windows throwaway-key managed-update job passed. Downloaded archive hashes were verified against the workflow manifests and, after publication, against the live authenticated feed; the Windows manifest uses CRLF, so cross-platform verification must normalize line endings. The packaged Linux CLI self-check ran offline in an x86_64 Ubuntu container and reported version 0.2.0, build 29 and a public key matching both release Environments.

| Published Rust artifact | Verified SHA-256 |
| --- | --- |
| `tinyprune-dev-0.2.0-g18407d26e218-linux-x86_64.tar.gz` | `1b972b38025d2dfc5155912e62bc50de263d60c2c7d601501a57ad2b4f223432` |
| `tinyprune-dev-0.2.0-g18407d26e218-windows-x86_64.zip` | `2ae730ce1ee58275c18cc2e3c1830d7cd02cda4ae90ebefd6882a0b341ae72eb` |

Both macOS DMGs were downloaded and verified against their published `.sha256` sidecars (recorded below). Rust feed authenticity and both public archive hashes were verified locally after deployment; this is not an OS installation or production update end-to-end test. The protected Rust `verify_public` workflow still needs user approval, and the macOS update feed still needs its separate signing/publication approval. Do not describe either pending workflow as passed.

**Homebrew tap handoff.** The cask job returned success after explicitly skipping publication because `HOMEBREW_TAP_TOKEN` was unset; this is not evidence that the tap advanced. The existing tap was still at 0.1.11. Manual fallback [homebrew-tap PR #1](https://github.com/navig-me/homebrew-tap/pull/1) updates it to 0.2.0 with the verified Homebrew DMG hash. Ruby syntax passed; a fresh tap installation was not performed for that PR, and it is not auto-merged.

**Verification status** (CI and local publication checks; nothing beyond the stated evidence is claimed).

| Item | Result | Evidence |
| --- | --- | --- |
| Swift behavior, golden fixtures (577 cases), native acceptance on macOS 14/15/15-intel, packaging of both channels, Homebrew smoke | passed for the Swift/Rust tree as merged in PR #15 | [CI run 39541522007](https://github.com/navig-me/tinyprune/actions/runs/39541522007) (head `878a1e6`) |
| Rust dev artifacts build matrix (Linux, Windows, macOS), Linux Docker install test, Windows Scheduled Task install/run/uninstall | passed on PR #15 and PR #16 heads | [run 39541522001](https://github.com/navig-me/tinyprune/actions/runs/39541522001) (#15), [run 39555906929](https://github.com/navig-me/tinyprune/actions/runs/39555906929) (#16, head `007bb92`) |
| `rust-core` (tests, clippy, release build, end-to-end smoke) on Ubuntu, Windows, macOS; Rust UI frontend tests + Tauri check; `rust-ui-windows` (non-gating) | passed on PR #16 head | [CI run 39555907074](https://github.com/navig-me/tinyprune/actions/runs/39555907074) |
| Windows managed-update end-to-end (`windows-update-e2e`, real Scheduled Task, launcher, agent, throwaway key) | passed once on `windows-2022` | [dispatch run 39550764775](https://github.com/navig-me/tinyprune/actions/runs/39550764775) (commit `c25ee1f`); also a job in run 39555906929 |
| Tagged `main` commit (`4975449`, `v0.2.0`) | CI passed, including native macOS acceptance, all Rust platforms and the Windows UI smoke | [run 39594441064](https://github.com/navig-me/tinyprune/actions/runs/39594441064) |
| Preparation PR #17 (`2a49601`) | all 17 checks passed, including Windows UI and managed-update end-to-end | [CI run 39580285014](https://github.com/navig-me/tinyprune/actions/runs/39580285014), [artifact/install/update run 39580285020](https://github.com/navig-me/tinyprune/actions/runs/39580285020) |
| 100k-entry benchmark on tagged `main` commit | benchmark tests completed on Linux, Windows and macOS; figures below are single hosted-runner measurements, not latency guarantees | [run 39594441064](https://github.com/navig-me/tinyprune/actions/runs/39594441064), jobs 119203145741, 119203145505 and 119203145747 |
| macOS 0.2.0 packaging and downloaded direct/Homebrew DMG checksums | passed; automatic cask publication skipped for missing token, manual tap PR #1 open; appcast publication awaiting approval | [release run 39598318323](https://github.com/navig-me/tinyprune/actions/runs/39598318323), [tap PR #1](https://github.com/navig-me/homebrew-tap/pull/1); published `.sha256` sidecars |
| Production-key Rust feed signing, Sparkle and Rust verification, tampered-feed rejection | passed with the existing production key | [signing run 39598352481](https://github.com/navig-me/tinyprune/actions/runs/39598352481), merged [PR #20](https://github.com/navig-me/tinyprune/pull/20) (`0fea75e`) |
| Rust feed deployment and live public downloads | deployment passed; feed signature and both archive hashes verified locally | [deployment 39704695956](https://github.com/navig-me/tinyprune/actions/runs/39704695956); `https://tinyprune.com/updates/rust/rust-update-feed.json` and `.sig` |
| Protected Rust public-feed verification | dispatched, **waiting for user approval**; not passed | [`verify_public` run 39704822483](https://github.com/navig-me/tinyprune/actions/runs/39704822483) |

| 100k files / 100 directories | Linux x86_64 | Windows x86_64 | macOS Rust adapter |
| --- | --- | --- | --- |
| Initial index | 4.54 s | 46.45 s | 9.56 s |
| All decision rows visible | 15.83 s | 87.02 s | 27.05 s |
| New-file event to deadline | 63 ms, inotify | 161 ms, native watcher | 1184 ms, periodic fallback |
| Overview / Upcoming (100 items) | 25.5 / 5.5 ms | 57.7 / 14.5 ms | 23.3 / 6.3 ms |

macOS numbers exercise the Rust test runtime, not the shipping Swift app. CI benchmark steps are non-gating; their logs were inspected for completed benchmark results before recording these figures.

**Evidence and remaining limits.** Native Linux/Windows watchers, filesystem/Trash adapters, stores, IPC, daemon/CLI and developer installations have CI/container coverage. Tauri webviews ran against the real agent in Linux Docker and Windows CI; managed update tests used throwaway keys. The [detailed matrix](https://github.com/navig-me/tinyprune/blob/main/rust/README.md#status-matrix) identifies tested environments and limits. These checks do not establish screen-reader acceptance, logon/reboot-trigger behavior, non-administrator behavior or other Windows editions; native updater, Shell and path-race limitations remain. The existing production key is embedded in build 29 and now authenticates the live Rust feed, with Sparkle-tool/Rust-verifier interoperability and tamper rejection proved by the signing run. No new production update end-to-end test or OS install was run: feed authenticity is not installation acceptance, and protected public verification remains awaiting approval. macOS Sparkle installation remains end-to-end unverified (ADR 0009), and its 0.2.0 appcast publication is pending.

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
| 0.2.0 | 2026-10-22 (published 2026-10-22T01:16:33Z) | GitHub prerelease | `TinyPrune-0.2.0.dmg` (direct), `TinyPrune-0.2.0-homebrew.dmg`, `.sha256` sidecars, `TinyPrune-0.2.0.json`; ad-hoc signed, not notarized (`signing: unsigned`) | 23 | **not yet**; run 39598318323 awaits `update-feed` approval, live appcast remains 0.1.13/build 22 | [0.2.0](CHANGELOG.md#020---2026-10-21) | macOS code unchanged apart from version; separate unsigned Linux/Windows Rust developer-preview archives and authenticated feed published at build 29; see [entry](#020). |
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
| 0.2.0 | `468a81d7e79b045b19eaaed5a04c49f23a2de6bce1ca303183ee24dafbbd3edb` | `dba6deef54f6177b2e93add2b0e5ca829891f0227db3c48ce05bee76d21fa855` |
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
