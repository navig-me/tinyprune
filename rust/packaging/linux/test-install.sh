#!/usr/bin/env bash
# Hermetic test of package.sh + install.sh + uninstall.sh: temp HOME, fake systemctl
# shim, stub binaries. Does not run systemd or the real agent.
#   test-install.sh [--bin-dir DIR]   (default: stub binaries)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_src=""
[ "${1:-}" != "--bin-dir" ] || bin_src="$2"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { [ -e "$1" ] || fail "expected $1"; }
hasnt() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "unexpected $1"; }

if [ -z "$bin_src" ]; then
  bin_src="$work/stubs"; mkdir -p "$bin_src"
  for b in tinyprune tinyprune-agentd tinyprune-ui; do
    printf '#!/bin/sh\necho "%s stub"\n' "$b" >"$bin_src/$b"; chmod +x "$bin_src/$b"
  done
fi
ui=""; [ ! -x "$bin_src/tinyprune-ui" ] || ui="--ui-bin $bin_src/tinyprune-ui"

# shellcheck disable=SC2086
archive="$("$here/package.sh" --bin-dir "$bin_src" --out-dir "$work/out" --arch testarch $ui)"
has "$archive"; has "$archive.sha256"
(cd "$work/out" && { sha256sum -c "$(basename "$archive").sha256" 2>/dev/null || shasum -a 256 -c "$(basename "$archive").sha256"; } >/dev/null) || fail "checksum"
mkdir "$work/x"; tar -xzf "$archive" -C "$work/x"
pkg="$(echo "$work"/x/tinyprune-dev-*)"
grep -q '^status=unreleased-development-artifact' "$pkg/VERSION" || fail "VERSION stamp"
grep -q '^package_version=0\.' "$pkg/VERSION" || fail "VERSION package_version"

# Fake systemctl records its arguments.
mkdir "$work/shim"
cat >"$work/shim/systemctl" <<EOF
#!/bin/sh
echo "\$@" >>"$work/systemctl.log"
EOF
chmod +x "$work/shim/systemctl"

export HOME="$work/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME XDG_DATA_HOME
export PATH="$work/shim:$PATH"
unit="$HOME/.config/systemd/user/tinyprune-agentd.service"

# 1. Default install: files present, unit rewritten, service NOT enabled.
"$pkg/install.sh" >"$work/install.log"
has "$HOME/.local/bin/tinyprune"; has "$HOME/.local/bin/tinyprune-agentd"; has "$unit"
grep -q "^ExecStart=$HOME/.local/bin/tinyprune-agentd\$" "$unit" || fail "ExecStart not substituted"
! grep -q '@BINDIR@' "$unit" || fail "placeholder left in unit"
grep -q 'daemon-reload' "$work/systemctl.log" || fail "no daemon-reload"
! grep -q 'enable' "$work/systemctl.log" || fail "enabled without --enable-service"
if [ -n "$ui" ]; then
  has "$HOME/.local/share/applications/tinyprune.desktop"
  grep -q "^Exec=$HOME/.local/bin/tinyprune-ui\$" "$HOME/.local/share/applications/tinyprune.desktop" || fail "desktop Exec"
fi

# 2. Idempotent re-install with --enable-service.
"$pkg/install.sh" --enable-service >/dev/null
grep -q 'enable --now tinyprune-agentd.service' "$work/systemctl.log" || fail "enable not called"

# 3. User data survives plain uninstall; unrelated files untouched.
mkdir -p "$HOME/.local/share/tinyprune/logs"; echo x >"$HOME/.local/share/tinyprune/agent.sqlite3"
echo keep >"$HOME/.local/bin/unrelated"
"$pkg/uninstall.sh" >/dev/null
hasnt "$unit"; hasnt "$HOME/.local/bin/tinyprune"; hasnt "$HOME/.local/bin/tinyprune-agentd"
hasnt "$HOME/.local/share/applications/tinyprune.desktop"
has "$HOME/.local/share/tinyprune/agent.sqlite3"; has "$HOME/.local/bin/unrelated"
grep -q 'disable --now tinyprune-agentd.service' "$work/systemctl.log" || fail "disable not called"

# 4. --purge removes only the data dir; refuses a symlinked data dir.
"$pkg/install.sh" --no-systemd >/dev/null; hasnt "$unit"
"$pkg/uninstall.sh" --purge >/dev/null
hasnt "$HOME/.local/share/tinyprune"; has "$HOME/.local/bin/unrelated"
mkdir "$work/victim"; echo precious >"$work/victim/f"; ln -s "$work/victim" "$HOME/.local/share/tinyprune"
if "$pkg/uninstall.sh" --purge >/dev/null 2>&1; then fail "purged through symlink"; fi
has "$work/victim/f"; rm "$HOME/.local/share/tinyprune"

# 5. Custom prefix + XDG overrides; bad prefixes rejected.
export XDG_CONFIG_HOME="$work/cfg" XDG_DATA_HOME="$work/data"
"$pkg/install.sh" --prefix "$work/pfx" >/dev/null
has "$work/pfx/bin/tinyprune"; has "$work/cfg/systemd/user/tinyprune-agentd.service"
"$pkg/uninstall.sh" --prefix "$work/pfx" >/dev/null; hasnt "$work/pfx/bin/tinyprune"
if "$pkg/install.sh" --prefix "$work/has space" >/dev/null 2>&1; then fail "space prefix accepted"; fi
if "$pkg/install.sh" --prefix relative >/dev/null 2>&1; then fail "relative prefix accepted"; fi
if "$pkg/install.sh" --enable-service --no-systemd >/dev/null 2>&1; then fail "conflicting flags accepted"; fi
echo "PASS"
