# Rust developer-preview packaging

Packages the Rust daemon (`tinyprune-agentd`), CLI (`tinyprune`) and, when built, Tauri UI (`tinyprune-ui`) into unsigned Linux and Windows archives. The [0.2.0 developer preview](https://github.com/navig-me/tinyprune/releases/tag/rust-preview-0.2.0) is published; these platforms are not supported general-desktop products. macOS uses the separate Swift application. The artifact-build workflow uses no secrets and does not publish releases; the separate reviewed signing workflow authenticates the update feed with the existing production key. See the [release log](../../RELEASES.md#020) for published artifacts, hashes and verification evidence.

**macOS is deliberately not packaged.** The macOS CI leg only builds and runs `--version` on the binaries.

## Layout

```
packaging/
  common/stamp.sh          VERSION stamp (crate versions from Cargo.toml + git sha)
  linux/                   tinyprune-agentd.service, tinyprune.desktop, install.sh, uninstall.sh,
                           install-managed.sh, uninstall-managed.sh, package.sh, test-install.sh
  windows/                 install.ps1, uninstall.ps1, install-managed.ps1, uninstall-managed.ps1, package.ps1
```

CI: `.github/workflows/rust-artifacts.yml` (`workflow_dispatch` and `pull_request` touching `rust/**`; `contents: read`; pinned action SHAs; 7-day artifact retention; no release/publish step).

### Archive contents

`tinyprune-dev-<version>-linux-x86_64.tar.gz` / `tinyprune-dev-<version>-windows-x86_64.zip`, each with a `.sha256` sidecar, plus a per-job `SHA256SUMS` in the workflow artifact. Inside: `bin/` (`tinyprune`, `tinyprune-agentd`, optional `tinyprune-ui`), the install/uninstall scripts, Linux `share/systemd/user/` and (with UI) `share/applications/`, `LICENSE`, `README.txt`, `VERSION`.

`VERSION` is key=value text, no timestamps: `status=unreleased-development-artifact`, `package_version=<daemon crate version>+g<12-char sha>` (`-dirty` appended for local builds with uncommitted changes under `rust/`), `build=<TINYPRUNE_BUILD>` (0 for unstamped local builds), each crate's version, full `git_sha`, `target`. All workspace crates and `rust/ui` carry the same version (`Scripts/check-versions.py` enforces it; the release version is in [RELEASES.md](../../RELEASES.md)); the archive name uses the daemon's. `tinyprune-agentd --version` and `tinyprune --version` print the crate version only (no git sha embedded in the binary). The `tinyprune-dev` archive name and `unreleased-development-artifact` status are unchanged for the 0.2.0 developer preview.

### Doctor-friendly layout

Binaries install to `<prefix>/bin` (Linux `~/.local/bin`, Windows `%LOCALAPPDATA%\Programs\TinyPrune\bin`); the CLI finds the agent through the same default endpoint the agent uses (Linux `${XDG_DATA_HOME:-~/.local/share}/tinyprune/agent.sock`; Windows per-user named pipe). Installers end by printing `tinyprune doctor`. Agent state is separate from the install: Linux `${XDG_DATA_HOME:-~/.local/share}/tinyprune`, Windows `%LOCALAPPDATA%\TinyPrune`.

## Install the published developer preview with updates

Download and extract the archive for your platform from the [preview release](https://github.com/navig-me/tinyprune/releases/tag/rust-preview-0.2.0), and verify its SHA-256 against the attached checksum files. The signed feed authenticates those archive hashes; it does not OS-sign the executables or remove trust warnings.

For a managed, updatable installation, run from the extracted archive as your normal user:

```sh
# Linux: install the managed layout and start the systemd user service.
./install-managed.sh --enable-service
# For an isolated CLI-only inspection without a service, use --no-systemd instead.
```

```powershell
# Windows: normal, non-administrator PowerShell.
powershell -ExecutionPolicy Bypass -File .\install-managed.ps1 -Start -AddToPath
# Open a new terminal so the PATH change is visible.
```

Then run `tinyprune update check --json`. A current installation reports `upToDate`; an available update supplies a confirmation token for `tinyprune update install --confirm <token>`. Installation requires explicit confirmation. Both live production feeds passed protected public verification; the published Linux managed client also consumed the real feed in an isolated non-root container. This is not proof of production OS update installation on every platform.

Managed installers use version directories and a current-version pointer rather than overwriting running binaries. Use the corresponding `uninstall-managed.sh` or `uninstall-managed.ps1` for that layout. The `install.sh` / `install.ps1` examples below are **unmanaged** developer installs and are deliberately excluded from in-app updates, as are package-manager installations. Do not overlay a managed installation onto a plain-copy installation; use its own uninstaller first, preserving data unless you explicitly choose a purge.

## Linux

Build the archive from built release binaries (`cd rust && cargo build --release --locked -p tinyprune-daemon -p tinyprune-cli`):

```sh
rust/packaging/linux/package.sh --bin-dir rust/target/release --out-dir dist [--ui-bin rust/ui/target/release/tinyprune-ui]
```

Install (user scope; refuses root; no sudo ever):

```sh
tar xzf tinyprune-dev-*-linux-x86_64.tar.gz && cd tinyprune-dev-*/
./install.sh [--prefix DIR] [--enable-service] [--no-systemd]
./uninstall.sh [--prefix DIR] [--purge]
```

By default the unit is installed but **not enabled or started**; `--enable-service` runs `systemctl --user enable --now tinyprune-agentd.service`. `uninstall.sh` disables/stops the unit and removes only the files install.sh wrote (unit, binaries, desktop entry). It keeps the agent data directory unless `--purge`, which removes only `${XDG_DATA_HOME:-~/.local/share}/tinyprune` (database, audit log, socket) and refuses if that path is a symlink. Neither script touches the Trash or any managed file. `--prefix` must be absolute and free of whitespace and `% " ' \ $ ;` (systemd expands those in `ExecStart`).

### Sandboxing (why the unit is not "fully hardened")

The agent must be able to move any file the user owns into the freedesktop Trash: `$XDG_DATA_HOME/Trash`, or `<mount>/.Trash-$UID` / `<mount>/.Trash/$UID` for items on other mounts (`/media`, `/mnt`, network shares), from managed roots the user chooses at runtime. Mount-namespace sandboxing cannot express that set, so the unit deliberately omits `ProtectSystem=strict|full` (with `ReadWritePaths`: managed roots and per-mount trash dirs cannot be enumerated at install time), `ProtectHome`, `InaccessiblePaths`, `TemporaryFileSystem`, `BindPaths`, `PrivateTmp` (hides the real `/tmp`), `PrivateDevices`, `PrivateUsers`. Adding any of these would make some legitimate trash operations fail or, worse, silently see a different filesystem. What is kept does not change the filesystem view: `NoNewPrivileges`, `LockPersonality`, `RestrictRealtime`, `RestrictSUIDSGID`, `RestrictNamespaces`, `SystemCallArchitectures=native`, `RestrictAddressFamilies=AF_UNIX` (IPC is a Unix socket; no network), `MemoryDenyWriteExecute`, `UMask=0077`. Also: `KillSignal=SIGINT` because the daemon handles only SIGINT (SIGTERM would skip its clean shutdown); `Restart=on-failure` with a start-limit.

`SystemCallFilter` is not set: I could not exercise the daemon under systemd here, so an allow-list I cannot validate could break trashing; tighten it only after running it under `strace`/`systemd-analyze security` on Linux.

### Testing the Linux scripts

```sh
shellcheck -x rust/packaging/linux/*.sh rust/packaging/common/*.sh
rust/packaging/linux/test-install.sh [--bin-dir rust/target/release]
```

`test-install.sh` builds a package, verifies the checksum and VERSION stamp, then in a temp `HOME` with a fake `systemctl` shim checks: default install (no enable), unit placeholder substitution, `--enable-service`, uninstall preserving data and unrelated files, `--purge`, symlink refusal, `--prefix`/`XDG_*` overrides and bad-argument rejection. It runs in CI on Linux against the real binaries.

`docker-test.sh [--archive FILE]` is the real acceptance test: it builds (or takes) the tarball, then in a fresh Ubuntu 24.04 container with systemd as PID 1 (`--privileged --cgroupns=host`, `loginctl enable-linger`) and a non-root user runs `install.sh --enable-service`, `systemd-analyze verify`, `desktop-file-validate`, starts the agent through `systemctl --user`, adds roots and rules through the CLI, checks the Trash result (home Trash `.trashinfo` encoding for a path with spaces, `%` and Unicode, a standard `trash-restore`, a tmpfs mount's `.Trash-$uid` fallback with a relative `Path=`, and refusal without copy/delete when the same-device Trash is unwritable), `systemctl --user stop` (SIGINT, exit 0, socket removed), restart after `kill -KILL`, then `uninstall.sh` (keeps data) and `--purge`. If a real user manager cannot start it falls back to the unit verification plus running ExecStart directly (and says so); the restart-on-failure check is skipped there.

## Windows

```powershell
packaging\windows\package.ps1 -BinDir rust\target\release -OutDir dist [-UiBin rust\ui\target\release\tinyprune-ui.exe]
# in the extracted zip, from a NORMAL (non-admin) PowerShell:
powershell -ExecutionPolicy Bypass -File install.ps1 [-Prefix DIR] [-Start] [-AddToPath] [-NoTask]
powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-Prefix DIR] [-Purge]
```

`install.ps1` refuses elevation, copies the binaries and registers the per-user Scheduled Task `TinyPrune Agent (dev)`: trigger at logon of the current user, interactive token with `RunLevel Limited` (no elevation), restart up to 5 times at 1-minute intervals on failure, no execution time limit, single instance, runs on battery. The task is not started unless `-Start`. `-AddToPath` edits only the user (HKCU) PATH. With the UI, a Start Menu shortcut is created. `uninstall.ps1` stops and unregisters the task, removes the files, shortcut and PATH entry, leaves `%LOCALAPPDATA%\TinyPrune` unless `-Purge` (refuses a reparse point), and never touches the Recycle Bin.

Known limits: the agent is a console binary, so the task may show a console window at logon; `Stop-ScheduledTask` terminates the process rather than sending Ctrl-C, so the agent does not run its graceful shutdown (lock/socket cleanup relies on startup recovery; [INFERENCE] not verified). The zip is not signed, so SmartScreen may warn.

## Versioning and checksums

Stamping is done at packaging time (`common/stamp.sh`, `package.ps1`) from `Cargo.toml` and `git rev-parse HEAD` (`GITHUB_SHA` in CI). Verify downloads with `sha256sum -c <archive>.sha256` (Linux) or compare `Get-FileHash -Algorithm SHA256` against the `.sha256` file / `SHA256SUMS`.

## Tauri bundling

`rust/ui/tauri.conf.json` keeps `bundle.active = false` and is not changed: `cargo build --release` of the UI produces a bare executable, which is what is packaged. `tauri build` bundles (deb/AppImage/MSI/NSIS) are out of scope: they need the Tauri CLI (an extra dependency) and real icons, and have not been tried.

## CI workflow (`rust-artifacts.yml`)

Matrix `ubuntu-24.04`, `windows-2022`, `macos-14`. Each: pinned toolchain from `rust-toolchain.toml`, `cargo build --release --locked -p tinyprune-daemon -p tinyprune-cli`, run `--version` of both binaries and require the crate version in the output. Ubuntu/Windows then package, upload (`tinyprune-rust-dev-<runner>`, 7 days, with `SHA256SUMS`); macOS uploads nothing. The UI step (Ubuntu: apt GTK/WebKit packages; Windows: WebView2 is preinstalled) is `continue-on-error`, so if it fails the package silently omits the UI; check the step result in the run. The Windows job also parse-checks the install scripts under real PowerShell; the Linux job runs `test-install.sh`.

Update identity: every run stamps `TINYPRUNE_BUILD` (the run's `github.run_number`, a counter separate from `release.yml`). The production update public key (`TINYPRUNE_UPDATE_PUBLIC_KEY`, from the repository variable of the same name) is embedded **only** by the step "Embed production update key" and only on a `workflow_dispatch` run on `main`; pull-request and other-branch builds have updates disabled. See [.github/RELEASING.md](../../.github/RELEASING.md).

## What is NOT verified

- Linux scripts and UI builds ran in recorded local/CI checks, including the x86_64 build 29 Docker installation check. A separate non-root Ubuntu 24.04 container installed the published managed archive and successfully checked the live production feed without starting systemd or installing an update. Distro variety, SELinux/AppArmor and desktop acceptance remain outside this evidence.
- Windows install/task/uninstall and managed update/rollback paths ran on hosted `windows-2022` with real binaries. The update end-to-end check used a throwaway key and loopback feed; it does not prove a production-key update installation, non-admin acceptance, or logon/reboot-trigger behavior.
- Both 0.2.0 archive builds included the UI. See the [status matrix](../README.md#status-matrix) and [release log](../../RELEASES.md#020) for exact runs, native UI checks and remaining screen-reader/general-desktop limits; a green build alone is not that acceptance.
- Tauri bundling, `.deb`, AppImage, MSI: not attempted.
- Archives are unsigned and unreproducible beyond a stable VERSION stamp (tar/zip metadata is not normalised on Windows).
