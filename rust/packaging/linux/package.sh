#!/usr/bin/env bash
# Build the Linux development tarball from already-built release binaries.
#   package.sh --bin-dir DIR --out-dir DIR [--ui-bin FILE] [--arch x86_64]
# Output (in --out-dir):
#   tinyprune-dev-<ver>-linux-<arch>.tar.gz   and   <same>.tar.gz.sha256
set -euo pipefail

bin_dir=""; out_dir=""; ui_bin=""; arch="$(uname -m)"
while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) bin_dir="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --ui-bin) ui_bin="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
[ -n "$bin_dir" ] && [ -n "$out_dir" ] || { echo "--bin-dir and --out-dir are required" >&2; exit 64; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
for b in tinyprune tinyprune-agentd; do
  [ -x "$bin_dir/$b" ] || { echo "missing executable $bin_dir/$b" >&2; exit 1; }
done
[ -z "$ui_bin" ] || [ -x "$ui_bin" ] || { echo "missing executable $ui_bin" >&2; exit 1; }

stamp="$("$here/../common/stamp.sh" "linux-$arch")"
version="$(printf '%s\n' "$stamp" | sed -n 's/^package_version=//p')"
name="tinyprune-dev-${version//+/-}-linux-$arch"

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
pkg="$stage/$name"
mkdir -p "$pkg/bin" "$pkg/share/systemd/user" "$pkg/share/applications"
install -m 0755 "$bin_dir/tinyprune" "$bin_dir/tinyprune-agentd" "$pkg/bin/"
if [ -n "$ui_bin" ]; then
  install -m 0755 "$ui_bin" "$pkg/bin/tinyprune-ui"
  install -m 0644 "$here/tinyprune.desktop" "$pkg/share/applications/tinyprune.desktop"
else
  rmdir "$pkg/share/applications"
fi
install -m 0644 "$here/tinyprune-agentd.service" "$pkg/share/systemd/user/"
install -m 0755 "$here/install.sh" "$here/uninstall.sh" "$here/install-managed.sh" "$here/uninstall-managed.sh" "$pkg/"
install -m 0644 "$root/LICENSE" "$pkg/LICENSE"
printf '%s\n' "$stamp" >"$pkg/VERSION"
cat >"$pkg/README.txt" <<'EOF'
TinyPrune development build. UNRELEASED engineering artifact: Linux is not a
supported platform; the macOS app is the only released TinyPrune.
Install (user scope, no root):  ./install.sh [--prefix DIR] [--enable-service]
Remove:                         ./uninstall.sh [--purge]
Updatable layout (versions/ + current symlink, `tinyprune update`):
                                ./install-managed.sh [--enable-service]   /   ./uninstall-managed.sh [--purge]
Check:                          tinyprune doctor
EOF

archive="$out_dir/$name.tar.gz"
# Deterministic ordering; ownership normalised so extraction never needs root.
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner -czf "$archive" "$name" 2>/dev/null \
  || tar -C "$stage" -czf "$archive" "$name"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$out_dir" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
else
  (cd "$out_dir" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
fi
echo "$archive"
