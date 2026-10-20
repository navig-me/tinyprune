# ADR 0010 — cross-platform core parity via golden fixtures

Status: accepted for verification. The shared Swift-reference contract contains 577 cases in 13 JSONL files, including templates, broadness, roots, plans, and schedule. The Rust core includes domain/config/pre-Trash decisions and synchronous scheduler scan decisions with injected Clock/MetadataSource/ObservationStore. `tinyprune-unix` implements FileAccess and freedesktop Trash and has been tested on macOS; `tinyprune-watch` implements an inotify EventSource but is cross-compile-checked only, never executed; `tinyprune-windows` implements Recycle Bin/IFileOperation access but is compile-checked only, never executed. The existing CI matrix runs workspace tests and Clippy on Linux, Windows, and macOS, including applicable adapter tests, but configuration is not native execution evidence. Product scope remains macOS; no Linux or Windows build is released.

## Problem

TinyPrune is macOS-only. Linux and Windows support would need a Rust core (single static agent binary, mature inotify/Windows bindings, one toolchain across platforms) while the macOS app, Finder extension, and Sparkle updater stay in Swift. Two engines can drift on safety logic, and a wrongful Trash is the failure that matters most.

## Decision

The Swift implementation is the behavioral reference. Its decisions are pinned by language-neutral golden fixtures in `Fixtures/golden/` (see its README): glob matching, path normalization, scope matching, rule evaluation and precedence, Keep/protection, overrides, hidden-file protection, identity equality, templates, broadness, managed roots, plans, scheduling, config, and scripted pre-Trash coordination.

- Swift tests fail when behavior drifts from the committed fixtures. Changing behavior means regenerating `expected` and reviewing the diff.
- A Rust core must pass the same fixtures before it may schedule or trash anything.
- Fixtures cover deterministic decisions and scripted coordination, not native filesystem acceptance. Platform adapters (Trash, file events, identity, IPC, startup, metadata storage) retain separate per-platform contracts.
- Scope remains macOS until the spec is amended; this ADR records the verification contract, not a product commitment.

## Remaining integration boundaries

The scheduler does not include watcher transport, batching/cancellation, retry/backoff, or a run loop. The Rust agent run loop and IPC, Linux/Windows UI and packaging, and real-OS execution of the inotify and Windows adapters are not started. POSIX rename and Windows Shell provide no atomic identity-conditional move; the respective crate READMEs document these residual races. None of this establishes end-to-end platform safety or changes the macOS-only product contract.

### Platform path flavor

The Rust core defaults to Swift-reference POSIX semantics. Explicit `PathFlavor::Windows` adds drive/UNC paths, both separators, extended-prefix stripping, ordinal single-scalar case-insensitive matching, and managed-root system/profile protection; fresh Windows hidden attributes also participate in preflight protection. These additive platform semantics have no Swift counterpart and are covered by Rust-only unit tests, not changes to the 577 shared golden cases. Windows integrations must select the flavor consistently and supply canonical resolution/profile directories; native adapter execution and agent acceptance remain separate requirements.

## Consequences

- Fixture gaps: rule templates, broadness, managed-root validation, `ConfigPlan`, and the indexer/scheduler are not covered yet and must be added before a port can claim parity. Config parse/render and the `TrashCoordinator` pre-Trash sequence are covered.
- Pinned Swift-isms become part of the contract unless fixtures and Swift are deliberately changed together: grapheme-cluster length tie-break, scalar-based glob without normalization, and canonical-equivalence string equality, prefix tests, and NFC-order sorting everywhere else.
- Known logic bugs should be fixed in Swift before they are ported. The directory-rename observation-record loss in `ManagedRootIndexer` is already fixed (`scheduledDeadline` refreshes hints; covered by `testDirectoryRenamePreservesDescendantObservationsAcrossRestart`).
