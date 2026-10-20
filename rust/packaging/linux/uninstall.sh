#!/usr/bin/env bash
# Remove a TinyPrune development install made by install.sh. Leaves user data
# (agent database, logs) unless --purge. Never touches Trash or managed files.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--prefix DIR] [--purge] [--help]
  --prefix DIR   Prefix used at install time (default: ~/.local)
  --purge        Also delete the agent's own data directory
                 (${XDG_DATA_HOME:-~/.local/share}/tinyprune: database, audit log, socket).
                 Items already moved to Trash are NOT touched.
EOF
}

prefix=""
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a value" >&2; exit 64; }; prefix="$2"; shift 2 ;;
    --purge) purge=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ "$(id -u)" = "0" ]; then
  echo "refusing to run as root" >&2; exit 1
fi
: "${HOME:?HOME must be set}"
[ -n "$prefix" ] || prefix="$HOME/.local"
case "$prefix" in /*) ;; *) echo "--prefix must be an absolute path" >&2; exit 64 ;; esac

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
unit="$config_home/systemd/user/tinyprune-agentd.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now tinyprune-agentd.service >/dev/null 2>&1 || true
fi

removed=0
for f in "$unit" "$prefix/bin/tinyprune" "$prefix/bin/tinyprune-agentd" \
         "$prefix/bin/tinyprune-ui" "$data_home/applications/tinyprune.desktop"; do
  if [ -e "$f" ] || [ -L "$f" ]; then
    rm -f -- "$f"
    echo "removed $f"
    removed=$((removed + 1))
  fi
done
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

data="$data_home/tinyprune"
if [ "$purge" = 1 ]; then
  if [ -L "$data" ]; then
    echo "refusing to purge: $data is a symlink" >&2; exit 1
  elif [ -d "$data" ]; then
    # Only the agent's private directory (exact name, under the data home).
    rm -rf -- "$data"
    echo "purged $data"
  fi
elif [ -d "$data" ]; then
  echo "kept user data in $data (use --purge to delete it)"
fi
echo "uninstall complete ($removed files removed)"
