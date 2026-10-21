#!/usr/bin/env bash
set -euo pipefail
export CARGO_TARGET_DIR=/build
mkdir -p rust/ui/docker/out && rm -f rust/ui/docker/out/*
if [[ "${UI_SKIP_DAEMON_BUILD:-0}" != 1 ]]; then
  cargo build --manifest-path rust/Cargo.toml --release --locked -p tinyprune-daemon -p tinyprune-cli
fi
cargo build --manifest-path rust/ui/Cargo.toml --release --locked -p tinyprune-ui
node --test rust/ui/frontend/tests/frontend.test.js
export HOME=/tmp/tinyprune-ui-home XDG_DATA_HOME=/tmp/tinyprune-ui-xdg TINYPRUNE_ENDPOINT=/tmp/tinyprune-ui-socket/agent.sock
mkdir -p "$HOME/.config/gtk-3.0"
printf '[Settings]\ngtk-enable-animations=false\n' > "$HOME/.config/gtk-3.0/settings.ini"
# Software rendering inside Xvfb (no GPU/DRI3 in the container); chosen up front, not shown to be required.
export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1
mkdir -p "$HOME" "$XDG_DATA_HOME" /tmp/tinyprune-ui-socket /tmp/tinyprune-ui-fixture
chmod 700 /tmp/tinyprune-ui-socket
printf 'metadata fixture\n' > /tmp/tinyprune-ui-fixture/old.txt
printf 'keep fixture\n' > /tmp/tinyprune-ui-fixture/keep.txt
touch -t 202001010000 /tmp/tinyprune-ui-fixture/*.txt
/build/release/tinyprune-agentd --data-dir /tmp/tinyprune-ui-data > rust/ui/docker/out/agent.log 2>&1 &
agent=$!
trap 'kill -INT "$agent" 2>/dev/null || true' EXIT
export TINYPRUNE_UI_AGENT_PID="$agent"
python3 rust/ui/docker/fixture.py
exec dbus-run-session -- xvfb-run -a -s '-screen 0 1440x1000x24' python3 rust/ui/docker/smoke.py
