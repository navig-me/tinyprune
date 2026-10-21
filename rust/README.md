# TinyPrune Rust core (in development)

This workspace reproduces TinyPrune's Swift decision logic against the shared, language-neutral [golden fixtures](../Fixtures/golden/README.md). Swift is the behavioral reference ([ADR 0010](../ADRs/0010-cross-platform-core-and-golden-fixtures.md)). This is internal, unreleased engineering work: TinyPrune remains macOS-only, and no Linux or Windows build is released.

## Layout

- `tinyprune-core/src/`: domain models and validation (`rule`), globs (`glob`), precedence/protection (`resolve`), config parse/render (`config`), Swift-compatible string semantics (`swiftstr`), deterministic IDs (`uuid`), the pre-Trash sequence (`trash`), and scan decisions (`scheduler`) with injected `Clock`, `MetadataSource`, and `ObservationStore`.
- `tinyprune-core/tests/golden.rs` and `tests/trash_ops/mod.rs`: consume 577 cases in 13 `../Fixtures/golden/*.jsonl` files, including templates, broadness, roots, plans, and schedule, using real core decisions and scripted collaborators.
- [`tinyprune-unix/`](tinyprune-unix/README.md): FileAccess and freedesktop Trash adapter (not the native macOS Trash adapter); tests run on macOS and, in CI at the last pushed head, on Linux.
- [`tinyprune-watch/`](tinyprune-watch/README.md): portable EventSource contract/scripted source, Linux inotify and Windows `ReadDirectoryChangesW` implementations. Neither native watcher has been executed against a real OS event stream; macOS has no native watcher.
- [`tinyprune-windows/`](tinyprune-windows/README.md): Windows FileAccess and Recycle Bin/IFileOperation adapter; its tests ran on a `windows-2022` CI runner at the last pushed head.
- [`tinyprune-agent/`](tinyprune-agent/README.md): synchronous deterministic engine (bounded indexing, events, execution, backoff, restart recovery).
- [`tinyprune-store/`](tinyprune-store/README.md): SQLite persistence (`rusqlite` bundled), distinct from the Swift database.
- [`tinyprune-scan/`](tinyprune-scan/README.md): bounded metadata-only traversal and read-only Preview dry run.
- [`tinyprune-ipc/`](tinyprune-ipc/README.md): length-prefixed JSON protocol over Unix socket or Windows named pipe, shared endpoint resolution; samples in `../Fixtures/ipc/dtos.json`. Not Swift-XPC compatible.
- [`tinyprune-daemon/`](tinyprune-daemon/README.md): `tinyprune-agentd` binary assembling store, scan, agent, watchers and IPC.
- [`tinyprune-cli/`](tinyprune-cli/README.md): `tinyprune` binary, an IPC-only client.
- [`tinyprune-update/`](tinyprune-update/README.md): updater for this runtime ([ADR 0012](../ADRs/0012-rust-runtime-signed-updates.md)): signed-feed check, verified staged install with rollback, `tinyprune update` (hosted by the CLI), `tinyprune-launcher`, `tinyprune-feed`, and the Trash/update interlock the agent embeds. Unreleased; macOS keeps Sparkle.
- [`ui/`](ui/README.md): Tauri 2 shell plus static frontend, a **separate Cargo workspace** excluded from this one (own `Cargo.lock`).
- `Cargo.lock`: committed dependency resolution; `rust-toolchain.toml`: pinned toolchain and Clippy component.

## Boundaries and safety

The core is synchronous and trait-based. It provides no concrete filesystem, database, Trash, clock, or network I/O. `TrashCoordinator` orchestrates injected `PolicyStore`, `FileAccess`, `AuditSink`, `Clock`, `UpdateGate`, `CandidateHydrator`, and `SizeMeasurer` implementations; adapters own their actual effects. Config parsing operates on supplied text, not files.

Product invariants apply identically here: metadata only, Trash only (never permanent deletion), Keep wins, re-check current identity/policy/protection/deadline/pause/availability before Trash, and Preview never trashes. Preserve path bytes rather than silently normalizing Unicode; Swift-compatible comparisons and raw-scalar glob behavior are distinct contracts.

The Rust agent (`tinyprune-agentd`) and its IPC, CLI and UI exist as unreleased engineering work, not a shipped Linux or Windows product. CI executes native watchers, sockets/pipes, daemon/CLI smokes, dev installs and a non-gating 100k benchmark on Linux and Windows; the Tauri webview ran only in a Linux aarch64 Docker container. POSIX rename and the Windows Shell cannot atomically condition a move on source identity; adapter READMEs document the races. Fixture coverage does not prove platform-adapter safety. ADR 0011 records the runtime decisions: macOS stays on Swift, Windows config import/export is unsupported, macOS has only a periodic reconcile fallback. ADR 0012 covers the separate, user-confirmed Rust updater; macOS keeps Sparkle.

### Platform paths and hidden metadata

`PathFlavor::Posix` is the default and preserves the Swift-reference behavior. Windows integrations explicitly select `PathFlavor::Windows` for `RuleScope::new_with_flavor`, `AgentSettings.path_flavor` (resolver/coordinator/scan), and `roots::validate_root_with_flavor`; `tinyprune-windows::PATH_FLAVOR` supplies that choice. Windows paths handle drive letters, UNC shares, either separator, lexical dot components, and extended-length prefixes. Comparisons use ordinal single-scalar uppercase mappings without Unicode normalization or expanding case folds. Managed-root validation checks resolved aliases, rejects drive/share roots and system trees, and requires injected profile roots to protect the user's home.
Use `ItemPolicyOverride::new_with_flavor` for Windows path-based overrides; the default override constructor remains POSIX. Config text parsing/rendering remains the POSIX Swift-reference contract, not a Windows config codec.

Hot Windows-flavor loops do not re-normalize both operands per pair: `tinyprune_core::path::WindowsKey` is the normalized, single-scalar-uppercased comparison key computed once per path (equality and `is_descendant_of` are identical to `PathFlavor::Windows.equal`/`is_descendant`), `AncestorIndex` answers "does any inserted path lie strictly below this directory" in O(depth), and `ContainerIndex` returns every indexed path containing a path in O(depth). They are used by the scheduler's full pass (protected descendants, project markers/activity), the store's containment checks and the daemon's decision job. `tinyprune-core/tests/windows_path_equivalence.rs` keeps the original allocating implementation as a reference and compares them on tens of thousands of varied spellings; `tinyprune-core/tests/windows_scale.rs` and a store unit test assert near-linear growth (2x input stays well below 4x time), and core and store each hold an ignored 25k/50k/100k benchmark. POSIX comparisons are unchanged. Measured on the macOS development host only; no Windows run exists.

`RuleCandidate::new` defaults `platform_hidden` to false. Windows inspection sets it from `FILE_ATTRIBUTE_HIDDEN`; hidden protection applies just as for dot-names, including the existing explicit-dot matcher exemption. Preflight preserves fresh metadata through timestamp hydration and re-inspects before Trash. Windows flavor and platform-hidden metadata have no Swift counterpart: their coverage is Rust-only (`tinyprune-core/tests/windows_flavor.rs` plus native adapter tests), while all 577 shared golden cases remain unchanged. This additive engineering boundary is not released Windows support.

## Status matrix

Evidence: PR #15 checks at commit `536d105` passed on Ubuntu 24.04, Windows 2022 and macOS 14/15 (later commits need their own check). UI and updater Docker smokes ran locally on Linux aarch64. CI benchmarks are non-gating, so a green job can hide a failed benchmark. These are developer artifacts, not released builds.

| Component | Linux | Windows | macOS (Rust) |
|---|---|---|---|
| Core, 577 Swift-reference fixtures, agent, store, scan | workspace tests + Clippy pass in CI | workspace tests + Clippy pass in CI | workspace tests + Clippy pass in CI |
| Native filesystem, watcher, IPC | real inotify, Unix socket, freedesktop Trash exercised by CI and Docker smokes; symlink/volume races remain | real `ReadDirectoryChangesW`, named pipe and Recycle Bin exercised by the CI smoke; Shell race remains | Unix adapter uses a freedesktop-style Trash, not native macOS Trash; periodic reconcile, no Rust native watcher |
| Daemon + CLI | real-binary smoke (23 checks) in CI; systemd user install/uninstall and cross-mount Trash in Docker | real-binary smoke and per-user Scheduled Task install/uninstall in CI | real-binary smoke in CI; not the shipping Swift agent |
| 100k-file benchmark | Local Docker Linux/aarch64 (compact audit, dirty-priority): initial index 5.61 s, all decisions 30.01 s, event-to-upcoming 99 ms. Hosted CI run 39466056350 (older code): 4.94 s / 17.60 s / 87 ms. Different filesystems; not a regression comparison | Hosted `windows-2022`. Before: run 39528107010: index 33.44 s, all decisions 142.57 s, decision storage 102.36 s (25 commits), event-to-upcoming 41.185 s. After the policy-fingerprint fix (run 39539558359, `1e4784f`): index 44.48 s, all decisions 171.80 s, decision storage 119.92 s (SQL 10.98 s + COMMIT 108.94 s), event-to-upcoming **124 ms** (the 35-41 s was a full 100k re-enumeration caused by a cold-vs-warm Windows glob cache in the snapshot fingerprint; watcher receipt was +42 ms and never overflowed). COMMIT cost was checkpoint-dominated: SQLite autocheckpoint is now off and the daemon checkpoints between decision pages (PASSIVE over 192 MiB of WAL, TRUNCATE when idle; synchronous=FULL unchanged). Run 39553499888: all decisions visible 60.62 s, decision storage 12.44 s (SQL 7.69 s + COMMIT 4.74 s); production-Store 100k control 14.7-21.6 s (WAL peak 199-230 MiB) versus 129-171 s with the previous 1,000-frame autocheckpoint. Single runs on a noisy runner (about 2x run-to-run); benchmark non-gating; no released Windows support | Local development Mac: initial index 8.7-20 s, all decisions 31-55 s across runs (machine load varies), event-to-upcoming 0.4-1.6 s via polling fallback; production-Store 100k control 11.1-16.5 s with the new checkpointing vs 13.8 s with autocheckpoint (no regression beyond noise); not shipped |
| Tauri UI | real-agent webview run in Linux aarch64 Docker under Xvfb; 15 axe-core runs without violations; CI compiles the shell and runs frontend tests | non-gating `rust-ui-windows` CI job on windows-2022 (run 39547401643): real Tauri/WebView2 131 window driven by tauri-driver + msedgedriver against the real agent over a named pipe (Overview, Rules/Preview, Upcoming, Activity, Settings, explanation drawer, pause, offline); 15 axe-core runs without violations; found and fixed a pipe-busy client bug; one 1024x768, 100% DPI runner only | webview not launched; SwiftUI remains the macOS UI |
| Developer archives and install | unsigned tarball + systemd user unit; fresh-container install/Trash/restart/uninstall/purge passed locally and is repeated in CI | unsigned zip + Scheduled Task; install/uninstall step passed in CI | Rust binaries build only; Swift app owns packaging |
| User-confirmed updater (ADR 0012) | unit tests and a Docker signed-feed update/rollback with a throwaway key passed; no production feed or key | unit tests pass in CI; managed update end to end on a hosted `windows-2022` runner (throwaway key, loopback feed, real Scheduled Task and launcher; update, restart into the new build, state survival, tamper/replay refusal, rollback, Trash blocked while quiesced) passed in workflow run 39550764775 at `c25ee1f`; one run, no logon/reboot trigger or non-admin user tested, no production feed | not used; Sparkle unchanged |

Not accepted as a product: Windows 100k performance, desktop-level and screen-reader accessibility, signed releases, a production update feed.

## Commands

From the repository root, with Rust installed through rustup:

```sh
cd rust
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

Run the agent and CLI locally (unreleased):

```sh
cargo run --locked -p tinyprune-daemon --bin tinyprune-agentd
cargo run --locked -p tinyprune-cli --bin tinyprune -- status
```

The UI is checked separately (`cargo check --manifest-path rust/ui/Cargo.toml`; `node --test tests/*.test.js` in `rust/ui/frontend`); see [ui/README.md](ui/README.md).

The `rust-core` job in `../.github/workflows/ci.yml` runs workspace tests and Clippy on `ubuntu-24.04`, `windows-2022` and `macos-14`, then release-binary smokes and a **non-gating** benchmark. The separate Ubuntu `rust-ui` job runs frontend tests and compiles the Tauri shell; `.github/workflows/rust-artifacts.yml` builds dev archives and tests installation. A passing job does not prove a release. Dependencies need a concrete need; commit `Cargo.lock` and keep `rust-toolchain.toml` pinned.

## Adding a golden case

1. Read [the fixture schema and pinned behaviors](../Fixtures/golden/README.md). Add a JSONL input with a unique case name; use an existing operation where possible. Do not hand-author expected outputs.
2. For a new operation, update both the Swift runner in `../Tests/TinyPruneGoldenTests/` and the Rust runner in `tinyprune-core/tests/golden.rs` (or `tests/trash_ops/mod.rs` for Trash scenarios), along with the schema documentation. Keep fixtures and both runners aligned in the same change. Fix behavioral bugs in Swift before porting the fix.
3. On macOS, regenerate expected outputs using the reference implementation from the repository root:

   ```sh
   TINYPRUNE_UPDATE_GOLDEN=1 swift test --filter GoldenFixtureTests
   ```

4. Review every generated `expected` diff. Verify without regeneration:

   ```sh
   swift test --filter GoldenFixtureTests
   ```

5. Run both Rust commands above. A mismatch is a parity failure, not permission to change expected output independently.

On a CommandLineTools-only Mac, replace the Swift verification command with:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F --filter GoldenFixtureTests
```

Prefix that Swift command with `TINYPRUNE_UPDATE_GOLDEN=1` only for intentional regeneration. Other contributors can run Rust checks on their platform, but regeneration requires the macOS Swift reference. See [AGENTS.md](../AGENTS.md#running-tests) for the full contributor test guidance.
