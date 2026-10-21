#!/usr/bin/env bash
# TinyPrune development tarball installer, UPDATABLE layout (Linux, user scope, no root).
# Unreleased engineering artifact: Linux is not a supported or released platform.
#
# Unlike install.sh (plain files in ~/.local/bin, never touched by the updater), this lays the build out
# so `tinyprune update install` can swap it atomically (ADR 0012):
#   ${XDG_DATA_HOME:-~/.local/share}/tinyprune/versions/<package_version>-b<build>/{bin,share,VERSION}
#   ${XDG_DATA_HOME:-~/.local/share}/tinyprune/current -> versions/<name>      (relative symlink)
#   ~/.local/bin/{tinyprune,tinyprune-agentd[,tinyprune-ui]} -> <data>/current/bin/*  (symlinks)
#   ${XDG_CONFIG_HOME:-~/.config}/systemd/user/tinyprune-agentd.service  (ExecStart via <data>/current/bin)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-managed.sh [--enable-service] [--no-systemd] [--link-dir DIR] [--help]

Installs into your home directory; refuses to run as root.
  --enable-service   Also `systemctl --user enable --now tinyprune-agentd`
  --no-systemd       Do not install the systemd user unit
  --link-dir DIR     Where the command symlinks go (default: ~/.local/bin)
Updates: `tinyprune update check` / `tinyprune update install --confirm <token>`
EOF
}

enable=0
systemd=1
linkdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --enable-service) enable=1; shift ;;
    --no-systemd) systemd=0; shift ;;
    --link-dir) [ $# -ge 2 ] || { echo "--link-dir needs a value" >&2; exit 64; }; linkdir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done
if [ "$(id -u)" = "0" ]; then
  echo "refusing to run as root: this installs per-user files only" >&2
  exit 1
fi
: "${HOME:?HOME must be set}"
if [ "$enable" = 1 ] && [ "$systemd" = 0 ]; then
  echo "--enable-service conflicts with --no-systemd" >&2; exit 64
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in bin/tinyprune bin/tinyprune-agentd share/systemd/user/tinyprune-agentd.service VERSION; do
  [ -f "$here/$f" ] || { echo "incomplete package: missing $f" >&2; exit 1; }
done

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
data="$data_home/tinyprune"
[ -n "$linkdir" ] || linkdir="$HOME/.local/bin"
case "$data$linkdir" in
  *[[:space:]%\"\'\\\$\;]*) echo "install paths must not contain whitespace, quotes, %, \\, \$ or ;" >&2; exit 64 ;;
esac

package_version="$(sed -n 's/^package_version=//p' "$here/VERSION" | sed -n '1p')"
build="$(sed -n 's/^build=//p' "$here/VERSION" | sed -n '1p')"
: "${build:=0}"
name="${package_version}-b${build}"
case "$name" in
  ''|.*|*[!0-9A-Za-z.+_-]*) echo "VERSION has an unusable package_version/build: '$name'" >&2; exit 1 ;;
esac
[ "$build" != 0 ] || echo "note: this package has no build number (build=0): it installs, but updates stay disabled" >&2

# Never take over an unmanaged install silently.
for b in tinyprune tinyprune-agentd tinyprune-ui; do
  if [ -e "$linkdir/$b" ] && [ ! -L "$linkdir/$b" ]; then
    echo "$linkdir/$b exists and is not a symlink (an install.sh copy?). Run its uninstall.sh first." >&2
    exit 1
  fi
done

mkdir -p "$data/versions" "$linkdir"
if [ -e "$data/versions/$name" ]; then
  echo "version $name is already installed at $data/versions/$name" >&2
  exit 1
fi
stage="$data/versions/.stage-$$"
rm -rf "$stage"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT
cp -R "$here/bin" "$here/share" "$stage/"
cp "$here/VERSION" "$stage/VERSION"
[ ! -f "$here/LICENSE" ] || cp "$here/LICENSE" "$stage/LICENSE"
chmod 0755 "$stage"/bin/*
mv "$stage" "$data/versions/$name"
trap - EXIT

# Atomic pointer swap: rename a fresh symlink over `current`.
ln -s "versions/$name" "$data/current.new"
mv -T "$data/current.new" "$data/current"
echo "installed $data/versions/$name and pointed $data/current at it"

for b in tinyprune tinyprune-agentd tinyprune-ui; do
  [ -e "$here/bin/$b" ] || continue
  ln -sfn "$data/current/bin/$b" "$linkdir/$b"
  echo "linked $linkdir/$b"
done

if [ "$systemd" = 1 ]; then
  unit_dir="$config_home/systemd/user"
  mkdir -p "$unit_dir"
  # ExecStart resolves `current` at every (re)start, so an update only has to restart the unit.
  sed "s|@BINDIR@|$data/current/bin|g" "$here/share/systemd/user/tinyprune-agentd.service" >"$unit_dir/tinyprune-agentd.service"
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
  *":$linkdir:"*) ;;
  *) echo "note: $linkdir is not on PATH" ;;
esac
echo "next: tinyprune doctor   (agent data lives in $data)"
