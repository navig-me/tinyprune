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
- [`ui/`](ui/README.md): Tauri 2 shell plus static frontend, a **separate Cargo workspace** excluded from this one (own `Cargo.lock`).
- `Cargo.lock`: committed dependency resolution; `rust-toolchain.toml`: pinned toolchain and Clippy component.

## Boundaries and safety

The core is synchronous and trait-based. It provides no concrete filesystem, database, Trash, clock, or network I/O. `TrashCoordinator` orchestrates injected `PolicyStore`, `FileAccess`, `AuditSink`, `Clock`, `UpdateGate`, `CandidateHydrator`, and `SizeMeasurer` implementations; adapters own their actual effects. Config parsing operates on supplied text, not files.

Product invariants apply identically here: metadata only, Trash only (never permanent deletion), Keep wins, re-check current identity/policy/protection/deadline/pause/availability before Trash, and Preview never trashes. Preserve path bytes rather than silently normalizing Unicode; Swift-compatible comparisons and raw-scalar glob behavior are distinct contracts.

The Rust agent (`tinyprune-agentd`) and its IPC, CLI and UI exist as unreleased engineering work, but this is not a shipped Linux or Windows product: native execution of inotify, the Windows watcher and named pipes, installers, UI on Linux/Windows, performance on those systems, and an accessibility audit are not done (see the matrix below). POSIX rename and Windows Shell cannot atomically condition a move on source identity; the adapter READMEs document the remaining races. Core fixture coverage does not prove platform-adapter safety or end-to-end scheduler parity. Decisions are recorded in [ADR 0011](../ADRs/0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md): macOS stays on Swift and is not wired to this runtime; config import/export is POSIX-only (Windows returns `InvalidRequest`); macOS has only a periodic reconcile fallback instead of a native watcher.

### Platform paths and hidden metadata

`PathFlavor::Posix` is the default and preserves the Swift-reference behavior. Windows integrations explicitly select `PathFlavor::Windows` for `RuleScope::new_with_flavor`, `AgentSettings.path_flavor` (resolver/coordinator/scan), and `roots::validate_root_with_flavor`; `tinyprune-windows::PATH_FLAVOR` supplies that choice. Windows paths handle drive letters, UNC shares, either separator, lexical dot components, and extended-length prefixes. Comparisons use ordinal single-scalar uppercase mappings without Unicode normalization or expanding case folds. Managed-root validation checks resolved aliases, rejects drive/share roots and system trees, and requires injected profile roots to protect the user's home.
Use `ItemPolicyOverride::new_with_flavor` for Windows path-based overrides; the default override constructor remains POSIX. Config text parsing/rendering remains the POSIX Swift-reference contract, not a Windows config codec.

`RuleCandidate::new` defaults `platform_hidden` to false. Windows inspection sets it from `FILE_ATTRIBUTE_HIDDEN`; hidden protection applies just as for dot-names, including the existing explicit-dot matcher exemption. Preflight preserves fresh metadata through timestamp hydration and re-inspects before Trash. Windows flavor and platform-hidden metadata have no Swift counterpart: their coverage is Rust-only (`tinyprune-core/tests/windows_flavor.rs` plus native adapter tests), while all 577 shared golden cases remain unchanged. This additive engineering boundary is not released Windows support.

## Status matrix

"CI at pushed head" means `gh pr checks 15` for commit `6672a10` (pull request head when this was written), which contained only core, unix, watch (Linux inotify and portable parts), windows and agent; the later crates and the Windows watcher are uncommitted/unpushed and have **no CI result**. "Dev Mac" is the macOS Darwin x86_64 development host. Rows marked "in progress" are owned by other work items and are not claimed.

| Component | Linux | Windows | macOS (Rust) |
|---|---|---|---|
| core + 577 golden cases | tests run in CI at pushed head | tests run in CI at pushed head | tests run in CI at pushed head and on dev Mac |
| `tinyprune-unix` (FileAccess, freedesktop Trash) | filesystem tests run in CI at pushed head | not applicable (empty crate) | tests run on dev Mac and in CI |
| `tinyprune-windows` (Recycle Bin) | not applicable | native tests run in CI at pushed head | compile-checked only (cross target) |
| `tinyprune-watch`: inotify | compile-checked only from macOS; real inotify events never executed | not applicable | not applicable; portable scripted-source tests run |
| `tinyprune-watch`: `ReadDirectoryChangesW` | not applicable | implemented; compile-checked only, never executed (no CI result) | synthetic-buffer parser tests run; no native watcher exists (periodic reconcile fallback in the daemon) |
| `tinyprune-agent` | tests run in CI at pushed head | tests run in CI at pushed head | tests run in CI and on dev Mac |
| `tinyprune-store` | configured in CI, not yet pushed; cross-target check not possible on dev Mac (needs C toolchain) | same | tests and Clippy run on dev Mac |
| `tinyprune-scan` | cross-compile-checked per README; never executed | same | tests run on dev Mac; 35,761 entries/s measured (50,101 entries, release, ignored benchmark) |
| `tinyprune-ipc` Unix socket | never executed natively; no CI result | not applicable | tests run on dev Mac |
| `tinyprune-ipc` named pipe | not applicable | cross-checked and linted only; never executed | not applicable |
| `tinyprune-daemon` (`tinyprune-agentd`) | never executed | never executed | tests run on dev Mac (including real-socket end-to-end) |
| `tinyprune-cli` (`tinyprune`) | never executed | never executed | tests run on dev Mac (loopback and real Unix socket) |
| UI frontend (`rust/ui/frontend`, 9 Node tests) | never run | never run | 9 Node tests and manual Chromium run on dev Mac |
| UI Tauri shell | never run (needs WebKitGTK/GTK) | never run (needs WebView2) | no webview run |
| Restart-stable identity persistence | implemented; Linux path (filesystem UUID from mountinfo, `statx` birth time) never executed, cross-compile-checked only | implemented (volume serial, file ID, creation time); compile-checked only | tests run on dev Mac (reopen, rename, replacement, inode reuse); volumes without a durable id or without creation time are non-persistent |
| End-to-end smoke (`rust/tests-e2e/smoke.sh`, `smoke.ps1`), benchmark (`cargo test --release --locked -p tinyprune-daemon --test bench -- --ignored --nocapture`) | configured in `ci.yml`, not yet run on GitHub | configured (`smoke.ps1` has never run on Windows), not yet run on GitHub | configured; smoke uses the freedesktop-style Trash under a temp `XDG_DATA_HOME`, not `~/.Trash` |
| Dev archives (`rust/packaging`, `.github/workflows/rust-artifacts.yml`) | unsigned `.tar.gz` + systemd user unit scripts; install test run only on macOS with a fake `systemctl`; never run on Linux/systemd; workflow never run on GitHub | unsigned `.zip` + PowerShell scripts (per-user Scheduled Task); scripts never run or parse-checked; workflow never run on GitHub | build and `--version` only; no package (Swift app ships macOS) |
| Accessibility audit | not started | not started | not started |

Not verified anywhere: real inotify events, the Windows watcher, named pipes, Linux/Windows UI, installers, performance on Linux or Windows, and any accessibility audit beyond static HTML/CSS contract tests and computed contrast (no screen reader was run). Passing CI means unit and fixture tests passed on that runner; it is not product acceptance.

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

The `rust-core` job in `../.github/workflows/ci.yml` runs the first two commands on `ubuntu-24.04`, `windows-2022`, and `macos-14`. Its “Golden fixtures” step runs `cargo test --locked` for the workspace, not just golden fixtures. The same job then builds release `tinyprune-agentd` and `tinyprune` and runs the end-to-end smoke (`tests-e2e/smoke.sh`, or `tests-e2e/smoke.ps1` on Windows), and a non-gating benchmark whose table goes to the job summary; a separate Ubuntu `rust-ui` job runs the frontend tests and a Tauri compile check. These added steps are configured but had not run on GitHub when this was written. A configured job is not evidence of a completed native run or adapter acceptance. Dependencies are allowed only for a concrete need; commit `Cargo.lock` changes and keep `rust-toolchain.toml` pinned. These checks do not produce a released cross-platform application.

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
