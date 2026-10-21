# Releasing TinyPrune

Runbook for maintainers. It covers both channels: the **macOS app** (the supported product) and the **Rust runtime developer preview** for Linux x86_64 and Windows x86_64. Decisions and rationale: [ADR 0013](../ADRs/0013-release-process-and-signing-custody.md). Every release is recorded in [RELEASES.md](../RELEASES.md). Workflow and Environment setup details: [DEPLOYMENT.md](DEPLOYMENT.md).

This file contains no secrets and must stay free of them. Nothing here is a Linux or Windows support claim: the Rust archives are unsigned developer-preview builds, macOS is the only supported product.

## 0. State of the controls (read first)

As observed with the maintainer's `gh` token on 2026-10-21, **none of the four Environments (`release`, `update-feed`, `homebrew`, `cloudflare-pages-production`) has required reviewers or a deployment-branch restriction, and `main` has no branch protection.** Every "approval" below that relies on an Environment reviewer is therefore not enforced until a maintainer configures it. Do that before the first production signing (section 8). Re-check at any time:

```sh
gh api repos/:owner/:repo/environments/update-feed --jq '{rules: [.protection_rules[] | {type, reviewers: (.reviewers // [] | length)}], branches: .deployment_branch_policy}'
gh api repos/:owner/:repo/branches/main/protection --jq .required_pull_request_reviews   # 404 means unprotected
```

## 1. Signing key custody

- One Ed25519 key (the one from [ADR 0009](../ADRs/0009-eddsa-only-updates-for-adhoc-builds.md)) signs the Sparkle appcast and the Rust update feed. There is no separate Rust key.
- The **private** key lives only in the `update-feed` Environment secret `SPARKLE_ED25519_PRIVATE_KEY` and in the maintainers' offline backup. It is never committed, printed, passed as an argument or written to disk; the workflows give it to Sparkle's pinned `sign_update` on stdin. Do not export it to "check" it, and do not generate a replacement in CI.
- The **public** key is nonsecret. It is the Environment variable `SPARKLE_ED25519_PUBLIC_KEY` in both `release` and `update-feed`, and (for Rust builds) the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY`.

### Check that the Environment holds both halves, without reading values

```sh
gh api repos/:owner/:repo/environments/update-feed/secrets   --jq '.secrets[].name'     # expect SPARKLE_ED25519_PRIVATE_KEY
gh api repos/:owner/:repo/environments/update-feed/variables --jq '.variables[].name'   # expect SPARKLE_ED25519_PUBLIC_KEY
gh api repos/:owner/:repo/environments/release/variables     --jq '.variables[].name'   # expect SPARKLE_ED25519_PUBLIC_KEY
gh api repos/:owner/:repo/actions/variables                  --jq '.variables[].name'   # Rust builds need TINYPRUNE_UPDATE_PUBLIC_KEY
```

The secret endpoint lists names only; GitHub never returns secret values.

### Check that the embedded public key equals the Environment's key

Public keys are not secret, so comparing them is fine.

```sh
# The three public values must be identical:
gh api repos/:owner/:repo/environments/update-feed/variables/SPARKLE_ED25519_PUBLIC_KEY --jq .value
gh api repos/:owner/:repo/environments/release/variables/SPARKLE_ED25519_PUBLIC_KEY     --jq .value
gh variable get TINYPRUNE_UPDATE_PUBLIC_KEY       # Rust builds; unset today, see section 3
```

The workflows verify this for you at signing time, and you should read their logs rather than trust a green tick alone:

- **macOS:** `release.yml` embeds the `release` Environment's key as `SUPublicEDKey`. `publish-update-feed.yml` (`Scripts/distribution.py feed`) checks its configured key against the key embedded in the released direct app and verifies the DMG signature with that embedded key. To look yourself: `/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' /Applications/TinyPrune.app/Contents/Info.plist`.
- **Rust:** `rust-update-feed.yml` job `prepare` runs `tinyprune update self-check --json` on the extracted Linux binary and exports its `publicKey`; job `sign` aborts with "embedded public key differs from the Environment public key; refusing to sign" unless it equals `SPARKLE_ED25519_PUBLIC_KEY`. To look yourself: extract the archive and run `bin/tinyprune update self-check --expect-version 0.2.0 --expect-build <N> --json`.

### Loss and rotation

See ADR 0013 and ADR 0009. In short: if the private key is lost and there is no backup, a new key cannot be trusted by anything already installed. Every installed copy (macOS app or Rust runtime) embeds the old public key and rejects feeds signed with a new one: macOS copies keep running but never offer an in-app update, Rust copies report a bad signature and do not update. The migration is a manually announced, explicitly trusted reinstall of a build embedding the new public key. If the old key is still available, ship a transition release signed by the old key that embeds the new public key first, test it on a test feed, then switch the secret and all three public-key locations together. Compromise is an incident, not a rotation.

## 2. Pre-release checklist

Do all of these in the release PR or before tagging. Record the evidence (run links) in the RELEASES.md entry.

1. CI is green on `main` for the commit you will tag: `gh run list --branch main --limit 5`. Includes `Rust core golden fixtures` on Ubuntu, Windows and macOS, `Rust UI`, `Rust UI on Windows (WebView2, real agent; non-gating)` (`rust-ui-windows`, non-gating: open it and read the result, do not rely on the overall tick), `Native acceptance` on all three macOS runners and `Version consistency`.
2. `python3 Scripts/check-versions.py` passes locally (and `--tag vX.Y.Z` for the tag you intend to push).
3. `RELEASES.md` has the new `## X.Y.Z` entry (copy the template at its top; prepared releases say "prepared, not published") and previous entries are untouched.
4. `CHANGELOG.md`: a dated `## X.Y.Z - YYYY-MM-DD` section above the older ones, a fresh empty `## Unreleased` above it, wording that matches what was actually verified. The macOS release notes and Sparkle notes are generated from this section.
5. Golden fixtures: `swift test --filter GoldenFixtureTests` and `cd rust && cargo test --locked -p tinyprune-core` (command for CommandLineTools-only Macs is in AGENTS.md).
6. Smoke and end-to-end: `rust-core` end-to-end smoke (all three OSes), `windows-update-e2e` job of `rust-artifacts.yml` (real Scheduled Task, launcher, throwaway key), the Linux Docker install test, `native` acceptance. Note which ran on which commit.
7. Benchmark numbers recorded: the 100k-entry and store benchmarks are non-gating and write their tables to the job summary of the `rust-core` jobs. Copy the figures (and the runner) into the RELEASES.md entry; do not quote numbers from another machine as if they came from CI.
8. Environments: section 0 checks pass; the three public-key locations match (section 1).
9. For a Rust preview additionally: the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` is set (section 3), and you have read the "Not verified" list in the RELEASES.md entry so the announcement does not overstate it.

## 3. How the Rust workflow embeds the production key

`rust-artifacts.yml` stamps `TINYPRUNE_BUILD` (this run's `github.run_number`) into every build, but embeds `TINYPRUNE_UPDATE_PUBLIC_KEY` only in the step "Embed production update key (workflow_dispatch on main only)", whose `if` is `github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'`. Pull-request runs, forks and dispatches from other branches never receive the key and produce binaries with in-app updates disabled (`tinyprune update status` reports why). The step validates that the variable is a base64 32-byte key and warns if it is unset. No secret is read by this workflow.

Gap found and fixed with this release: the workflow used to read `vars.TINYPRUNE_UPDATE_PUBLIC_KEY` for every run, including pull requests, and that repository variable is not set (the key only exists as an Environment variable, which the build job cannot read). A dispatch build would have had no key and `rust-update-feed.yml` would have rejected it. The boundary is not weakened: signing still happens only in `rust-update-feed.yml` on `main` inside `update-feed`, and it still refuses an artifacts run that is not a successful `workflow_dispatch` on a commit on `main`. **Remaining manual step:** set the repository variable to the same public value as the Environment variable:

```sh
gh variable set TINYPRUNE_UPDATE_PUBLIC_KEY --body "$(gh api repos/:owner/:repo/environments/update-feed/variables/SPARKLE_ED25519_PUBLIC_KEY --jq .value)"
```

(That reads and writes only the public key.)

## 4. macOS release procedure

Build numbers: the macOS build number is the `release.yml` `github.run_number` (`CFBundleVersion`); it must exceed every appcast entry (last published: 22, 0.1.13).

1. Merge the release PR (version bump, CHANGELOG, RELEASES.md) into `main` after review and green CI. Do not tag a commit that is not on `main`.
2. There is no pre-tag dry run: `release.yml`'s `workflow_dispatch` needs an existing `vX.Y.Z` tag. Pre-tag confidence comes from the `native` CI job, which packages both channels. After tagging, `release.yml` publishes directly (tag pushes publish); a dispatch with `publish=false` is only for re-inspecting an existing tag.
3. Tag and push (maintainer action; the tag is immutable): `git switch main && git pull --ff-only && python3 Scripts/check-versions.py --tag vX.Y.Z && git tag -a vX.Y.Z -m "TinyPrune X.Y.Z" && git push origin vX.Y.Z`. The tag triggers `release.yml`.
4. **Approval:** `release.yml` runs in the `release` Environment: approve the run if reviewers are configured. It publishes a GitHub **prerelease** (ad-hoc, not notarized) with `TinyPrune-X.Y.Z.dmg`, `TinyPrune-X.Y.Z-homebrew.dmg`, their `.sha256` files and `TinyPrune-X.Y.Z.json`, then calls `homebrew.yml` and `publish-update-feed.yml`.
5. **Approval:** `publish-update-feed.yml` runs in `update-feed`: approve it. It signs the appcast with the key on stdin and opens the PR `updates/vX.Y.Z` (needs "Allow GitHub Actions to create and approve pull requests").
6. Review that PR: retained older entries (including the absence of 0.1.12), strictly higher `sparkle:version`, the direct DMG enclosure URL and length, release notes. Merge it. Bot-created PRs may not trigger CI; run the checks by hand if policy requires.
7. **Approval:** the merge triggers `deploy-pages.yml` (`cloudflare-pages-production` Environment): approve and wait for success on that `main` commit.
8. Verify the live feed: `gh workflow run publish-update-feed.yml -f tag=vX.Y.Z -f verify_public=true` (approve the `update-feed` job). It must pass: signed XML, enclosure URL/length, DMG signature against the key embedded in the app, signed notes. Then `curl -fsS https://tinyprune.com/updates/appcast.xml | grep -A3 'sparkle:version'` shows the new build on top.
9. Homebrew: review the `navig-me/homebrew-tap` PR if `HOMEBREW_TAP_TOKEN` is set; otherwise render the cask by hand as in DEPLOYMENT.md.
10. Download both DMGs, `shasum -a 256 -c` against the sidecars, and fill the checksums, build number, run links and approvals into RELEASES.md (a follow-up PR; the entry already exists).

## 5. Rust developer-preview procedure

Archives are unsigned; the **feed** is signed. Build number: `github.run_number` of the `rust-artifacts.yml` dispatch run you promote; `tinyprune-feed generate` refuses a number not above the retained feed entries.

1. Prerequisites: release PR merged to `main`; the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` set (section 3).
2. Build: `gh workflow run rust-artifacts.yml --ref main`, wait for success, and note the run ID. This run embeds the key (it is a dispatch on `main`) and produces `tinyprune-rust-dev-ubuntu-24.04` (`.tar.gz`, `.sha256`, `SHA256SUMS`) and `tinyprune-rust-dev-windows-2022` (`.zip` and sums) artifacts, and runs the Windows Scheduled Task install test and the `windows-update-e2e` job. A run from a branch or pull request cannot be promoted.
3. Create the hosting **prerelease** with a tag that does **not** start with `v` (a `v*` tag would start the macOS `release.yml`): `gh release create rust-preview-X.Y.Z --target main --prerelease --title "TinyPrune Rust runtime X.Y.Z (developer preview)" --notes "Developer preview for Linux x86_64 and Windows x86_64. Unsigned archives, no supported-platform claim. macOS is unchanged and is the only supported product. See RELEASES.md."` The workflow uploads the archives itself and never overwrites an existing asset.
4. **Approval:** `gh workflow run rust-update-feed.yml --ref main -f artifacts_run_id=<run id> -f release_tag=rust-preview-X.Y.Z`. Job `prepare` (no environment, no secret) validates the run (successful `workflow_dispatch` on `main`, commit on `main`), checks archive checksums, extracts the Linux archive, compares its stamped version and build with the run, reads the embedded public key and generates the unsigned feed. Job `sign` runs in `update-feed`: approve it. It requires the embedded key to equal `SPARKLE_ED25519_PUBLIC_KEY`, signs on stdin, verifies with Sparkle's tool and the Rust verifier, proves a tampered feed is rejected, uploads the archives to the prerelease and opens a PR `rust-updates/b<build>`.
5. Review the PR (`website/updates/rust/rust-update-feed.json` and `.sig`: version, build above any previous entry, `github.com/.../releases/download/rust-preview-X.Y.Z/...` URLs, SHA-256 values equal to the `.sha256` files). Merge. Note the archives are attached to the prerelease before this PR is reviewed and are never overwritten; closing the PR without merging leaves unreferenced assets on the prerelease, which you should mark as such in its notes.
6. **Approval:** the merge deploys Pages through `deploy-pages.yml`; approve and wait for success.
7. Verify: `gh workflow run rust-update-feed.yml --ref main -f release_tag=rust-preview-X.Y.Z -f verify_public=true` (approve `update-feed`). It downloads the live feed and signature from `https://tinyprune.com/updates/rust/` and every archive the feed names, and verifies hashes and signature against the public key. Do not announce before this passes.
8. Record SHA-256 values (from the prerelease's `.sha256` files), the artifacts run ID, the feed run IDs and the approvals in RELEASES.md.

Note: archive names and the `VERSION` stamp currently say `tinyprune-dev` and `status=unreleased-development-artifact`, and no real production feed has ever been published, so the first run is also the first test of `rust-update-feed.yml` against GitHub. Treat step 7 as the acceptance test and expect to fix workflow problems then.

## 6. Post-release checklist

- RELEASES.md entry updated from "prepared" to published with run links, checksums and build numbers.
- `https://tinyprune.com/updates/appcast.xml` (macOS) and `https://tinyprune.com/updates/rust/rust-update-feed.json` (Rust) serve the new entry; `Version consistency` still passes on `main`.
- `tinyprune --version` and `tinyprune-agentd --version` from the published archive print the release version.
- Install the new macOS DMG on a disposable Mac and confirm first-run Gatekeeper wording matches the release notes (ad-hoc). Update from the previous version if you want to extend the unverified Sparkle acceptance (ADR 0009).
- Website and docs mention no stale version (the `versions` job guards pins of the form `vX.Y.Z` / `TinyPrune X.Y.Z`).
- Announce only what RELEASES.md says was verified. Do not announce Linux/Windows support.

## 7. Rollback, yank and withdrawal

Version and build numbers only go up. Clients refuse downgrades and replayed feeds, so you cannot rewind a feed.

- **Bad macOS release:** ship `X.Y.(Z+1)` with the fix through the normal procedure; the new, higher `sparkle:version` supersedes it for everyone. Edit the bad GitHub release's notes to say it is superseded (an edit of release text, not of immutable assets). Do not delete or replace assets: the appcast pins the DMG's length and signature, and published artifacts are immutable. A signed `appcast.xml` cannot be hand-edited; removing an entry requires regenerating and re-signing it through the workflow in a reviewed PR (not yet exercised).
- **Bad Rust preview:** publish a higher build the same way. For an immediate stop before a fix exists, the safest tools are: mark the hosting prerelease as superseded in its notes; and, if nobody should install it, delete only the feed PR before merge. Once a feed is live there is no rewind; a new feed with a higher build whose newest entry is the fix is the remedy. A client that already installed the bad build rolls itself back only when the new build fails its own health check.
- **Record it:** change the RELEASES.md entry's status to `withdrawn` or `yanked`, with date, reason and the replacement version, in the same PR that ships the replacement. Never delete the entry or its checksums.
- **Key compromise or loss:** section 1 and ADR 0009; this is an incident, not a rollback.

## 8. Manual maintainer actions that cannot be automated here

- Configure required reviewers and deployment-branch/tag restrictions on `release`, `update-feed`, `homebrew` and `cloudflare-pages-production`, and protect `main`, before the first production signing (section 0). Until then, the private key is reachable by any workflow job from any branch that names `update-feed`.
- Set the repository variable `TINYPRUNE_UPDATE_PUBLIC_KEY` (section 3).
- Approve every Environment-gated job (`release` once; `update-feed` for the appcast publish, the appcast verify, the Rust sign and the Rust verify; `cloudflare-pages-production` for each Pages deploy), merge the feed PRs, and push the tag. A tag push is irreversible in practice; nothing in this PR creates one.
- Create the Rust hosting prerelease (section 5, step 3).
- Apple Developer ID signing and notarization: not available. Without all six Apple secrets in `release` every macOS release is ad-hoc and not notarized; providing them is an account-level maintainer action (DEPLOYMENT.md).
- Keep the private key backup offline and verify it is restorable. No tool in this repository can verify that for you.
- Homebrew tap token and tap PR review, Google Search Console/Bing sitemap submission, any announcement, and real-desktop acceptance (GUI first-run on macOS 15/26, Linux/Windows UI) remain manual.
