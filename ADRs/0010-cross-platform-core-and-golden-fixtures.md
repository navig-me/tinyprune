# ADR 0010 — cross-platform core parity via golden fixtures

Status: accepted for verification; extended by [ADR 0011](0011-rust-runtime-store-scan-ipc-daemon-cli-ui.md). The shared Swift-reference contract contains 577 cases in 13 JSONL files, including templates, broadness, roots, plans, and schedule. The Rust core includes domain/config/pre-Trash decisions and synchronous scheduler scan decisions with injected Clock/MetadataSource/ObservationStore. `tinyprune-unix` implements FileAccess and freedesktop Trash; `tinyprune-watch` implements Linux inotify and Windows `ReadDirectoryChangesW` event sources; `tinyprune-windows` implements Recycle Bin/IFileOperation access. Native execution evidence differs per component and is itemized in the [status matrix](../rust/README.md#status-matrix): real inotify events and the Windows watcher have never been executed, and configured CI is not acceptance. Product scope remains macOS; no Linux or Windows build is released.

## Problem

TinyPrune is macOS-only. Linux and Windows support would need a Rust core (single static agent binary, mature inotify/Windows bindings, one toolchain across platforms) while the macOS app, Finder extension, and Sparkle updater stay in Swift. Two engines can drift on safety logic, and a wrongful Trash is the failure that matters most.

## Decision

The Swift implementation is the behavioral reference. Its decisions are pinned by language-neutral golden fixtures in `Fixtures/golden/` (see its README): glob matching, path normalization, scope matching, rule evaluation and precedence, Keep/protection, overrides, hidden-file protection, identity equality, templates, broadness, managed roots, plans, scheduling, config, and scripted pre-Trash coordination.

- Swift tests fail when behavior drifts from the committed fixtures. Changing behavior means regenerating `expected` and reviewing the diff.
- A Rust core must pass the same fixtures before it may schedule or trash anything.
- Fixtures cover deterministic decisions and scripted coordination, not native filesystem acceptance. Platform adapters (Trash, file events, identity, IPC, startup, metadata storage) retain separate per-platform contracts.
- Scope remains macOS until the spec is amended; this ADR records the verification contract, not a product commitment.

## Remaining integration boundaries

The scheduler itself does not include watcher transport, batching/cancellation, retry/backoff, or a run loop; those live in `tinyprune-agent`, hosted by `tinyprune-daemon` (ADR 0011). Linux/Windows UI polish, installers and packaging, and native acceptance of the inotify and Windows watchers and Windows named pipes are not complete (see the status matrix). POSIX rename and Windows Shell provide no atomic identity-conditional move; the respective crate READMEs document these residual races. None of this establishes end-to-end platform safety or changes the macOS-only product contract.

### Platform path flavor

The Rust core defaults to Swift-reference POSIX semantics. Explicit `PathFlavor::Windows` adds drive/UNC paths, both separators, extended-prefix stripping, ordinal single-scalar case-insensitive matching, and managed-root system/profile protection; fresh Windows hidden attributes also participate in preflight protection. These additive platform semantics have no Swift counterpart and are covered by Rust-only unit tests, not changes to the 577 shared golden cases. Windows integrations must select the flavor consistently and supply canonical resolution/profile directories; native adapter execution and agent acceptance remain separate requirements.

## Consequences

- Fixture coverage: templates, broadness, managed-root validation, plans (`ConfigPlan`) and schedule decisions are now in the 577 cases. The indexer/run loop and platform adapters are still outside the fixtures and must not be assumed to have parity. Config parse/render and the `TrashCoordinator` pre-Trash sequence are covered.
- Pinned Swift-isms become part of the contract unless fixtures and Swift are deliberately changed together: grapheme-cluster length tie-break, scalar-based glob without normalization, and canonical-equivalence string equality, prefix tests, and NFC-order sorting everywhere else.
- Known logic bugs should be fixed in Swift before they are ported. The directory-rename observation-record loss in `ManagedRootIndexer` is already fixed (`scheduledDeadline` refreshes hints; covered by `testDirectoryRenamePreservesDescendantObservationsAcrossRestart`).
