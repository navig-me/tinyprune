#!/usr/bin/env bash
# TinyPrune development tarball installer (Linux, user scope, no root).
# Unreleased engineering artifact: Linux is not a supported or released platform.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [--prefix DIR] [--enable-service] [--no-systemd] [--help]

Installs into your home directory; refuses to run as root.
  --prefix DIR       Install binaries to DIR/bin (default: ~/.local)
  --enable-service   Also `systemctl --user enable --now tinyprune-agentd`
                     (default: the unit is installed but NOT enabled or started)
  --no-systemd       Do not install the systemd user unit at all
Files:
  PREFIX/bin/{tinyprune,tinyprune-agentd[,tinyprune-ui]}
  ${XDG_CONFIG_HOME:-~/.config}/systemd/user/tinyprune-agentd.service
  ${XDG_DATA_HOME:-~/.local/share}/applications/tinyprune.desktop   (only if the UI is bundled)
Check afterwards with: tinyprune doctor
EOF
}

prefix=""
enable=0
systemd=1
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a value" >&2; exit 64; }; prefix="$2"; shift 2 ;;
    --enable-service) enable=1; shift ;;
    --no-systemd) systemd=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ "$(id -u)" = "0" ]; then
  echo "refusing to run as root: this installs per-user files only" >&2
  exit 1
fi
: "${HOME:?HOME must be set}"
[ -n "$prefix" ] || prefix="$HOME/.local"
case "$prefix" in
  /*) ;;
  *) echo "--prefix must be an absolute path" >&2; exit 64 ;;
esac
# systemd expands % and splits on whitespace in ExecStart; keep the path trivial.
case "$prefix" in
  *[[:space:]%\"\'\\\$\;]*) echo "--prefix must not contain whitespace, quotes, %, \\, \$ or ;" >&2; exit 64 ;;
esac
if [ "$enable" = 1 ] && [ "$systemd" = 0 ]; then
  echo "--enable-service conflicts with --no-systemd" >&2; exit 64
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in bin/tinyprune bin/tinyprune-agentd share/systemd/user/tinyprune-agentd.service; do
  [ -f "$here/$f" ] || { echo "incomplete package: missing $f" >&2; exit 1; }
done

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
bindir="$prefix/bin"
unit_dir="$config_home/systemd/user"
apps_dir="$data_home/applications"

mkdir -p "$bindir"
install -m 0755 "$here/bin/tinyprune" "$bindir/tinyprune"
install -m 0755 "$here/bin/tinyprune-agentd" "$bindir/tinyprune-agentd"
echo "installed $bindir/tinyprune and $bindir/tinyprune-agentd"

if [ -f "$here/bin/tinyprune-ui" ]; then
  install -m 0755 "$here/bin/tinyprune-ui" "$bindir/tinyprune-ui"
  mkdir -p "$apps_dir"
  sed "s|@BINDIR@|$bindir|g" "$here/share/applications/tinyprune.desktop" >"$apps_dir/tinyprune.desktop"
  chmod 0644 "$apps_dir/tinyprune.desktop"
  echo "installed $bindir/tinyprune-ui and $apps_dir/tinyprune.desktop"
fi

if [ "$systemd" = 1 ]; then
  mkdir -p "$unit_dir"
  sed "s|@BINDIR@|$bindir|g" "$here/share/systemd/user/tinyprune-agentd.service" >"$unit_dir/tinyprune-agentd.service"
  chmod 0644 "$unit_dir/tinyprune-agentd.service"
  echo "installed $unit_dir/tinyprune-agentd.service"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || echo "warning: systemctl --user daemon-reload failed" >&2
    if [ "$enable" = 1 ]; then
      systemctl --user enable --now tinyprune-agentd.service
      echo "service enabled and started"
    else
      echo "service NOT enabled. To start: systemctl --user enable --now tinyprune-agentd.service"
    fi
  else
    echo "systemctl not found; unit installed but not loaded" >&2
    [ "$enable" = 0 ] || { echo "cannot enable service without systemctl" >&2; exit 1; }
  fi
fi

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "note: $bindir is not on PATH" ;;
esac
echo "next: tinyprune doctor   (agent data lives in ${data_home}/tinyprune)"
