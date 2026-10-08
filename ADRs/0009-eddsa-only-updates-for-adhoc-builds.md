# ADR 0009: EdDSA-only updates for ad-hoc direct builds

Status: Accepted; end-to-end installation acceptance remains unverified.

## Context

TinyPrune has no Apple Developer account or production Developer ID/notary credentials. An ad-hoc code signature seals a bundle but does not establish an Apple-verified publisher. Sparkle can authenticate updates using an independently provisioned Ed25519 key. Requiring Developer ID for every direct update unnecessarily prevented this channel and its pending-install recovery from working without Apple credentials.

This decision supersedes ADR 0005's exclusion of all unsigned previews from Sparkle and ADR 0006's Developer-ID-only updater/recovery restriction. ADR 0004's identifiers, entitlements and inside-out signing policy remain intact; its Developer ID/notarization requirements still apply when that release mode is selected.

## Decision

- A direct bundle with a configured valid Ed25519 public key enables Sparkle 2.9 regardless of whether it is ad-hoc or Developer ID signed. The public key is embedded before signing. Homebrew never constructs the updater; a direct bundle without a key visibly explains the disabled in-app channel and uses ReleaseNotifier/manual download instead. Malformed nonempty keys fail packaging.
- EdDSA is the authentication trust root for ad-hoc updates. Require signed final feed XML, signed release notes and signed immutable direct DMG enclosures, and verify the update before extraction. Do not turn off signature enforcement or accept a Developer ID signature as a substitute for the configured EdDSA trust root. Homebrew DMGs never enter the appcast.
- The stable appcast may carry key-enabled ad-hoc direct releases even when GitHub labels them prereleases. Apple signing mode is not update-feed eligibility. Feed publication still validates release metadata, immutable checksums and the signature against the public key actually embedded in the direct app, opens a reviewed website PR, and verifies public bytes after deployment.
- Release builds use `github.run_number` as `CFBundleVersion`, shared by direct and Homebrew artifacts. Marketing version remains the release tag's version. Sparkle ordering and the installation marker use the build number; release retries must not overwrite immutable published artifacts. New feed entries must have a build greater than retained entries; do not rename/reset the workflow counter without deliberately migrating to higher numbers. A rollback is a new higher-version/build release, not a silent downgrade.
- Automatic checks follow `checkForNewVersions`, on by default. Users can disable them in Settings. Installation is user-confirmed through Update Now and Sparkle's native dialog; automatic installation is disabled. ReleaseNotifier remains the Homebrew/no-key fallback and only offers repository release links or the Homebrew upgrade command.
- Preserve ADR 0006's cross-process installation interlock. Key-enabled ad-hoc direct source builds may resume a pending update with the exclusive gate held, and matching target builds may recover/reconcile an already-enabled bundled agent. An old/wrong target, corrupt marker or failed reconciliation never silently resumes pruning. Homebrew and no-key copies cannot clear or resume the marker, regardless of signing mode. This eligibility does not bypass EdDSA update verification.

## Key custody, loss and rotation

The existing public key is nonsecret configuration in the protected `release` and `update-feed` Environments. Its private partner belongs only in the protected `update-feed` Environment and offline maintainer-controlled backup. Never commit, print or pass the private key as a command-line argument; Sparkle tools receive it on stdin.

Loss of the private key prevents signing updates trusted by already-installed copies. Creating a replacement key in CI cannot restore that trust. If the old private key is available, ship a deliberately reviewed transition update authenticated by the old key that embeds the new public key, then publish subsequent releases with the new private key. Validate the transition with Sparkle's key-rotation behavior before publishing. If the old key is lost or compromised, do not claim a seamless trusted rotation: require an out-of-band, explicitly trusted manual reinstall with the new public key and document the incident. Treat compromise as the ability to forge update authority, not as an ordinary credential refresh.

## Gatekeeper and acceptance boundary

First installation from a browser-downloaded ad-hoc DMG is unchanged: it is not notarized, may be quarantined and requires the user's explicit Gatekeeper approval/trust decision. Keep ADR 0005's Open Anyway instructions and opt-in quarantine-removal fallback. EdDSA signatures do not create Apple trust, prove benign code, guarantee Finder/login-item approval or guarantee bookmark continuity across rebuilt ad-hoc identities.

Sparkle-downloaded replacements are expected not to carry browser-download quarantine, so subsequent updates are expected not to repeat first-install Gatekeeper approval. This is an expectation, not verified end-to-end install evidence; do not remove quarantine in the updater or advertise notarization.

Before claiming proven in-app installation, exercise an actual older/newer key-enabled ad-hoc direct pair against a signed test feed: checks/no update, tampered feed/notes/DMG, download failure, dismissal/skip, retained resume, user-confirmed install, install-on-quit, interrupted installation, target relaunch, agent reconciliation and collision with an in-flight disposable Trash operation. Fixture signatures and packaging checks do not establish this acceptance. Developer ID/notarized acceptance remains separate and requires real Apple credentials.

References: [Sparkle security](https://sparkle-project.org/documentation/security-and-reliability/), [Sparkle setup](https://sparkle-project.org/documentation/), [ADR 0005](0005-unsigned-preview-distribution.md), [ADR 0006](0006-update-installation-interlock.md), [deployment setup](../.github/DEPLOYMENT.md).
