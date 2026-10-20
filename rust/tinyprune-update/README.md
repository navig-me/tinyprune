# tinyprune-update (unreleased)

Updater for the Rust runtime on Linux and Windows. macOS keeps Sparkle ([ADR 0009](../../ADRs/0009-eddsa-only-updates-for-adhoc-builds.md)) and is not touched. Design, threat model and key policy: [ADR 0012](../../ADRs/0012-rust-runtime-signed-updates.md). **Unreleased**: no Linux or Windows build, production feed or production signing key exists. Nothing here is a public support claim.

## What it does

- Fetches a signed JSON feed (`rust-update-feed.json` + detached `.sig`) over HTTPS from a **pinned constant URL**, verifies the Ed25519 signature over the exact bytes **before parsing**, parses strictly, and picks the newest build for this `<os>-<arch>`.
- Orders by monotonic **build number**; refuses downgrades, same-build-different-content, and a replayed older feed (the highest verified build is persisted).
- Streams the archive into a private temp file with a size cap and incremental SHA-256 (against the signed feed), extracts it with a hardened extractor, **runs the staged binaries** (`--version`, `tinyprune update self-check`), then swaps an atomic `current` pointer under the Trash/update interlock, restarts the service and health-checks it. A failed restart/health check rolls back to the previous build.
- Never installs automatically. `check` only reports; `install --confirm <token>` installs the exact offer the user saw.
- No telemetry: two plain `GET`s (feed and its `.sig`), constant `User-Agent`, no identifiers, no query string.

## Where it runs (not in the agent)

The agent's unit allows `AF_UNIX` only, so the updater is **not** linked into it. `tinyprune-update` has a dependency-free `interlock` module (always built) that the daemon and agent embed (`default-features = false`), and a `client` feature (default) with everything that needs HTTP/TLS, crypto, archives and processes: the `tinyprune update` command (hosted by `tinyprune-cli`), `tinyprune-launcher` and `tinyprune-feed`. Build the agent and the CLI in separate `cargo` invocations (as `rust-artifacts.yml` does) so the agent is not compiled with the client features.

## Command surface

```text
tinyprune update status   [--json]
tinyprune update check    [--json] [--auto]            --auto: only if checkForNewVersions is on and 24h passed; silent otherwise
tinyprune update install  [--json] [--confirm TOKEN]   without --confirm: shows the offer, installs nothing
tinyprune update settings [--json] [--check-for-new-versions on|off]
tinyprune update self-check --expect-version V --expect-build N        (run by the updater on a staged build)
```

`--json` output has `schemaVersion: 1` and a `status`. Exit codes: 0 ok; 64 usage; 65 feed/package/confirmation rejected; 69 network unavailable; 70 install failed, `rolledBack` or `rollbackFailed`; 75 `busy` (a Trash operation is in flight or another update holds the lease); 78 `disabled` (see below). `checkForNewVersions` follows the Swift semantics (default on; automatic check only) and is stored in `<root>/update/state.json`, not in the agent.

Updates are **disabled** (exit 78) for a copy that: embeds no key (`TINYPRUNE_UPDATE_PUBLIC_KEY`), has no build number (`TINYPRUNE_BUILD`), runs on macOS, or does not live under `<root>/versions/` (package-manager, Homebrew-style or hand-copied installs are never replaced).

## Layout and platforms

```text
<root>/versions/<version>-b<build>/{bin,share,VERSION}
<root>/current          Linux: relative symlink -> versions/<name>;  Windows: text file naming the directory
<root>/update/state.json
```

`<root>` is `${XDG_DATA_HOME:-~/.local/share}/tinyprune` or `%LOCALAPPDATA%\TinyPrune`. Created by `packaging/linux/install-managed.sh` (symlink shims in `~/.local/bin`, unit `ExecStart` through `current/bin`) or `packaging/windows/install-managed.ps1` (per-user Scheduled Task running `tinyprune-launcher`, which resolves `current`). Windows stages side by side because a running exe cannot be replaced; only the pointer file is swapped. The previous build is kept; older ones are pruned best effort.

## Trash/update interlock

`interlock::Interlock` is held by the agent engine: every Trash takes a `TrashGuard` before its safety re-check and holds it until after the move. `QuiesceForUpdate{token,target,leaseSeconds}` blocks new Trash immediately, never cancels one in flight (`draining` until it finishes, then `quiesced`), refuses a second updater, expires by itself, and fails closed on a poisoned lock. IPC: `QuiesceForUpdate`, `ReleaseUpdateQuiesce`, `LoadUpdateStatus` -> `UpdateStatus{phase,target,trashInFlight,leaseRemainingSeconds}` (see [tinyprune-ipc](../tinyprune-ipc/README.md)).

## Release tooling

`tinyprune-feed generate|verify` (CI). Production signing is done by Sparkle's `sign_update` in the protected `update-feed` Environment ([`rust-update-feed.yml`](../../.github/workflows/rust-update-feed.yml)); `test-keygen`/`test-sign` exist only under `--features test-overrides` for throwaway test keys.

## Features

| Feature | Meaning |
| --- | --- |
| `client` (default) | everything except the interlock |
| `test-overrides` | NEVER for release artifacts: runtime `TINYPRUNE_UPDATE_FEED_URL`, loopback `http://` feeds, test signing in `tinyprune-feed`. `tinyprune-cli` forwards it as `update-test-overrides` |

## Dependencies (each has a concrete need)

`ureq` 3 + `rustls` (sync HTTPS, no async runtime; `reqwest` would add tokio/hyper), `ring` (Ed25519 + SHA-256; already required by rustls), `base64` (already in the TLS tree), `flate2` + `tar` (no `xattr`) + `zip` (deflate only) for extraction, `serde`/`serde_json`.

## Tests

```sh
cd rust
cargo test --locked -p tinyprune-update
cargo test --locked -p tinyprune-daemon --test update_interlock     # real daemon: quiesced agent does not Trash
cargo clippy --locked -p tinyprune-update --all-targets -- -D warnings
rust/tests-e2e/update-docker.sh                                      # Docker: real systemd, real binaries, throwaway key
```

Unit tests inject a scripted `Transport` and fixed throwaway test keys and cover: valid update; bad signature; tampered feed; hash mismatch; truncated, dropped and oversize downloads; replayed feed; downgrade and build reuse; unsupported platform; hostile archives; install blocked while a Trash is in flight and Trash blocked while quiescing (real `Interlock`); atomic swap and rollback on failed self-check, failed restart and failed health check on real temp directories; Windows swap logic against an in-memory filesystem with Windows semantics (locked running directory, no overwrite).

## Not verified

- The Windows install swap, Scheduled Task restart and `tinyprune-launcher` spawn path have **never run on Windows**; `install-managed.ps1` was not parsed or run. Only the swap logic is unit-tested (in-memory fake).
- Real `systemd` is exercised only by the Docker end-to-end; there is no GitHub CI result for it.
- No production key, production feed, deployed site or GitHub workflow run exists. Sparkle `sign_update` interoperability is by signature format (checked against RFC 8032 vectors and ring), not against a run of the real tool with a real exported key.
- macOS: `rename(2)` over a symlink is not atomic for concurrent readers on APFS (observed `EINVAL`); the updater does not target macOS.
- Residual interlock race: the lease is verified right before the swap, not held across the service restart (ADR 0012).
