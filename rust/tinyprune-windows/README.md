# Windows filesystem adapter (in development, unreleased)

TinyPrune remains a macOS-only product. This crate is internal Windows adapter work, not a released Windows application or an agent. It is empty on non-Windows targets.

## Boundary

`WindowsFileAccess` implements the synchronous core `FileAccess` trait. `windows` supplies the missing Win32 FileIdInfo, ordinal case-insensitive comparison, volume/registry metadata and Shell COM APIs; `windows-core` is required by its COM implementation macro. Both are pinned by the workspace lockfile. No file contents are read. `WindowsFileAccess::new` injects wall time for bounded walks; `Default` uses system wall time.

Identity combines the 64-bit volume serial and full 128-bit `FileIdInfo` identifier with creation time and a path hint. Core identity equality deliberately excludes the hint; the move additionally requires Windows ordinal case-insensitive hint equality. IDs are marked nonpersistent because this adapter does not establish a durable volume identity across reformatting/reconnection. Paths preserve Unicode spelling; no lossy conversions. Fully qualified drive and UNC paths and `\\?\` extended-length forms are accepted, with extended-length I/O internally. Dot components, alternate data streams, and ambiguous trailing dots/spaces are rejected. Case-sensitive Windows directories are conservatively treated case-insensitively for protection.

Reparse points are rejected, including symlinks, junctions and volume mount points. Inspection and Trash reject reparse ancestors all the way to the volume root (stronger than just the managed root); the core ancestor check includes the managed root itself. Descendant enumeration never follows reparse points and considers their presence protected. Walks stream directory entries, bound visited entries and injected time, and return indeterminate if the budget expires. Keep matches by identity or case-insensitive path; recorded missing descendants still protect their ancestor. With hidden protection enabled, both dot-names and `FILE_ATTRIBUTE_HIDDEN` descendants protect a directory. Turning that setting off permits ordinary hidden descendants, not reparse points. The current core candidate DTO has no Windows hidden-attribute field: direct-item attribute protection cannot be conveyed through `inspect`; a future Windows agent must address this before activation (dot-name protection is already core-owned).

## Recycle Bin only

Only `IFileOperation::DeleteItem` with `FOFX_RECYCLEONDELETE | FOF_ALLOWUNDO` is used; there is no direct-delete, cross-volume copy/delete, SHFileOperation fallback, or manual Recycle Bin implementation. Only local fixed volumes are eligible. `SHQueryRecycleBinW`, per-volume `NukeOnDelete`/zero-capacity settings, legacy `NukeOnDelete`, and user/machine `NoRecycleFiles` policies are checked, failing closed on query errors. Network and removable drives are refused. The Shell progress sink vetoes deletion unless it supplies `TSF_DELETE_RECYCLE_IF_POSSIBLE`, rechecks volume eligibility/reparse ancestry/identity in `PreDeleteItem`, and requires the recycled destination from `PostDeleteItem` before claiming success. `FOF_WANTNUKEWARNING` is retained, `FOF_NOCONFIRMATION` is intentionally absent, and no permanent-delete confirmation is automatically accepted. Abort and HRESULT failures propagate; sharing/lock violations are explicitly transient errors for the scheduler to defer/retry. The adapter never retries by permanently deleting.

COM is initialized as STA for each synchronous move and balanced on that thread. Callers already using an incompatible COM apartment receive an error, not an unbalanced uninitialization. Shell deletion is pathname-based: although identity is checked again in the callback, Win32 Shell exposes no atomic compare-file-ID-and-recycle primitive. This adapter does not claim to eliminate a malicious concurrent pathname replacement after that callback. A final recycled-path absence/error is not reported as successful recycling.

## Core path and hidden metadata integration

Inspection sets `RuleCandidate.platform_hidden` from fresh `FILE_ATTRIBUTE_HIDDEN` metadata, including directly selected items. Core rule evaluation honors it under the same hidden-protection setting and explicit-dot matcher exemption as dot-names; the coordinator preserves the fresh flag across timestamp hydration and checks it again during final preflight. Portable candidates constructed with `RuleCandidate::new` default the flag to false.

Use this crate's `PATH_FLAVOR` (`PathFlavor::Windows`) with `RuleScope::new_with_flavor`, `AgentSettings.path_flavor`, and `roots::validate_root_with_flavor`. Default core constructors remain POSIX for Swift parity. Windows normalization accepts drive/UNC roots, both separators, lexical dot components, and `\\?\` prefixes without Unicode normalization; native filesystem entry points still reject ambiguous paths and dot components rather than silently accepting them. Core comparisons use ordinal single-scalar uppercase mappings (no expanding folds such as `ß` to `SS`); native identity-hint checks use `CompareStringOrdinal`. Unicode casing tables are supplied by the pinned Rust toolchain versus the host Windows version, so native acceptance remains required. Root validation rejects drive/share roots, Windows/Program Files system trees, and injected user profile roots, including resolved aliases; integrations must supply actual profile directories and canonical resolution.
Construct path-based overrides with `ItemPolicyOverride::new_with_flavor(..., PATH_FLAVOR)` as well. The core's config text codec remains POSIX/Swift-reference; a Windows agent must not feed Windows paths through that default codec.

Windows flavor and platform-hidden metadata have no Swift counterpart and are covered by Rust-only tests, not the 577 unchanged Swift-reference golden cases. Do not activate a Windows scheduler until agent integration and adversarial native race/Recycle Bin tests are reviewed. These restrictions do not change the macOS-only product contract.

## Verification

On macOS, cross-check compilation only:

```sh
rustup target add x86_64-pc-windows-msvc
cargo check --locked -p tinyprune-windows --target x86_64-pc-windows-msvc --all-targets
cargo clippy --locked -p tinyprune-windows --target x86_64-pc-windows-msvc --all-targets -- -D warnings
```

On Windows, `cargo test --locked -p tinyprune-windows` exercises real temporary directories: stable/replaced identity, path hints and long paths, missing/stale items, Keep, hidden attributes, budgets, sharing violations, real directory junction rejection, the permanent-delete veto, and a real Recycle Bin round trip (restoring the test-owned payload afterward). If preflight finds the bin unavailable, that test instead asserts refusal and preservation of the source. Tests do not alter Recycle Bin configuration or require symlink privilege; junction creation uses the built-in `mklink /J`. Cross-compilation does not execute these tests or demonstrate runtime safety. Windows code was not executed during implementation on macOS.

Shell flag and callback contracts: [SetOperationFlags](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-setoperationflags), [PreDeleteItem](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperationprogresssink-predeleteitem).
