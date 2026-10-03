#!/usr/bin/env bash
# Fixture harness for mac-local-exec-self-heal. CI-safe: never quits a live app.
# Live process-down prove is tests/live-process-down.sh and requires LIVE=1 on macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEAL="$ROOT/grok-bot-local-exec-heal.sh"
FIX="$ROOT/tests/fixtures"
PASS=0
FAIL=0

if [[ ! -x "$HEAL" ]]; then
  chmod +x "$HEAL" || true
fi

die() { echo "FAIL ${NAME:-?}: $*" >&2; exit 1; }

jget() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
v=d.get(sys.argv[2], None)
print("None" if v is None else v)' "$HEAL_STATE" "$1"
}

setup_env() {
  TMP="$(mktemp -d)"
  export GROK_APP_PATH="$TMP/app"
  export GROK_SUPPORT_DIR="$TMP/sup"
  export LATCH_DIR="$TMP/latch"
  export HEAL_LOG="$TMP/logs/heal.log"
  export HEAL_STATE="$TMP/logs/last.json"
  export HEAL_DRY_RUN=1
  export HEAL_TRUST_PID=1
  export HEAL_DISABLE_PGREP=1
  export READINESS_WAIT_SEC=1
  export READINESS_POLL_SEC=0
  export COOLDOWN_SEC=300
  export HEARTBEAT_STALE_SEC=180
  export STUCK_SEC=120
  export OK_HINT_SEC=300
  export HEAL_ON_STUCK_SESSION=1
  export HEAL_CURSOR=0
  unset HEAL_SWAP_SUPPORT_ON_RELAUNCH || true
  unset HEAL_NOW_MS || true
  mkdir -p "$GROK_APP_PATH" "$GROK_SUPPORT_DIR" "$LATCH_DIR" "$(dirname "$HEAL_LOG")"
}

# Copy a fixture into a support dir. heartbeatOffsetMs is applied against NOW_MS.
materialize() {
  local src="$1" dest="$2" now_ms="$3"
  mkdir -p "$dest/dune-reliability/sessions"
  cp "$src/desktop-status.json" "$dest/desktop-status.json"
  if [[ -f "$src/session.json" ]]; then
    python3 - "$src/session.json" "$dest/dune-reliability/sessions/test.running.json" "$now_ms" <<'PY'
import json, sys
src, dst, now = sys.argv[1:]
now = int(now)
j = json.load(open(src))
off = int(j.pop("heartbeatOffsetMs", 0))
j["heartbeatAtMs"] = now + off
json.dump(j, open(dst, "w"))
PY
  fi
}

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

run_heal() {
  bash "$HEAL" || die "heal script exited $?"
}

seed_state() {
  python3 - "$HEAL_STATE" "$1" <<'PY'
import json, sys
path, blob = sys.argv[1], sys.argv[2]
json.dump(json.loads(blob), open(path, "w"), indent=2)
PY
}

run_case() {
  NAME="$1"
  shift
  if ( set -euo pipefail; NAME="$NAME"; setup_env; "$@"; ); then
    echo "PASS $NAME"
    PASS=$((PASS + 1))
  else
    echo "FAIL $NAME"
    FAIL=$((FAIL + 1))
  fi
}

t_healthy() {
  local now; now="$(now_ms)"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget readiness)" == "local_healthy" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget escalateHint)" == "None" ]] || die "hint=$(jget escalateHint)"
  [[ "$(jget pid)" == "4242" ]] || die "pid=$(jget pid)"
  [[ "$(jget kitVersion)" == "1.3.0" ]] || die "kit=$(jget kitVersion)"
  [[ "$(jget lastHealAtMs)" == "None" ]] || die "unexpected heal stamp"
  grep -q "heal start" "$HEAL_LOG" && die "healthy tick relaunched" || true
}

t_disable() {
  local now; now="$(now_ms)"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.disable"
  run_heal
  [[ "$(jget status)" == "disabled" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "disable_file" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "disabled" ]] || die "readiness=$(jget readiness)"
  [[ -f "$LATCH_DIR/grok-bot-local-exec-heal.request" ]] || die "disable consumed request"
  grep -q "heal start" "$HEAL_LOG" && die "disabled tick relaunched" || true
}

t_cooldown() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  local last=$((now - 10000))
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$last,\"heartbeatAtMs\":$((now - 15000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "boot_outcome_starting" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "cooldown" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget lastHealAtMs)" == "$last" ]] || die "lastHeal overwritten $(jget lastHealAtMs)"
  grep -q "cooldown" "$HEAL_LOG" || die "log missing cooldown"
  grep -q "heal start" "$HEAL_LOG" && die "cooldown relaunched" || true
}

t_readiness_pass() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "boot_outcome_starting" ]] || die "reason=$(jget reason)"
  [[ "$(jget action)" == "relaunch" ]] || die "action=$(jget action)"
  [[ "$(jget readiness)" == "ready" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget pid)" == "5151" ]] || die "pid=$(jget pid)"
  [[ "$(jget bootOutcome)" == "ready" ]] || die "boot=$(jget bootOutcome)"
  [[ "$(jget escalateHint)" == "None" ]] || die "hint set on success"
  grep -q "heal start" "$HEAL_LOG" || die "missing heal start"
  grep -q "dry-run: skip quit/open" "$HEAL_LOG" || die "dry-run did not skip open"
}

t_readiness_incomplete() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-unready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  run_heal
  [[ "$(jget status)" == "heal_incomplete" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "incomplete" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget status)" != "healed" ]] || die "premature healed"
  [[ "$(jget reason)" == "boot_outcome_starting" ]] || die "reason=$(jget reason)"
  [[ "$(jget escalateHint)" == *"readiness_timeout"* ]] || die "hint=$(jget escalateHint)"
  [[ -n "$(jget lastHealAtMs)" && "$(jget lastHealAtMs)" != "None" ]] || die "no lastHeal"
}

t_readiness_failed() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  export HEAL_TRUST_PID=0
  materialize "$FIX/dead-pid" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "heal_failed" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "failed" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget reason)" == "process_down" ]] || die "reason=$(jget reason)"
  [[ "$(jget escalateHint)" == *"heal_failed"* ]] || die "hint=$(jget escalateHint)"
}

t_operator_request() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  printf 'force\n' > "$LATCH_DIR/grok-bot-local-exec-heal.request"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "operator_request" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "ready" ]] || die "readiness=$(jget readiness)"
  [[ ! -f "$LATCH_DIR/grok-bot-local-exec-heal.request" ]] || die "request not consumed"
  grep -q "consumed operator request" "$HEAL_LOG" || die "log missing consume"
}

t_operator_bypasses_cooldown() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  local last=$((now - 5000))
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$last}"
  printf 'force\n' > "$LATCH_DIR/grok-bot-local-exec-heal.request"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "operator_request" ]] || die "reason=$(jget reason)"
  [[ "$(jget status)" != "cooldown" ]] || die "cooldown blocked operator"
}

t_heartbeat_frozen() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/frozen-hb" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  local hb=$((now - 150000))
  local since=$((now - 130000))
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$hb,\"heartbeatFrozenSinceMs\":$since,\"checkedAtMs\":$((now - 60000))}"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "heartbeat_frozen" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "ready" ]] || die "readiness=$(jget readiness)"
}

t_frozen_under_threshold() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/frozen-hb" "$GROK_SUPPORT_DIR" "$now"
  local hb=$((now - 150000))
  # Age is 150s (> STUCK 120) but the unchanged clock started only 30s ago.
  local since=$((now - 30000))
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$hb,\"heartbeatFrozenSinceMs\":$since,\"checkedAtMs\":$((now - 30000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget heartbeatFrozenSinceMs)" == "$since" ]] || die "frozen stamp not carried $(jget heartbeatFrozenSinceMs)"
  grep -q "heal start" "$HEAL_LOG" && die "under-threshold frozen relaunched" || true
}

t_stale_beats_frozen() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/stale-hb" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  local hb=$((now - 200000))
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$hb,\"heartbeatFrozenSinceMs\":$((now - 200000))}"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == heartbeat_stale_* ]] || die "reason=$(jget reason)"
  [[ "$(jget reason)" != "heartbeat_frozen" ]] || die "frozen won over stale"
}

t_moving_heartbeat_no_heal() {
  # Incident regression: heartbeat age stays small but the timestamp MOVES.
  # That is not heartbeat_frozen and must not relaunch (S-NEW-D).
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  local hb=$((now - 15000))
  local prev_hb=$((hb - 20000))
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$prev_hb,\"okStreakSinceMs\":$((now - 10000)),\"checkedAtMs\":$((now - 60000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget escalateHint)" == "None" ]] || die "hint too early: $(jget escalateHint)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
}

t_ok_escalate_hint() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  local hb=$((now - 15000))
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$((hb - 30000)),\"okStreakSinceMs\":$((now - 400000)),\"checkedAtMs\":$((now - 60000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "local_healthy" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget escalateHint)" == *"S-NEW-D"* ]] || die "hint=$(jget escalateHint)"
  [[ "$(jget action)" == "none" ]] || die "long ok streak relaunched"
  [[ "$(jget cloudConnectObservable)" == "False" ]] || die "cloud flag $(jget cloudConnectObservable)"
}

t_no_heartbeat_soft() {
  local now; now="$(now_ms)"
  materialize "$FIX/no-heartbeat" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "process_up_no_heartbeat_file" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "process_up_no_heartbeat" ]] || die "readiness=$(jget readiness)"
  grep -q "heal start" "$HEAL_LOG" && die "soft no-hb relaunched" || true
}

t_stuck_flag_off() {
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  export HEAL_ON_STUCK_SESSION=0
  materialize "$FIX/frozen-hb" "$GROK_SUPPORT_DIR" "$now"
  local hb=$((now - 150000))
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$hb,\"heartbeatFrozenSinceMs\":$((now - 400000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
}

t_app_missing() {
  rm -rf "$GROK_APP_PATH"
  run_heal
  [[ "$(jget status)" == "error" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "app_missing" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "app_missing" ]] || die "readiness=$(jget readiness)"
}

echo "kit $(cat "$ROOT/VERSION")  heal=$HEAL"
run_case T-healthy t_healthy
run_case T-disable t_disable
run_case T-cooldown t_cooldown
run_case T-readiness-pass t_readiness_pass
run_case T-readiness-incomplete t_readiness_incomplete
run_case T-readiness-failed t_readiness_failed
run_case T-operator_request t_operator_request
run_case T-operator-bypasses-cooldown t_operator_bypasses_cooldown
run_case T-heartbeat-frozen t_heartbeat_frozen
run_case T-frozen-under-threshold t_frozen_under_threshold
run_case T-stale-beats-frozen t_stale_beats_frozen
run_case T-moving-heartbeat-no-heal t_moving_heartbeat_no_heal
run_case T-ok-escalate-hint t_ok_escalate_hint
run_case T-no-heartbeat-soft t_no_heartbeat_soft
run_case T-stuck-flag-off t_stuck_flag_off
run_case T-app-missing t_app_missing

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
