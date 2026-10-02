# ADR 0004: Signing identifier and entitlement policy

Status: Accepted

## Context

TinyPrune ships four signed code units: the app (`TinyPruneApp`), the background agent (`TinyPruneAgent`), the CLI (`tinyprune`), and the Finder Sync extension (`TinyPruneFinderExtension.appex`). Two constraints shape signing:

1. Security-scoped bookmarks are created by the app and resolved by the agent (and by the CLI for `config apply`). A bookmark only resolves for a process whose code-signing identity matches the creator's, so those executables must share one team and one signing identifier.
2. A Finder Sync extension must run inside the App Sandbox. A sandboxed process cannot look up arbitrary Mach services, so it needs an explicit exception to reach the agent over XPC.

## Decision

- **Team.** All Mach-O files in the bundle are signed by the same Developer ID Application identity and therefore carry one Team ID. Release verification fails on mixed or missing Team IDs and, when `TINYPRUNE_EXPECTED_TEAM_ID` is set, on a different team.
- **Identifiers.** `TinyPruneApp`, `TinyPruneAgent`, and `tinyprune` are signed with `--identifier com.navig-me.tinyprune` (the app bundle id). Plain `codesign` would derive per-binary identifiers from the file name and break bookmark resolution. Ad-hoc development builds have no Team ID, so the identifier alone enforces the policy there.
- **Finder extension.** Signed first, with its own bundle id `com.navig-me.tinyprune.finder` and `Resources/Entitlements/FinderExtension.entitlements`: `com.apple.security.app-sandbox` and a `temporary-exception.mach-lookup.global-name` for exactly `com.navig-me.tinyprune.agent`. No network, file-access, or other entitlements. The extension holds no bookmarks and sends only paths to the agent, which owns all access.
- **App, agent, CLI.** Not sandboxed and no entitlements beyond defaults (the agent needs FSEvents, Trash, and user-selected-root bookmarks across the user's volumes). Release builds must not carry `get-task-allow`.
- **Hardened runtime and timestamp.** Every component is signed with `--options runtime`; ad-hoc builds use it too so dev mirrors release. Developer ID builds add `--timestamp` (secure timestamp), which notarization requires.
- **Sparkle isolation.** Sparkle, when added, is embedded only in the app. The agent, CLI, and extension must not link or embed it, so an update can never be applied from a process that performs Trash operations. Sparkle's own helper tools keep Sparkle's identifiers and are exempt from the identifier rule but not from the single Team ID rule.
- **Order.** appex, then agent and CLI, then the app bundle (inner to outer, no `--deep` signing). The app is notarized and stapled, then placed in a signed, notarized, stapled DMG.
- **Enforcement.** `Scripts/verify-signing.sh` encodes this policy. CI runs it in development mode on every package build; `release.yml` runs `--release --pre-notarize` after signing, `--release` after stapling, and again on the app inside the mounted DMG.

## Consequences

- Rotating the Developer ID team invalidates existing bookmarks; users would re-add managed folders. Keep one team for the product's lifetime.
- The mach-lookup exception is a temporary-exception entitlement. It is acceptable for Developer ID distribution but would need an XPC service/App Group redesign for the Mac App Store.
- Real signing, notarization, and Gatekeeper checks cannot be exercised without a Developer ID certificate and notary credentials. The verifier's release branches are exercised only against the ad-hoc package (where they correctly fail) until a certificate is available.
