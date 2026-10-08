# ADR 0005: Interim unsigned preview distribution

Status: Accepted (interim); update-channel restrictions superseded by [ADR 0009](0009-eddsa-only-updates-for-adhoc-builds.md).

## Context

TinyPrune has no configured production Apple Developer ID certificate. Maintainers need a real downloadable universal DMG without pretending that an ad-hoc signature is Developer ID trust or notarization. The original preview policy disabled Sparkle; ADR 0009 now permits EdDSA-authenticated updates for key-enabled ad-hoc direct builds. ADR 0004 remains the Developer ID signing contract.

## Decision

- Keep `release.yml` as one entry point. No Apple secrets means an explicitly ad-hoc signed, non-notarized **GitHub prerelease**. All six secrets means the existing Developer ID/notarized path. Partial credentials or an explicit mode that cannot be satisfied fails. Signing/notary errors never trigger fallback.
- Build universal macOS apps on an Xcode-equipped macOS runner. Sign with `TINYPRUNE_SIGN_IDENTITY=-` and run `verify-signing.sh` in development mode for previews, package with `hdiutil`, and publish immutable DMGs with SHA-256 sidecars and signing-mode metadata.
- Publish two distinct artifacts: direct and Homebrew. Homebrew sets `TinyPruneDistribution=homebrew` and `SUEnableAutomaticChecks=false` before signing; direct defaults to `direct`. Both share version/build. The cask is its sole updater. No Homebrew artifact enters a Sparkle appcast.
- Under ADR 0009, key-enabled ad-hoc direct releases may enter the stable Sparkle feed, including GitHub prereleases. Direct feeds require the app's corresponding Ed25519 public key and separately protected private key. Pinned/checksummed Sparkle 2.9 tools sign enclosures, release notes and final XML into a reviewed website PR. After merge and successful Pages deploy, a separate dispatch verifies feed/notes signatures and the enclosure against the app's embedded public key. No direct writes bypass protected `main`.
- Homebrew updates go through a reviewed tap PR and a clean-macOS install/CLI smoke against that PR branch. Only metadata-marked unsigned builds warn and clear quarantine in postflight; signed builds never do so.
- Missing optional channel secrets skip clearly rather than failing an otherwise valid release. Signing keys and cross-repository tokens belong exclusively to reviewer-protected GitHub Environments, never pull-request jobs or shell arguments containing interpolated secrets.

## What preview users see

Gatekeeper may say Apple cannot check the app for malicious software or that the developer cannot be verified. A checksum detects artifact corruption against the published reference; it does not establish Apple trust. On macOS 15 Sequoia and macOS 26 Tahoe, copy to `/Applications`, attempt launch once, dismiss the alert, then go to **System Settings > Privacy & Security > Open Anyway**, confirm Open and authenticate if requested. Control-click Open is not a replacement on these versions. If users deliberately trust the release and that approval is unavailable, release notes provide the exact opt-in fallback:

```sh
xattr -dr com.apple.quarantine /Applications/TinyPrune.app
```

Removing quarantine is a local trust decision, not notarization. Finder extension and launch-at-login may need approval in **System Settings > General > Login Items & Extensions**; unsigned extension/login-item activation is not guaranteed on every Mac. Ad-hoc signatures have no Developer ID Team ID and do not promise bookmark continuity across rebuilt binaries. Do not silently rewrite or claim preservation of existing managed-folder access after signing changes; users may need to re-add folders.

## Update availability

Key-enabled direct previews now use Sparkle's EdDSA-only channel under ADR 0009; they are still not notarized or Apple-verified. Direct copies without a key use ReleaseNotifier and manual download, while Homebrew copies use ReleaseNotifier and `brew upgrade --cask tinyprune`; neither constructs Sparkle. Automatic checks follow Check for new versions (on by default), and installs are user-confirmed, never automatic. Clean CI CLI launch proof does not prove agent registration, Finder activation, login-item approval, real-device Gatekeeper behavior or end-to-end update installation.

## Transition to Developer ID

For Apple-verified distribution, obtain the Apple Developer Program account, Developer ID Application certificate/private key and App Store Connect notary API credentials, populate all six `release` Environment secrets, and run an explicit `signed` dry run. Require successful Team ID/signature, app and DMG notarization, stapling and Gatekeeper checks plus real macOS 15/26 installation/extension/login-item checks. Keep that Developer ID team stable for bookmark continuity. Apple credentials are not a prerequisite for the EdDSA-only direct update channel.

Only claim proven direct update installation after exercising a real older/newer pair with matching key configuration, the Trash interlock and public appcast verification (ADR 0009). Retain immutable prior artifacts and feed entries; rollback is a new higher-version/build release, never asset replacement or silent downgrade. Homebrew never constructs Sparkle. Environment setup and the full maintainer checklist live in `.github/DEPLOYMENT.md`.
