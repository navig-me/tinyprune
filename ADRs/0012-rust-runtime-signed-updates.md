# ADR 0012: Signed, user-confirmed updates for the Rust runtime (Linux and Windows)

Status: Accepted as design and implementation. Unreleased: the Rust runtime ships on no OS ([ADR 0010](0010-cross-platform-core-and-golden-fixtures.md), [ADR 0011](0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md)), no production feed exists, no production key has been used with this code, and the Windows install swap has never run on Windows. Nothing here is a public Linux or Windows support claim.

## Context

macOS direct builds update through Sparkle with an Ed25519-authenticated feed ([ADR 0009](0009-eddsa-only-updates-for-adhoc-builds.md)) and an update/Trash interlock ([ADR 0006](0006-update-installation-interlock.md)). Sparkle is macOS-only, so the Rust runtime needs its own updater before any Linux/Windows build can be released. The macOS app keeps Sparkle unchanged; nothing in this ADR touches the Swift sources.

## Threat model

Assets: the user's files (the agent can move anything the user owns to Trash), the user's account (an update is code execution as the user), and the Trash/Keep guarantees.

In scope (defended):

| Attacker | Capability | Defense |
| --- | --- | --- |
| Network (on-path, hostile Wi-Fi, malicious proxy/CDN) | Read/modify/replay HTTP | HTTPS only with a constant feed URL; feed and artifacts authenticated independently of TLS by an Ed25519 signature and SHA-256, so TLS compromise alone cannot install code |
| Compromised mirror/hosting of feed or artifacts | Serve any bytes | Signature over the feed; feed carries the artifact SHA-256 and size; mismatch deletes the download |
| Feed rollback / replay of an old validly signed feed | Serve an older feed to hide a fix or force an old build | Monotonic build numbers; a build lower than the installed one is refused; a feed whose newest build is below the highest build ever verified on this machine is refused (`maxFeedBuildSeen`) |
| Malicious or buggy archive | Path traversal, links, bombs | Hardened extraction (no `..`/absolute/backslash/`:` names, no links or special files, one top-level dir, entry/size caps, bounded decompression), hard 256 MiB artifact ceiling regardless of what a signed feed claims |
| Local race with the agent | Replace binaries or restart mid-Trash | Interlock below; fail closed |
| Bad release (signed but broken) | New build does not start | Self-check of the staged build before the swap; post-restart health check; automatic rollback; previous build retained |
| Surprise installs | Update runs without the user | Install is a separate command that requires a confirmation token from a check the user read; checks never install |
| Privacy | Updater as telemetry | Plain `GET` of two static URLs (feed and its `.sig`) with a constant `User-Agent`; no version, platform, identifier, cookie, query string or body is sent; no proxy-side state; automatic check at most once per 24 h and only while `checkForNewVersions` is on |

Out of scope / residual risk (stated, not solved):

- Compromise or loss of the signing key. See key policy below; the Rust runtime inherits the ADR 0009 position exactly.
- A user-level attacker who can already write to `~/.local/share/tinyprune` or run as the user can run arbitrary code regardless of any updater.
- A network attacker can **withhold** updates (freeze attack). There is no signed expiry; users keep running a working older build. Adding a signed `expires` would force re-signing on a schedule and was rejected for now.
- Malware already running as the user can call `tinyprune update install --confirm <token>` itself; the token binds a confirmation to a specific offer, it is not a secret and not an authenticated human gesture.
- Windows code signing / SmartScreen and Linux distro signing are not provided. EdDSA is not OS-vendor trust.

## Decision

### Keys: reuse the ADR 0009 Ed25519 key

Reuse the existing Sparkle Ed25519 key and its custody, loss, rotation and compromise policy (ADR 0009 "Key custody, loss and rotation") unchanged. It is compatible: a Sparkle `sign_update -p <file>` signature is a plain RFC 8032 Ed25519 signature over the exact file bytes, base64 encoded, and the public key is a base64 32-byte key. The Rust updater verifies that byte format (`ring`), so the production workflow signs the feed with the same `sign_update` and the same stdin private-key handling as `publish-update-feed.yml`; no second key to custody, back up, rotate or lose. Cost accepted: one key compromise forges both channels, which was already true across Sparkle feed/notes/DMG. A separate Rust key would double custody burden for no change in the trust root's blast radius (the same maintainers and Environment hold it).

The public key is embedded at compile time (`TINYPRUNE_UPDATE_PUBLIC_KEY`). A build without it, without a build number (`TINYPRUNE_BUILD`), or outside a managed install directory has updates disabled, mirroring the Swift "no key => disabled" rule. Rotation uses the ADR 0009 transition procedure: a release authenticated by the old key embeds the new public key. Domain separation is in-band (`format: tinyprune-rust-update-v1`), not a signed prefix, to stay byte-compatible with `sign_update`; a signature over this JSON can be confused with no appcast, DMG or release note because those are different, structurally incompatible documents.

### Feed: signed JSON manifest, not the appcast

A custom JSON document `rust-update-feed.json` plus detached `rust-update-feed.json.sig`, published beside the Sparkle feed on the project site (`https://tinyprune.com/updates/rust/`). The appcast was rejected: it is XML with Sparkle-specific semantics (EdDSA-signed enclosure per DMG, `sparkle:version`, delta and OS-version rules), would force an XML parser into a security-sensitive path, and its enclosure signature is over a whole artifact that the client would have to buffer or hash twice. The manifest records each artifact's SHA-256 and size, is verified over its exact bytes **before** it is parsed, and is parsed strictly (format, versions, builds, hex digests, HTTPS URLs, sizes, path-safe version strings). One signature over the manifest authenticates all artifacts through their hashes; downloads stream into a size-capped temp file hashed incrementally, so no whole-artifact buffering and no per-artifact signature is needed.

### Artifacts and platforms

Linux: the existing `tinyprune-dev-<ver>-linux-<arch>.tar.gz` (user scope). Windows: the existing `.zip`. The feed key is `<os>-<arch>` (`linux-x86_64`, `windows-x86_64`). macOS and any OS/arch without an entry get `unsupported`, never a guess. Archives are extracted by the updater itself (no shelling out to `tar`/`unzip`).

### Ordering and rollback protection

The **build number** (monotonic, from the producing workflow's run number, as in ADR 0009) is the authoritative order; the semantic version is display plus a second guard: an offer is acceptable only if build is greater **and** version is not lower. Lower build, lower version, or the same build with different content are refused. The newest build in a verified feed is persisted; a later feed that tops out below it is refused. A genuine rollback is a new higher build. The previous *installed* build is kept on disk for automatic rollback after a failed health check, which is a local recovery, not an update from the network.

### Transport

HTTPS only, `rustls` (ring) with the bundled Mozilla roots, at most three redirects each of which must also be HTTPS, connect/response/global timeouts, 256 KiB feed cap, 1 KiB signature cap. The feed URL is a constant in the binary. No runtime override exists in released builds. A cargo feature `test-overrides` (never enabled for release artifacts) allows a runtime feed URL and loopback `http://` so the Docker end-to-end test can use a local server.

Dependency justification (AGENTS.md: dependencies need a concrete gap): `ureq` 3 with `rustls` is a synchronous client, so no async runtime enters the CLI; `reqwest` (blocking) drags in tokio and hyper for one GET. `ring` supplies both Ed25519 verification and SHA-256 and is **already required by rustls**, so it adds no second crypto stack (`ed25519-dalek` + `sha2` would). `flate2` (pure Rust backend), `tar` (without `xattr`) and `zip` (deflate only) extract the archives. `base64` is already in the TLS dependency tree.

### Where the code runs: not in the agent

The agent's systemd unit allows only `AF_UNIX` (`RestrictAddressFamilies=AF_UNIX`) and the agent is meant to need no network ([AGENTS.md](../AGENTS.md)): linking a TLS client into it would widen its attack surface for no benefit. Therefore the check, download and install run in the user's `tinyprune` CLI (and in whatever the UI shells out to); the agent only gains the Trash/update **interlock**. The requested "CheckForUpdate/InstallUpdate" IPC operations are consequently **not** agent RPCs: `tinyprune update check|install` is the API, with `--json` output for the UI. The IPC additions are the interlock operations `QuiesceForUpdate`, `ReleaseUpdateQuiesce` and `LoadUpdateStatus` / `UpdateStatus`.

### Settings

`checkForNewVersions` mirrors the Swift semantics: absent means **on**, controls only the automatic **check**, is read at use time, and never installs. It lives in the client-owned `update/state.json` under the install root (`tinyprune update settings --check-for-new-versions on|off`), not in the agent's policy database, because the agent never checks. `tinyprune update check --auto` is the hook for the UI/timers: it exits silently unless the setting is on and 24 h have passed.

### Confirmation

`tinyprune update install` without `--confirm` prints the offer and installs nothing. `--confirm <token>` re-fetches and re-verifies the signed feed and proceeds only if the token matches the offer **now** (token = truncated SHA-256 over platform, version, build, artifact hash and URL). The UI shows the offer from `check --json`, and on the user's click runs `install --confirm <token>`.

### Install layout and swap

```text
<root>/versions/<version>-b<build>/{bin,share,VERSION}
<root>/current                       Linux: relative symlink; Windows: text file naming the version dir
<root>/update/state.json             setting, last check, highest feed build seen, rollback target
```

`<root>` is `${XDG_DATA_HOME:-~/.local/share}/tinyprune` on Linux and `%LOCALAPPDATA%\TinyPrune` on Windows. The service executes `<root>/current/bin/...` (Linux unit and `~/.local/bin` shims) or `tinyprune-launcher` (Windows Scheduled Task), so an update is one atomic pointer rename. A binary outside `<root>/versions/` (a package-manager, Homebrew-style or hand-copied install) is **never** updated: updates report `disabled` and say to use the owning tool. Windows cannot overwrite or delete a running executable, so the new build is always staged side by side and only the pointer moves; removal of an old, still-running directory is best effort. Linux retains the previous build; everything older is pruned.

Sequence: download (size cap, SHA-256) -> extract into `versions/.stage-*` -> run the staged `tinyprune --version`, `tinyprune-agentd --version` and `tinyprune update self-check` (the new build must be able to verify the *next* update) -> move into place -> quiesce -> verify lease -> swap pointer -> restart -> health check. A failed restart or health check repoints to the previous build and restarts it; a failure of that too is reported as `rollbackFailed` with the exact state, never silent. Restart is `systemctl --user restart tinyprune-agentd.service` when the unit is active (Linux) or ending/starting the per-user Scheduled Task (Windows); an agent running outside those is reported `manualRestartRequired` while Trash is released.

### Trash/update interlock (fail closed)

The agent embeds an in-memory `Interlock` (dependency-free module of the update crate). Every Trash operation takes a guard before its policy re-check and holds it until after the filesystem move and audit; `acquire_trash_permit` returns "installation pending" while an update lease exists, which the existing coordinator records as a safety skip and a transient block (the deadline is retained, exactly as in ADR 0006). `QuiesceForUpdate{token,target,lease}` installs a time-limited lease: new Trash is blocked immediately, in-flight Trash is **never cancelled** and the state is `draining` until it finishes, then `quiesced`. The updater swaps and restarts only in `quiesced`, re-verifies the remaining lease immediately before the swap, and gives up (releasing the lease) after a drain timeout. The updater refuses to proceed if the agent is reachable but unsupported, busy or erroring; only "no agent listening" proceeds. Only the token holder can release. A lease expires by itself so a dead updater cannot leave pruning stopped; a poisoned lock blocks Trash. The state is deliberately not durable (unlike ADR 0006's marker): the restart that completes an update replaces the process, and the pointer swap is atomic, so a crashed updater can leave only an old-or-new, never a half-installed, build. Residual race: the lease is checked immediately before the swap, not held across `systemctl restart`; a lease that expires in those milliseconds could let Trash start before the old process is stopped. A mid-move process kill has not been shown crash-safe for either Trash adapter. This window is an accepted, unverified risk. The pre-existing Swift interlock is unchanged.

## Release workflow and key handling

`.github/workflows/rust-update-feed.yml` is manual (`workflow_dispatch`), runs only from `main`, and uses the protected **`update-feed`** Environment for the signing job, with the same custody rules as ADR 0009: `SPARKLE_ED25519_PRIVATE_KEY` is an Environment secret, passed to Sparkle's pinned `sign_update` on stdin only; `SPARKLE_ED25519_PUBLIC_KEY` is the non-secret Environment variable. No signing runs in pull-request builds. A no-secret job prepares and self-checks the archives from a `rust-artifacts.yml` run; the signing job generates and signs the manifest, **verifies the signature with both Sparkle's tool and the Rust verifier**, checks the key embedded in the binaries equals the Environment's public key, then opens a review PR adding the feed and signature and attaches the archives to a pre-created release without overwriting anything. A separate dispatch verifies the deployed public feed and artifacts after Pages deploys.

## Consequences and not-verified

- Unit tests with injected transport and fixed throwaway test keys cover valid update, bad signature, tampered feed, hash mismatch, truncated and oversize downloads, replayed feed, downgrade, unsupported platform, hostile archives, interlock (install blocked during in-flight Trash; Trash blocked while quiescing), atomic swap and rollback on failed self-check and health on real temp directories, and the Windows swap logic against an in-memory filesystem with Windows semantics.
- A Docker Linux end-to-end serves a locally signed feed, installs an older build, updates it to a newer build and checks the version changed and Keep/state survived.
- A `windows-2022` end-to-end (`rust/tests-e2e/update-windows.ps1`, CI job `windows-update-e2e`; passed in workflow run 39550764775) installs build 1 with `install-managed.ps1`, serves a throwaway-key-signed feed from a loopback server, updates to build 2 through the real Scheduled Task and `tinyprune-launcher`, and checks state survival, tamper/replay refusal, rollback of a bad build, refusal of a build whose `--version` fails, and Trash blocked while quiesced.
- **Not verified**: a logon/reboot trigger of the Windows task, non-administrator or other Windows editions, the Windows UI path; real `systemd` on GitHub (only the local Docker end-to-end); any production key, production feed or deployed site; Sparkle-key interoperability with a real exported private key (the signature *format* is the Sparkle `sign_update` format, checked against an RFC 8032 vector, not against a real `sign_update` run); no UI integration beyond the documented CLI contract.
- Until a release exists, nothing may describe Linux or Windows as supported or updatable.

References: [ADR 0006](0006-update-installation-interlock.md), [ADR 0009](0009-eddsa-only-updates-for-adhoc-builds.md), [ADR 0010](0010-cross-platform-core-and-golden-fixtures.md), [ADR 0011](0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md), [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032), [rust/tinyprune-update](../rust/tinyprune-update/README.md).
