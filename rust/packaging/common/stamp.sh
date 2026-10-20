#!/usr/bin/env bash
# Print the VERSION stamp for a development package: crate versions come from the
# Cargo.toml files, the revision from git (GITHUB_SHA in CI). No timestamps, so the
# stamp is reproducible for a given commit. Usage: stamp.sh <target-label>
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
label="${1:?target label required, e.g. linux-x86_64}"

crate_version() {
  sed -n 's/^version *= *"\(.*\)"/\1/p' "$root/rust/$1/Cargo.toml" | sed -n '1p'
}
daemon="$(crate_version tinyprune-daemon)"
cli="$(crate_version tinyprune-cli)"
ui="$(crate_version ui)"
[ -n "$daemon" ] && [ -n "$cli" ] || { echo "cannot read crate versions" >&2; exit 1; }

sha="${GITHUB_SHA:-}"
[ -n "$sha" ] || sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
short="$(printf %.12s "$sha")"
dirty=""
if [ -z "${GITHUB_SHA:-}" ] && [ -n "$(git -C "$root" status --porcelain -- rust 2>/dev/null || true)" ]; then
  dirty="-dirty"
fi

cat <<EOF
status=unreleased-development-artifact
package_version=$daemon+g$short$dirty
tinyprune-agentd=$daemon
tinyprune=$cli
tinyprune-ui=$ui
git_sha=$sha$dirty
target=$label
EOF
