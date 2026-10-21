# tinyprune-unix (unreleased)

In-development Unix filesystem adapter for `tinyprune-core`, tested with real temporary trees. This is not a Linux product, scheduler, or agent; TinyPrune remains macOS-only. The freedesktop Trash implementation is not the native macOS Trash adapter.

`UnixFileAccess::new(trash_root)` injects a home Trash location; `from_environment()` selects `$XDG_DATA_HOME/Trash` or `$HOME/.local/share/Trash`. The adapter uses lstat metadata, device/inode identity, modification/access/birth timestamps where available, and separately exposes metadata-change time through `inspect_metadata`. Device IDs are not persistent volume UUIDs. Non-UTF-8 paths fail closed because the core trait takes strings; paths are never converted lossily.

Trash uses private, user-owned 0700 directories, exclusive 0600 `.trashinfo` creation, percent-encoded original paths and local deletion dates, collision-safe atomic no-replace rename, and no copy/delete fallback. If the home Trash is on another device, the adapter tries that filesystem's top-level `.Trash-$uid`, with a top-directory-relative recorded path. An unavailable same-device Trash is an error. Linux and macOS provide the required no-replace rename primitives; other Unix targets reject moves. The crate is empty on Windows.

Inspection rejects symbolic links. Walks never follow symbolic links, honor recorded and identity-addressed Keep overrides and hidden protection, and return indeterminate when their entry/time budget expires. Walk deadlines use Unix-epoch seconds and should be supplied with a wall clock; indexed activity is not inferred from ctime.

## Concurrency boundary

Identity is re-inspected immediately before rename and checked afterward. Unix does **not** provide a rename conditional on source inode identity: concurrent replacement of a source or ancestor can still race this check. A post-move mismatch returns an error naming the retained Trash path; the adapter never deletes that item or tries an unsafe rollback. Directory descriptor hardening and integration with a platform coordination mechanism are required before treating this as a production executor for concurrently hostile trees. The core trait's atomic-identity wording cannot be fully implemented with POSIX rename alone.

## Tests

From `rust/`: `cargo test --locked -p tinyprune-unix` and `cargo clippy --locked -p tinyprune-unix --all-targets -- -D warnings`. Tests exercise file/directory retention, collisions and info records, symlinks, replacement identities, walk budgets/hidden/Keep protection, and the real core coordinator. The Linux-only cross-device primitive test runs when `/dev/shm` is writable and on another device; it never copies or deletes the source.
