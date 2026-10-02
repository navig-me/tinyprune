# Deployment setup

The repository uses Cloudflare Pages Direct Upload from GitHub Actions. This keeps source control and deployment policy in one place. Cloudflare documents that a Direct Upload project cannot later be converted to Git integration; retain this model unless a new Pages project is deliberately created.

## One-time Cloudflare setup

1. Create two **Direct Upload** Pages projects in the same Cloudflare account:
   - `tinyprune` → `tinyprune.com` and `www.tinyprune.com`
   - `tinyprune-docs` → `docs.tinyprune.com`
2. Add those custom domains in each Pages project and make the DNS records Cloudflare-proxied. Redirect `www.tinyprune.com` to `tinyprune.com` at the Cloudflare zone level.
3. Create an account-scoped API token with only **Account / Cloudflare Pages / Edit** access. Do not use a Global API Key.
4. In the GitHub repository, create the `cloudflare-pages-production` Environment. Store the Cloudflare account ID and API token as environment secrets named `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. Require a reviewer before production deploys once a maintainer group exists.

`website/` deploys to the `tinyprune` project. `docs/` deploys to the `tinyprune-docs` project. The workflow validates each static site before uploading it. A push to `main` deploys both Pages projects; manual runs can select one site.

## macOS release setup

Create a protected GitHub Environment named `release` (required reviewers, restricted to `v*` tags and `main`) and store these **environment secrets** (nothing else; never repository-level):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | `base64 -i DeveloperID.p12` of the *Developer ID Application* certificate and private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID; the workflow refuses a certificate from another team |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID (Developer access or higher) |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | `base64 -i AuthKey_<ID>.p8` |

`release.yml` is the single release entry point. It builds **two** universal DMGs on `macos-15` with Xcode: the direct artifact `TinyPrune-X.Y.Z.dmg` and the Homebrew artifact `TinyPrune-X.Y.Z-homebrew.dmg`. Both have immutable SHA-256 sidecars. A release metadata asset `TinyPrune-X.Y.Z.json` records the selected signing mode; downstream jobs validate it and their selected DMG checksum. Never overwrite released assets.

### Unsigned versus signed matrix

| Apple secrets in `release` | `signing=auto` (also tag pushes) | Explicit `signed` | Explicit `unsigned` |
| --- | --- | --- | --- |
| None | Ad-hoc **GitHub prerelease**, not notarized | Fail | Ad-hoc prerelease |
| Some, but not all six | Fail: partial configuration | Fail | Fail |
| All six | Developer ID signed/notarized release | Signed release | Fail: remove credentials only by deliberate environment administration |

An import, signing, notarization, or verification failure **never** falls back to unsigned. The environment reviewer approves the chosen mode before any credentials become available. Manual dispatch defaults to a non-publishing dry run (`publish=false`). Signed artifacts retain the hardened-runtime, secure-timestamp, Team ID, notarization, stapling, Gatekeeper and mounted-DMG checks from ADR 0004. Preview artifacts use `TINYPRUNE_SIGN_IDENTITY=-`, `TINYPRUNE_UNIVERSAL=1`, and the verifier's **development** mode. There is currently no Apple Developer ID certificate and no Sparkle linked into the app; do not invent credentials or advertise automatic updates.

Unsigned prerelease notes explain that Gatekeeper cannot verify the developer and include the macOS 15 Sequoia/macOS 26 Tahoe procedure: copy to `/Applications`, attempt opening once, dismiss the alert, then **System Settings > Privacy & Security > Open Anyway**, confirm Open and authenticate if prompted. For users who deliberately trust the artifact, the documented fallback is exactly:

```sh
xattr -dr com.apple.quarantine /Applications/TinyPrune.app
```

This removes quarantine, not proof of safety or notarization. Finder extension and launch-at-login may need separate approval in **System Settings > General > Login Items & Extensions**. Their activation on unsigned builds is not guaranteed. See ADR 0005.

### Update feed environment and review boundary

Create a reviewer-protected **`update-feed`** Environment restricted to `main` and `v*` tags:

| Secret | Value / scope |
| --- | --- |
| `SPARKLE_ED25519_PRIVATE_KEY` | Private key exported by Sparkle's `generate_keys`; paste the exported key string, not a fabricated placeholder |

No website-publishing secret is required: the repository `GITHUB_TOKEN` opens a PR with `contents:write` and `pull-requests:write`; it cannot bypass protected `main`. Enable **Allow GitHub Actions to create and approve pull requests** in repository Actions settings (the workflow never approves its own PR). Require review and the existing site checks on `main`. GitHub bot-created PRs may not automatically trigger other workflows; use a maintainer-reviewed PR/run when required by repository policy. PR merge by a maintainer triggers `deploy-pages.yml` with the existing `cloudflare-pages-production` review.

`publish-update-feed.yml` is called after publishing or dispatchable with a tag. A missing key skips clearly and does **not** fail the release. Unsigned previews skip the stable feed even if a key exists. The feed downloads only the **direct** released DMG, validates its SHA-256, uses Sparkle's real `generate_appcast` with the private key on **stdin** (`--ed-key-file -`), and opens `updates/vX.Y.Z` as a PR adding `website/updates/appcast.xml` and `website/updates/X.Y.Z.html`. It retains old feed entries (`--maximum-versions 0`), does not create deltas, and never uses the Homebrew DMG.

After reviewing and merging the PR and a successful Pages deploy of current `main`, manually dispatch the same workflow with `verify_public=true` and the release tag. Its separate verification job requires a successful `deploy-pages.yml` run for that `main` commit, fetches `https://tinyprune.com/updates/appcast.xml`, matches the direct enclosure URL and exact byte length, and verifies `sparkle:edSignature` against the checksum-validated released DMG using Sparkle `sign_update --verify` (key again via stdin). The PR-based boundary intentionally requires a **post-deploy verification dispatch** rather than holding a release runner open awaiting human review. Do not mark the feed published until this verification succeeds.

Sparkle tools are pinned in `Scripts/distribution.py` to **2.8.1**, official release asset `Sparkle-2.8.1.tar.xz`, SHA-256 `5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be`. To bump: download the new upstream release asset, inspect upstream release/provenance, calculate `shasum -a 256 Sparkle-<version>.tar.xz`, update **both** `SPARKLE_URL` and `SPARKLE_SHA256`, review `bin/generate_appcast --help` and `bin/sign_update --help`, and exercise generation plus signature verification on a fixture DMG. Never compute a new trusted checksum at workflow runtime.

### Homebrew environment and channel separation

Create a reviewer-protected **`homebrew`** Environment restricted to `main` and `v*` tags:

| Secret | Value / scope |
| --- | --- |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token for **only `tinyprune/homebrew-tap`**, Contents read/write, Pull requests read/write (Metadata read implicit); no administration, workflows, or branch-protection bypass |

Create `tinyprune/homebrew-tap` with a protected `main` branch and required human review. `homebrew.yml` is called after release or manually dispatched for a tag; absent token skips without failing the release. It renders `Resources/Homebrew/tinyprune.rb.template`, pins the Homebrew DMG release URL and SHA-256, and opens `release/vX.Y.Z` as a PR. The cask installs the app and bundled CLI, requires Sonoma or newer, unloads `com.navig-me.tinyprune.agent`, disables Finder plugin `com.navig-me.tinyprune.finder`, and zaps TinyPrune Application Support and preference files. Zap deletes local configuration: users should export rules first.

Only metadata-marked **unsigned** builds get a postflight that plainly warns about lack of notarization and removes quarantine from the installed app. Signed casks never clear quarantine. Check that policy change explicitly in PR review; the checksum and metadata are delivered together through the protected release.

The clean `macos-15` verification job installs from the **PR branch** (not tap `main`), checks the distribution Info.plist, and runs `tinyprune status --json`. Exit 69 with `{\"schemaVersion\":1,\"status\":\"unavailable\"}` is acceptable on a fresh machine without a registered agent; it proves the CLI runs, not agent integration. No auto-merge is configured. To reproduce on a clean Mac:

```sh
brew tap tinyprune/tap
git -C \"$(brew --repo tinyprune/tap)\" fetch origin release/vX.Y.Z
git -C \"$(brew --repo tinyprune/tap)\" checkout --detach FETCH_HEAD
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask tinyprune/tap/tinyprune
tinyprune status --json
# Exit 0 (available) or 69 with unavailable-agent JSON is expected.
```

`TINYPRUNE_DISTRIBUTION=direct|homebrew` is backward-compatible packaging plumbing: default `direct`. The packager writes `TinyPruneDistribution` and `SUEnableAutomaticChecks` (`false` for Homebrew, `true` for direct) **before signing**. These keys are harmless while Sparkle is absent. Homebrew has a separately packaged, signed/notarized when available DMG with identical version/build; its only updater is `brew upgrade --cask tinyprune`. Future Sparkle integration must honor the distribution key and link only into the app; `verify-signing.sh` enforces component isolation.

### Maintainer release checklist

1. Protect `main`, tags and all four Environments (`release`, `update-feed`, `homebrew`, `cloudflare-pages-production`), require reviewers, and populate only real environment credentials. All six Apple secrets or none; optional channels may remain unset.
2. Create an immutable `vX.Y.Z` tag. Dispatch `release.yml` with `publish=false` for artifact review; use explicit `signed` when notarization is mandatory. Inspect selected mode, universal binaries, dev/release verifier results and both DMGs.
3. Publish via tag push or dispatch with `publish=true`. Without Apple credentials, confirm GitHub **prerelease** status and Gatekeeper warnings/approval instructions. Download and verify both SHA-256 sidecars.
4. Review the Homebrew PR and clean-macOS CLI proof, then merge under tap policy. Confirm only unsigned casks clear quarantine and the bundle disables Sparkle checks.
5. For signed releases with an update key, review the appcast PR, retained older entries, direct enclosure and release notes. Merge, approve Pages deploy, then dispatch `verify_public=true`; require passing public URL/length/EdDSA verification.
6. Until real Developer ID and Sparkle app integration exist, state plainly that previews require manual installation/update. Test first-open, Finder and login-item approval on actual macOS 15/26 before widening distribution.

Local default smoke: `swift Scripts/package-app.swift && Scripts/verify-signing.sh .build/package/TinyPrune.app`. The host needs Xcode for universal builds; ad-hoc local builds remain compatible with Command Line Tools.
