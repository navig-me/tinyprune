# ADR 0005: Interim unsigned preview distribution

Status: Accepted (interim)

## Context

TinyPrune has no configured production Apple Developer ID certificate. Maintainers need a real downloadable universal DMG without pretending that an ad-hoc signature is Developer ID trust or notarization. Sparkle is now linked only into the application, but unsigned previews never start it. ADR 0004 remains the production signing contract.

## Decision

- Keep `release.yml` as one entry point. No Apple secrets means an explicitly ad-hoc signed, non-notarized **GitHub prerelease**. All six secrets means the existing Developer ID/notarized path. Partial credentials or an explicit mode that cannot be satisfied fails. Signing/notary errors never trigger fallback.
- Build universal macOS apps on an Xcode-equipped macOS runner. Sign with `TINYPRUNE_SIGN_IDENTITY=-` and run `verify-signing.sh` in development mode for previews, package with `hdiutil`, and publish immutable DMGs with SHA-256 sidecars and signing-mode metadata.
- Publish two distinct artifacts: direct and Homebrew. Homebrew sets `TinyPruneDistribution=homebrew` and `SUEnableAutomaticChecks=false` before signing; direct defaults to `direct`. Both share version/build. The cask is its sole updater. No Homebrew artifact enters a Sparkle appcast.
- Unsigned previews never enter the stable Sparkle feed. Signed direct feeds require the app's corresponding Ed25519 public key and separately protected private key. Pinned/checksummed Sparkle 2.9 tools sign enclosures, release notes and final XML into a reviewed website PR. After merge and successful Pages deploy, a separate dispatch verifies feed/notes signatures and the enclosure against the app's embedded public key. No direct writes bypass protected `main`.
- Homebrew updates go through a reviewed tap PR and a clean-macOS install/CLI smoke against that PR branch. Only metadata-marked unsigned builds warn and clear quarantine in postflight; signed builds never do so.
- Missing optional channel secrets skip clearly rather than failing an otherwise valid release. Signing keys and cross-repository tokens belong exclusively to reviewer-protected GitHub Environments, never pull-request jobs or shell arguments containing interpolated secrets.

## What preview users see

Gatekeeper may say Apple cannot check the app for malicious software or that the developer cannot be verified. A checksum detects artifact corruption against the published reference; it does not establish Apple trust. On macOS 15 Sequoia and macOS 26 Tahoe, copy to `/Applications`, attempt launch once, dismiss the alert, then go to **System Settings > Privacy & Security > Open Anyway**, confirm Open and authenticate if requested. Control-click Open is not a replacement on these versions. If users deliberately trust the release and that approval is unavailable, release notes provide the exact opt-in fallback:

```sh
xattr -dr com.apple.quarantine /Applications/TinyPrune.app
```

Removing quarantine is a local trust decision, not notarization. Finder extension and launch-at-login may need approval in **System Settings > General > Login Items & Extensions**; unsigned extension/login-item activation is not guaranteed on every Mac. Ad-hoc signatures have no Developer ID Team ID and do not promise bookmark continuity across rebuilt binaries. Do not silently rewrite or claim preservation of existing managed-folder access after signing changes; users may need to re-add folders.

## Disabled or unsupported today

There are no in-app updates for unsigned previews: the linked Sparkle controller is never constructed. Users install newer direct previews manually, or use `brew upgrade --cask tinyprune` for the cask. The native Check for Updates command explains that policy. Preview releases are not Apple-verified production releases, and no Gatekeeper acceptance/stapled-ticket claim is made. Clean CI CLI launch proof does not prove agent registration, Finder activation, login-item approval, or real-device Gatekeeper behavior.

## Transition to Developer ID

Before stable public distribution, obtain the Apple Developer Program account, Developer ID Application certificate/private key and App Store Connect notary API credentials, populate all six `release` Environment secrets, and run an explicit `signed` dry run. Require successful Team ID/signature, app and DMG notarization, stapling and Gatekeeper checks plus real macOS 15/26 installation/extension/login-item checks. Keep that Developer ID team stable for bookmark continuity.

Only advertise automatic direct updates after Sparkle is integrated into the app (never agent/CLI/Finder extension), the EdDSA public key/feed configuration is shipped, update installation respects active Trash operations, and public appcast verification passes. Retain immutable prior artifacts and feed entries; rollback is a new higher-version release, never asset replacement or silent downgrade. Homebrew automatic Sparkle checks remain disabled permanently. Environment setup and the full maintainer checklist live in `.github/DEPLOYMENT.md`.
