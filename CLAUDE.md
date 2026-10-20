# TinyPrune contributor guide

Read `spec.md` and `PLAN.md` before changing product behavior. `spec.md` is the product contract; `PLAN.md` defines the implementation sequence and release architecture.

## Product invariants

- TinyPrune is a local-first macOS lifecycle-rule tool, not a generic cleaner.
- Normal deletion means moving an item to macOS Trash. Never introduce permanent deletion in v1.
- Re-evaluate current filesystem identity, resolved rule, Keep/protected ancestors or descendants, deadline, pause state, permissions, and volume availability immediately before a Trash operation.
- The SQLite index schedules candidates; it never grants permission to delete.
- `Keep` takes precedence over every other policy. Do not trash a folder that contains a protected descendant.
- Preview runs matching and scheduling but must never invoke the Trash executor.
- Normal operation may read filesystem metadata only. Do not inspect file contents or require network access.
- Scale with FSEvents and scheduled deadlines. Initial indexing, recovery, and a user-initiated rule Preview dry run (which is read-only, bounded, cancellable, and never persists or trashes; see ADR 0003) are the only full traversals; they must enumerate in bounded batches.
- CLI and Finder extension are clients of the agent through XPC. Do not duplicate rule evaluation or cleanup logic in frontends.
- Do not add V2 agentic features, cloud sync, telemetry, subscriptions, system optimization, or content analysis.

The cross-platform core is an in-development, unreleased engineering effort ([ADR 0010](ADRs/0010-cross-platform-core-and-golden-fixtures.md)), not a change to the macOS-only product contract. No Linux or Windows build is released. The same safety invariants apply identically to Rust: Trash only, metadata only, Keep wins, re-check immediately before Trash, and Preview never trashes.

## Architecture boundaries

- `TinyPruneDomain`: pure deterministic types, validation, rule precedence, and explanations.
- `TinyPrunePersistence`: migrations, SQLite repositories, xattr codec, and identity persistence.
- `TinyPruneEngine`: filesystem events, streaming indexing, project activity, scheduling, safety preflight, and Trash execution.
- `TinyPruneIPC`: versioned XPC contract shared by app, agent, CLI, and Finder extension.
- UI targets must not directly mutate operational state or execute cleanup.

Use stable filesystem identity `(volume UUID, resource identifier, path hint)` rather than paths alone. Persist explicit overrides in SQLite and versioned xattrs only; never write metadata to every inherited child. User-selected roots require security-scoped bookmarks. Reject dangerous roots and force Preview for very broad scopes.

## Engineering conventions

- Swift concurrency: use actors for mutable agent/store coordination. Public cross-process DTOs must be `Codable` and evolution-safe.
- Make time, filesystem access, FSEvents, and Trash execution injectable for deterministic tests. Never use production sleeps in tests.
- Every decision returned to UI/CLI must include a complete explanation: item, scheduled time, rule, basis, project context, override, and suppression reason if any.
- Audit rule mutations, overrides, scheduling decisions, preview matches, safety skips, Trash success, and failures transactionally.
- Explicitly handle renamed/replaced identities, stale bookmarks, missing files, revoked permissions, disconnected volumes, xattr/database disagreement, agent restarts, and protected descendants.
- Do not add a dependency without a concrete platform gap. Pin tool and action versions.
- Rust crate dependencies require a concrete need; commit resolved versions in `rust/Cargo.lock` and keep the toolchain pinned in `rust/rust-toolchain.toml`.

## UI direction

Use the Stitch references in `stitch_tinyprune_macos_app/` as visual direction, interpreted through native SwiftUI/AppKit controls:

- Calm desktop utility: warm stone surfaces, editorial Newsreader titles, Manrope controls/body, JetBrains Mono for paths.
- Deep plum is the primary action/selection color; green represents safe/healthy states; amber represents caution. Preserve macOS accessibility contrast and state clarity.
- Overview remains quiet: managed places and next-to-prune, with one honest reclaim ledger showing moved-to-Trash, moving-soon, and scheduled totals plus a tiny 14-day bar sparkline. No axes, filled tracks, or inflated storage KPIs; moving to Trash does not free space until Trash is emptied.
- Explain safety and reversibility without inventing guarantees beyond the actual engine behavior.
- Use Preview as the primary affordance for broad developer rules.

## Test and release requirements

- `website/` is the static landing site for `tinyprune.com`; `docs/` is the separate static site for `docs.tinyprune.com`. Keep their published-domain links absolute, validate each with its local `npm run check`, and deploy them only through `.github/workflows/deploy-pages.yml`.
- Cloudflare Pages Direct Upload credentials belong exclusively in the reviewer-protected `cloudflare-pages-production` GitHub Environment. Use an account-scoped Pages-edit API token, never a Global API key.
- Add tests for behavior and invariants, not implementation plumbing. At minimum cover precedence, glob boundaries, protection, preview, stale identity, pause/safety races, project activity noise, recovery, and failed Trash operations when modifying those paths.
- For agent behavior, run a fixture-tree smoke test that observes actual scheduling/preflight/Trash outcomes. For UI, perform a manual/automation smoke of the affected native flow.
- Direct DMG builds with a valid Ed25519 public key use Sparkle's signed feed/notes/enclosures, including ad-hoc builds without an Apple account (ADR 0009). Automatic checks follow `checkForNewVersions` (default on); Update Now/native-dialog installation is user-confirmed, never automatic. Homebrew never constructs Sparkle; Homebrew/no-key copies use ReleaseNotifier and manual download or cask upgrade.
- The unreleased Rust runtime (Linux/Windows) has its own updater, `rust/tinyprune-update` ([ADR 0012](ADRs/0012-rust-runtime-signed-updates.md)); macOS keeps Sparkle unchanged. It reuses the ADR 0009 Ed25519 key and custody policy and verifies a signed JSON feed over a pinned HTTPS URL, with SHA-256 checks, monotonic build numbers (downgrades and replayed feeds refused), a size-capped download, staged extraction, a pre-swap self-check, an atomic `current` swap and health-checked rollback. Automatic checks follow `checkForNewVersions` (default on) and send only a plain GET; installation is user-confirmed (`tinyprune update install --confirm <token>`), never automatic. Package-manager and hand-copied installs are never replaced. The updater runs in the CLI, not the agent (no network code in the agent); the agent only embeds the Trash/update interlock, which blocks new Trash, never cancels an in-flight move and fails closed. Production signing exists only in the manual `rust-update-feed.yml` in the protected `update-feed` Environment, never in pull requests. Do not claim Linux/Windows support or updatability publicly; the Windows swap, a production key/feed and any workflow run are unverified (see the crate README).
- Release workflows must use protected GitHub Environments, least-privilege permissions, immutable artifacts, increasing `github.run_number` build numbers, checksums, and a verified appcast/cask update. Developer ID mode additionally requires notarization/stapling/Gatekeeper validation. Ad-hoc first-install Gatekeeper approval is unchanged; expected non-quarantined Sparkle replacements are not end-to-end verified. Preserve the Trash/update interlock and key-enabled direct target recovery; private-key loss/rotation policy is in ADR 0009.

## Before opening a pull request

1. Update affected domain, engine, persistence, XPC, app/extension/CLI callers, tests, and user-visible documentation.
2. Run the narrow test/fixture scenario for the changed behavior, then the repository’s prescribed quality command.
3. State the exact verification command and observed result in the PR.
4. Keep scope aligned with `spec.md`; record material architecture decisions as ADRs.

## Running tests

Tests use Swift Testing. On a runner with Xcode: `swift test`. On a CommandLineTools-only Mac, SwiftPM does not wire up `Testing.framework`, so run:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
```

Add `-c release -Xswiftc -enable-testing --filter PhaseTwoBenchmarkTests` for the 100k benchmark. Also run `swift run TinyPruneDomainCheck`, `swift run TinyPruneEngineCheck`, and `swift run TinyPruneUISnapshots` (offscreen UI render and flow check).

### Rust core and shared golden fixtures

The Rust workspace lives in `rust/`:

- `tinyprune-core`: synchronous, trait-based domain decisions, config handling, pre-Trash coordination, and scheduler scan decisions with injected `Clock`, `MetadataSource`, and `ObservationStore`; no platform I/O or process hosting.
- `tinyprune-agent`: synchronous deterministic orchestration of bounded indexing, events, execution, cancellation/resume, deadline queue, per-item backoff, and restart recovery. Its 19 tests include a real Unix temporary-tree Trash move. Enumeration and per-tick event/execution budgets are bounded; watcher hints are applied incrementally (changed subtrees, their ancestors and project dependents only; `tinyprune-core/tests/incremental.rs` differentially compares them with a complete pass), while initial indexing, reconcile, overflow and any policy change evaluate the complete snapshot, whose CPU and retained metadata grow with root size. It performs no I/O itself; `tinyprune-daemon` embeds it.
- `tinyprune-unix`: FileAccess and freedesktop Trash. `tinyprune-windows`: Recycle Bin/IFileOperation access. `tinyprune-watch`: Linux inotify and Windows `ReadDirectoryChangesW` EventSources (neither executed against real OS events); macOS has none, so the daemon reconciles periodically.
- `tinyprune-store` (SQLite, `rusqlite` bundled; distinct from the Swift database), `tinyprune-scan` (bounded metadata traversal, read-only Preview dry run), `tinyprune-ipc` (length-prefixed JSON over a Unix socket or Windows named pipe; not XPC-compatible), `tinyprune-daemon` (`tinyprune-agentd`), `tinyprune-cli` (`tinyprune`).
- `tinyprune-update` (updater and Trash/update interlock, ADR 0012; the agent embeds only its dependency-free `interlock`, built with `default-features = false`; build the agent and CLI in separate `cargo` invocations so the agent does not compile the HTTP/TLS client). `rust/tests-e2e/update-docker.sh` is its Docker Linux end-to-end.
- `rust/ui`: Tauri shell and static frontend in a **separate Cargo workspace** (excluded from `rust/Cargo.toml`, own lockfile); it is an IPC client only.

All of this is unreleased and not shipped on any OS; macOS stays on the Swift implementation ([ADR 0011](ADRs/0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md)). The per-component, per-OS verification matrix and the list of what is not verified (real inotify, Windows watcher, named pipes, Linux/Windows UI, installers, performance, accessibility) are in [rust/README.md](rust/README.md#status-matrix); do not describe a component as working on an OS unless that matrix says it ran there. Platform I/O stays in adapters, not the core. The store schedules but never authorizes; every IPC mutation goes through the core validation and the store's revision compare-and-swap, and Preview must never reach a Trash executor. The additive `platform_hidden` candidate flag and explicit Windows `PathFlavor` are covered by Rust-only tests with no Swift counterpart. Default `Posix` behavior leaves the 577 shared golden cases unchanged; the config codec remains POSIX, so Windows config import/export is unsupported. POSIX rename and Windows Shell cannot atomically condition moves on identity; read the crate READMEs and [rust/README.md](rust/README.md).

From the repository root:

```sh
cd rust && cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
# Focused agent-engine checks:
cargo test --locked -p tinyprune-agent
cargo clippy --locked -p tinyprune-agent --all-targets -- -D warnings
```

The `rust-core` job in `.github/workflows/ci.yml` runs both commands on Ubuntu, Windows, and macOS, then builds release `tinyprune-agentd`/`tinyprune` and runs the end-to-end smoke (`rust/tests-e2e/smoke.sh`, `smoke.ps1` on Windows) and a non-gating benchmark. Despite its “Golden fixtures” step name, `cargo test --locked` runs the workspace's target-applicable tests, including the newer crates. Configured CI is not evidence that native adapter tests have executed or proof of released platform support. The separate `rust/ui` workspace is outside that job; the `rust-ui` job runs `node --test rust/ui/frontend/tests/frontend.test.js` and `cargo check --locked --manifest-path rust/ui/Cargo.toml` on Ubuntu. Run the smoke locally with `cd rust && tests-e2e/smoke.sh`. Run the local agent and CLI with `cargo run --locked -p tinyprune-daemon --bin tinyprune-agentd` and `cargo run --locked -p tinyprune-cli --bin tinyprune -- status` from `rust/`.

`Fixtures/golden/*.jsonl` is the shared behavior contract: 577 cases in 13 files, including templates, broadness, roots, plans, and schedule; Swift is the reference. Keep fixture inputs/schema and both runners (`Tests/TinyPruneGoldenTests/` and `rust/tinyprune-core/tests/golden.rs`, including `tests/trash_ops/mod.rs`) aligned whenever operations or behavior change. Follow [the fixture schema](Fixtures/golden/README.md); hand-author inputs with unique case names, never expected outputs.

On a Mac with Xcode, verify or intentionally regenerate expected outputs from the repository root:

```sh
swift test --filter GoldenFixtureTests
TINYPRUNE_UPDATE_GOLDEN=1 swift test --filter GoldenFixtureTests
```

On a CommandLineTools-only Mac, use:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F --filter GoldenFixtureTests
```

For the update workflow, prefix that Swift command with `TINYPRUNE_UPDATE_GOLDEN=1`. Review every regenerated `expected` diff, run again without the update variable, then run the Rust checks. Fix known behavior bugs in Swift first; do not independently reinterpret safety or Unicode behavior in Rust.
