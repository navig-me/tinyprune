# ADR 0013: Release process, release log and signing-key custody for both channels

Status: Accepted. Process decision only; it changes no product behavior. Acceptance of a release still depends on the verification recorded in [RELEASES.md](../RELEASES.md), and several controls below depend on GitHub settings that a maintainer must apply (see "Observed state").

## Context

TinyPrune now has two release channels with different trust surfaces:

- **macOS** (Swift): `release.yml` builds ad-hoc DMGs on a tag, `publish-update-feed.yml` signs a Sparkle appcast and opens a review PR ([ADR 0004](0004-signing-identifier-policy.md), [ADR 0005](0005-unsigned-preview-distribution.md), [ADR 0009](0009-eddsa-only-updates-for-adhoc-builds.md)).
- **Rust runtime** (Linux and Windows developer preview): `rust-artifacts.yml` builds unsigned archives, `rust-update-feed.yml` signs a JSON feed with the same Ed25519 key ([ADR 0012](0012-rust-runtime-signed-updates.md)).

Until 0.2.0 the releases were recorded only implicitly (tags, GitHub release pages, CHANGELOG, `website/updates/`), versions were declared in several unrelated places, and the process lived in a cheat sheet in `.github/DEPLOYMENT.md`. A release required editing a Swift packaging default, a Swift service default and two Swift test assertions by hand, and nothing checked that they agreed. The Rust workflow read the production public key from a repository variable that did not exist, and it would have embedded that key in every build including pull-request builds.

## Decision

1. **One source of truth for the version.** The default `marketingVersion` in `Scripts/package-app.swift` is the release version. Everything else must equal it: the Swift agent's `serviceVersion` default and its two test assertions, every Rust crate (including `rust/ui`), both `Cargo.lock` files, `rust/ui/tauri.conf.json`, the newest dated CHANGELOG heading and a `RELEASES.md` entry. `Scripts/check-versions.py` enforces this and runs as the cheap CI job `versions`; release procedures may add `--tag vX.Y.Z`. Rust crates keep explicit per-crate versions rather than `[workspace.package]` inheritance because `rust/ui` is a separate workspace and the packaging scripts and workflows read `version = "..."` from each `Cargo.toml` directly; the check, not inheritance, keeps them equal.
2. **A release log.** [RELEASES.md](../RELEASES.md) is the authoritative record of every release: date, artifacts, signing mode, checksums, build numbers, highlights and verification. Every release, including prereleases, prepared-but-unpublished, withdrawn and yanked ones, MUST be recorded in the same pull request that bumps the version. Entries are never deleted; a withdrawal is a status on the entry.
3. **Build numbers are per channel and strictly increasing.** macOS: `github.run_number` of the `release.yml` run (`CFBundleVersion`, ADR 0009). Rust: `github.run_number` of the `rust-artifacts.yml` run, read back by `rust-update-feed.yml` from the artifacts run (ADR 0012). The counters are independent and each is only compared inside its own feed. A rollback or yank is never a lower number: ship a higher build.
4. **One signing key, two feeds, one custody policy.** The ADR 0009 Ed25519 key signs both the Sparkle appcast and the Rust feed. No new key is created for the Rust runtime. The private key exists only in the `update-feed` Environment secret `SPARKLE_ED25519_PRIVATE_KEY` and in the maintainers' offline backup; it is passed to Sparkle's pinned `sign_update` on stdin only. The public key is non-secret configuration (`SPARKLE_ED25519_PUBLIC_KEY` Environment variable in `release` and `update-feed`). Nobody, and no tool or agent acting for a maintainer, reads, prints, exports, generates or rotates the private key outside the procedures in ADR 0009.
5. **Embedded key equals signing key, enforced at signing time.** macOS: `release.yml` embeds the `release` Environment's public key (`SUPublicEDKey`) and the feed job verifies against the key embedded in the released app. Rust: `rust-artifacts.yml` embeds the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` **only** for `workflow_dispatch` runs on `main` (pull-request and other-branch builds get no key, so updates are disabled in them), and `rust-update-feed.yml` refuses to sign unless the key embedded in the Linux binary equals the `update-feed` Environment's `SPARKLE_ED25519_PUBLIC_KEY`. A maintainer keeps the repository variable equal to the Environment variable; a mismatch fails closed rather than signing a feed that installed copies cannot verify.
6. **Publication goes through review.** Both feeds are published only by a pull request that a maintainer reviews and merges, followed by a Pages deploy and a `verify_public` run. The Rust prerelease that hosts the archives uses a tag that does **not** start with `v` (for example `rust-preview-0.2.0`), because every `v*` tag triggers the macOS `release.yml`.
7. **Rollback is forward.** Feeds retain history and clients refuse downgrades; withdrawing a bad release means publishing a higher build and recording the status in RELEASES.md. A published feed is signed over its final bytes, so a hand edit (for example deleting a bad entry) invalidates the signature; removing an entry is possible only by regenerating and re-signing the feed through the signing workflow in a reviewed PR, which has not been exercised and must be tried on a test feed first.
8. **Honest public wording.** The Rust runtime is a developer preview: unsigned archives, no supported-platform claim, macOS is the only supported product. A release record may only say what a linked run, or a stated manual check, actually proved.

## Key custody, loss and rotation

ADR 0009's policy is unchanged and now covers both feeds. Specifically:

- **Loss of the private key** (no backup): nothing can be signed that installed copies trust. A replacement key created anywhere, including in CI, cannot restore that trust. Every installed copy keeps its embedded old public key, so every installed copy rejects any feed signed by the new key. Installed macOS copies still run but never offer an in-app update; installed Rust copies report a bad signature and do not update. The only migration is an out-of-band, explicitly trusted manual reinstall of a build that embeds the new public key, announced with an incident note.
- **Rotation with the old key available**: ship a transition release authenticated by the old key whose binaries embed the new public key, validate the behavior (Sparkle's key-rotation rules for macOS; for the Rust updater, a staged self-check that the new build verifies the next feed, which ADR 0012's self-check already requires), then switch the Environment secret and variables to the new pair. Until the transition release is installed everywhere that matters, keep signing with the old key. This path is not implemented as automation and must be exercised on a test feed first.
- **Compromise** is the ability to forge update authority: treat it as an incident, not a credential refresh. Without a trusted channel to installed copies, the remedy is the same manual reinstall.
- A rotation changes the Environment secret, the `release` and `update-feed` variables, the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` and the embedded keys in all subsequent builds together, and is recorded in RELEASES.md and in a new ADR.

## Observed state (2026-10-21, read with the maintainer's `gh` token)

- Environment `update-feed` holds the secret name `SPARKLE_ED25519_PRIVATE_KEY` and the variable `SPARKLE_ED25519_PUBLIC_KEY`; `release` holds the variable `SPARKLE_ED25519_PUBLIC_KEY` and no secrets (so there are no Apple credentials and releases are ad-hoc). Values were not read.
- The repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` is **not set**; no Rust build could embed the production key before this change, and none can be promoted to a feed until it is set.
- The API reports **no required reviewers and no deployment-branch restrictions** on any of the four Environments, and `main` has no branch protection. The documented reviewer gates are therefore not enforced by GitHub today. Until a maintainer enables them, any user with write access can run a workflow job that names the `update-feed` Environment and obtain the private key. Enabling required reviewers and restricting `update-feed` and `release` to `main` and `v*` tags is a mandatory step before the first production signing (see the runbook).

## Consequences

- Version bumps are one small checklist enforced by CI instead of tribal knowledge; a stale test assertion or crate version fails the `versions` job.
- RELEASES.md adds a documentation duty to every release PR; the check enforces only that the entry exists, not that it is correct.
- A release can be fully prepared (versions, changelog, log entry) in one reviewable PR and published later from `main` by tagging.
- Nothing here automates approvals, notarization, announcements or the GitHub settings above; see the runbook's manual list.

References: [RELEASING runbook](../.github/RELEASING.md), [deployment setup](../.github/DEPLOYMENT.md), [RELEASES.md](../RELEASES.md), [ADR 0009](0009-eddsa-only-updates-for-adhoc-builds.md), [ADR 0012](0012-rust-runtime-signed-updates.md).
