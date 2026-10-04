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

### Search and assistant discovery

Both sites publish canonical URLs, social metadata, JSON-LD, `robots.txt`, `sitemap.xml`, and an advisory `llms.txt`. The landing social image is `website/og.png` (1200×630); docs reference its absolute published URL. Keep product claims synchronized with the visible documentation, including release availability and optional updater behavior. Run `npm run check` in each site before deployment.

After deployment, submit `https://tinyprune.com/sitemap.xml` and `https://docs.tinyprune.com/sitemap.xml` through verified Google Search Console/Bing Webmaster accounts. These require owner access and are not performed by the deployment workflow. Allowing crawlers and publishing `llms.txt` does not guarantee indexing, ranking, or inclusion in model answers; `llms.txt` is advisory, not a search-engine standard. Cloudflare zone-level bot/WAF rules must also permit the desired crawlers.

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

An import, signing, notarization, or verification failure **never** falls back to unsigned. The environment reviewer approves the chosen mode before any credentials become available. Manual dispatch defaults to a non-publishing dry run (`publish=false`). Signed artifacts retain the hardened-runtime, secure-timestamp, Team ID, notarization, stapling, Gatekeeper and mounted-DMG checks from ADR 0004. Preview artifacts use `TINYPRUNE_SIGN_IDENTITY=-`, `TINYPRUNE_UNIVERSAL=1`, and the verifier's **development** mode. Sparkle is linked only into the application, but development/unsigned and Homebrew copies never start it. Real Apple signing credentials and the update public/private key pair remain external prerequisites; do not invent credentials or advertise verified production updates before signed end-to-end proof.

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

Set the non-secret **`release` Environment variable** `SPARKLE_ED25519_PUBLIC_KEY` to the corresponding base64 Ed25519 public key printed by Sparkle's real key tooling. The release workflow passes it as `TINYPRUNE_SPARKLE_PUBLIC_KEY`; local packaging accepts the same environment variable. Never put a private key in this variable, generate credentials in CI, or commit credentials. A missing public key packages a signed app with in-app updates disabled and a visible explanation. A malformed nonempty public key fails packaging. Publishing with a private key but without a matching public key embedded in the direct app fails verification.

No website-publishing secret is required: the repository `GITHUB_TOKEN` opens a PR with `contents:write` and `pull-requests:write`; it cannot bypass protected `main`. Enable **Allow GitHub Actions to create and approve pull requests** in repository Actions settings (the workflow never approves its own PR). Require review and the existing site checks on `main`. GitHub bot-created PRs may not automatically trigger other workflows; use a maintainer-reviewed PR/run when required by repository policy. PR merge by a maintainer triggers `deploy-pages.yml` with the existing `cloudflare-pages-production` review.

`publish-update-feed.yml` is called after publishing or dispatchable with a tag. A missing key skips clearly and does **not** fail the release. Unsigned previews skip the stable feed even if a key exists. The feed downloads only the **direct** released DMG, validates its SHA-256, uses Sparkle's real `generate_appcast` with the private key on **stdin** (`--ed-key-file -`), and opens `updates/vX.Y.Z` as a PR adding `website/updates/appcast.xml` and `website/updates/X.Y.Z.html`. It retains old feed entries (`--maximum-versions 0`), does not create deltas, and never uses the Homebrew DMG.

The helper explicitly signs and verifies the immutable direct DMG, then mounts it read-only and verifies that signature with **the public key embedded in that app** using CryptoKit. It signs the final release-note bytes and adds their signature/length to the notes link; after changing enclosure and note URLs it signs the **final XML bytes** with Sparkle 2.9 `sign_update`. Never mutate the feed or notes after signing. Bundles require `SURequireSignedFeed=true`, `SUVerifyUpdateBeforeExtraction=true`, and no signed-feed-failure expiration; unsigned/mismatched feeds and notes fail closed.

After reviewing and merging the PR and a successful Pages deploy of current `main`, manually dispatch the same workflow with `verify_public=true` and the release tag. The job requires a successful Pages deploy for that commit, verifies the downloaded signed XML before parsing it, matches the direct enclosure URL/length, verifies the immutable DMG signature against its embedded public key, and downloads/verifies the signed release notes. Private key use stays on stdin. The PR-based boundary intentionally requires a **post-deploy verification dispatch** rather than holding a release runner open awaiting human review. Do not mark the feed published until this verification succeeds.

Sparkle app and release tools are pinned to **2.9.0**, which introduced signed feeds. `Package.swift` pins the exact version and upstream SwiftPM checksums the binary artifact. `Scripts/distribution.py` pins official `Sparkle-2.9.0.tar.xz`, SHA-256 `01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19`. To bump: review upstream release/provenance, download and independently calculate the checksum, update both app/tool pins, review `generate_appcast --help` / `sign_update --help`, then exercise signed generation and verification. Never compute a new trusted checksum at workflow runtime. Primary references: [setup/security](https://sparkle-project.org/documentation/), [programmatic lifecycle](https://sparkle-project.org/documentation/programmatic-setup/), [security settings](https://sparkle-project.org/documentation/customization/), [delegate contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).

### Homebrew environment and channel separation

Create a reviewer-protected **`homebrew`** Environment restricted to `main` and `v*` tags:

| Secret | Value / scope |
| --- | --- |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token for **only `tinyprune/homebrew-tap`**, Contents read/write, Pull requests read/write (Metadata read implicit); no administration, workflows, or branch-protection bypass |

Create `tinyprune/homebrew-tap` with a protected `main` branch and required human review. `homebrew.yml` is called after release or manually dispatched for a tag; absent token skips without failing the release. It renders `Resources/Homebrew/tinyprune.rb.template`, pins the Homebrew DMG release URL and SHA-256, and opens `release/vX.Y.Z` as a PR. The cask installs the app and bundled CLI, requires Sonoma or newer, unloads `com.navig-me.tinyprune.agent`, disables Finder plugin `com.navig-me.tinyprune.finder`, and zaps TinyPrune Application Support and preference files. Zap deletes local configuration: users should export rules first.

Only metadata-marked **unsigned** builds get a postflight that plainly warns about lack of notarization and removes quarantine from the installed app. Signed casks never clear quarantine. Check that policy change explicitly in PR review; the checksum and metadata are delivered together through the protected release.

The template intentionally retains the requested `depends_on macos: ">= :sonoma"` spelling and unsigned `postflight` block. Current Homebrew `brew style` recommends `macos: :sonoma` and the newer `postflight_steps` DSL; these are style/deprecation recommendations, not Ruby syntax failures. No source-level linter suppressions are shipped. Revisit them together with a deliberate cask policy update, rather than silently changing the requested distribution contract.

The clean `macos-15` verification job installs from the **PR branch** (not tap `main`), checks the distribution Info.plist, and runs `tinyprune status --json`. Exit 69 with `{\"schemaVersion\":1,\"status\":\"unavailable\"}` is acceptable on a fresh machine without a registered agent; it proves the CLI runs, not agent integration. No auto-merge is configured. To reproduce on a clean Mac:

```sh
brew tap tinyprune/tap
git -C \"$(brew --repo tinyprune/tap)\" fetch origin release/vX.Y.Z
git -C \"$(brew --repo tinyprune/tap)\" checkout --detach FETCH_HEAD
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask tinyprune/tap/tinyprune
tinyprune status --json
# Exit 0 (available) or 69 with unavailable-agent JSON is expected.
```

Local unsigned cask smoke (2026-10-02): the checksum-verified `TinyPrune-0.0.1-homebrew.dmg` installed through the current rendered template and a trusted local HTTP tap using isolated native-arm64 Homebrew: `brew install --debug --verbose --cask --appdir="$F/apps" local/tinyprune-smoke-20261002/tinyprune`. Homebrew exited 0 and linked the CLI; deep/strict signature verification passed, `TinyPruneDistribution=homebrew`, `SUEnableAutomaticChecks=false`, and both bundled/linked CLI status commands returned exit 69 with unavailable-agent JSON. The unsigned postflight removed propagated quarantine. This host required manually detaching the fixture DMG and terminating its stuck `diskutil eject` child before Homebrew continued; this is not proof of an unattended clean-host install. No public tap, Developer ID/notarization, running agent, Finder activation, or uninstall hooks were exercised. The isolated fixture was removed without touching user app data or `/Applications`.

`TINYPRUNE_DISTRIBUTION=direct|homebrew` defaults to `direct`. The packager embeds Sparkle with preserved symlinks, signs all helpers inside-out and the app last, and writes feed/key/channel settings **before signing**. `TinyPruneUpdatesEnabled` and automatic checks are true only for Developer ID direct builds with a configured public key. Homebrew never constructs the updater, including manual checks, even if old Sparkle preferences enable checks; `brew upgrade --cask tinyprune` is its sole updater. Development previews likewise never construct it. The native application menu's **Check for Updates…** explains unavailability instead of silently doing nothing. Automatic installations are disallowed; signed direct builds offer automatic checks and standard native release notes/install UI. `verify-signing.sh` enforces component isolation, embedded helpers and distribution/security settings. Only ad-hoc app packaging disables library validation to load the linked framework; release packaging retains library validation.

Before Sparkle offers a downloadable update, the application acquires an exclusive cross-process installation gate. An in-flight Trash operation holds a shared permit through preflight, move and audit; the update is refused, not allowed to interrupt it. A durable marker inhibits new agent Trash executions after the old app exits. A skipped/dismissed pre-download update releases the gate; retained downloads or installs keep it (Sparkle bypasses the initial delegate gate on resumes). The original app can safely resume a pending updater with the gate held. Only a launch matching the marker's different target **CFBundleVersion** clears successful replacement; an ordinary old-app launch, crash or timeout never silently resumes pruning. **Update Safety Status…** explains the inhibition and manual installation recovery when resuming fails. Do not manually delete the marker while an installer may still be running.

On successful target-version recovery, TinyPrune unregisters and re-registers its bundled LaunchAgent **only when that agent was already enabled**, while the installation gate remains exclusively held and the marker is intact. This avoids leaving the prior agent executable running after bundle replacement and does not enable a previously disabled agent. A registration error retains the marker and shows the recovery reason instead of reopening pruning; macOS may require renewed background-item approval.

Update-blocked due deadlines remain in SQLite. The scheduler sleeps until a kernel filesystem event observes coordination-directory changes, then reruns full safety preflight; it neither consumes blocked deadlines nor polls the tree. Scheduler shutdown drains its in-flight worker. See ADR 0006 for marker persistence, lock-release/removal ordering and fail-closed recovery.

Recovery and pending-update resume require the running app's actual Developer ID signature before consulting version-based recovery. Development/ad-hoc copies may display the pending safety status but never clear or resume its marker, even if their bundle version matches the target. A signed target may recover completed installation before applying Homebrew or missing-feed-key restrictions; successful recovery does not enable that copy's in-app updater.

### Maintainer release checklist

1. Protect `main`, tags and all four Environments (`release`, `update-feed`, `homebrew`, `cloudflare-pages-production`), require reviewers, and populate only real environment credentials. All six Apple secrets or none; optional channels may remain unset.
2. Create an immutable `vX.Y.Z` tag. Dispatch `release.yml` with `publish=false` for artifact review; use explicit `signed` when notarization is mandatory. Inspect selected mode, universal binaries, dev/release verifier results and both DMGs.
3. Publish via tag push or dispatch with `publish=true`. Without Apple credentials, confirm GitHub **prerelease** status and Gatekeeper warnings/approval instructions. Download and verify both SHA-256 sidecars.
4. Review the Homebrew PR and clean-macOS CLI proof, then merge under tap policy. Confirm only unsigned casks clear quarantine and the bundle disables Sparkle checks.
5. For signed releases with an update key, review the appcast PR, retained older entries, direct enclosure and release notes. Merge, approve Pages deploy, then dispatch `verify_public=true`; require passing public URL/length/EdDSA verification.
6. Previews always require manual installation/update. Before advertising signed direct updates, exercise a genuine older/newer Developer ID signed and notarized pair against a signed test feed: native check, no-update, download failure/tampering, dismissal/skip, pending resume, install-on-quit, relaunch, interrupted install, and collision with a disposable fixture Trash operation. Missing Apple/key credentials block this production proof; ad-hoc launch alone is not evidence. Test first-open, Finder and login-item approval on actual macOS 15/26 before widening distribution.

Local universal smoke: `TINYPRUNE_UNIVERSAL=1 swift Scripts/package-app.swift && Scripts/verify-signing.sh .build/package/TinyPrune.app`. Repeat with `TINYPRUNE_DISTRIBUTION=homebrew` for the package-manager channel. Universal ad-hoc builds work with this host's Command Line Tools; Developer ID signing and notarization still require real Apple credentials.

### Native acceptance and clean-install verification

`ci.yml` runs on disposable `macos-15` arm64 and `macos-15-intel` GitHub-hosted runners. It runs the Swift Testing suite, real filesystem fixtures, native view/lifecycle smoke, both packaging channels and `Scripts/smoke-homebrew.py`. The latter serves the actual Homebrew bundle in a local DMG, uses the release renderer for a checksum-pinned local tap, and performs a real unattended cask installation. It verifies the installed seal, channel settings, linked/bundled CLI and unsigned quarantine postflight, then removes its own receipt/app/link/tap without zap. It refuses non-hosted runners or existing TinyPrune state. It intentionally never registers an agent, enables Finder or claims Gatekeeper acceptance. Logs and native render PNGs are uploaded as acceptance artifacts.

The local eject problem was separately reproduced with a plain disposable HFS+ DMG outside Homebrew/TinyPrune; `diskutil eject` stalled, while detaching that owned fixture with `hdiutil` succeeded. Do not add a cask retry or describe the assisted local install as unattended proof. A passing fresh-runner install provides a separate environmental check.

For actual GUI acceptance, use a disposable macOS account/VM with no existing TinyPrune rules:

1. Install/open the verified app, approve its background item and enable the Finder extension in System Settings. Choose only a disposable fixture folder; do not grant Full Disk Access.
2. Complete onboarding with a Preview rule. Inspect Why; set Keep on one fixture item. Activate a rule with a different due item and verify only that item reaches Trash and appears in Activity. Restart and revoke/restore fixture-folder access; verify preserved Keep and actionable error/recovery.
3. In Finder, exercise single-file presets, Keep, Inherit and Why, and folder protection/lifetime/rule handoffs. Verify Custom/folder/rule handoffs disable for multi-selection, while supported multi-item actions retain the menu's original selection. Add/remove a managed root and verify monitoring refreshes without restarting the extension.
4. Use full keyboard navigation and VoiceOver: native Upcoming row activation, inspector Escape, editor initial name focus, Return/Escape sheets, reading/focus order, copyable exact paths, light/dark/Increase Contrast, system accessibility text size and Reduce Motion. Offscreen rendered PNGs and AppKit label checks cannot replace this step.
5. Record actual macOS version, architecture, standard-user permission state, app version and outcomes. Automation needs user-approved Accessibility and applicable Automation permissions for its actual host; never bypass TCC or infer a grant from another process.

