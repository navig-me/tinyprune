#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
image="tinyprune-ui-linux:local"
docker build -t "$image" "$repo/rust/ui/docker"
mkdir -p "$repo/rust/ui/docker/out"
docker run --rm --init --shm-size=1g -e UI_SKIP_DAEMON_BUILD \
  -v "$repo:/repo" \
  -v tinyprune-ui-cargo-cache:/usr/local/cargo/registry \
  -v tinyprune-ui-target:/build \
  "$image"
