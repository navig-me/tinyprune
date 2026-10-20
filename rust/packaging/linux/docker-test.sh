#!/usr/bin/env bash
# Real, isolated Linux development-archive acceptance. Never runs an installed host agent.
# Requires Docker; builds in Rust, installs in a fresh Ubuntu 24.04 container.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

if [[ ${1:-} != --inside ]]; then
  work="$(mktemp -d)"
  name="tinyprune-install-$$"
  image="$name:local"
  cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; docker image rm "$image" >/dev/null 2>&1 || true; rm -rf "$work"; }
  trap cleanup EXIT
  # An explicit archive skips compilation in CI; local default exercises the packager in Docker.
  if [[ $# == 2 && $1 == --archive ]]; then
    cp "$2" "$work/package.tar.gz"
  elif [[ $# == 0 ]]; then
    docker run --rm -v "$repo:/src:ro" -v tinyprune-install-cargo:/usr/local/cargo \
      -v tinyprune-install-target:/target -v "$work:/out" -w /src/rust \
      -e CARGO_TARGET_DIR=/target rust:1.98.1 bash -ec \
      'cargo build --release --locked -p tinyprune-daemon -p tinyprune-cli; packaging/linux/package.sh --bin-dir /target/release --out-dir /out; cp /out/*.tar.gz /out/package.tar.gz'
  else
    echo 'Usage: docker-test.sh [--archive FILE]' >&2; exit 64
  fi
  cp "$here/docker-test.sh" "$here/tinyprune.desktop" "$work/"
  cat >"$work/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus-user-session desktop-file-utils trash-cli python3 ca-certificates && rm -rf /var/lib/apt/lists/* && useradd -m -u 1001 -s /bin/bash tester
COPY package.tar.gz docker-test.sh tinyprune.desktop /fixture/
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
  docker build -t "$image" "$work"
  docker run -d --name "$name" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    --tmpfs /mnt/other:rw,mode=1777 "$image"
  # Real PID 1 systemd + logind create a real per-user manager, not a fake systemctl.
  if ! docker exec "$name" bash -ec 'for ((i=0;i<100;i++)); do if loginctl enable-linger tester; then exit 0; fi; sleep .1; done; exit 1'; then
    docker logs "$name" >&2
    echo 'Real systemd PID 1 unavailable; using verified unit + direct ExecStart fallback.' >&2
    docker rm -f "$name"
    docker run -d --name "$name" --privileged --tmpfs /mnt/other:rw,mode=1777 "$image" sleep infinity
    docker exec "$name" runuser -u tester -- env HOME=/home/tester bash /fixture/docker-test.sh --inside direct
  else
    docker exec "$name" bash -ec 'for ((i=0;i<300;i++)); do [ -S /run/user/1001/bus ] && exit 0; sleep .1; done; ls -la /run/user /run/user/1001 >&2; systemctl status user@1001 >&2 || true; exit 1'
    docker exec "$name" runuser -u tester -- env HOME=/home/tester XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus bash /fixture/docker-test.sh --inside systemd
  fi
  exit
fi

mode=${2:?missing service mode}
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/package" "$HOME/fixture/space 雪 % directory" /mnt/other/fixture
cd "$HOME/package"
tar xzf /fixture/package.tar.gz
cd tinyprune-dev-*
pkg=$PWD
unit="$HOME/.config/systemd/user/tinyprune-agentd.service"
data="$HOME/.local/share/tinyprune"
sock="$data/agent.sock"
trap 'if [[ $mode == systemd ]]; then journalctl --user -u tinyprune-agentd --no-pager || true; elif [[ -n ${pid:-} ]]; then kill -INT "$pid" 2>/dev/null || true; cat "$HOME/agent.log"; fi' ERR
wait_for() {
  local end=$((SECONDS + 45)); local description=$1; shift
  until "$@"; do
    if ((SECONDS >= end)); then echo "FAIL timeout: $description" >&2; return 1; fi
    sleep .1
  done
}
absent() { [[ ! -e $1 ]]; }
status() { tinyprune status >/dev/null 2>&1; }
if [[ $mode == systemd ]]; then
  ./install.sh --enable-service
else
  ./install.sh
  # This fallback is only reached after a real PID 1 attempt failed.
  systemd-analyze --user verify "$unit"
  "$HOME/.local/bin/tinyprune-agentd" >"$HOME/agent.log" 2>&1 & pid=$!
fi
systemd-analyze --user verify "$unit"
# Validate the actual template even if a headless archive intentionally omits the UI.
sed "s|@BINDIR@|$HOME/.local/bin|g" /fixture/tinyprune.desktop >"$HOME/tinyprune.desktop"
desktop-file-validate "$HOME/tinyprune.desktop"
wait_for 'installed agent status' status

root="$HOME/fixture"
special="$root/space 雪 % directory/old %.txt"
printf 'retained-special\n' >"$special"
printf 'retained-other\n' >/mnt/other/fixture/other.txt
touch -t 202001010000 "$special" /mnt/other/fixture/other.txt
tinyprune roots add install-root "$root" Install
tinyprune roots add mount-root /mnt/other/fixture Other
add_rule() {
  local id=$1 path=$2
  python3 - "$id" "$path" >"$HOME/rule.json" <<'PY'
import json,sys
json.dump(dict(id=sys.argv[1],name='Install acceptance',scope=dict(path=sys.argv[2],recursive=True),matcher=dict(itemKind='file',exactNames=[],globPatterns=['*.txt']),expiryBasis='modified',lifetime=3600,gracePeriod=1,action='trashItem',state='preview',matchMode='scoped'),sys.stdout)
PY
  tinyprune rules add "$HOME/rule.json"
  tinyprune rules activate "$id"
}
add_rule 11111111-1111-4111-8111-111111111111 "$root"
add_rule 22222222-2222-4222-8222-222222222222 /mnt/other/fixture
wait_for 'unicode file trashed' absent "$special"
wait_for 'other mount file trashed' absent /mnt/other/fixture/other.txt
python3 - "$special" <<'PY'
import os,pathlib,sys,urllib.parse
trash=pathlib.Path.home()/'.local/share/Trash'
info=(trash/'info/old %.txt.trashinfo').read_text()
expected=urllib.parse.quote(sys.argv[1],safe='/-_.~')
assert f'Path={expected}\n' in info, info
assert '%20' in info and '%25' in info and '%E9%9B%AA' in info
assert (trash/'files/old %.txt').read_text()=='retained-special\n'
mount=pathlib.Path(f'/mnt/other/.Trash-{os.getuid()}')
assert (mount/'files/other.txt').read_text()=='retained-other\n'
assert 'Path=fixture/other.txt\n' in (mount/'info/other.txt.trashinfo').read_text()
assert mount.stat().st_dev != trash.stat().st_dev
assert mount.stat().st_mode & 0o777 == 0o700
PY
# Pause before restoring, so the real agent cannot immediately trash the old file again.
tinyprune pause
printf '0\n' | trash-restore "$special"
[[ $(cat "$special") == retained-special ]]
[[ ! -e "$HOME/.local/share/Trash/files/old %.txt" ]]
echo 'PASS home Trash encoding + standard trash-cli restore; tmpfs .Trash-UID relative path'

# Deny the per-mount Trash: the executor must retain the source, never copy/delete.
chmod 500 "/mnt/other/.Trash-$(id -u)/files"
printf 'must-stay\n' >/mnt/other/fixture/refused.txt
touch -t 202001010000 /mnt/other/fixture/refused.txt
tinyprune resume
# Await an explicit failure audit instead of treating a short lack of movement as success.
failed_trash() { tinyprune activity --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any("refused.txt" in str(e) and ("fail" in str(e).lower() or "denied" in str(e).lower()) for e in d["events"]) else 1)'; }
wait_for 'same-device Trash refusal audit' failed_trash
[[ $(cat /mnt/other/fixture/refused.txt) == must-stay ]]
[[ ! -e "$HOME/.local/share/Trash/files/refused.txt" ]]
[[ ! -e "/mnt/other/.Trash-$(id -u)/files/refused.txt" ]]
chmod 700 "/mnt/other/.Trash-$(id -u)/files"
echo 'PASS unavailable same-device Trash fails closed without copy/delete'

if [[ $mode == systemd ]]; then
  systemctl --user stop tinyprune-agentd
  [[ $(systemctl --user show tinyprune-agentd -p ExecMainStatus --value) == 0 ]]
  [[ ! -e $sock ]]
  systemctl --user start tinyprune-agentd
  wait_for 'service restarted' status
  old=$(systemctl --user show tinyprune-agentd -p MainPID --value)
  kill -KILL "$old"
  restarted() { local new; new=$(systemctl --user show tinyprune-agentd -p MainPID --value); [[ $new != 0 && $new != "$old" ]] && status; }
  wait_for 'Restart=on-failure' restarted
  systemctl --user stop tinyprune-agentd
  [[ $(systemctl --user show tinyprune-agentd -p ExecMainStatus --value) == 0 && ! -e $sock ]]
  echo 'PASS real systemd --user SIGINT clean stop and restart-on-failure'
else
  kill -INT "$pid"; wait "$pid"; pid=''
  [[ ! -e $sock ]]
  echo 'LIMIT real systemd unavailable: direct ExecStart SIGINT exit 0; restart-on-failure not exercised'
fi
"$pkg/uninstall.sh"
[[ -d $data && ! -e $unit && ! -e $HOME/.local/bin/tinyprune && ! -e $HOME/.local/bin/tinyprune-agentd ]]
if [[ $mode == systemd ]]; then ! systemctl --user is-enabled tinyprune-agentd; fi
"$pkg/uninstall.sh" --purge
[[ ! -e $data ]]
[[ -e "/mnt/other/.Trash-$(id -u)/files/other.txt" ]]
echo "DOCKER INSTALL PASS ($mode; Ubuntu 24.04; $(uname -m); non-root uid $(id -u))"
