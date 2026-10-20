# TinyPrune cross-platform desktop UI (in development)

Unreleased engineering work. TinyPrune remains macOS-only; the native Swift app is unchanged and is not replaced. No Linux or Windows build is released, and this shell has not been run on Linux or Windows.

This is a separate Cargo workspace (`rust/Cargo.toml` excludes `ui`) so webview and GTK dependencies cannot break the main Rust workspace or CI. It contains a Tauri 2 shell and a static, build-step-free HTML/CSS/vanilla-JS frontend.

## Boundary

The frontend is an IPC client. It does not evaluate rules, scan folders, trash items, or inspect contents. `frontend/api.js` is the only backend boundary. In Tauri it calls one Rust command, `agent_request`, which uses `tinyprune-ipc::Client` over `tinyprune_ipc::default_endpoint()` with the loopback-protected Unix socket or Windows named pipe. Each call opens a short-lived authenticated connection. If a transport fails after sending, the UI says a mutation may have applied and asks the user to reload before retrying; it never auto-retries.

Preview is read-only. The editor asks the agent to preview the current draft, and saving always creates or edits the rule in Preview. This UI does not activate automation. Every Upcoming item, preview sample, and activity decision opens the complete agent explanation. Explicit nulls are shown as unavailable or inapplicable, and the drawer states that Trash is still re-checked immediately before every move.

Copy says moved items go to the OS Trash or Recycle Bin and remain restorable until emptied. The reclaim ledger shows recorded moved-to-Trash bytes and a 14-day sparkline without axes; it says Trash does not free disk space until emptied.

## Fonts

`frontend/fonts/` copies Newsreader, Manrope and JetBrains Mono variable fonts plus their SIL OFL texts from `docs/assets/fonts/`; the same fonts are already shipped in this repository.

## Browser development with mock data

```sh
cd rust/ui/frontend
python3 -m http.server 8437 --bind 127.0.0.1
```

Open `http://127.0.0.1:8437/?mock=1`. Add `&state=empty`, `&state=error`, or `&state=offline` for fixture states. Without `?mock=1`, a plain browser shows an agent-not-connected error; mock data is never selected automatically. Mock data cannot modify files. It is development-only evidence, not agent behavior.

## Tests

```sh
cd rust/ui/frontend
node --test tests/*.test.js
```

Tests use only Node's built-in runner: API boundary and failure forwarding, mock selection, Preview non-mutation, cursor pages/filter fixtures, complete explanation fields, escaping/ledger helpers, and an HTML/CSS accessibility contract (landmarks, labels, live regions, dialog, focus, reduced motion, light/dark).

Manual verification used Chromium against the static fixture server: overview, rules, rule editor, upcoming, activity and settings screens at 1280 and 390 px widths in light and dark, rule creation with Preview and save, explanation drawer, Load more/filter, empty/error/offline states, and keyboard tab order. Contrast was computed for the main token pairs after correcting borders/placeholders. A real screen reader and Tauri webview were not run.

## Tauri shell

```sh
cargo check --manifest-path rust/ui/Cargo.toml
```

Linux requires WebKitGTK/GTK development packages; Windows requires WebView2. To run once those are present: `cargo run --manifest-path rust/ui/Cargo.toml`. Packaging and icons are intentionally minimal: the development icon is a placeholder, and bundling is disabled. Endpoint selection is shared with the CLI/daemon through `tinyprune-ipc`.
