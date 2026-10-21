#!/usr/bin/env bash
# Remove an install made by install-managed.sh. Keeps the agent's database/audit log unless --purge.
# Never touches the Trash or any managed file.
set -euo pipefail

purge=0
linkdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) purge=1; shift ;;
    --link-dir) [ $# -ge 2 ] || { echo "--link-dir needs a value" >&2; exit 64; }; linkdir="$2"; shift 2 ;;
    -h|--help) echo "Usage: uninstall-managed.sh [--purge] [--link-dir DIR]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
if [ "$(id -u)" = "0" ]; then echo "refusing to run as root" >&2; exit 1; fi
: "${HOME:?HOME must be set}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data="${XDG_DATA_HOME:-$HOME/.local/share}/tinyprune"
[ -n "$linkdir" ] || linkdir="$HOME/.local/bin"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now tinyprune-agentd.service 2>/dev/null || true
fi
rm -f "$config_home/systemd/user/tinyprune-agentd.service"
if command -v systemctl >/dev/null 2>&1; then systemctl --user daemon-reload 2>/dev/null || true; fi

# Only symlinks that point into this install are removed.
for b in tinyprune tinyprune-agentd tinyprune-ui; do
  if [ -L "$linkdir/$b" ] && [ "$(readlink "$linkdir/$b")" = "$data/current/bin/$b" ]; then
    rm -f "$linkdir/$b"
    echo "removed $linkdir/$b"
  fi
done
if [ -L "$data/current" ] || [ -d "$data/versions" ]; then
  rm -f "$data/current" "$data/current.new"
  [ ! -d "$data/versions" ] || rm -rf "$data/versions"
  rm -rf "$data/update"
  echo "removed installed versions and update state"
fi
if [ "$purge" = 1 ]; then
  [ ! -L "$data" ] || { echo "refusing to purge: $data is a symlink" >&2; exit 1; }
  rm -rf "$data"
  echo "purged $data"
else
  echo "kept agent data in $data (use --purge to remove)"
fi
