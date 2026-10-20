#!/usr/bin/env bash
# Docker Linux end-to-end for `tinyprune update` (ADR 0012). Requires Docker; unreleased dev tooling.
#
#   rust/tests-e2e/update-docker.sh            build fixtures in Docker, run the scenario under real systemd
#
# What it does (nothing here touches the host agent):
#   1. In a rust:1.98.1 container: build `tinyprune-feed`, make a THROWAWAY Ed25519 test key, build three
#      stamped variants of the daemon+CLI (0.1.0 build 1 = old, 0.2.0 build 2 = new, 0.3.0 build 3 =
#      new but with an agent that dies on start), package each, and generate + sign feeds for several
#      scenarios (good, tampered feed, tampered artifact, stale/replayed, bad-agent).
#   2. In an Ubuntu 24.04 container with systemd PID 1 and a real per-user manager: install the OLD build in
#      the updatable layout, add a root/rule/Keep, serve the feeds with python http.server (test harness
#      only), then exercise check, confirmation, tamper rejection, the real update and restart, state
#      preservation, replay/downgrade refusal, and a failed-health update that must roll back.
# The compiled test binaries use the `test-overrides` features (loopback http feed); released artifacts do not.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
BASE=http://127.0.0.1:8765

# ---------------------------------------------------------------------------------------------------
# Phase 1 (inside the rust container): build + sign fixtures into $1
# ---------------------------------------------------------------------------------------------------
build_fixtures() {
  local out=$1
  cd /src/rust
  export CARGO_TARGET_DIR=/target
  cargo build --release --locked -p tinyprune-update --bin tinyprune-feed --features test-overrides
  local feed=/target/release/tinyprune-feed
  "$feed" test-keygen --seed-file "$out/seed.bin" >"$out/pubkey"
  local pub
  pub="$(cat "$out/pubkey")"

  variant() { # version build dir
    export TINYPRUNE_UPDATE_PUBLIC_KEY="$pub" TINYPRUNE_VERSION="$1" TINYPRUNE_BUILD="$2"
    # Separate invocations: the agent must not be compiled with the HTTP/TLS client features.
    cargo build --release --locked -p tinyprune-daemon
    cargo build --release --locked -p tinyprune-cli --features update-test-overrides
    mkdir -p "$3"
    packaging/linux/package.sh --bin-dir /target/release --out-dir "$3"
    mv "$3"/tinyprune-dev-*.tar.gz "$3/pkg.tar.gz"
    rm -f "$3"/*.sha256
  }
  variant 0.1.0 1 "$out/v1"
  variant 0.2.0 2 "$out/v2"
  variant 0.3.0 3 "$out/v3"

  # b3 passes the staged self-check (`--version` works) but its agent dies on start.
  rm -rf "$out/repack" && mkdir "$out/repack"
  tar xzf "$out/v3/pkg.tar.gz" -C "$out/repack"
  local top
  top="$(ls "$out/repack")"
  cat >"$out/repack/$top/bin/tinyprune-agentd" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "tinyprune-agentd 0.1.0"; exit 0; fi
echo "simulated broken agent" >&2
exit 1
EOF
  chmod 0755 "$out/repack/$top/bin/tinyprune-agentd"
  tar czf "$out/v3/bad.tar.gz" -C "$out/repack" "$top"

  local serve="$out/serve"
  local a1=tinyprune-0.1.0-b1-linux-x86_64.tar.gz a2=tinyprune-0.2.0-b2-linux-x86_64.tar.gz a3=tinyprune-0.3.0-b3-linux-x86_64.tar.gz
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sign() { "$feed" test-sign --seed-file "$out/seed.bin" --file "$1" >"$1.sig"; }
  gen() { # scenario version build artifact-file [existing-feed]
    local dir="$serve/$1"
    mkdir -p "$dir"
    local ex=()
    if [ $# -ge 5 ]; then ex=(--existing "$5"); fi
    "$feed" generate --out "$dir/rust-update-feed.json.new" "${ex[@]}" --version "$2" --build "$3" \
      --base-url "$BASE/$1/" --published "$now" --artifact "linux-$(uname -m)=$4"
    mv "$dir/rust-update-feed.json.new" "$dir/rust-update-feed.json"
    sign "$dir/rust-update-feed.json"
  }
  stage() { mkdir -p "$serve/$1"; cp "$2" "$serve/$1/$3"; }

  stage good "$out/v2/pkg.tar.gz" "$a2";            gen good 0.2.0 2 "$serve/good/$a2"
  stage tamper-artifact "$out/v2/pkg.tar.gz" "$a2"; gen tamper-artifact 0.2.0 2 "$serve/tamper-artifact/$a2"
  # Flip one byte AFTER the feed recorded the hash: same length, different content.
  printf 'X' | dd of="$serve/tamper-artifact/$a2" bs=1 seek=200 conv=notrunc 2>/dev/null
  mkdir -p "$serve/tamper-feed"
  cp "$serve/good/rust-update-feed.json" "$serve/good/rust-update-feed.json.sig" "$serve/tamper-feed/"
  sed -i 's/"build": 2/"build": 99/' "$serve/tamper-feed/rust-update-feed.json"
  stage stale "$out/v1/pkg.tar.gz" "$a1";           gen stale 0.1.0 1 "$serve/stale/$a1"
  stage bad "$out/v2/pkg.tar.gz" "$a2";             gen bad 0.2.0 2 "$serve/bad/$a2"
  cp "$out/v3/bad.tar.gz" "$serve/bad/$a3"
  gen bad 0.3.0 3 "$serve/bad/$a3" "$serve/bad/rust-update-feed.json"
  mkdir -p "$out/old" && cp "$out/v1/pkg.tar.gz" "$out/old/pkg.tar.gz"
  rm -rf "$out/repack" "$out/v1" "$out/v2" "$out/v3" "$out/seed.bin"
  chmod -R a+rX "$out"
  echo "fixtures ready"
}

# ---------------------------------------------------------------------------------------------------
# Phase 2 (inside the systemd container, as the unprivileged user): the scenario
# ---------------------------------------------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
wait_for() {
  local end=$((SECONDS + ${WAIT:-60})) description=$1
  shift
  until "$@"; do
    if ((SECONDS >= end)); then fail "timeout: $description"; fi
    sleep .2
  done
}

scenario() {
  export PATH="$HOME/.local/bin:$PATH"
  local data="$HOME/.local/share/tinyprune"
  local pub
  pub="$(cat /fixture/pubkey)"
  upd() { local s=$1; shift; TINYPRUNE_UPDATE_FEED_URL="$BASE/$s/rust-update-feed.json" tinyprune update "$@"; }
  cur() { readlink "$data/current"; }
  agent_pid() { systemctl --user show -p MainPID --value tinyprune-agentd.service; }
  agent_exe() { readlink "/proc/$(agent_pid)/exe"; }
  healthy() { tinyprune status >/dev/null 2>&1; }
  names() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort; }

  # --- install the OLD build in the updatable layout under real systemd ---
  mkdir -p "$HOME/old" && tar xzf /fixture/old/pkg.tar.gz -C "$HOME/old"
  ( cd "$HOME"/old/tinyprune-dev-* && ./install-managed.sh --enable-service )
  wait_for 'old agent answers' healthy
  [[ "$(cur)" == versions/0.1.0*-b1 ]] || fail "unexpected current: $(cur)"
  [[ "$(agent_exe)" == *"-b1/bin/tinyprune-agentd" ]] || fail "agent not running from the old version dir: $(agent_exe)"
  [[ "$(tinyprune update status --json | jget 'd["installedBuild"]')" == 1 ]] || fail "old build is not build 1"
  [[ "$(tinyprune update status --json | jget 'd["updatesEnabled"]')" == True ]] || fail "managed old build has updates disabled"
  ok "old build 1 installed in the managed layout and running under systemd"

  # --- state that must survive: a root, a Preview rule and a Keep item ---
  local root="$HOME/fixture-root" rule=11111111-1111-4111-8111-111111111111
  mkdir -p "$root"
  printf keep >"$root/keep.txt"; printf old >"$root/old.txt"
  touch -t 202001010000 "$root/keep.txt" "$root/old.txt"
  tinyprune roots add e2e-root "$root" E2E >/dev/null
  python3 - "$rule" "$root" >"$HOME/rule.json" <<'PY'
import json,sys
json.dump(dict(id=sys.argv[1],name='Update e2e',scope=dict(path=sys.argv[2],recursive=True),matcher=dict(itemKind='file',exactNames=[],globPatterns=['*.txt']),expiryBasis='modified',lifetime=3600,gracePeriod=1,action='trashItem',state='preview',matchMode='scoped'),sys.stdout)
PY
  tinyprune rules add "$HOME/rule.json" >/dev/null
  tinyprune keep "$root/keep.txt" >/dev/null
  sleep 2
  [[ -e $root/old.txt && -e $root/keep.txt ]] || fail "Preview must not trash"
  tinyprune explain "$root/keep.txt" | grep -qi keep || fail "Keep not recorded before the update"
  ok "root, Preview rule and Keep recorded"

  python3 -m http.server 8765 --bind 127.0.0.1 --directory /fixture/serve >"$HOME/http.log" 2>&1 &
  wait_for 'feed server' curl -fsS "$BASE/good/rust-update-feed.json" -o /dev/null

  # --- checks never install ---
  local out rc
  out="$(upd good check --json)"
  [[ "$(echo "$out" | jget 'd["status"]')" == available ]] || fail "check: $out"
  [[ "$(echo "$out" | jget 'd["build"]')" == 2 ]] || fail "check build: $out"
  local token
  token="$(echo "$out" | jget 'd["confirmationToken"]')"
  [[ "$(cur)" == versions/0.1.0*-b1 ]] || fail "check changed current"
  out="$(upd good install --json)"
  [[ "$(echo "$out" | jget 'd["status"]')" == confirmationRequired ]] || fail "install without --confirm: $out"
  [[ "$(cur)" == versions/0.1.0*-b1 ]] || fail "install without --confirm changed current"
  set +e; out="$(upd good install --confirm 00000000000000000000000000000000 --json)"; rc=$?; set -e
  [[ $rc == 65 ]] || fail "wrong confirmation exit $rc: $out"
  [[ "$(cur)" == versions/0.1.0*-b1 ]] || fail "wrong confirmation changed current"
  # `--auto` honors the setting: disabled = silent skip, no network.
  tinyprune update settings --check-for-new-versions off >/dev/null
  [[ "$(upd good check --auto --json | jget 'd["reason"]')" == disabled ]] || fail "--auto ignored checkForNewVersions=off"
  tinyprune update settings --check-for-new-versions on >/dev/null
  ok "check is read-only; install needs the exact confirmation token; the setting gates --auto"

  # --- tampering is rejected and changes nothing ---
  local pid_before
  pid_before="$(agent_pid)"
  set +e; out="$(upd tamper-feed check --json)"; rc=$?; set -e
  [[ $rc == 65 && "$(echo "$out" | jget 'd["code"]')" == feedRejected ]] || fail "tampered feed accepted (rc=$rc): $out"
  out="$(upd tamper-artifact check --json)"
  token="$(echo "$out" | jget 'd["confirmationToken"]')"
  set +e; out="$(upd tamper-artifact install --confirm "$token" --json)"; rc=$?; set -e
  [[ $rc == 65 && "$(echo "$out" | jget 'd["code"]')" == packageRejected ]] || fail "tampered artifact accepted (rc=$rc): $out"
  [[ "$(cur)" == versions/0.1.0*-b1 && "$(agent_pid)" == "$pid_before" ]] || fail "tampering disturbed the install or the agent"
  [[ -z "$(names "$data/update" | grep -v '^state.json$' || true)" ]] || fail "download leftovers: $(names "$data/update")"
  ok "tampered feed (signature) and tampered artifact (SHA-256) rejected; agent untouched"

  # --- the real update, with a real systemd restart ---
  out="$(upd good check --json)"
  token="$(echo "$out" | jget 'd["confirmationToken"]')"
  out="$(upd good install --confirm "$token" --json)" || fail "install failed: $out"
  [[ "$(echo "$out" | jget 'd["status"]')" == installed && "$(echo "$out" | jget 'd["agent"]')" == restarted ]] || fail "install result: $out"
  [[ "$(cur)" == versions/0.2.0-b2 ]] || fail "current after update: $(cur)"
  [[ -d $data/versions/0.2.0-b2 && "$(names "$data/versions" | wc -l)" == 2 ]] || fail "expected new + previous kept: $(names "$data/versions")"
  [[ "$(agent_pid)" != "$pid_before" ]] || fail "agent was not restarted"
  [[ "$(agent_exe)" == *"0.2.0-b2/bin/tinyprune-agentd" ]] || fail "agent not running the new build: $(agent_exe)"
  wait_for 'new agent answers' healthy
  [[ "$(tinyprune update status --json | jget 'd["installedBuild"]')" == 2 ]] || fail "CLI is not build 2 after update"
  [[ "$(tinyprune update status --json | jget 'd["installedVersion"]')" == 0.2.0 ]] || fail "CLI is not version 0.2.0 after update"
  ok "updated 0.1.0 build 1 -> 0.2.0 build 2; systemd restarted the agent from the new directory; previous kept"

  # --- state survived: Keep still wins, the Preview rule activates, pruning resumes ---
  tinyprune explain "$root/keep.txt" | grep -qi keep || fail "Keep lost across the update"
  tinyprune rules list | grep -q "$rule" || fail "rule lost across the update"
  tinyprune roots list | grep -qF "$root" || fail "root lost across the update"
  tinyprune rules activate "$rule" >/dev/null
  wait_for 'expired file trashed by the NEW agent' bash -c "[[ ! -e '$root/old.txt' ]]"
  sleep 2
  [[ -e $root/keep.txt ]] || fail "Keep item was trashed after the update"
  ok "root, rule and Keep survived; the new agent prunes old.txt and still protects keep.txt"

  # --- replay / downgrade ---
  set +e; out="$(upd stale check --json)"; rc=$?; set -e
  [[ $rc == 65 && "$(echo "$out" | jget 'd["code"]')" == feedRejected ]] || fail "older signed feed accepted (rc=$rc): $out"
  ok "replayed older (validly signed) feed refused"

  # --- a bad update (agent dies on start) must roll back ---
  out="$(upd bad check --json)"
  [[ "$(echo "$out" | jget 'd["build"]')" == 3 ]] || fail "bad scenario check: $out"
  token="$(echo "$out" | jget 'd["confirmationToken"]')"
  set +e; out="$(upd bad install --confirm "$token" --json)"; rc=$?; set -e
  [[ $rc == 70 && "$(echo "$out" | jget 'd["code"]')" == rolledBack ]] || fail "bad update not rolled back (rc=$rc): $out"
  [[ "$(cur)" == versions/0.2.0-b2 ]] || fail "current after rollback: $(cur)"
  wait_for 'rolled-back agent answers' healthy
  [[ "$(agent_exe)" == *"0.2.0-b2/bin/tinyprune-agentd" ]] || fail "agent not back on the good build: $(agent_exe)"
  [[ ! -e $data/versions/0.3.0-b3 ]] || fail "failed build directory left behind"
  [[ -z "$(names "$data/versions" | grep -- '^\.stage' || true)" ]] || fail "staging leftovers"
  [[ "$(tinyprune update status --json | jget 'd["installedBuild"]')" == 2 ]] || fail "installed build after rollback"
  ok "bad build rolled back automatically; build 2 agent running again"

  echo "UPDATE E2E PASSED"
}

# ---------------------------------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------------------------------
host() {
  command -v docker >/dev/null || { echo "Docker is required" >&2; exit 69; }
  # Globals on purpose: the EXIT trap runs after this function returns.
  work="$(mktemp -d)"
  name="tinyprune-update-e2e-$$"
  image="$name:local"
  cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; docker image rm "$image" >/dev/null 2>&1 || true; rm -rf "$work"; }
  trap cleanup EXIT
  mkdir -p "$work/fixture"
  docker run --rm -v "$repo:/src:ro" -v tinyprune-update-cargo:/usr/local/cargo \
    -v tinyprune-update-target:/target -v "$work/fixture:/out" -w /src/rust \
    -e CARGO_TARGET_DIR=/target rust:1.98.1 bash /src/rust/tests-e2e/update-docker.sh --build-fixtures /out
  cp "$here/update-docker.sh" "$work/"
  cat >"$work/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus-user-session python3 curl ca-certificates && rm -rf /var/lib/apt/lists/* && useradd -m -u 1001 -s /bin/bash tester
COPY fixture /fixture
COPY update-docker.sh /fixture-run/update-docker.sh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
  docker build -t "$image" "$work"
  # --cgroupns=host is required on Docker Desktop for the per-user systemd manager.
  docker run -d --name "$name" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --tmpfs /tmp "$image" >/dev/null
  docker exec "$name" bash -ec 'for ((i=0;i<100;i++)); do loginctl enable-linger tester && exit 0; sleep .1; done; exit 1' \
    || { docker logs "$name" >&2; echo "Real systemd PID 1 is unavailable here; this test does not fake it." >&2; exit 1; }
  docker exec "$name" bash -ec 'for ((i=0;i<300;i++)); do [ -S /run/user/1001/bus ] && exit 0; sleep .1; done; exit 1'
  docker exec "$name" runuser -u tester -- env HOME=/home/tester XDG_RUNTIME_DIR=/run/user/1001 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus bash /fixture-run/update-docker.sh --inside
}

case "${1:-}" in
  --build-fixtures) build_fixtures "${2:?output dir}" ;;
  --inside) scenario ;;
  "") host ;;
  *) echo "usage: update-docker.sh" >&2; exit 64 ;;
esac
