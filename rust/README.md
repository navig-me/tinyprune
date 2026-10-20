# TinyPrune Rust core (in development)

This workspace reproduces TinyPrune's Swift decision logic against the shared, language-neutral [golden fixtures](../Fixtures/golden/README.md). Swift is the behavioral reference ([ADR 0010](../ADRs/0010-cross-platform-core-and-golden-fixtures.md)). This is internal, unreleased engineering work: TinyPrune remains macOS-only, and no Linux or Windows build is released.

## Layout

- `tinyprune-core/src/`: domain models and validation (`rule`), globs (`glob`), precedence/protection (`resolve`), config parse/render (`config`), Swift-compatible string semantics (`swiftstr`), deterministic IDs (`uuid`), the pre-Trash sequence (`trash`), and scan decisions (`scheduler`) with injected `Clock`, `MetadataSource`, and `ObservationStore`.
- `tinyprune-core/tests/golden.rs` and `tests/trash_ops/mod.rs`: consume 577 cases in 13 `../Fixtures/golden/*.jsonl` files, including templates, broadness, roots, plans, and schedule, using real core decisions and scripted collaborators.
- [`tinyprune-unix/`](tinyprune-unix/README.md): FileAccess and freedesktop Trash adapter, tested on macOS; not the native macOS Trash adapter.
- [`tinyprune-watch/`](tinyprune-watch/README.md): portable EventSource contract/scripted source and Linux inotify implementation; inotify was cross-compile-checked only, never executed.
- [`tinyprune-windows/`](tinyprune-windows/README.md): Windows FileAccess and Recycle Bin/IFileOperation adapter; compile-checked only, never executed.
- `Cargo.lock`: committed dependency resolution; `rust-toolchain.toml`: pinned toolchain and Clippy component.

## Boundaries and safety

The core is synchronous and trait-based. It provides no concrete filesystem, database, Trash, clock, or network I/O. `TrashCoordinator` orchestrates injected `PolicyStore`, `FileAccess`, `AuditSink`, `Clock`, `UpdateGate`, `CandidateHydrator`, and `SizeMeasurer` implementations; adapters own their actual effects. Config parsing operates on supplied text, not files.

Product invariants apply identically here: metadata only, Trash only (never permanent deletion), Keep wins, re-check current identity/policy/protection/deadline/pause/availability before Trash, and Preview never trashes. Preserve path bytes rather than silently normalizing Unicode; Swift-compatible comparisons and raw-scalar glob behavior are distinct contracts.

The core is not a runnable agent. Scheduler scope is synchronous scan decisions, not watcher transport, batching/cancellation, retry/backoff, or a run loop. The Rust agent run loop and IPC, Linux/Windows UI and packaging, and real-OS execution of inotify and the Windows adapter are not started. POSIX rename and Windows Shell cannot atomically condition a move on source identity; the adapter READMEs document the remaining races. Core fixture coverage does not prove platform-adapter safety or end-to-end scheduler parity.

### Platform paths and hidden metadata

`PathFlavor::Posix` is the default and preserves the Swift-reference behavior. Windows integrations explicitly select `PathFlavor::Windows` for `RuleScope::new_with_flavor`, `AgentSettings.path_flavor` (resolver/coordinator/scan), and `roots::validate_root_with_flavor`; `tinyprune-windows::PATH_FLAVOR` supplies that choice. Windows paths handle drive letters, UNC shares, either separator, lexical dot components, and extended-length prefixes. Comparisons use ordinal single-scalar uppercase mappings without Unicode normalization or expanding case folds. Managed-root validation checks resolved aliases, rejects drive/share roots and system trees, and requires injected profile roots to protect the user's home.
Use `ItemPolicyOverride::new_with_flavor` for Windows path-based overrides; the default override constructor remains POSIX. Config text parsing/rendering remains the POSIX Swift-reference contract, not a Windows config codec.

`RuleCandidate::new` defaults `platform_hidden` to false. Windows inspection sets it from `FILE_ATTRIBUTE_HIDDEN`; hidden protection applies just as for dot-names, including the existing explicit-dot matcher exemption. Preflight preserves fresh metadata through timestamp hydration and re-inspects before Trash. Windows flavor and platform-hidden metadata have no Swift counterpart: their coverage is Rust-only (`tinyprune-core/tests/windows_flavor.rs` plus native adapter tests), while all 577 shared golden cases remain unchanged. This additive engineering boundary is not released Windows support.

## Commands

From the repository root, with Rust installed through rustup:

```sh
cd rust
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

The existing `rust-core` job in `../.github/workflows/ci.yml` runs these on `ubuntu-24.04`, `windows-2022`, and `macos-14`. Its “Golden fixtures” step runs `cargo test --locked` for the workspace, including target-applicable tests in the new adapter crates, not just golden fixtures. No workflow change is needed to include those crates. A configured job is not evidence of a completed native run or adapter acceptance. Dependencies are allowed only for a concrete need; commit `Cargo.lock` changes and keep `rust-toolchain.toml` pinned. These checks do not produce a released cross-platform application.

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
