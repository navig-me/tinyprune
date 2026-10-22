# TinyPrune cross-platform desktop UI (in development)

Unreleased engineering work. TinyPrune remains macOS-only; the native Swift app is unchanged and is not replaced. No Linux or Windows build is released. The shell has been run on Linux only inside the Docker harness below (Ubuntu 24.04, WebKitGTK under Xvfb, aarch64 container); it has also been run once on a GitHub-hosted windows-2022 runner (WebView2 131, see below) but never on macOS (WKWebView), and no screen reader has been used.

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

Manual verification used Chromium against the static fixture server: overview, rules, rule editor, upcoming, activity and settings screens at 1280 and 390 px widths in light and dark, rule creation with Preview and save, explanation drawer, Load more/filter, empty/error/offline states, and keyboard tab order. A real screen reader was not run.

## Tauri shell

```sh
cargo check --manifest-path rust/ui/Cargo.toml
```

Linux requires WebKitGTK/GTK development packages; Windows requires WebView2. To run once those are present: `cargo run --manifest-path rust/ui/Cargo.toml`. The shell reads the agent endpoint from `TINYPRUNE_ENDPOINT`, then `TINYPRUNE_SOCKET`, then the per-OS default, exactly like the daemon and CLI. If the agent cannot be reached, the error names the endpoint and says the agent is not running, instead of showing a bare OS error. Packaging is intentionally minimal: bundling is disabled and `icons/` holds a **placeholder** development icon, not a TinyPrune brand asset.

## Windows CI harness (real agent, real WebView2 window)

The non-gating (`continue-on-error`) `rust-ui-windows` job in `.github/workflows/ci.yml` builds `tinyprune-agentd`, `tinyprune` and the UI (release, `--locked`) on windows-2022, checks that the Evergreen WebView2 runtime is present (it is preinstalled on the hosted image, 131.0.2903.86 on 2026-10-21; `windows/setup-webdriver.ps1` installs Microsoft's bootstrapper if it is ever missing), downloads the Microsoft Edge WebDriver matching that version from `msedgedriver.microsoft.com` (Microsoft publishes no checksum, so the job requires a valid Microsoft Authenticode signature on the executable), installs `tauri-driver` 2.0.4 and axe-core 4.10.3, and runs `windows/run-smoke.ps1`. That script starts the real agent with an isolated `--data-dir` and a unique `\\.\pipe\tinyprune-ui-*` endpoint (`TINYPRUNE_ENDPOINT`), then runs the same `docker/fixture.py` and `docker/smoke.py` as the Linux harness (parameterised by `TINYPRUNE_UI_*` environment variables). The smoke drives the window through tauri-driver and covers Overview, Rules and Preview, Upcoming, Activity, Settings, the explanation drawer (including Escape and focus return), the pause toggle, dark and 390 px layouts, the offline state after the agent process is killed (TerminateProcess), explicit mock mode, and 15 axe-core runs (all with 0 violations). Preview never touches the Recycle Bin; the smoke checks the fixture files still exist. Artifacts (WebDriver page screenshots, whole-desktop grabs, axe JSON, agent and driver logs) are kept 7 days.

Limits: one hosted runner at 1024x768, devicePixelRatio 1 (no high-DPI or non-default scaling was exercised); the 1180x820 default window is larger than that desktop, so the lower part of the window is off-screen in the whole-desktop grabs, and those grabs are partly covered by a console window that msedgedriver makes `msedgewebview2.exe` open (the WebDriver page screenshots are unaffected). `prefers-reduced-motion` reads as reduce on the runner, so it is recorded rather than asserted. No screen reader, Narrator or installed (non-driver) launch path was tested.

Defect found by this job: with several parallel requests the agent's single pending pipe instance made the client fail with `ERROR_PIPE_BUSY` (os error 231) and the UI showed "Agent unavailable" although the agent was running. Fixed in `tinyprune-ipc` (`windows::connect` now waits for a free instance), with a Windows burst test.

## Linux Docker harness (real agent, real Tauri window)

```sh
rust/ui/docker/run.sh        # needs Docker; first run compiles the workspace and Tauri (many minutes), later runs reuse named cargo/target volumes
```

`docker/Dockerfile` (Ubuntu 24.04) installs the Tauri 2 Linux packages from the `rust-ui` CI job plus `xvfb`, `dbus-x11`, ImageMagick (`import` window grabs), `fonts-dejavu-core`, `webkit2gtk-driver` (`WebKitWebDriver`), `tauri-driver` 2.0.4 and axe-core 4.10.3 (npm, installed at image build time, then offline). `docker/container.sh` builds release `tinyprune-agentd` and `tinyprune` plus the UI, starts the real agent with isolated data, socket, `HOME`, `XDG_DATA_HOME` (Trash) and a two-file fixture tree, creates the managed root, a Keep and a Preview rule through the real CLI, then runs `docker/smoke.py` under `xvfb-run` inside a D-Bus session. `smoke.py` drives the real window through tauri-driver/WebKitWebDriver (no `?mock=1`): Overview with the managed root and `old.txt`; Rules; creating a rule by typing, Preview (`1 match`), and saving, confirmed through `tinyprune rules --json`; the explanation drawer (Escape closes it and focus returns to its trigger); Upcoming; Activity; Settings with pause/resume confirmed through the CLI; dark theme; a 390 px window with no horizontal overflow; one Tab step; `prefers-reduced-motion` (GTK animations disabled in `settings.ini`, computed `transition-duration` is `0s`); stopping the agent with SIGINT mid-session, which must show the offline state naming the endpoint; and finally the explicit `?mock=1` demo. It asserts that Preview left both fixture files in place and the Trash empty. axe-core (WCAG 2.0/2.1 A and AA tags) runs on every real screen plus drawer, dark, narrow and offline states and every mock screen, writing JSON and screenshots to `docker/out/` (gitignored). `UI_SKIP_DAEMON_BUILD=1` reuses binaries already in the target volume.

Observed (2026-10-20, Docker Desktop, aarch64 Linux container, Ubuntu 24.04 `libwebkit2gtk-4.1`): the harness printed `UI DOCKER PASS`; all 15 axe runs reported 0 violations (axe also lists one `color-contrast` node as *incomplete* on most pages: the decorative `aria-hidden` brand glyph, which has no text to measure). The frontend suite passed 10 of 10 tests in the container.

Defects this harness found and fixed: `button{display:inline-flex}` overrode the `hidden` attribute, so “Load more” stayed visible without a next page; Upcoming requested pages of 3 items from a real agent (now 50; the 3-item page remains for the mock to exercise cursors); “1 places”, “1 days”, “1 of 1 items”, “1 matches”; camel-case activity kinds printed as “moved To Trash” and every row said “No additional detail”; the explanation drawer did not return focus or close on a backdrop click; `aria-pressed` on a button whose label already flips; the pause toggle lost focus after re-render and stale toasts survived into the offline screen; overlapping toasts cleared each other early; and an unreachable agent showed only “No such file or directory (os error 2)”.

Limits and known flakiness:

- `tauri-driver` 2.0.4 intermittently reset its proxied connection (`Connection reset by peer`; 3 of the first 4 full runs failed on it before reads were retried, cause not isolated; the next 2 runs passed). `smoke.py` retries only side-effect-free reads (script execution, element lookup, screenshots) up to 3 times and never replays clicks or typing. A reset during a click still fails the run.
- This is one container image on one host architecture, one WebKitGTK version, software rendering (`WEBKIT_DISABLE_COMPOSITING_MODE=1`, `WEBKIT_DISABLE_DMABUF_RENDERER=1`), and one font set. It says nothing about WebView2 or WKWebView, about real desktops (Wayland, HiDPI, system dark mode, native file dialogs), or about a screen reader. axe finds only a subset of WCAG problems; this is not an accessibility audit.
- A fresh agent reports `protectHiddenFiles: false` and a 0 hour default grace period in Settings. That is agent behavior, not UI behavior; the UI displays what the agent returns.

### Proposed CI job (not wired; `ci.yml` is not edited here)

```yaml
  rust-ui-linux-e2e:
    name: Rust UI Linux end-to-end (Docker, WebKitGTK)
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@<pinned sha, as the other jobs>
      - name: Build image, run real agent + Tauri UI + axe
        run: bash rust/ui/docker/run.sh
      - if: always()
        uses: actions/upload-artifact@<pinned sha>
        with:
          name: rust-ui-linux-screenshots-and-axe
          path: rust/ui/docker/out/
          retention-days: 7
```

Pin the base image digest and add a cargo cache step (`~/.cargo/registry` and the target volume) before enabling it; the cold build is the cost (the first full run on the development Mac, image plus workspace and Tauri compile, took about 13 minutes). Because of the tauri-driver flake, start it as non-gating (`continue-on-error: true`) until a few GitHub runs show its stability. `run.sh` mounts the repo into the container, so on CI the artifacts appear under `rust/ui/docker/out/`.

## Update hook (manual check implemented; the rest is design only)

Settings has a "Version and updates" panel: the app version (`ui_version` Tauri command, the UI crate version), the agent version (`health` IPC request, `serviceVersion`; a note appears when it differs from the app's) and a **Check for updates** button. The button calls the `update_check` Tauri command, which runs the `tinyprune` CLI beside the UI executable (else on PATH) as `tinyprune update check --json` and returns its stdout; the frontend (`interpretUpdateCheck` in `state.js`) words checking / up to date / update available (version, build, size, release notes URL as plain text, and the `tinyprune update install --confirm <token>` command to run yourself) / unsupported / updates off / error (offline, feed rejected). The UI itself contains no network, signature, download or install code, and has no install button. Covered by `frontend/tests/frontend.test.js` (fixtures: `?mock=1&update=current|available|offline|rejected|disabled`); the Tauri command compiles under `cargo check` but was not run against a real feed or in the Docker/Windows harness. The rest of this section is still the unbuilt contract ([ADR 0012](../../ADRs/0012-rust-runtime-signed-updates.md), [tinyprune-update](../tinyprune-update/README.md)).

- At start and about hourly: `tinyprune update check --auto --json`. It exits silently (`status: skipped`) unless `checkForNewVersions` is on (default) and 24 hours have passed, and it never installs.
- Done (manual button above): a manual "Check for Updates" runs `tinyprune update check --json` and shows version, size and notes from `status: available`.
- Only after the user clicks a confirm button: `tinyprune update install --confirm <confirmationToken> --json` (the token comes from that check). Never install without that click.
- While `LoadUpdateStatus` reports a phase other than `idle`, show "pruning paused for update". The agent restarts during an install, so the UI must reconnect.
- Settings toggle: `tinyprune update settings --check-for-new-versions on|off`.
- Exit codes to handle: 65 (feed or package rejected), 69 (network unavailable), 70 (install failed or rolled back), 75 (a Trash operation is in flight, retry), 78 (updates disabled: a package-manager or development copy).

Still to build: the automatic check, an install confirm button, the update-in-progress banner, the Settings toggle, and harness coverage in `docker/smoke.py` against a fake feed.
