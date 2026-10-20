#!/usr/bin/env bash
# End-to-end smoke for the REAL tinyprune-agentd and tinyprune binaries (Linux/macOS).
# Unreleased engineering check; it does not claim Linux/Windows support.
#
# Everything lives under one temp dir: fixture tree, agent data dir, IPC socket, HOME and
# XDG_DATA_HOME (whose Trash/ is the freedesktop-style Trash the Unix adapter writes to).
# Time is the real clock: "old" items get a 2020 mtime, the rule uses basis=modified with a
# 1 h lifetime and 1 s grace, so old items are due now and new items are not (the daemon has no
# test-clock flag, and none is needed).
#
# Env: TINYPRUNE_BIN_DIR (default rust/target/release), SMOKE_SKIP_BUILD=1, SMOKE_KEEP=1 (keep temp dir).
# Exit: 0 pass, 1 assertion failure, 2 setup failure.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rust="$(cd "$here/.." && pwd)"
bin="${TINYPRUNE_BIN_DIR:-$rust/target/release}"

if [[ "${SMOKE_SKIP_BUILD:-0}" != 1 ]]; then
  (cd "$rust" && cargo build --release --locked -p tinyprune-daemon -p tinyprune-cli) || { echo "build failed" >&2; exit 2; }
fi
agentd="$bin/tinyprune-agentd"
cli="$bin/tinyprune"
[[ -x "$agentd" && -x "$cli" ]] || { echo "missing binaries in $bin" >&2; exit 2; }

T="$(mktemp -d /tmp/tpsmoke.XXXXXX)" || exit 2
T="$(cd "$T" && pwd -P)"           # resolve symlinks (/tmp -> /private/tmp on macOS)
ROOT="$T/root"; DATA="$T/data"; SOCK="$T/sock/agent.sock"; XDG="$T/xdg"; HOMEDIR="$T/home"
TRASH="$XDG/Trash/files"
RULE=11111111-1111-4111-8111-111111111111
mkdir -p "$ROOT/docs" "$ROOT/stale" "$T/sock" "$HOMEDIR" "$XDG"
chmod 700 "$T/sock"

pid=""
checks=0
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; fi
  if [[ "${SMOKE_KEEP:-0}" == 1 ]]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- daemon stderr/stdout ---" >&2; cat "$T/agentd.log" >&2 2>/dev/null
  echo "--- root ---" >&2; find "$ROOT" >&2 2>/dev/null
  echo "--- trash ---" >&2; find "$XDG/Trash" >&2 2>/dev/null
  exit 1
}
ok() { checks=$((checks + 1)); echo "ok   $*"; }
tp() { TINYPRUNE_ENDPOINT="$SOCK" "$cli" "$@"; }
exists() { [[ -e "$1" ]]; }
# wait_for <seconds> <description> <command...>
wait_for() {
  local limit=$1 what=$2; shift 2
  local end=$((SECONDS + limit))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < end )) || fail "timeout (${limit}s) waiting for: $what"
    sleep 0.25
  done
}
json_count() { # <kind> -> number of activity events of that kind
  tp activity --json | python3 -c 'import json,sys; k=sys.argv[1]; print(sum(1 for e in json.load(sys.stdin)["events"] if e["kind"]==k))' "$1"
}

start_agent() {
  XDG_DATA_HOME="$XDG" HOME="$HOMEDIR" TINYPRUNE_ENDPOINT="$SOCK" \
    "$agentd" --data-dir "$DATA" --reconcile-seconds 1 >>"$T/agentd.log" 2>&1 &
  pid=$!
  wait_for 20 "agent to answer status" tp status
}
stop_agent() { # clean shutdown: SIGINT, exit code 0, socket removed
  kill -INT "$pid" 2>/dev/null || fail "agent not running"
  local end=$((SECONDS + 15))
  while kill -0 "$pid" 2>/dev/null; do (( SECONDS < end )) || fail "agent did not exit after SIGINT"; sleep 0.2; done
  wait "$pid"; local rc=$?
  pid=""
  [[ $rc -eq 0 ]] || fail "agent exit code $rc after SIGINT"
  ok "agent exited 0 on SIGINT"
  [[ ! -e "$SOCK" ]] || fail "socket still present after shutdown"
  ok "socket removed after shutdown"
  tp status >/dev/null 2>&1 && fail "CLI still reached a stopped agent"
  tp status >/dev/null 2>&1; [[ $? -eq 69 ]] || fail "CLI exit code for unreachable agent is not 69"
  ok "CLI reports unavailable (69) when agent is down"
}

# ---- fixture ---------------------------------------------------------------------------------
echo old    >"$ROOT/old.txt"
echo keep   >"$ROOT/keep.txt"          # old but Keep-protected
echo recent >"$ROOT/recent.txt"        # new: not due for an hour
echo prot   >"$ROOT/docs/protected.txt" # old Keep-protected descendant => docs/ must survive
touch -t 202001010000 "$ROOT/old.txt" "$ROOT/keep.txt" "$ROOT/docs/protected.txt" "$ROOT/docs" "$ROOT/stale"

start_agent
ok "agent started, CLI status answers"
tp status | grep -q 'available' || fail "status output"

tp roots add smoke-root "$ROOT" Fixture >/dev/null || fail "roots add"
tp roots list | grep -qF "$ROOT" || fail "managed root not listed"
ok "managed root added"

tp keep "$ROOT/keep.txt" >/dev/null || fail "keep file"
tp keep "$ROOT/docs/protected.txt" >/dev/null || fail "keep descendant"
ok "Keep set on keep.txt and docs/protected.txt"

cat >"$T/rule.json" <<EOF
{"id":"$RULE","name":"Old items","scope":{"path":"$ROOT","recursive":true},
 "matcher":{"itemKind":"fileOrDirectory","exactNames":[],"globPatterns":["*"]},
 "expiryBasis":"modified","lifetime":3600,"gracePeriod":1,"action":"trashItem",
 "state":"preview","matchMode":"scoped"}
EOF
tp rules add "$T/rule.json" >/dev/null || fail "rules add"
ok "Preview rule added (modified + 1h lifetime, 1s grace)"

# ---- Preview moves nothing -------------------------------------------------------------------
wait_for 20 "index to list old.txt as eligible" bash -c "TINYPRUNE_ENDPOINT='$SOCK' '$cli' upcoming | grep -qF '$ROOT/old.txt'"
prev="$(tp rules preview "$RULE")" || fail "rules preview"
grep -q 'Nothing was changed or moved to Trash' <<<"$prev" || fail "preview did not state nothing changed"
sleep 4   # several reconcile ticks (1 s) under a Preview rule
for f in old.txt keep.txt recent.txt docs/protected.txt docs stale; do exists "$ROOT/$f" || fail "Preview moved $f"; done
[[ -z "$(ls -A "$TRASH" 2>/dev/null)" ]] || fail "Trash not empty under Preview"
[[ "$(json_count movedToTrash)" == 0 ]] || fail "movedToTrash audit event under Preview"
ok "Preview + 4 s of reconcile moved nothing; Trash empty; no movedToTrash audit"

# ---- explanations ----------------------------------------------------------------------------
e_old="$(tp explain "$ROOT/old.txt")"
for field in Scheduled: Eligible: Rule: Basis: 'Basis date:' 'Project context:' Override: Suppression: Disposition: 'Globally paused:' Identity: Overrides:; do
  grep -qF "$field" <<<"$e_old" || fail "explain old.txt is missing field $field"
done
grep -q 'Disposition: "preview"' <<<"$e_old" || fail "old.txt should be a Preview decision"
ok "explain old.txt has every explanation field; disposition preview"
tp explain "$ROOT/keep.txt" | grep -q 'Suppression: "protected"' || fail "keep.txt not suppressed as protected"
grep -A12 "^$ROOT/docs\$" <<<"$prev" | grep -q 'Suppression: "protectedDescendant"' || fail "Preview does not show docs as protectedDescendant"
now="$(date +%s)"
sched="$(tp explain "$ROOT/recent.txt" | sed -n 's/^Scheduled: \([0-9]*\).*/\1/p')"
[[ -n "$sched" && "$sched" -gt $((now + 1800)) ]] || fail "recent.txt deadline is not ~1 h away (got '$sched')"
ok "Keep, protected folder and recent-item deadlines explained"

# ---- pause blocks Active ---------------------------------------------------------------------
tp pause >/dev/null || fail "pause"
tp rules activate "$RULE" >/dev/null || fail "rules activate"
tp rules | grep -q 'paused' || fail "rules list does not show global pause"
sleep 4
for f in old.txt stale; do exists "$ROOT/$f" || fail "Active rule moved $f while globally paused"; done
[[ -z "$(ls -A "$TRASH" 2>/dev/null)" ]] || fail "Trash not empty while paused"
tp explain "$ROOT/old.txt" | grep -q 'Globally paused: true' || fail "explain does not report global pause"
ok "Active rule + global pause moved nothing in 4 s"

# pause must survive a restart
stop_agent
start_agent
tp rules | grep -q 'paused' || fail "pause did not persist across restart"
sleep 3
exists "$ROOT/old.txt" || fail "old.txt moved after restart although paused"
ok "pause persisted across restart and still blocks"

# ---- Active moves exactly the expected items -------------------------------------------------
tp resume >/dev/null || fail "resume"
wait_for 30 "old.txt and stale to leave the root" bash -c "[[ ! -e '$ROOT/old.txt' && ! -e '$ROOT/stale' ]]"
sleep 3   # settle: nothing else may follow
survivors="$(cd "$ROOT" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')"
[[ "$survivors" == "./docs ./docs/protected.txt ./keep.txt ./recent.txt " ]] || fail "unexpected survivors: $survivors"
ok "survivors are exactly docs/, docs/protected.txt, keep.txt, recent.txt"
trashed="$(cd "$TRASH" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')"
[[ "$trashed" == "./old.txt ./stale " ]] || fail "unexpected Trash contents: $trashed"
for n in old.txt stale; do
  grep -q "^Path=" "$XDG/Trash/info/$n.trashinfo" || fail "missing/invalid $n.trashinfo"
done
[[ "$(cat "$TRASH/old.txt")" == old ]] || fail "trashed old.txt content changed (it must be moved, not rewritten)"
ok "Trash holds exactly old.txt and stale (+ .trashinfo); contents intact"

# ---- audit / explain completeness ------------------------------------------------------------
n_moved="$(json_count movedToTrash)"
[[ "$n_moved" -ge 2 ]] || fail "expected >=2 movedToTrash audit events, got $n_moved"
tp activity --json | python3 -c '
import json, sys
ev = [e for e in json.load(sys.stdin)["events"] if e["kind"] == "movedToTrash"]
need = ("scheduledAt","eligibleAt","rule","basis","basisDate","suppression","disposition","globallyPaused","identity")
bad = [e for e in ev if not e.get("explanation")]
assert not bad, "movedToTrash event without explanation"
' || fail "movedToTrash audit events lack a full explanation"
ok "activity: $n_moved movedToTrash events, each with an explanation"
tp activity | grep -q movedToTrash || fail "human activity output lacks movedToTrash"

# ---- restart persistence ---------------------------------------------------------------------
stop_agent
start_agent
tp rules | grep -q "$RULE.*active" || fail "Active rule not persisted"
tp roots list | grep -qF "$ROOT" || fail "root not persisted"
tp explain "$ROOT/keep.txt" | grep -q 'Suppression: "protected"' || fail "Keep not persisted"
[[ "$(json_count movedToTrash)" == "$n_moved" ]] || fail "audit history changed across restart"
ok "rule, root, Keep and audit history persisted across restart"

echo old2 >"$ROOT/old2.txt"; touch -t 202001010000 "$ROOT/old2.txt"
wait_for 30 "post-restart old2.txt to be trashed" bash -c "[[ ! -e '$ROOT/old2.txt' && -e '$TRASH/old2.txt' ]]"
exists "$ROOT/keep.txt" && exists "$ROOT/recent.txt" && exists "$ROOT/docs/protected.txt" || fail "survivor lost after restart"
ok "restarted agent keeps enforcing (old2.txt trashed; Keep/recent/protected survive)"

# ---- clean final shutdown --------------------------------------------------------------------
stop_agent
echo "SMOKE PASS ($checks checks)"
