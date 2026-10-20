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
  # Helper observer: canned ps/lsof unless a test turns the hooks off.
  # T-helper-ps-hook-requires-test-mode calls the real ps binary and must not
  # see the fixture. HEAL_TEST_MODE is what makes the canned hooks live.
  export HEAL_TEST_MODE=1
  export HEAL_TEST_CONTINUOUS=1
  export HEAL_TEST_PROCESS_DOWN_PROVEN=1
  export RECOVERY_MODE=active
  export HELPER_CHECK=1
  export HEAL_ON_HELPER_MISSING=0
  export HELPER_MISSING_SEC=300
  export HELPER_BASELINE_SEC=600
  export HELPER_RELAUNCH_WINDOW_SEC=3600
  export HELPER_SOCKET_CHECK=1
  export HELPER_LSOF_FILE="$FIX/helpers/sockets.lsof"
  unset HELPER_EXPECTED HEAL_SNAPSHOT_DIR HEAL_SNAPSHOT_KEEP HEAL_SNAPSHOT_MIN_SEC || true
  # Stage 0 defaults to observation; this suite explicitly simulates active policy.
  # Production HEAL_ON_HELPER_MISSING=0. The suite pins 0 so the
  # log-only cases stay explicit. Codex stays off unless a case opts in.
  export CODEX_WATCH=0
  export CODEX_REOPEN_POLICY=crash_only
  export CODEX_READINESS_WAIT_SEC=1
  export CODEX_READINESS_POLL_SEC=0
  unset CODEX_PS_FILE CODEX_PS_AFTER_FILE CODEX_OPEN_BIN CODEX_CRASH_DIR CODEX_WAL_FILE CODEX_PAUSE || true
  mkdir -p "$GROK_APP_PATH" "$GROK_SUPPORT_DIR" "$LATCH_DIR/bin" "$(dirname "$HEAL_LOG")"
  cp "$ROOT/grok-bot-restart-guard.py" "$LATCH_DIR/bin/grok-bot-restart-guard.py"
  cp "$ROOT/codex-watch.py" "$LATCH_DIR/bin/codex-watch.py"
  chmod 755 "$LATCH_DIR/bin/grok-bot-restart-guard.py" "$LATCH_DIR/bin/codex-watch.py"
  stage_ps "$FIX/helpers/two-helpers.ps"
}

# Canned ps rows name the real app path. Point them at this test's GROK_APP_PATH
# so only processes inside the app are allowed to contribute flags.
stage_ps() {
  local dest="$TMP/staged-helper.ps"
  python3 - "$1" "$dest" "$GROK_APP_PATH" <<'PY'
import sys
src, dst, app = sys.argv[1:]
open(dst, "w").write(open(src).read().replace("/Applications/Grok Bot.app", app))
PY
  export HELPER_PS_FILE="$dest"
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
  if [[ -n "${TEST_FILTER:-}" && "$NAME" != *"$TEST_FILTER"* ]]; then return 0; fi
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
  [[ "$(jget kitVersion)" == "1.6.0" ]] || die "kit=$(jget kitVersion)"
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
  [[ "$(jget status)" == "observe" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "frozen hint authorized recovery"
  [[ "$(jget reason)" == "heartbeat_frozen" ]] || die "reason=$(jget reason)"
  [[ "$(jget readiness)" == "heartbeat_frozen_observe" ]] || die "readiness=$(jget readiness)"
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


# --- worker-beacon poll hook (curl is stubbed; no network) ---
beacon_env() {
  export BEACON_URL="https://beacon.invalid"
  export BEACON_MACHINE_ID="test-machine"
  export BEACON_POLL_TOKEN_FILE="$TMP/poll-token"
  printf 'fake-poll-token-for-tests\n' > "$BEACON_POLL_TOKEN_FILE"
  chmod 600 "$BEACON_POLL_TOKEN_FILE"
  export BEACON_CURL="$FIX/beacon-curl-stub.sh"
  export BEACON_STUB_CALLS="$TMP/curl-calls"
  export BEACON_STUB_RESPONSE='{"heal":true}'
  : > "$BEACON_STUB_CALLS"
  local now; now="$(now_ms)"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
}

t_beacon_heal() {
  beacon_env
  run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget action)" == "relaunch" ]] || die "action=$(jget action)"
  [[ "$(jget lastBeaconHealAtMs)" != "None" ]] || die "no beacon stamp"
  [[ "$(jget cloudConnectObservable)" == "False" ]] || die "cloudConnectObservable flipped"
  grep -q "fake-poll-token" "$BEACON_STUB_CALLS" && die "token leaked into curl argv" || true
  grep -q "fake-poll-token" "$HEAL_LOG" && die "token leaked into log" || true
}

t_beacon_false_noop() {
  beacon_env
  export BEACON_STUB_RESPONSE='{"heal":false}'
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched on heal:false" || true
}

t_beacon_bad_response_noop() {
  beacon_env
  for r in '{"heal":true,"cmd":"x"}' 'not json' '{"heal":"true"}' '{"heal":1}' ''; do
    export BEACON_STUB_RESPONSE="$r"
    rm -f "$HEAL_STATE"
    run_heal
    [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) for response: $r"
  done
}

t_beacon_worker_down_noop() {
  beacon_env
  export BEACON_STUB_FAIL=1
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
}

t_beacon_unconfigured_no_poll() {
  beacon_env
  unset BEACON_URL
  run_heal
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled while unconfigured"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
}

t_beacon_bypasses_cooldown() {
  beacon_env
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$((now - 30000))}"
  run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ "$(jget status)" == "healed" ]] || die "cooldown blocked beacon: status=$(jget status)"
}

t_beacon_disabled_no_poll_stays_queued() {
  beacon_env
  touch "$LATCH_DIR/grok-bot-local-exec-heal.disable"
  run_heal
  [[ "$(jget status)" == "disabled" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled (would consume) while disabled"
  grep -q "heal start" "$HEAL_LOG" && die "disabled tick relaunched" || true
}

t_beacon_second_request_escalates() {
  beacon_env
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$((now - 600000)),\"lastBeaconHealAtMs\":$((now - 600000))}"
  run_heal
  [[ "$(jget status)" == "beacon_suppressed" ]] || die "status=$(jget status)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget escalateHint)" == *"escalate"* ]] || die "no escalate hint"
  grep -q "heal start" "$HEAL_LOG" && die "second beacon relaunched" || true
  # outside the window a new outage is allowed again
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$((now - 7200000)),\"lastBeaconHealAtMs\":$((now - 7200000))}"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status) after window"
}

t_beacon_operator_request_wins() {
  beacon_env
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  run_heal
  [[ "$(jget reason)" == "operator_request" ]] || die "reason=$(jget reason)"
}


t_kit_version_matches() {
  local ver kit
  ver="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  kit="$(grep -E '^KIT_VERSION=' "$HEAL" | head -1 | sed -E 's/^KIT_VERSION="//; s/"$//')"
  [[ "$ver" == "1.6.0" ]] || die "VERSION=$ver"
  [[ "$kit" == "$ver" ]] || die "KIT_VERSION=$kit VERSION=$ver"
}

t_beacon_skip_poll_when_local_heal_cooldown() {
  # Local heal needed + cooldown: must NOT poll (would consume + Worker 5m lockout).
  beacon_env
  local now; now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  materialize "$FIX/stale-hb" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$((now - 30000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled during local-heal cooldown (would consume)"
}

t_beacon_token_world_readable_refuses() {
  beacon_env
  chmod 644 "$BEACON_POLL_TOKEN_FILE"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled with world-readable token"
  grep -q "perms too open" "$HEAL_LOG" || die "missing perms log"
}

t_beacon_token_group_readable_refuses() {
  beacon_env
  chmod 640 "$BEACON_POLL_TOKEN_FILE"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled with group-readable token"
  grep -q "perms too open (640)" "$HEAL_LOG" || die "missing perms log"
}

t_beacon_token_0400_polls() {
  beacon_env
  chmod 400 "$BEACON_POLL_TOKEN_FILE"
  run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "did not poll with 0400 token"
}

t_beacon_token_0600_polls() {
  beacon_env
  chmod 600 "$BEACON_POLL_TOKEN_FILE"
  run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "did not poll with 0600 token"
  ! grep -q "fake-poll-token-for-tests" "$HEAL_LOG" || die "token leaked into log"
}

# Writes $TMP/shim/stat. The two permission probes (`-c %a`, `-f %Lp`) get the canned behaviour
# named by $1/$2 ("junk" = exit 0 with GNU filesystem-stat junk, "fail" = exit 1, else print that
# value); every other stat call is delegated to the real stat so the rest of the heal run is unaffected.
make_stat_shim() {
  local c_mode="$1" f_mode="$2" real
  real="$(command -v stat)"
  mkdir -p "$TMP/shim"
  cat > "$TMP/shim/stat" <<EOF
#!/bin/sh
canned() {
  case "\$1" in
    junk) echo "  File: junk"; echo "    ID: 0 Namelen: 255"; exit 0 ;;
    fail) echo "stat: illegal option" >&2; exit 1 ;;
    *) echo "\$1"; exit 0 ;;
  esac
}
if [ "\$1" = "-c" ] && [ "\$2" = "%a" ]; then canned "$c_mode"; fi
if [ "\$1" = "-f" ] && [ "\$2" = "%Lp" ]; then canned "$f_mode"; fi
exec "$real" "\$@"
EOF
  chmod 755 "$TMP/shim/stat"
}

# Junk from both probes and the python fallback disabled (test-only BEACON_TEST_NO_PY_PERMS):
# mode cannot be determined, so the poll must be refused (fail closed).
t_beacon_token_perms_unknown_refuses() {
  beacon_env
  make_stat_shim junk junk
  PATH="$TMP/shim:$PATH" BEACON_TEST_NO_PY_PERMS=1 run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled with unknown perms"
  grep -q "perms unknown; refuse" "$HEAL_LOG" || die "missing perms unknown log"
}

# Same junk stat but python fallback enabled: mode is recovered, 0600 still polls.
t_beacon_token_junk_stat_python_fallback_polls() {
  beacon_env
  make_stat_shim junk junk
  PATH="$TMP/shim:$PATH" run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "did not poll via python fallback"
}

# Probe, not uname: GNU stat first on PATH (e.g. macOS + Homebrew gnubin) answers `-c %a` and gives
# junk for `-f %Lp`. With no python fallback the mode must still be found from the GNU probe.
t_beacon_token_probe_gnu_stat_polls() {
  beacon_env
  make_stat_shim 600 junk
  PATH="$TMP/shim:$PATH" BEACON_TEST_NO_PY_PERMS=1 run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "did not poll with GNU-style stat"
}

# Mirror: BSD stat rejects `-c`; the `-f %Lp` probe answers. A too-open answer still refuses.
t_beacon_token_probe_bsd_stat() {
  beacon_env
  make_stat_shim fail 600
  PATH="$TMP/shim:$PATH" BEACON_TEST_NO_PY_PERMS=1 run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "did not poll with BSD-style stat"
  setup_env; beacon_env
  make_stat_shim fail 644
  PATH="$TMP/shim:$PATH" BEACON_TEST_NO_PY_PERMS=1 run_heal
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled with BSD-reported 644"
  grep -q "perms too open (644)" "$HEAL_LOG" || die "missing perms too open log"
}

# token_file_mode on real files (stat needs no read access, so mode 040 is testable without a
# second uid): a short mode is judged, not "unknown"; 4-digit modes pass through.
t_token_file_mode_real_modes() {
  local f="$TMP/modefile" m
  : > "$f"
  eval "$(sed -n '/^token_file_mode() {/,/^}/p' "$HEAL")"
  local PYTHON; PYTHON="$(command -v python3)"
  chmod 040 "$f"; m="$(token_file_mode "$f")"
  [[ "$m" =~ ^0?040$ ]] || die "040 -> '$m'"
  (( (8#$m & 077) != 0 )) || die "040 not judged too open"
  chmod 600 "$f"; m="$(token_file_mode "$f")"; [[ "$m" == "600" ]] || die "600 -> '$m'"
  chmod 1600 "$f" 2>/dev/null && { m="$(token_file_mode "$f")"; [[ "$m" == "1600" || "$m" == "600" ]] || die "1600 -> '$m'"; }  # BSD %Lp drops the sticky bit
  # Same 040 with both stat probes junk: python fallback zero-pads to 040.
  make_stat_shim junk junk
  chmod 040 "$f"; m="$(PATH="$TMP/shim:$PATH" token_file_mode "$f")"
  [[ "$m" == "040" ]] || die "python 040 -> '$m'"
  chmod 600 "$f"
}

# The token must never be in any argv: record python and curl argv via shims and grep both.
t_beacon_token_never_in_argv() {
  beacon_env
  local real_py; real_py="$(command -v python3)"
  export PY_ARGV_LOG="$TMP/py-argv"
  : > "$PY_ARGV_LOG"
  mkdir -p "$TMP/shim"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$PY_ARGV_LOG"\nexec "%s" "$@"\n' "$real_py" > "$TMP/shim/python3-argv"
  chmod 755 "$TMP/shim/python3-argv"
  PYTHON="$TMP/shim/python3-argv" run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ -s "$PY_ARGV_LOG" ]] || die "python shim not used"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "curl stub not used"
  ! grep -q "fake-poll-token" "$PY_ARGV_LOG" || die "token in python argv"
  ! grep -q "fake-poll-token" "$BEACON_STUB_CALLS" || die "token in curl argv"
  ! grep -q "fake-poll-token" "$HEAL_LOG" || die "token in log"
}

# A non-HTTPS BEACON_URL must never receive the poller bearer (fail closed, no poll, no heal).
t_beacon_http_url_refuses() {
  beacon_env
  export BEACON_URL="http://beacon.invalid"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled over http"
  grep -q "BEACON_URL is not https; refuse" "$HEAL_LOG" || die "missing https refuse log"
  ! grep -q "fake-poll-token-for-tests" "$HEAL_LOG" || die "token leaked into log"
}

# The https poll passes --proto =https so curl itself cannot be steered to another scheme.
t_beacon_curl_proto_https_only() {
  beacon_env
  run_heal
  grep -q -- "--proto =https" "$BEACON_STUB_CALLS" || die "curl not pinned to https"
}

t_beacon_token_quote_refuses() {
  beacon_env
  printf 'bad"token\n' > "$BEACON_POLL_TOKEN_FILE"
  chmod 600 "$BEACON_POLL_TOKEN_FILE"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "polled with quote in token"
  grep -q "quote or backslash" "$HEAL_LOG" || die "missing refuse log"
}

# --- helper-count observer (1.5.0, S-NEW-D helper-exit signature). Canned ps/lsof; no live app. ---
jraw() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps(d.get(sys.argv[2])))' "$HEAL_STATE" "$1"
}
snap_count() { ls "$(dirname "$HEAL_STATE")"/GrokBotLocalExecHeal-snap-*.json 2>/dev/null | wc -l | tr -d ' '; }
newest_snap() { ls "$(dirname "$HEAL_STATE")"/GrokBotLocalExecHeal-snap-*.json 2>/dev/null | sort | tail -1; }

# Seed: same main pid 4242, learned baseline 2, helper count below baseline since $1 ms ago.
seed_helper_missing() {
  local now="$1" missing_ms="$2" extra="${3:-}"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"checkedAtMs\":$((now - 60000)),\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":1,\"helperStableSinceMs\":$((now - missing_ms)),\"helperMissingSinceMs\":$((now - missing_ms))${extra}}"
}

# The restart guard records an attempt before quit/open. Cases that relaunch
# several times in one second clear it so they still test the floor, not backoff.
clear_restart_ledger() {
  rm -f "$LATCH_DIR/grok-bot-restart-attempts.json"
}

t_helper_fields_healthy() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget helperCount)" == "2" ]] || die "helperCount=$(jget helperCount)"
  [[ "$(jraw helperSockets)" == '{"4300": 2, "4301": 0}' ]] || die "healthy sockets=$(jraw helperSockets)"
  grep -q "helper_sockets 4300:2,4301:0" "$HEAL_LOG" || die "healthy tick did not log socket counts"
  ! grep -q "203.0.113\|192.0.2" "$HEAL_LOG" || die "address leaked into healthy log"
  [[ "$(jget helperNoneSeen)" == "False" ]] || die "helperNoneSeen=$(jget helperNoneSeen)"
  # Other-parent NodeService helper (7000), NetworkService (4302), renderer/GPU and a shell child are not counted.
  [[ "$(jraw helperPids)" == "[4300, 4301]" ]] || die "helperPids=$(jraw helperPids)"
  [[ "$(jget helperExpected)" == "None" ]] || die "expected before learning=$(jget helperExpected)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "baseline learned in one tick"
  [[ "$(jget helperStableSinceMs)" == "$now" ]] || die "stable clock=$(jget helperStableSinceMs)"
  [[ "$(jget healOnHelperMissing)" == "False" ]] || die "default not log-only"
  [[ "$(snap_count)" == "0" ]] || die "snapshot on ok tick"
}

t_helper_learn_baseline() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000)),\"helperHealthySamples\":2}"
  run_heal
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline=$(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperExpectedSource)" == "learned" ]] || die "src=$(jget helperExpectedSource)"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
}

t_helper_learn_needs_stable_window() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 100000))}"
  run_heal
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned before HELPER_BASELINE_SEC: $(jget helperBaseline)"
}

t_helper_learn_not_while_unhealthy() {
  # boot not ready: count may be stable, but it must not become the baseline,
  # and it must not seed the running minimum.
  local now t1 t2 t3 t4 t5
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"cooldown\",\"pid\":4242,\"lastHealAtMs\":$((now - 10000)),\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned while unhealthy"
  [[ "$(jget helperStableSinceMs)" == "$now" ]] || die "stable clock not reset while unhealthy"
  [[ "$(jget helperStableCount)" == "None" ]] || die "unhealthy seeded min=$(jget helperStableCount)"
  [[ "$(jget helperCount)" == "2" ]] || die "boot count=$(jget helperCount)"

  # No heartbeat yet, live count 1. That 1 must not become the minimum.
  # Steady 2 after that learns 2, so a later 2 to 1 still observes.
  rm -f "$HEAL_STATE"
  rm -rf "$GROK_SUPPORT_DIR/dune-reliability"
  : > "$HEAL_LOG"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/no-heartbeat" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget reason)" == "process_up_no_heartbeat_file" ]] || die "no-hb reason=$(jget reason)"
  [[ "$(jget helperCount)" == "1" ]] || die "no-hb count=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "no-hb learned $(jget helperBaseline)"
  [[ "$(jget helperStableCount)" == "None" ]] || die "no-hb seeded min=$(jget helperStableCount)"

  stage_ps "$FIX/helpers/two-helpers.ps"
  t1=$((now + 60000))
  export HEAL_NOW_MS="$t1"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t1"
  run_heal
  [[ "$(jget helperCount)" == "2" ]] || die "steady count=$(jget helperCount)"
  [[ "$(jget helperStableCount)" == "2" ]] || die "min after healthy=$(jget helperStableCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned on first healthy tick"
  t2=$((t1 + 60000))
  export HEAL_NOW_MS="$t2"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned before 3 samples"
  t3=$((t1 + 600000))
  export HEAL_NOW_MS="$t3"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t3"
  run_heal
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline=$(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget status)" == "ok" ]] || die "learn status=$(jget status)"

  stage_ps "$FIX/helpers/one-helper.ps"
  t4=$((t3 + 60000))
  export HEAL_NOW_MS="$t4"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t4"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "drop grace status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline moved on the drop"
  t5=$((t4 + 400000))
  export HEAL_NOW_MS="$t5"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t5"
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "2 to 1 status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "2 to 1 reason=$(jget reason)"
  [[ "$(jget helperExpected)" == "2" ]] || die "2 to 1 expected=$(jget helperExpected)"
  [[ "$(jget helperCount)" == "1" ]] || die "2 to 1 count=$(jget helperCount)"
}

t_helper_baseline_never_lowers() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  # count 1 has been stable for 700s (> HELPER_BASELINE_SEC) but the baseline must stay 2.
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":1,\"helperStableSinceMs\":$((now - 700000))}"
  run_heal
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline lowered to $(jget helperBaseline)"
  [[ "$(jget helperMissingSinceMs)" == "$now" ]] || die "missing clock=$(jget helperMissingSinceMs)"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
}

t_helper_under_threshold() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 120000
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget helperMissingSinceMs)" == "$((now - 120000))" ]] || die "missing clock not carried"
  [[ "$(jget helperCount)" == "1" ]] || die "helperCount=$(jget helperCount)"
  [[ "$(snap_count)" == "0" ]] || die "snapshot under threshold"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched under threshold" || true
}

t_helper_missing_log_only() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget readiness)" == "helper_missing_observe" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget escalateHint)" == *"helper_missing (log-only)"* ]] || die "hint=$(jget escalateHint)"
  [[ "$(jget lastHealAtMs)" == "None" ]] || die "heal stamp in log-only"
  [[ "$(jraw helperPids)" == "[4300]" ]] || die "helperPids=$(jraw helperPids)"
  grep -q "observe reason=helper_missing" "$HEAL_LOG" || die "missing observe log"
  grep -q "heal start" "$HEAL_LOG" && die "log-only relaunched" || true
  [[ "$(snap_count)" == "1" ]] || die "snapshots=$(snap_count)"
  python3 - "$(newest_snap)" <<'PY' || die "snapshot content"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["status"] == "observe" and s["reason"] == "helper_missing", s
assert s["helperCount"] == 1 and s["helperExpected"] == 2, s
pids = sorted(p["pid"] for p in s["processTree"])
assert pids == [4242, 4290, 4291, 4300, 4302, 4400], pids
gpu = [p for p in s["processTree"] if p["pid"] == 4290][0]
assert gpu["exe"] == "Grok Bot Helper" and gpu.get("subType") != "node.mojom.NodeService", gpu
assert 4290 not in (s.get("helperPids") or []), gpu
assert s.get("phase") == "tick", s.get("phase")
assert s.get("desktopStatus", {}).get("pid") == 4242, s.get("desktopStatus")
assert s.get("dune", {}).get("bootOutcome") == "ready", s.get("dune")
PY
}

t_helper_missing_relaunch() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason=$(jget reason)"
  [[ "$(jget action)" == "relaunch" ]] || die "action=$(jget action)"
  [[ "$(jget readiness)" == "ready" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget lastHelperHealAtMs)" == "$now" ]] || die "lastHelperHealAtMs=$(jget lastHelperHealAtMs)"
  [[ "$(jget lastHealAtMs)" == "$now" ]] || die "lastHealAtMs=$(jget lastHealAtMs)"
  [[ "$(jget helperMissingSinceMs)" == "None" ]] || die "missing clock kept across relaunch"
  [[ "$(jget helperBaseline)" == "2" ]] || die "floor baseline=$(jget helperBaseline)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "floor pending=$(jget helperFloorPending)"
  [[ "$(jget helperBaselinePid)" == "5151" ]] || die "baseline pid=$(jget helperBaselinePid)"
  [[ "$(jget helperCount)" == "1" ]] || die "pre-heal helperCount=$(jget helperCount)"
  grep -q "heal start reason=helper_missing" "$HEAL_LOG" || die "missing heal start"
  grep -q "dry-run: skip quit/open" "$HEAL_LOG" || die "dry-run did not skip quit/open"
  grep -q "snapshot before relaunch" "$HEAL_LOG" || die "no pre-relaunch snapshot"
  python3 - "$HEAL_LOG" <<'PY' || die "snapshot not written before quit/open"
import sys
text = open(sys.argv[1]).read()
a = text.find("snapshot before relaunch")
b = text.find("dry-run: skip quit/open")
assert a != -1 and b != -1 and a < b, (a, b)
PY
  # Detection record (*-before.json) plus the post-readiness tick snapshot.
  [[ "$(snap_count)" == "2" ]] || die "snapshots=$(snap_count)"
  local before
  before="$(ls "$(dirname "$HEAL_STATE")"/GrokBotLocalExecHeal-snap-*-before.json | tail -1)"
  python3 - "$before" <<'PY' || die "before snapshot content"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["phase"] == "before_relaunch" and s["reason"] == "helper_missing", s
assert s["helperCount"] == 1 and s["status"] == "pre_relaunch", s
assert s["processTreeAt"] == "tick_start"
PY
  # The relaunch wrote the floor. Past the hourly window, still one helper:
  # stay suppressed. Do not relaunch again and do not store the lower count.
  local later hits
  later=$((now + 4000000))
  export HEAL_NOW_MS="$later"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$later"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "post-window grace status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline lost after window: $(jget helperBaseline)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "floor cleared while still short"
  [[ "$(jget helperMissingSinceMs)" == "$later" ]] || die "grace not restarted: $(jget helperMissingSinceMs)"
  hits="$(grep -c "heal start" "$HEAL_LOG" || true)"
  [[ "$hits" == "1" ]] || die "relaunched during restarted grace: $hits"
  export HEAL_NOW_MS=$((later + 400000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(jget status)" == "helper_suppressed" ]] || die "still-short status=$(jget status) reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "hourly relaunch action=$(jget action)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "stored the lower count: $(jget helperBaseline)"
  [[ "$(jget helperCount)" == "1" ]] || die "still-short count=$(jget helperCount)"
  hits="$(grep -c "heal start" "$HEAL_LOG" || true)"
  [[ "$hits" == "1" ]] || die "relaunched hourly while the floor was unmet: $hits"
}

t_helper_missing_cooldown() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 30000))"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget helperMissingSinceMs)" == "$((now - 400000))" ]] || die "missing clock lost in cooldown"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched in cooldown" || true
  # Floor pending is the status even when cooldown would also apply.
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 30000)),\"helperFloorPending\":true,\"lastHelperHealAtMs\":$((now - 30000))"
  run_heal
  [[ "$(jget status)" == "helper_suppressed" ]] || die "floor recorded as $(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "floor reason=$(jget reason)"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched while floor and cooldown both applied" || true
  # Cooldown over (last heal from another reason 400s ago): helper_missing relaunches.
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 400000))"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status after cooldown=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason after cooldown=$(jget reason)"
}

t_helper_one_relaunch_per_window() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 600000)),\"lastHelperHealAtMs\":$((now - 600000))"
  run_heal
  [[ "$(jget status)" == "helper_suppressed" ]] || die "status=$(jget status)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget escalateHint)" == *"helper_suppressed"* ]] || die "hint=$(jget escalateHint)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline=$(jget helperBaseline)"
  grep -q "heal start" "$HEAL_LOG" && die "second helper relaunch inside window" || true
  # Window elapsed and the count is still short: stay suppressed. Do not store 1 as healthy.
  seed_state "{\"version\":2,\"status\":\"helper_suppressed\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperFloorPending\":true,\"helperStableCount\":1,\"helperStableSinceMs\":$((now - 400000)),\"helperMissingSinceMs\":$((now - 400000)),\"lastHealAtMs\":$((now - 7200000)),\"lastHelperHealAtMs\":$((now - 7200000))}"
  run_heal
  [[ "$(jget status)" == "helper_suppressed" ]] || die "status after window=$(jget status)"
  [[ "$(jget action)" == "none" ]] || die "relaunched after window while still short"
  [[ "$(jget helperBaseline)" == "2" ]] || die "stored the lower count: $(jget helperBaseline)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "floor cleared while still short"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched while the floor was still pending" || true
}

t_helper_operator_request_wins() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_helper_missing "$now" 400000
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  run_heal
  [[ "$(jget reason)" == "operator_request" ]] || die "reason=$(jget reason)"
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
}

t_helper_log_only_beacon_still_heals() {
  beacon_env
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "reason=$(jget reason)"
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ -s "$BEACON_STUB_CALLS" ]] || die "log-only observe skipped the beacon poll"
}

t_helper_disable_wins() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  touch "$LATCH_DIR/grok-bot-local-exec-heal.disable"
  run_heal
  [[ "$(jget status)" == "disabled" ]] || die "status=$(jget status)"
  grep -q "heal start" "$HEAL_LOG" && die "disabled tick relaunched" || true
  [[ "$(snap_count)" == "0" ]] || die "snapshot while disabled"
}

t_helper_expected_override() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_EXPECTED=3
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperMissingSinceMs\":$((now - 400000))}"
  run_heal
  [[ "$(jget helperExpected)" == "3" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperExpectedSource)" == "config" ]] || die "src=$(jget helperExpectedSource)"
  [[ "$(jget status)" == "observe" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason=$(jget reason)"
}

t_helper_pid_change_resets() {
  # External pid change while a missing interval is open: keep the old expected
  # count, and restart grace so the new process is not judged on the old clock.
  # A short sample on the new pid must not become the healthy baseline.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":9999,\"helperBaseline\":2,\"helperBaselinePid\":9999,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 900000)),\"helperMissingSinceMs\":$((now - 900000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline=$(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperCount)" == "1" ]] || die "count=$(jget helperCount)"
  [[ "$(jget helperMissingSinceMs)" == "$now" ]] || die "grace not restarted: $(jget helperMissingSinceMs)"
  grep -q "heal start" "$HEAL_LOG" && die "log-only pid change relaunched" || true
  # Past the fresh 300s grace the short count is helper_missing again, still at baseline 2.
  local later; later=$((now + 400000))
  export HEAL_NOW_MS="$later"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$later"
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "after grace status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "after grace reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline after grace=$(jget helperBaseline)"
  [[ "$(jget helperMissingSinceMs)" == "$now" ]] || die "clock moved: $(jget helperMissingSinceMs)"
  grep -q "heal start" "$HEAL_LOG" && die "log-only after grace relaunched" || true
}

t_helper_config_expected_pid_change_keeps_floor() {
  # Operator HELPER_EXPECTED and no learned baseline. A pid change while short
  # keeps that expected count and the pending floor, and restarts grace.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_EXPECTED=2
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"observe\",\"pid\":9999,\"helperExpected\":2,\"helperExpectedSource\":\"config\",\"helperFloorPending\":true,\"helperMissingSinceMs\":$((now - 900000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperExpectedSource)" == "config" ]] || die "src=$(jget helperExpectedSource)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned a baseline on the short pid: $(jget helperBaseline)"
  [[ "$(jget helperCount)" == "1" ]] || die "count=$(jget helperCount)"
  [[ "$(jget helperMissingSinceMs)" == "$now" ]] || die "grace not restarted: $(jget helperMissingSinceMs)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "floor dropped: $(jget helperFloorPending)"
}

t_helper_pid_change_healthy_resets() {
  # No open missing interval and no pending floor: a new pid starts learning over.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":9999,\"helperBaseline\":2,\"helperBaselinePid\":9999,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 900000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "baseline carried on a healthy pid change"
  [[ "$(jget helperMissingSinceMs)" == "None" ]] || die "missing clock=$(jget helperMissingSinceMs)"
  [[ "$(jget helperCount)" == "2" ]] || die "count=$(jget helperCount)"
  [[ "$(jget helperFloorPending)" == "False" ]] || die "floor=$(jget helperFloorPending)"
}

t_helper_check_off() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_CHECK=0 HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget helperCount)" == "None" ]] || die "scanned with HELPER_CHECK=0"
}

t_helper_ps_unreadable_no_signal() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  export HELPER_PS_FILE="$TMP/does-not-exist.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget helperCount)" == "None" ]] || die "count from unreadable ps"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched on unknown count" || true
}

t_helper_sockets_counts_no_addresses() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jraw helperSockets)" == '{"4300": 2}' ]] || die "helperSockets=$(jraw helperSockets)"
  local f; for f in "$HEAL_STATE" "$HEAL_LOG" "$(newest_snap)"; do
    ! grep -q "203.0.113\|192.0.2" "$f" || die "address leaked into $f"
    ! grep -q "fixture-user\|fixture-handle\|fixture-secret\|fixture-grandchild" "$f" || die "argv leaked into $f"
  done
  # A healthy tick records socket counts and does not heal.
  stage_ps "$FIX/helpers/two-helpers.ps"
  rm -f "$HEAL_STATE"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "healthy status=$(jget status)"
  [[ "$(jraw helperSockets)" == '{"4300": 2, "4301": 0}' ]] || die "sockets on healthy tick=$(jraw helperSockets)"
  grep -q "helper_sockets " "$HEAL_LOG" || die "healthy tick did not log sockets"
  ! grep -q "203.0.113\|192.0.2" "$HEAL_LOG" || die "address leaked on healthy tick"
  # Snapshot tick with two helpers: the second has only a non-443 socket.
  export HELPER_EXPECTED=3
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "observe status=$(jget status)"
  [[ "$(jraw helperSockets)" == '{"4300": 2, "4301": 0}' ]] || die "helperSockets(2)=$(jraw helperSockets)"
  export HELPER_SOCKET_CHECK=0; rm -f "$HEAL_STATE"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget helperSockets)" == "None" ]] || die "socket check not off"
  # Exit 1 with stderr is a real error. macOS lsof exits 1 with no output when
  # none of the pids has an ESTABLISHED socket; that is {pid: 0}, not null.
  export HELPER_SOCKET_CHECK=1
  export HELPER_LSOF_FILE=""
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "lsof: fixture error" >&2\nexit 1\n' > "$TMP/bin/lsof"
  chmod +x "$TMP/bin/lsof"
  export HELPER_LSOF_BIN="$TMP/bin/lsof"
  rm -f "$HEAL_STATE"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "lsof-error status=$(jget status)"
  [[ "$(jget helperSockets)" == "None" ]] || die "lsof stderr stored $(jget helperSockets)"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/lsof"
  rm -f "$HEAL_STATE"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "lsof-nomatch status=$(jget status)"
  [[ "$(jraw helperSockets)" == '{"4300": 0, "4301": 0}' ]] || die "lsof no-match sockets=$(jraw helperSockets)"
}

t_snapshot_rate_limited_and_pruned() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(snap_count)" == "1" ]] || die "first snapshots=$(snap_count)"
  export HEAL_NOW_MS=$((now + 60000))
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "second status=$(jget status)"
  [[ "$(snap_count)" == "1" ]] || die "not rate-limited: $(snap_count)"
  [[ "$(jget lastSnapshotAtMs)" == "$now" ]] || die "lastSnapshotAtMs=$(jget lastSnapshotAtMs)"
  [[ "$(jget snapshotBackoffMs)" == "900000" ]] || die "first backoff=$(jget snapshotBackoffMs)"
  export HEAL_NOW_MS=$((now + 960000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(snap_count)" == "2" ]] || die "no snapshot after HEAL_SNAPSHOT_MIN_SEC: $(snap_count)"
  [[ "$(jget snapshotBackoffMs)" == "1800000" ]] || die "doubled backoff=$(jget snapshotBackoffMs)"
  # Inside the doubled gap: same observe status does not snapshot again.
  export HEAL_NOW_MS=$((now + 1860000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(snap_count)" == "2" ]] || die "doubled gap still wrote: $(snap_count)"
  export HEAL_SNAPSHOT_KEEP=2 HEAL_NOW_MS=$((now + 2760000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(snap_count)" == "2" ]] || die "not pruned to HEAL_SNAPSHOT_KEEP: $(snap_count)"
}

t_snapshot_backoff_resets_on_ok() {
  # A 4h backoff must not survive an ok tick. The next outage snapshots
  # once the base gap has elapsed, not after another 4h.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000 ",\"lastSnapshotAtMs\":$((now - 1000000)),\"lastSnapshotStatus\":\"observe\",\"lastSnapshotReason\":\"helper_missing\",\"snapshotBackoffMs\":14400000"
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "still-short status=$(jget status)"
  [[ "$(snap_count)" == "0" ]] || die "4h backoff wrote a snapshot: $(snap_count)"
  [[ "$(jget snapshotBackoffMs)" == "14400000" ]] || die "backoff=$(jget snapshotBackoffMs)"

  export HEAL_NOW_MS=$((now + 60000))
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "recover status=$(jget status) reason=$(jget reason)"
  [[ "$(jget snapshotBackoffMs)" == "None" ]] || die "ok kept backoff=$(jget snapshotBackoffMs)"
  [[ "$(snap_count)" == "0" ]] || die "ok tick snapshotted: $(snap_count)"

  local drop=$((now + 120000))
  export HEAL_NOW_MS="$drop"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$drop"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "new grace status=$(jget status)"
  export HEAL_NOW_MS=$((drop + 400000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "new outage status=$(jget status) reason=$(jget reason)"
  [[ "$(snap_count)" == "1" ]] || die "new outage snapshots=$(snap_count)"
  [[ "$(jget snapshotBackoffMs)" != "14400000" ]] || die "4h backoff survived the ok tick"
}

# Oct 7 shape: main pid and a moving fresh heartbeat stay healthy while one
# NodeService helper is gone (2 → 1). Under the grace window that is still ok.
# Past HELPER_MISSING_SEC the default is log-only plus a snapshot. With
# HEAL_ON_HELPER_MISSING=1 the same shape relaunches and reaches readiness,
# and the diagnostics file is written before quit/open. Secrets in the status
# files must not appear in the snapshot, last.json, or the heal log.
t_oct7_helper_drop_replay() {
  local now t2 t3 before
  now="$(now_ms)"
  export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/oct7" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"heartbeatAtMs\":$((now - 40000)),\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000)),\"okStreakSinceMs\":$((now - 10000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "baseline tick status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "baseline reason=$(jget reason)"
  [[ "$(jget helperCount)" == "2" ]] || die "baseline count=$(jget helperCount)"
  [[ "$(jget cloudConnectObservable)" == "False" ]] || die "cloud flag on healthy tick"
  [[ "$(snap_count)" == "0" ]] || die "snapshot while both helpers are up"

  t2=$((now + 60000))
  export HEAL_NOW_MS="$t2"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/oct7" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "under-grace status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "under-grace reason=$(jget reason)"
  [[ "$(jget helperCount)" == "1" ]] || die "dropped count=$(jget helperCount)"
  [[ "$(jget helperMissingSinceMs)" == "$t2" ]] || die "missing clock=$(jget helperMissingSinceMs)"
  [[ "$(jget action)" == "none" ]] || die "under-grace action=$(jget action)"
  [[ "$(snap_count)" == "0" ]] || die "snapshot inside HELPER_MISSING_SEC"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched inside grace" || true

  t3=$((t2 + 360000))
  export HEAL_NOW_MS="$t3"
  materialize "$FIX/oct7" "$GROK_SUPPORT_DIR" "$t3"
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "observe status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "observe reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "log-only action=$(jget action)"
  [[ "$(jget readiness)" == "helper_missing_observe" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget cloudConnectObservable)" == "False" ]] || die "cloudConnectObservable flipped"
  [[ "$(snap_count)" == "1" ]] || die "observe snapshots=$(snap_count)"
  python3 - "$(newest_snap)" "$HEAL_STATE" "$HEAL_LOG" <<'PY' || die "oct7 observe snapshot"
import json, sys
snap_path, state_path, log_path = sys.argv[1:]
s = json.load(open(snap_path))
blob = json.dumps(s) + open(state_path).read() + open(log_path).read()
for needle in ("should-not-appear", "fixture-user", "fixture-secret", "fixture-handle", "gatewayToken", "installId"):
    assert needle not in blob, needle
assert s["phase"] == "tick" and s["reason"] == "helper_missing", s
assert s["helperCount"] == 1 and s["helperExpected"] == 2, s
ds, dune = s["desktopStatus"], s["dune"]
assert ds["signedIn"] is True and ds["appVersion"] == "0.68.1" and ds["pid"] == 4242, ds
assert "installId" not in ds and "token" not in ds, ds
assert dune["bootOutcome"] == "ready" and dune["mainFaultSeen"] is False, dune
assert dune["childDeaths"] == {}, dune
assert "installId" not in dune and "gatewayToken" not in dune, dune
subs = [p.get("subType") for p in s["processTree"]]
assert subs.count("node.mojom.NodeService") == 1, subs
PY

  export HEAL_ON_HELPER_MISSING=1
  export HEAL_NOW_MS="$t3"
  materialize "$FIX/oct7" "$GROK_SUPPORT_DIR" "$t3"
  materialize "$FIX/post-ready" "$TMP/post" "$t3"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "heal status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "heal reason=$(jget reason)"
  [[ "$(jget readiness)" == "ready" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget action)" == "relaunch" ]] || die "action=$(jget action)"
  [[ "$(jget cloudConnectObservable)" == "False" ]] || die "cloud flag after heal"
  python3 - "$HEAL_LOG" <<'PY' || die "oct7 snapshot not before relaunch"
import sys
text = open(sys.argv[1]).read()
a = text.find("snapshot before relaunch")
b = text.find("dry-run: skip quit/open")
assert a != -1 and b != -1 and a < b, (a, b)
PY
  before="$(ls "$(dirname "$HEAL_STATE")"/GrokBotLocalExecHeal-snap-*-before.json | tail -1)"
  python3 - "$before" <<'PY' || die "oct7 before snapshot"
import json, sys
s = json.load(open(sys.argv[1]))
blob = json.dumps(s)
assert "should-not-appear" not in blob and "installId" not in blob
assert s["phase"] == "before_relaunch" and s["helperCount"] == 1, s
assert s["dune"]["childDeaths"] == {} and s["desktopStatus"]["signedIn"] is True, s
PY
}

t_install_preserves_helper_env() {
  local home="$TMP/home-helper"
  local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home/Library/LaunchAgents"
  python3 - "$pl" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "x", "EnvironmentVariables": {
    "HEAL_ON_HELPER_MISSING": "1",
    "HELPER_MISSING_SEC": "120",
    "HELPER_BASELINE_SEC": "900",
    "HELPER_EXPECTED": "2",
    "BEACON_URL": "https://example.invalid",
    "PATH": "/opt/custom/bin:/usr/bin:/bin"}},
    open(sys.argv[1], "wb"))
PY
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "install failed"
  # Stage 0 resets helper recovery. Other numeric overrides are preserved.
  # Beacon env is still preserved. Kit-owned PATH comes from the template.
  t_install_env_check "$pl" "RECOVERY_MODE=observe;HEAL_ON_HELPER_MISSING=0;HELPER_MISSING_SEC=120;HELPER_BASELINE_SEC=900;HELPER_EXPECTED=2;BEACON_URL=https://example.invalid;HEAL_ON_STUCK_SESSION=1;PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    || die "helper env not preserved"
}

t_install_template_helper_defaults() {
  local home="$TMP/home3"; local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home"
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "fresh install failed"
  # Stage 0 explicitly pins recovery off on a fresh install.
  python3 - "$pl" <<'PY' || die "script-owned helper defaults must not be pinned by the template"
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]
assert env["HEAL_ON_HELPER_MISSING"] == "0", env
assert env["RECOVERY_MODE"] == "observe", env
for key in ("HELPER_EXPECTED", "HELPER_MISSING_SEC", "HELPER_BASELINE_SEC", "HELPER_RELAUNCH_WINDOW_SEC"):
    assert key not in env, (key, env)
PY
}

t_install_helper_missing_opt_in_survives() {
  # A legacy opt-in is demoted; only explicit invocation options enable recovery.
  local home="$TMP/home-optin"
  local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home"
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "fresh install failed"
  python3 - "$pl" <<'PY' || die "fresh install pinned HEAL_ON_HELPER_MISSING"
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]
assert env["HEAL_ON_HELPER_MISSING"] == "0", env
assert env["RECOVERY_MODE"] == "observe", env
PY
  python3 - "$pl" <<'PY'
import plistlib, sys
path = sys.argv[1]
pl = plistlib.load(open(path, "rb"))
pl["EnvironmentVariables"]["HEAL_ON_HELPER_MISSING"] = "1"
pl["EnvironmentVariables"]["RECOVERY_MODE"] = "active"
plistlib.dump(pl, open(path, "wb"))
PY
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "reinstall failed"
  t_install_env_check "$pl" "RECOVERY_MODE=observe;HEAL_ON_HELPER_MISSING=0" || die "legacy opt-in preserved silently"
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 INSTALL_RECOVERY_MODE=active INSTALL_HELPER_HEAL=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "explicit install opt-in failed"
  t_install_env_check "$pl" "RECOVERY_MODE=active;HEAL_ON_HELPER_MISSING=1" || die "explicit opt-in lost"
}

t_helper_baseline_never_rises() {
  # A third helper held for hours must not raise an already-learned 2.
  # The stored minimum is 2: that is the value learn-once kept. A live count
  # of 3 is above the minimum, so the seed is a state the min can actually hold.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/three-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 14400000)),\"helperHealthySamples\":3}"
  run_heal
  [[ "$(jget helperCount)" == "3" ]] || die "helperCount=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline raised to $(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
}

t_helper_dip_recovers_within_grace() {
  # 2 → 1 → 2 inside HELPER_MISSING_SEC: clock clears, no observe, no snapshot.
  local now t2 t3
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "start status=$(jget status)"
  [[ "$(jget helperCount)" == "2" ]] || die "start count=$(jget helperCount)"
  [[ "$(jget helperMissingSinceMs)" == "None" ]] || die "start missing=$(jget helperMissingSinceMs)"
  [[ "$(snap_count)" == "0" ]] || die "snapshot at count 2"

  t2=$((now + 60000))
  export HEAL_NOW_MS="$t2"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "dip status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "dip reason=$(jget reason)"
  [[ "$(jget helperCount)" == "1" ]] || die "dip count=$(jget helperCount)"
  [[ "$(jget helperMissingSinceMs)" == "$t2" ]] || die "dip clock=$(jget helperMissingSinceMs)"
  [[ "$(jget action)" == "none" ]] || die "dip action=$(jget action)"
  [[ "$(snap_count)" == "0" ]] || die "snapshot inside grace"

  t3=$((t2 + 60000))
  export HEAL_NOW_MS="$t3"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t3"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "recover status=$(jget status)"
  [[ "$(jget reason)" == "healthy" ]] || die "recover reason=$(jget reason)"
  [[ "$(jget helperCount)" == "2" ]] || die "recover count=$(jget helperCount)"
  [[ "$(jget helperMissingSinceMs)" == "None" ]] || die "clock not cleared: $(jget helperMissingSinceMs)"
  [[ "$(jget action)" == "none" ]] || die "recover action=$(jget action)"
  [[ "$(snap_count)" == "0" ]] || die "snapshot after recovery"
  grep -q "observe reason=helper_missing" "$HEAL_LOG" && die "observed a dip that recovered" || true
  grep -q "heal start" "$HEAL_LOG" && die "relaunched inside grace" || true
}

t_helper_floor_met_allows_new_outage() {
  # Once the live count meets the floor, a later drop past the window can relaunch.
  local now t2
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_state "{\"version\":2,\"status\":\"helper_suppressed\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperFloorPending\":true,\"helperStableCount\":1,\"helperStableSinceMs\":$((now - 700000)),\"lastHealAtMs\":$((now - 7200000)),\"lastHelperHealAtMs\":$((now - 7200000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "recovered status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperFloorPending)" == "False" ]] || die "floor stuck after count recovered"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline=$(jget helperBaseline)"
  [[ "$(jget helperCount)" == "2" ]] || die "count=$(jget helperCount)"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched a recovered count" || true

  t2=$((now + 400000))
  export HEAL_NOW_MS="$t2"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  materialize "$FIX/post-ready" "$TMP/post" "$t2"
  run_heal
  # Missing clock just started; still inside grace.
  [[ "$(jget status)" == "ok" ]] || die "new dip status=$(jget status)"
  [[ "$(jget helperMissingSinceMs)" == "$t2" ]] || die "new clock=$(jget helperMissingSinceMs)"

  export HEAL_NOW_MS=$((t2 + 400000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  materialize "$FIX/post-ready" "$TMP/post" "$HEAL_NOW_MS"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "new outage status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "new outage reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline after new heal=$(jget helperBaseline)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "floor not re-armed"
}

t_helper_argv_not_in_snapshot() {
  # Other processes' argv must not become exe: shell-quoted curl bearer, browser query secret.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/argv-leak.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "status=$(jget status)"
  [[ "$(jget helperCount)" == "1" ]] || die "helperCount=$(jget helperCount)"
  [[ "$(jraw helperPids)" == "[4300]" ]] || die "helperPids=$(jraw helperPids)"
  [[ "$(snap_count)" == "1" ]] || die "snapshots=$(snap_count)"
  python3 - "$(newest_snap)" "$HEAL_STATE" "$HEAL_LOG" <<'PY' || die "argv leaked"
import json, sys
snap_path, state_path, log_path = sys.argv[1:]
s = json.load(open(snap_path))
blob = json.dumps(s) + open(state_path).read() + open(log_path).read()
for needle in (
    "fixture-bearer-token", "fixture-query-secret", "Authorization", "Bearer",
    "fixture-user", "fixture-handle", "fixture-secret", "fixture-grandchild",
    "example.invalid", "user-data-dir", "seatbelt",
    "PROBESECRET8", "PROBE-SECRET-9",
):
    assert needle not in blob, needle
by_pid = {p["pid"]: p for p in s["processTree"]}
browser, curl = by_pid[4500], by_pid[4501]
assert browser["exe"] == "other" and browser["type"] == "other" and browser["subType"] is None, browser
assert curl["exe"] == "other" and curl["type"] == "other" and curl["subType"] is None, curl
quoted = by_pid[4502]
assert quoted["exe"] == "other" and quoted["type"] == "other" and quoted["subType"] is None, quoted
probe = by_pid[4510]
assert probe["exe"] == "other" and probe["subType"] is None, probe
assert 4510 not in (s.get("helperPids") or [])
gpu = by_pid[4290]
assert gpu["exe"] == "Grok Bot Helper" and gpu["type"] == "gpu-process", gpu
allowed = {"utility", "renderer", "gpu-process", "zygote", "other"}
assert all(p.get("type") in allowed for p in s["processTree"]), s["processTree"]
assert 4502 not in (s.get("helperPids") or [])
node = [p for p in s["processTree"] if p.get("subType") == "node.mojom.NodeService"]
assert len(node) == 1 and node[0]["pid"] == 4300 and node[0]["exe"] == "Grok Bot Helper", node
assert s["helperCount"] == 1
PY
}

t_snapshot_mode_0600() {
  local now dir snap custom
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  dir="$(dirname "$HEAL_STATE")"
  snap="$(newest_snap)"
  python3 - "$dir" "$snap" <<'PY' || die "default snapshot mode"
import os, stat, sys
d, f = sys.argv[1:]
assert stat.S_IMODE(os.stat(d).st_mode) == 0o700, oct(os.stat(d).st_mode)
assert stat.S_IMODE(os.stat(f).st_mode) == 0o600, oct(os.stat(f).st_mode)
PY
  custom="$TMP/custom-snaps"
  export HEAL_SNAPSHOT_DIR="$custom"
  export HEAL_NOW_MS=$((now + 960000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  python3 - "$custom" <<'PY' || die "overridden snapshot dir mode"
import glob, os, stat, sys
d = sys.argv[1]
files = glob.glob(os.path.join(d, "GrokBotLocalExecHeal-snap-*.json"))
assert files, "no snapshot in overridden dir"
assert stat.S_IMODE(os.stat(d).st_mode) == 0o700, oct(os.stat(d).st_mode)
for f in files:
    assert stat.S_IMODE(os.stat(f).st_mode) == 0o600, (f, oct(os.stat(f).st_mode))
PY
}

t_helper_none_seen() {
  # Zero NodeService helpers must not be learned, and must not relaunch by itself.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/no-nodeservice.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":0,\"helperStableSinceMs\":$((now - 700000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperCount)" == "0" ]] || die "helperCount=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned zero: $(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "None" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperNoneSeen)" == "True" ]] || die "helperNoneSeen=$(jget helperNoneSeen)"
  [[ "$(jget escalateHint)" == *"helper_none_seen"* ]] || die "hint=$(jget escalateHint)"
  grep -q "heal start" "$HEAL_LOG" && die "relaunched from helper_none_seen" || true
  [[ "$(snap_count)" == "0" ]] || die "snapshot on helper_none_seen alone"
  # A long local-ok streak already names S-NEW-D. Zero helpers must not replace that hint.
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"okStreakSinceMs\":$((now - 400000)),\"helperBaselinePid\":4242}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "long-ok status=$(jget status)"
  [[ "$(jget helperNoneSeen)" == "True" ]] || die "helperNoneSeen=$(jget helperNoneSeen)"
  [[ "$(jget escalateHint)" == *"S-NEW-D"* ]] || die "long-ok hint lost: $(jget escalateHint)"
  [[ "$(jget escalateHint)" != *"helper_none_seen"* ]] || die "none-seen overwrote long-ok: $(jget escalateHint)"
}

t_helper_ps_hook_requires_test_mode() {
  # Without HEAL_TEST_MODE the canned table is ignored, so pid 4300 cannot appear.
  # A live scan may still count zero helpers; that is not the fixture.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  unset HEAL_TEST_MODE
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
  export HELPER_PS_BIN="$FIX/helpers/ps-shim.py"
  export HELPER_LSOF_FILE="$FIX/helpers/sockets.lsof"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242}"
  run_heal
  [[ "$(jraw helperPids)" != "[4300]" ]] || die "HELPER_PS_FILE honored without HEAL_TEST_MODE"
  [[ "$(jraw helperPids)" != "[4300, 4301]" ]] || die "HELPER_PS_BIN honored without HEAL_TEST_MODE"
  [[ "$(jget helperCount)" != "1" ]] || die "fixture count used without HEAL_TEST_MODE"
  python3 - "$HEAL_STATE" "$HEAL_LOG" <<'PY' || die "lsof fixture used without HEAL_TEST_MODE"
import json, sys
state, log = sys.argv[1:]
blob = open(state).read() + open(log).read()
assert "203.0.113" not in blob and "192.0.2" not in blob
d = json.load(open(state))
assert d.get("helperSockets") in (None, {})
assert d.get("helperPids") != [4300]
PY
}

t_helper_ps_bin_production_path() {
  # The canned HELPER_PS_FILE parser is not this path. HELPER_PS_BIN answers both
  # production ps calls (comm= and command=) and is ignored unless HEAL_TEST_MODE=1.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  unset HELPER_PS_FILE
  export HELPER_PS_BIN="$FIX/helpers/ps-shim.py"
  materialize "$FIX/stale-hb" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"lastHealAtMs\":$((now - 10000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperCount)" == "2" ]] || die "helperCount=$(jget helperCount)"
  [[ "$(jraw helperPids)" == "[4300, 4301]" ]] || die "helperPids=$(jraw helperPids)"
  [[ "$(snap_count)" == "1" ]] || die "snapshots=$(snap_count)"
  grep -q "heal start" "$HEAL_LOG" && die "cooldown relaunched" || true
  python3 - "$(newest_snap)" "$HEAL_STATE" "$HEAL_LOG" <<'PY' || die "ps bin leaked or miscounted"
import json, sys
snap_path, state_path, log_path = sys.argv[1:]
s = json.load(open(snap_path))
blob = json.dumps(s) + open(state_path).read() + open(log_path).read()
for needle in (
    "fixture-bearer-token", "fixture-query-secret", "Authorization", "Bearer",
    "fixture-user", "fixture-handle", "user-data-dir", "seatbelt",
    "should-not-appear", "example.invalid", "203.0.113", "192.0.2",
    "PROBESECRET8", "PROBE-SECRET-9",
):
    assert needle not in blob, needle
by_pid = {p["pid"]: p for p in s["processTree"]}
assert s["helperCount"] == 2 and s["helperPids"] == [4300, 4301], s
assert by_pid[4242]["exe"] == "Grok Bot" and by_pid[4242]["type"] == "other", by_pid[4242]
assert by_pid[4300]["type"] == "utility" and by_pid[4300]["subType"] == "node.mojom.NodeService"
assert by_pid[4290]["exe"] == "Grok Bot Helper" and by_pid[4290]["type"] == "gpu-process", by_pid[4290]
assert by_pid[4291]["exe"] == "Grok Bot Helper (Renderer)" and by_pid[4291]["type"] == "renderer"
assert by_pid[4304]["type"] == "zygote" and 4304 not in s["helperPids"]
assert by_pid[4305]["type"] == "other" and by_pid[4305]["exe"] == "Grok Bot Helper"
assert 4305 not in s["helperPids"]
assert by_pid[4500]["exe"] == "other" and by_pid[4500]["type"] == "other"
assert by_pid[4501]["exe"] == "other" and by_pid[4501]["type"] == "other"
assert by_pid[4502]["exe"] == "other" and by_pid[4502]["type"] == "other"
assert 4502 not in s["helperPids"] and 4503 not in s["helperPids"]
assert by_pid[4503]["exe"] == "other"
probe = by_pid[4510]
assert probe["exe"] == "other" and probe["subType"] is None, probe
assert 4510 not in s["helperPids"]
allowed = {"utility", "renderer", "gpu-process", "zygote", "other"}
assert all(p.get("type") in allowed for p in s["processTree"]), s["processTree"]
PY
}

t_helper_sec_clamped_positive() {
  # 0 would mean "missing on the first tick" and "no relaunch gap". Both clamp to 1.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_MISSING_SEC=0
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 0
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "sec=0 status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "healthy" ]] || die "sec=0 reason=$(jget reason)"
  [[ "$(snap_count)" == "0" ]] || die "snapshot when missing clock is 0s"

  export HELPER_MISSING_SEC=300
  export HELPER_RELAUNCH_WINDOW_SEC=0
  export HEAL_ON_HELPER_MISSING=1
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 7200000)),\"lastHelperHealAtMs\":$now"
  run_heal
  [[ "$(jget status)" == "helper_suppressed" ]] || die "window=0 status=$(jget status) reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "window=0 action=$(jget action)"
  grep -q "heal start" "$HEAL_LOG" && die "relaunch window of 0 did not clamp" || true

  export HELPER_RELAUNCH_WINDOW_SEC=3600
  export HEAL_ON_HELPER_MISSING=0
  export HELPER_MISSING_SEC=abc
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "non-numeric missing sec status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "non-numeric reason=$(jget reason)"
}

t_helper_floor_on_other_relaunches() {
  # A short helper interval stays a floor across relaunches that are not helper_missing.
  # A relaunch while the count meets the expected level still clears it.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  stage_ps "$FIX/helpers/one-helper.ps"

  floor_kept() {
    local why="$1" want_status="$2"
    [[ "$(jget status)" == "$want_status" ]] || die "$why status=$(jget status) reason=$(jget reason)"
    [[ "$(jget action)" == "relaunch" ]] || die "$why action=$(jget action)"
    [[ "$(jget helperBaseline)" == "2" ]] || die "$why baseline=$(jget helperBaseline)"
    [[ "$(jget helperFloorPending)" == "True" ]] || die "$why floor=$(jget helperFloorPending)"
    [[ "$(jget helperMissingSinceMs)" == "None" ]] || die "$why missing clock=$(jget helperMissingSinceMs)"
  }

  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  clear_restart_ledger
  run_heal
  [[ "$(jget reason)" == "operator_request" ]] || die "operator reason=$(jget reason)"
  [[ "$(jget helperBaselinePid)" == "5151" ]] || die "operator baseline pid=$(jget helperBaselinePid)"
  floor_kept operator_request healed

  export BEACON_URL="https://beacon.invalid"
  export BEACON_MACHINE_ID="test-machine"
  export BEACON_POLL_TOKEN_FILE="$TMP/poll-token"
  printf 'fake-poll-token-for-tests\n' > "$BEACON_POLL_TOKEN_FILE"
  chmod 600 "$BEACON_POLL_TOKEN_FILE"
  export BEACON_CURL="$FIX/beacon-curl-stub.sh"
  export BEACON_STUB_CALLS="$TMP/curl-calls"
  export BEACON_STUB_RESPONSE='{"heal":true}'
  : > "$BEACON_STUB_CALLS"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  clear_restart_ledger
  run_heal
  [[ "$(jget reason)" == "beacon_request" ]] || die "beacon reason=$(jget reason)"
  [[ "$(jget helperBaselinePid)" == "5151" ]] || die "beacon baseline pid=$(jget helperBaselinePid)"
  floor_kept beacon_request healed
  unset BEACON_URL BEACON_CURL BEACON_STUB_RESPONSE

  materialize "$FIX/stale-hb" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  clear_restart_ledger
  run_heal
  [[ "$(jget reason)" == heartbeat_stale_* ]] || die "stale reason=$(jget reason)"
  [[ "$(jget helperBaselinePid)" == "5151" ]] || die "stale baseline pid=$(jget helperBaselinePid)"
  floor_kept heartbeat_stale healed

  export HEAL_TRUST_PID=0
  materialize "$FIX/dead-pid" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  clear_restart_ledger
  run_heal
  [[ "$(jget reason)" == "process_down" ]] || die "down reason=$(jget reason)"
  floor_kept process_down heal_failed
  export HEAL_TRUST_PID=1

  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 900000))}"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  clear_restart_ledger
  run_heal
  [[ "$(jget reason)" == "operator_request" ]] || die "healthy-relaunch reason=$(jget reason)"
  [[ "$(jget status)" == "healed" ]] || die "healthy-relaunch status=$(jget status)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "healthy relaunch kept baseline=$(jget helperBaseline)"
  [[ "$(jget helperFloorPending)" == "None" ]] || die "healthy relaunch floor=$(jget helperFloorPending)"
}

t_helper_baseline_sec_clamped() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  export HELPER_BASELINE_SEC=1
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 30000))}"
  run_heal
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned inside 60s floor: $(jget helperBaseline)"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperHealthySamples\":2,\"helperStableSinceMs\":$((now - 70000))}"
  run_heal
  [[ "$(jget helperBaseline)" == "2" ]] || die "70s did not learn under clamp: $(jget helperBaseline)"
  export HELPER_BASELINE_SEC=abc
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 70000))}"
  run_heal
  [[ "$(jget helperBaseline)" == "None" ]] || die "non-numeric learned early: $(jget helperBaseline)"
}

t_boot_outcome_reason_capped() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  python3 - "$GROK_SUPPORT_DIR/dune-reliability/sessions/test.running.json" <<'PY'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
j["bootOutcome"] = ("bad/path " + ("A" * 80) + " SHOULD-NOT-APPEAR-boot-tail")
json.dump(j, open(p, "w"))
PY
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"lastHealAtMs\":$((now - 10000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  local reason asig want
  reason="$(jget reason)"
  asig="$(python3 -c 'print("A"*23)')"
  want="boot_outcome_bad_path_${asig}"
  [[ "$reason" == "$want" ]] || die "reason=$reason want=$want"
  [[ "$reason" != */* && "$reason" != *' '* ]] || die "unsanitized reason=$reason"
  python3 - "$(newest_snap)" "$HEAL_STATE" "$HEAL_LOG" <<'PY' || die "boot tail leaked"
import json, sys
snap, state, log = sys.argv[1:]
blob = json.dumps(json.load(open(snap))) + open(state).read() + open(log).read()
assert "SHOULD-NOT-APPEAR-boot-tail" not in blob
assert "bad/path" not in blob
PY
}

t_boot_outcome_pub_token() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  python3 - "$GROK_SUPPORT_DIR/dune-reliability/sessions/test.running.json" <<'PY'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
j["bootOutcome"] = "bad/path here"
json.dump(j, open(p, "w"))
PY
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"lastHealAtMs\":$((now - 10000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "boot_outcome_bad_path_here" ]] || die "reason=$(jget reason)"
  [[ "$(jget bootOutcome)" == "None" ]] || die "bootOutcome=$(jget bootOutcome)"
  python3 - "$(newest_snap)" "$HEAL_STATE" "$HEAL_LOG" <<'PY' || die "boot outcome leaked"
import json, sys
snap, state, log = sys.argv[1:]
s = json.load(open(snap))
blob = json.dumps(s) + open(state).read() + open(log).read()
assert "bad/path here" not in blob
assert s.get("bootOutcome") is None, s.get("bootOutcome")
assert s.get("dune", {}).get("bootOutcome") is None, s.get("dune")
PY
}

t_snapshot_stale_reason_rate_limit() {
  # heartbeat_stale_<seconds>s changes every tick; the rate limit keys on the class.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/stale-hb" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"lastHealAtMs\":$((now - 10000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "heartbeat_stale_200s" ]] || die "reason=$(jget reason)"
  [[ "$(snap_count)" == "1" ]] || die "first snapshots=$(snap_count)"
  # Leave the heartbeat timestamp fixed so the next tick's age, and its reason text, grows.
  export HEAL_NOW_MS=$((now + 60000))
  run_heal
  [[ "$(jget reason)" == "heartbeat_stale_260s" ]] || die "second reason=$(jget reason)"
  [[ "$(jget status)" == "cooldown" ]] || die "second status=$(jget status)"
  [[ "$(snap_count)" == "1" ]] || die "stale reason was not rate-limited: $(snap_count)"
}

t_nonfinite_status_still_heals() {
  # 1e400 and NaN in status files used to abort the tick before process_down could heal.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_TRUST_PID=0
  materialize "$FIX/dead-pid" "$GROK_SUPPORT_DIR" "$now"
  python3 - "$GROK_SUPPORT_DIR" <<'PY'
import json, math, os, sys
sup = sys.argv[1]
desk = os.path.join(sup, "desktop-status.json")
sess = os.path.join(sup, "dune-reliability", "sessions", "test.running.json")
d = json.load(open(desk))
d["version"] = 1e400
d["startedAtMs"] = float("nan")
json.dump(d, open(desk, "w"))
s = json.load(open(sess))
s["pid"] = float("nan")
s["childDeaths"] = {"helper": float("nan")}
json.dump(s, open(sess, "w"))
PY
  run_heal
  [[ -s "$HEAL_STATE" ]] || die "no last.json"
  [[ "$(jget reason)" == "process_down" ]] || die "reason=$(jget reason)"
  [[ "$(jget status)" == "heal_failed" ]] || die "status=$(jget status)"
  [[ "$(jget action)" == "relaunch" ]] || die "action=$(jget action)"
  grep -q "heal start reason=process_down" "$HEAL_LOG" || die "diagnostics blocked the heal"
  python3 - "$HEAL_STATE" "$HEAL_LOG" "$(newest_snap)" <<'PY' || die "non-finite leaked"
import json, math, sys
state, log, snap = sys.argv[1:]
blob = open(state).read() + open(log).read() + open(snap).read()
for bad in ("NaN", "Infinity", "1e400", "1e+400"):
    assert bad not in blob, bad
s = json.load(open(state))
assert s.get("bootOutcome") in (None, "ready"), s.get("bootOutcome")
PY
}

t_helper_transient_high_at_launch() {
  # A first scan can catch 3 helpers mid-launch. Learn the minimum positive
  # count over the window that started on that first scan, not the high.
  # One tick at 2 does not lower the minimum. The second consecutive 2 does.
  # That second 2 is still short of HELPER_BASELINE_SEC on its own, so a
  # clock reset on the count change would not learn yet.
  local now t2 t3 t4
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/three-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget helperCount)" == "3" ]] || die "first count=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned on the first tick: $(jget helperBaseline)"
  [[ "$(jget helperStableCount)" == "3" ]] || die "min=$(jget helperStableCount)"
  [[ "$(jget helperStableSinceMs)" == "$now" ]] || die "window=$(jget helperStableSinceMs)"
  [[ "$(jget status)" == "ok" ]] || die "first status=$(jget status)"

  t2=$((now + 100000))
  export HEAL_NOW_MS="$t2"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget helperCount)" == "2" ]] || die "second count=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned before the window: $(jget helperBaseline)"
  [[ "$(jget helperStableCount)" == "3" ]] || die "one low tick moved the min: $(jget helperStableCount)"
  [[ "$(jget helperStableSinceMs)" == "$now" ]] || die "window reset on the drop: $(jget helperStableSinceMs)"

  t3=$((now + 160000))
  export HEAL_NOW_MS="$t3"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t3"
  run_heal
  [[ "$(jget helperStableCount)" == "2" ]] || die "second 2 did not lower min: $(jget helperStableCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned before the window: $(jget helperBaseline)"
  [[ "$(jget helperStableSinceMs)" == "$now" ]] || die "window reset when the min fell: $(jget helperStableSinceMs)"

  t4=$((now + 600000))
  export HEAL_NOW_MS="$t4"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t4"
  run_heal
  [[ "$(jget helperCount)" == "2" ]] || die "steady count=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "baseline=$(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperExpectedSource)" == "learned" ]] || die "src=$(jget helperExpectedSource)"
  [[ "$(jget status)" == "ok" ]] || die "learn status=$(jget status) reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  grep -q "observe reason=helper_missing" "$HEAL_LOG" && die "observed a transient high" || true
  grep -q "heal start" "$HEAL_LOG" && die "healed a transient high" || true
}

t_helper_low_count_needs_two_ticks() {
  # One low tick in the window must not lock the minimum. Two consecutive
  # healthy ticks at the lower count do.
  local now t
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget helperStableCount)" == "2" ]] || die "start min=$(jget helperStableCount)"

  t=$((now + 60000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  stage_ps "$FIX/helpers/one-helper.ps"
  t=$((now + 120000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  [[ "$(jget helperCount)" == "1" ]] || die "blip count=$(jget helperCount)"
  [[ "$(jget helperStableCount)" == "2" ]] || die "blip moved min: $(jget helperStableCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "blip learned $(jget helperBaseline)"

  stage_ps "$FIX/helpers/two-helpers.ps"
  t=$((now + 180000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  t=$((now + 600000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  [[ "$(jget helperBaseline)" == "2" ]] || die "blip baseline=$(jget helperBaseline)"
  [[ "$(jget status)" == "ok" ]] || die "blip status=$(jget status) reason=$(jget reason)"
  grep -q "observe reason=helper_missing" "$HEAL_LOG" && die "observed a one-tick blip" || true

  rm -f "$HEAL_STATE"
  : > "$HEAL_LOG"
  export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  t=$((now + 60000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  stage_ps "$FIX/helpers/one-helper.ps"
  t=$((now + 120000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  [[ "$(jget helperStableCount)" == "2" ]] || die "first 1 moved min: $(jget helperStableCount)"
  t=$((now + 180000))
  export HEAL_NOW_MS="$t"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t"
  run_heal
  [[ "$(jget helperCount)" == "1" ]] || die "second 1 count=$(jget helperCount)"
  [[ "$(jget helperStableCount)" == "1" ]] || die "two 1s did not count: $(jget helperStableCount)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned inside the short window: $(jget helperBaseline)"
}

t_helper_learn_needs_three_samples() {
  # Two healthy samples across a sleep gap are not enough, even past 600s.
  local now t2 t3
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget helperHealthySamples)" == "1" ]] || die "samples=$(jget helperHealthySamples)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned on sample 1"

  t2=$((now + 700000))
  export HEAL_NOW_MS="$t2"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget helperHealthySamples)" == "2" ]] || die "samples=$(jget helperHealthySamples)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "two samples across a gap learned $(jget helperBaseline)"

  t3=$((t2 + 60000))
  export HEAL_NOW_MS="$t3"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t3"
  run_heal
  [[ "$(jget helperHealthySamples)" == "3" ]] || die "samples=$(jget helperHealthySamples)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "third sample baseline=$(jget helperBaseline)"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
}

t_helper_learn_skips_low_completing_tick() {
  # The tick that finishes the window is a single 1 while the running min is 2.
  # Do not learn 2 on that tick. The next healthy 2 still can.
  local now t2
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperCount\":2,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000)),\"helperHealthySamples\":2}"
  run_heal
  [[ "$(jget helperCount)" == "1" ]] || die "count=$(jget helperCount)"
  [[ "$(jget helperStableCount)" == "2" ]] || die "min=$(jget helperStableCount)"
  [[ "$(jget helperHealthySamples)" == "3" ]] || die "samples=$(jget helperHealthySamples)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned on a low completing tick: $(jget helperBaseline)"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  grep -q "observe reason=helper_missing" "$HEAL_LOG" && die "observed the completing dip" || true

  t2=$((now + 60000))
  export HEAL_NOW_MS="$t2"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget helperCount)" == "2" ]] || die "recovered count=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "recovered baseline=$(jget helperBaseline)"
  [[ "$(jget helperBaselineLow)" == "False" ]] || die "low flag on baseline 2: $(jget helperBaselineLow)"
  [[ "$(jget status)" == "ok" ]] || die "recovered status=$(jget status) reason=$(jget reason)"
}

t_helper_baseline_low_hint() {
  # A learned 1 with HELPER_EXPECTED unset is visible. It does not relaunch,
  # and it does not replace the long-ok hint. Setting HELPER_EXPECTED clears the flag.
  local now t2
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperCount\":1,\"helperBaselinePid\":4242,\"helperStableCount\":1,\"helperStableSinceMs\":$((now - 700000)),\"helperHealthySamples\":2}"
  run_heal
  [[ "$(jget helperBaseline)" == "1" ]] || die "baseline=$(jget helperBaseline)"
  [[ "$(jget helperBaselineLow)" == "True" ]] || die "flag=$(jget helperBaselineLow)"
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status) reason=$(jget reason)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget escalateHint)" == *"HELPER_EXPECTED=2"* ]] || die "hint=$(jget escalateHint)"
  grep -q "helper_baseline_low:" "$HEAL_LOG" || die "low baseline not logged"
  grep -q "heal start" "$HEAL_LOG" && die "low baseline relaunched" || true

  t2=$((now + 400000))
  export HEAL_NOW_MS="$t2"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget helperBaselineLow)" == "True" ]] || die "flag dropped on the long-ok tick: $(jget helperBaselineLow)"
  [[ "$(jget escalateHint)" == *"S-NEW-D"* ]] || die "long-ok hint lost: $(jget escalateHint)"
  [[ "$(jget escalateHint)" != *"helper_baseline_low"* ]] || die "low hint replaced long-ok: $(jget escalateHint)"
  [[ "$(jget status)" == "ok" ]] || die "long-ok status=$(jget status) reason=$(jget reason)"
  grep -q "heal start" "$HEAL_LOG" && die "long-ok low baseline relaunched" || true

  export HELPER_EXPECTED=2
  export HEAL_NOW_MS=$((t2 + 60000))
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  : > "$HEAL_LOG"
  run_heal
  [[ "$(jget helperBaseline)" == "1" ]] || die "config changed baseline=$(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget helperBaselineLow)" == "False" ]] || die "flag stayed with HELPER_EXPECTED: $(jget helperBaselineLow)"
  [[ "$(jget status)" == "ok" ]] || die "config status=$(jget status) reason=$(jget reason)"
  grep -q "helper_baseline_low:" "$HEAL_LOG" && die "logged the low flag while HELPER_EXPECTED is set" || true
}

t_helper_expected_mitigates_late_drop() {
  # A late second helper does not raise a learned 1, even after hours.
  # HELPER_EXPECTED=2 is the mitigation: a later drop to 1 observes.
  local now t1 t2 t3
  now="$(now_ms)"; export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":1,\"helperStableSinceMs\":$((now - 700000)),\"helperHealthySamples\":2}"
  run_heal
  [[ "$(jget helperBaseline)" == "1" ]] || die "did not learn 1: $(jget helperBaseline)"
  [[ "$(jget status)" == "ok" ]] || die "learn status=$(jget status)"

  t1=$((now + 14400000))
  export HEAL_NOW_MS="$t1"
  stage_ps "$FIX/helpers/two-helpers.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t1"
  run_heal
  [[ "$(jget helperCount)" == "2" ]] || die "pair count=$(jget helperCount)"
  [[ "$(jget helperBaseline)" == "1" ]] || die "late pair raised baseline: $(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "1" ]] || die "expected=$(jget helperExpected)"
  [[ "$(jget status)" == "ok" ]] || die "pair status=$(jget status) reason=$(jget reason)"

  export HELPER_EXPECTED=2
  t2=$((t1 + 60000))
  export HEAL_NOW_MS="$t2"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t2"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "drop grace status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "1" ]] || die "baseline changed on the drop: $(jget helperBaseline)"
  [[ "$(jget helperExpected)" == "2" ]] || die "grace expected=$(jget helperExpected)"
  [[ "$(jget helperCount)" == "1" ]] || die "grace count=$(jget helperCount)"
  t3=$((t2 + 400000))
  export HEAL_NOW_MS="$t3"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$t3"
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "2 to 1 status=$(jget status) reason=$(jget reason)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "2 to 1 reason=$(jget reason)"
  [[ "$(jget helperExpected)" == "2" ]] || die "2 to 1 expected=$(jget helperExpected)"
  [[ "$(jget helperCount)" == "1" ]] || die "2 to 1 count=$(jget helperCount)"
  grep -q "heal start" "$HEAL_LOG" && die "log-only healed the late drop" || true
}

t_bash32_command_subst_heredoc_no_apostrophe() {
  # bash 3.2 scans for quotes inside a quoted heredoc when that heredoc sits
  # in $(...). One apostrophe in a comment makes the LaunchAgent fail to parse.
  # Balanced quotes in python -c are a different form and are not flagged.
  python3 - "$ROOT/grok-bot-local-exec-heal.sh" "$ROOT/install.sh" <<'PY' || die "apostrophe in command-subst heredoc"
import sys

def command_subst_heredoc_bodies(text):
    i = 0
    n = len(text)
    depth = 0
    arith = 0
    in_sq = False
    in_dq = False
    stack = []
    found = []
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        nxt2 = text[i + 2] if i + 2 < n else ""
        if in_sq:
            if c == "'":
                in_sq = False
            i += 1
            continue
        if in_dq:
            if c == "\\" and nxt:
                i += 2
                continue
            if c == '"':
                in_dq = False
            elif c == "$" and nxt == "(":
                if nxt2 == "(":
                    arith += 1
                    i += 3
                else:
                    stack.append((in_sq, in_dq, arith))
                    in_sq = False
                    in_dq = False
                    arith = 0
                    depth += 1
                    i += 2
                continue
            i += 1
            continue
        if c == "\\" and nxt:
            i += 2
            continue
        if c == "'":
            in_sq = True
            i += 1
            continue
        if c == '"':
            in_dq = True
            i += 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;{}()|&"):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if c == "$" and nxt == "(":
            if nxt2 == "(":
                arith += 1
                i += 3
                continue
            stack.append((in_sq, in_dq, arith))
            in_sq = False
            in_dq = False
            arith = 0
            depth += 1
            i += 2
            continue
        if c == ")" and arith > 0 and nxt == ")":
            arith -= 1
            i += 2
            continue
        if c == ")" and depth > 0:
            depth -= 1
            if stack:
                in_sq, in_dq, arith = stack.pop()
            i += 1
            continue
        if c == "<" and nxt == "<" and depth > 0:
            j = i + 2
            if j < n and text[j] == "-":
                j += 1
            delim = ""
            if j < n and text[j] in ("'", '"'):
                q = text[j]
                k = text.find(q, j + 1)
                if k < 0:
                    i += 1
                    continue
                delim = text[j + 1:k]
                j = k + 1
            else:
                k = j
                while k < n and (text[k].isalnum() or text[k] == "_"):
                    k += 1
                delim = text[j:k]
                j = k
            if delim:
                nl = text.find("\n", j)
                if nl < 0:
                    i = n
                    continue
                start = nl + 1
                rest = text[start:]
                body_lines = []
                pos = 0
                for line in rest.splitlines(True):
                    if line.rstrip("\r\n") == delim:
                        break
                    body_lines.append(line)
                    pos += len(line)
                body = "".join(body_lines)
                line_no = text.count("\n", 0, start) + 1
                found.append((line_no, body))
                i = start + pos
                continue
            i = j
            continue
        i += 1
    return found

bad = []
seen = 0
for path in sys.argv[1:]:
    text = open(path).read()
    bodies = command_subst_heredoc_bodies(text)
    seen += len(bodies)
    for line_no, body in bodies:
        for offset, line in enumerate(body.splitlines()):
            if "'" in line:
                bad.append("%s:%d: %s" % (path, line_no + offset, line.strip()[:160]))
if seen < 1:
    sys.stderr.write("no command-substitution heredoc found\n")
    sys.exit(1)
if bad:
    sys.stderr.write("apostrophe inside $(...) heredoc:\n" + "\n".join(bad) + "\n")
    sys.exit(1)
PY
  local bash32="${BASH32:-}"
  if [[ -z "$bash32" && -x /bin/bash ]]; then
    local bmaj
    bmaj="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
    if [[ "$bmaj" == "3" ]]; then
      bash32=/bin/bash
    fi
  fi
  if [[ -z "$bash32" && -x /tmp/bash-3.2-cache/bin/bash ]]; then
    bash32=/tmp/bash-3.2-cache/bin/bash
  fi
  if [[ -n "$bash32" && -x "$bash32" ]]; then
    "$bash32" -n "$ROOT/grok-bot-local-exec-heal.sh" || die "bash 3.2 -n heal"
    "$bash32" -n "$ROOT/install.sh" || die "bash 3.2 -n install"
    "$bash32" -n "$ROOT/tests/run-tests.sh" || die "bash 3.2 -n tests"
  else
    echo "NOTICE: bash 3.2 not found (set BASH32); skipped bash -n under bash 3.2"
  fi
}

t_skipped_scan_keeps_baseline() {
  # .disable and app_missing return before the scan. A mktemp failure still runs
  # the in-memory scan (so the decision can be healthy) but must not replace the
  # stored helper fields. The process has to be up: a process_down tick relaunches
  # and the existing floor path restarts the missing clock on purpose.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  local missing=$((now - 400000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaseline\":2,\"helperBaselinePid\":4242,\"helperStableCount\":1,\"helperStableSinceMs\":$missing,\"helperMissingSinceMs\":$missing,\"helperFloorPending\":true}"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.disable"
  run_heal
  [[ "$(jget status)" == "disabled" ]] || die "disable status=$(jget status)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "disable wiped baseline=$(jget helperBaseline)"
  [[ "$(jget helperMissingSinceMs)" == "$missing" ]] || die "disable wiped clock=$(jget helperMissingSinceMs)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "disable wiped floor=$(jget helperFloorPending)"
  grep -q "heal start" "$HEAL_LOG" && die "disabled tick relaunched" || true
  rm -f "$LATCH_DIR/grok-bot-local-exec-heal.disable"

  local notdir="$TMP/not-a-tmpdir"
  : > "$notdir"
  TMPDIR="$notdir" run_heal
  grep -q "mktemp failed" "$HEAL_LOG" || die "no mktemp warning"
  [[ "$(jget status)" == "ok" ]] || die "mktemp status=$(jget status) reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "mktemp wiped baseline=$(jget helperBaseline)"
  [[ "$(jget helperMissingSinceMs)" == "$missing" ]] || die "mktemp wiped clock=$(jget helperMissingSinceMs)"
  [[ "$(jget helperFloorPending)" == "True" ]] || die "mktemp wiped floor=$(jget helperFloorPending)"
  [[ "$(jget helperCount)" == "None" ]] || die "mktemp recorded count=$(jget helperCount)"
  grep -q "heal start" "$HEAL_LOG" && die "mktemp tick relaunched" || true
  unset TMPDIR

  rm -rf "$GROK_APP_PATH"
  run_heal
  [[ "$(jget status)" == "error" ]] || die "app_missing status=$(jget status)"
  [[ "$(jget reason)" == "app_missing" ]] || die "app_missing reason=$(jget reason)"
  [[ "$(jget helperBaseline)" == "2" ]] || die "app_missing wiped baseline=$(jget helperBaseline)"
  [[ "$(jget helperMissingSinceMs)" == "$missing" ]] || die "app_missing wiped clock=$(jget helperMissingSinceMs)"
}

echo "kit $(cat "$ROOT/VERSION")  heal=$HEAL"
t_install_env_check() {
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]
want = dict(kv.split("=", 1) for kv in sys.argv[2].split(";") if kv)
for k, v in want.items():
    assert env.get(k) == v, (k, env.get(k))
PY
}

t_install_preserves_beacon_env() {
  local home="$TMP/home"; local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home/Library/LaunchAgents"
  python3 - "$pl" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "x", "EnvironmentVariables": {
    "BEACON_URL": "https://example.invalid", "BEACON_POLL_TOKEN_FILE": "/nonexistent/tok",
    "BEACON_MACHINE_ID": "fixture-machine", "MY_CUSTOM": "1", "COOLDOWN_SEC": "999",
    "HEAL_CURSOR": "1", "HEAL_TEST_MODE": "1", "PATH": "/opt/custom/bin:/usr/bin:/bin"}},
    open(sys.argv[1], "wb"))
PY
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "install failed"
  # Operator tunables + BEACON_* + custom survive; kit-owned PATH comes from template; missing STUCK_SEC from template.
  t_install_env_check "$pl" "BEACON_URL=https://example.invalid;BEACON_POLL_TOKEN_FILE=/nonexistent/tok;BEACON_MACHINE_ID=fixture-machine;MY_CUSTOM=1;COOLDOWN_SEC=999;HEAL_CURSOR=1;STUCK_SEC=120;PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    || die "env not preserved or template key lost"
  python3 - "$pl" <<'PY' || die "HEAL_TEST_MODE preserved"
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]
assert "HEAL_TEST_MODE" not in env, env.get("HEAL_TEST_MODE")
PY
  python3 - "$pl" "$home" <<'PY' || die "ProgramArguments not updated from template"
import plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
home = sys.argv[2]
args = pl.get("ProgramArguments") or []
want = f"{home}/Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh"
assert args == ["/bin/bash", want], args
assert pl.get("Label") == "com.latch.grok-bot-local-exec-heal", pl.get("Label")
PY
  # idempotent on a second run
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "reinstall failed"
  t_install_env_check "$pl" "BEACON_URL=https://example.invalid;MY_CUSTOM=1;COOLDOWN_SEC=999;HEAL_CURSOR=1" || die "second run lost env"
}

t_install_reset_env() {
  local home="$TMP/home-reset"; local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home/Library/LaunchAgents"
  python3 - "$pl" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "x", "EnvironmentVariables": {
    "BEACON_URL": "https://wipe.example.invalid", "COOLDOWN_SEC": "999", "HEAL_CURSOR": "1"}},
    open(sys.argv[1], "wb"))
PY
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 INSTALL_RESET_ENV=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "reset install failed"
  python3 - "$pl" <<'PY' || die "INSTALL_RESET_ENV did not wipe operator env"
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]
assert "BEACON_URL" not in env, env
assert env.get("COOLDOWN_SEC") == "300", env.get("COOLDOWN_SEC")
assert env.get("HEAL_CURSOR") == "0", env.get("HEAL_CURSOR")
PY
}

t_install_merge_fail_aborts() {
  local home="$TMP/home-merge-fail"; local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home/Library/LaunchAgents"
  python3 - "$pl" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "keep-me", "EnvironmentVariables": {
    "BEACON_URL": "https://keep.example.invalid", "BEACON_MACHINE_ID": "keep-machine",
    "MY_CUSTOM": "stay"}}, open(sys.argv[1], "wb"))
PY
  if HOME="$home" INSTALL_SKIP_LAUNCHD=1 INSTALL_TEST_MERGE_FAIL=1 bash "$ROOT/install.sh" >/dev/null 2>&1; then
    die "merge-fail install should have exited non-zero"
  fi
  t_install_env_check "$pl" "BEACON_URL=https://keep.example.invalid;BEACON_MACHINE_ID=keep-machine;MY_CUSTOM=stay" \
    || die "merge fail wiped BEACON env"
  python3 - "$pl" <<'PY' || die "merge fail replaced plist"
import plistlib, sys
pl = plistlib.load(open(sys.argv[1], "rb"))
assert pl.get("Label") == "keep-me", pl.get("Label")
assert "STUCK_SEC" not in (pl.get("EnvironmentVariables") or {}), "template leaked after failed merge"
PY
}

t_install_fresh() {
  local home="$TMP/home2"; local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home"
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "fresh install failed"
  t_install_env_check "$pl" "COOLDOWN_SEC=300;CODEX_REOPEN_POLICY=crash_only" || die "fresh plist wrong"
  [[ -f "$home/Library/Application Support/Latch/bin/grok-bot-restart-guard.py" ]] || die "guard not installed"
  [[ -f "$home/Library/Application Support/Latch/bin/codex-watch.py" ]] || die "codex watch not installed"
}

t_install_post_tick_drops_test_hooks() {
  # Full installer flow uses temporary HOME and a fake launchctl. Nothing is
  # registered with real launchd; an unexpected app command fails this case.
  local home="$TMP/no-second-tick-home"
  local shims="$TMP/install-shims"
  mkdir -p "$home" "$shims"
  export INSTALL_CALL_LOG="$TMP/install-calls"
  cat > "$shims/launchctl" <<'EOFSTUB'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$INSTALL_CALL_LOG"
[ "$1" = print ] && exit 1
exit 0
EOFSTUB
  printf '#!/bin/sh\nexit 0\n' > "$shims/sleep"
  local name
  for name in open osascript pkill; do
    cat > "$shims/$name" <<'EOFSTUB'
#!/bin/sh
printf 'unexpected-app-command\n' >> "$INSTALL_CALL_LOG"
exit 1
EOFSTUB
  done
  chmod +x "$shims/launchctl" "$shims/sleep" "$shims/open" "$shims/osascript" "$shims/pkill"
  mkdir -p "$home/Library/Application Support/Latch"
  touch "$home/Library/Application Support/Latch/grok-bot-restart.hold"
  HOME="$home" PATH="$shims:$PATH" INSTALL_MAINTENANCE_CONFIRMED=1 INSTALL_SKIP_LAUNCHD=0 INSTALL_RECOVERY_MODE=active INSTALL_HELPER_HEAL=1 bash "$ROOT/install.sh" > "$TMP/install-output" 2>&1 || die "stubbed installer failed"
  [[ -s "$INSTALL_CALL_LOG" ]] || die "launchctl stub not called"
  grep -q 'bootstrap' "$INSTALL_CALL_LOG" || die "no registration attempt"
  grep -q 'kickstart\|launchctl enable\|unexpected-app-command' "$INSTALL_CALL_LOG" && die "extra tick or app operation" || true
  [[ ! -e "$home/Library/Application Support/Latch/grok-bot-observation-clock.json" ]] || die "installer sampled continuity directly"
  [[ ! -e "$home/Library/Logs/GrokBotLocalExecHeal-last.json" ]] || die "installer executed an extra tick"
  grep -q 'RunAtLoad owns' "$TMP/install-output" || die "initial observation ownership unclear"
}

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
run_case T-kit-version-matches t_kit_version_matches
run_case T-beacon-heal t_beacon_heal
run_case T-beacon-false-noop t_beacon_false_noop
run_case T-beacon-bad-response-noop t_beacon_bad_response_noop
run_case T-beacon-worker-down-noop t_beacon_worker_down_noop
run_case T-beacon-unconfigured-no-poll t_beacon_unconfigured_no_poll
run_case T-beacon-bypasses-cooldown t_beacon_bypasses_cooldown
run_case T-beacon-disabled-stays-queued t_beacon_disabled_no_poll_stays_queued
run_case T-beacon-second-request-escalates t_beacon_second_request_escalates
run_case T-beacon-operator-request-wins t_beacon_operator_request_wins
run_case T-beacon-skip-poll-local-cooldown t_beacon_skip_poll_when_local_heal_cooldown
run_case T-beacon-token-world-readable t_beacon_token_world_readable_refuses
run_case T-beacon-token-group-readable t_beacon_token_group_readable_refuses
run_case T-beacon-token-0400-polls t_beacon_token_0400_polls
run_case T-beacon-token-0600-polls t_beacon_token_0600_polls
run_case T-beacon-token-perms-unknown-refuses t_beacon_token_perms_unknown_refuses
run_case T-beacon-token-junk-stat-python-fallback t_beacon_token_junk_stat_python_fallback_polls
run_case T-beacon-token-probe-gnu-stat t_beacon_token_probe_gnu_stat_polls
run_case T-beacon-token-probe-bsd-stat t_beacon_token_probe_bsd_stat
run_case T-token-file-mode-real-modes t_token_file_mode_real_modes
run_case T-beacon-token-never-in-argv t_beacon_token_never_in_argv
run_case T-beacon-token-quote-refuses t_beacon_token_quote_refuses
run_case T-beacon-http-url-refuses t_beacon_http_url_refuses
run_case T-beacon-curl-proto-https-only t_beacon_curl_proto_https_only
run_case T-install-preserves-beacon-env t_install_preserves_beacon_env
run_case T-install-fresh t_install_fresh
run_case T-install-merge-fail-aborts t_install_merge_fail_aborts
run_case T-install-reset-env t_install_reset_env

run_case T-helper-fields-healthy t_helper_fields_healthy
run_case T-helper-learn-baseline t_helper_learn_baseline
run_case T-helper-learn-needs-stable-window t_helper_learn_needs_stable_window
run_case T-helper-learn-not-while-unhealthy t_helper_learn_not_while_unhealthy
run_case T-helper-baseline-never-lowers t_helper_baseline_never_lowers
run_case T-helper-baseline-never-rises t_helper_baseline_never_rises
run_case T-helper-transient-high-at-launch t_helper_transient_high_at_launch
run_case T-helper-low-count-needs-two-ticks t_helper_low_count_needs_two_ticks
run_case T-helper-learn-needs-three-samples t_helper_learn_needs_three_samples
run_case T-helper-learn-skips-low-completing-tick t_helper_learn_skips_low_completing_tick
run_case T-helper-baseline-low-hint t_helper_baseline_low_hint
run_case T-helper-expected-mitigates-late-drop t_helper_expected_mitigates_late_drop
run_case T-bash32-command-subst-heredoc-no-apostrophe t_bash32_command_subst_heredoc_no_apostrophe
run_case T-nonfinite-status-still-heals t_nonfinite_status_still_heals
run_case T-skipped-scan-keeps-baseline t_skipped_scan_keeps_baseline
run_case T-helper-under-threshold t_helper_under_threshold
run_case T-helper-missing-log-only t_helper_missing_log_only
run_case T-helper-missing-relaunch t_helper_missing_relaunch
run_case T-helper-missing-cooldown t_helper_missing_cooldown
run_case T-helper-one-relaunch-per-window t_helper_one_relaunch_per_window
run_case T-helper-operator-request-wins t_helper_operator_request_wins
run_case T-helper-log-only-beacon-still-heals t_helper_log_only_beacon_still_heals
run_case T-helper-disable-wins t_helper_disable_wins
run_case T-helper-expected-override t_helper_expected_override
run_case T-helper-pid-change-resets t_helper_pid_change_resets
run_case T-helper-config-expected-pid-change-keeps-floor t_helper_config_expected_pid_change_keeps_floor
run_case T-helper-pid-change-healthy-resets t_helper_pid_change_healthy_resets
run_case T-helper-floor-met-allows-new-outage t_helper_floor_met_allows_new_outage
run_case T-helper-dip-recovers-within-grace t_helper_dip_recovers_within_grace
run_case T-helper-argv-not-in-snapshot t_helper_argv_not_in_snapshot
run_case T-snapshot-mode-0600 t_snapshot_mode_0600
run_case T-helper-none-seen t_helper_none_seen
run_case T-helper-ps-hook-requires-test-mode t_helper_ps_hook_requires_test_mode
run_case T-helper-ps-bin-production-path t_helper_ps_bin_production_path
run_case T-helper-sec-clamped-positive t_helper_sec_clamped_positive
run_case T-helper-floor-on-other-relaunches t_helper_floor_on_other_relaunches
run_case T-helper-baseline-sec-clamped t_helper_baseline_sec_clamped
run_case T-boot-outcome-reason-capped t_boot_outcome_reason_capped
run_case T-boot-outcome-pub-token t_boot_outcome_pub_token
run_case T-snapshot-stale-reason-rate-limit t_snapshot_stale_reason_rate_limit
run_case T-helper-check-off t_helper_check_off
run_case T-helper-ps-unreadable-no-signal t_helper_ps_unreadable_no_signal
run_case T-helper-sockets-counts-no-addresses t_helper_sockets_counts_no_addresses
run_case T-snapshot-rate-limited-and-pruned t_snapshot_rate_limited_and_pruned
run_case T-snapshot-backoff-resets-on-ok t_snapshot_backoff_resets_on_ok
run_case T-install-template-helper-defaults t_install_template_helper_defaults
run_case T-install-helper-missing-opt-in-survives t_install_helper_missing_opt_in_survives
run_case T-install-preserves-helper-env t_install_preserves_helper_env
run_case T-install-no-second-tick t_install_post_tick_drops_test_hooks
run_case T-oct7-helper-drop-replay t_oct7_helper_drop_replay

cget() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])).get("codex") or {}
v=d.get(sys.argv[2], None)
print("None" if v is None else v)' "$HEAL_STATE" "$1"
}

codex_on() {
  export CODEX_WATCH=1
  export CODEX_APP_PATH="$TMP/ChatGPT.app"
  mkdir -p "$CODEX_APP_PATH/Contents/MacOS"
  export CODEX_CRASH_DIR="$TMP/codex-crashes"
  mkdir -p "$CODEX_CRASH_DIR"
  export CODEX_OPEN_LOG="$TMP/codex-open.log"
  export CODEX_OPEN_BIN="$TMP/codex-open"
  cat > "$CODEX_OPEN_BIN" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CODEX_OPEN_LOG"
exit 0
EOF
  chmod +x "$CODEX_OPEN_BIN"
  : > "$CODEX_OPEN_LOG"
}

write_codex_ps() {
  local dest="$1"
  shift
  python3 - "$dest" "$@" <<'PY'
import sys
dest = sys.argv[1]
lines = []
for row in sys.argv[2:]:
    pid, ppid, comm, exe = row.split("|", 3)
    lines.append("%s %s 00:01 %s\t%s\n" % (pid, ppid, comm, exe))
open(dest, "w").write("".join(lines))
PY
  export CODEX_PS_FILE="$dest"
}

codex_decoys() {
  local exe="$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  write_codex_ps "$1" \
    "9100|1|Codex (Service)|$CODEX_APP_PATH/Contents/Frameworks/Codex (Service)" \
    "9101|1|Codex (Renderer)|$CODEX_APP_PATH/Contents/Frameworks/Codex (Renderer)" \
    "9102|1|codex|/usr/local/bin/codex" \
    "9103|1|node|/usr/local/bin/node" \
    "9104|1|ChatGPT Classic|/Applications/ChatGPT Classic.app/Contents/MacOS/ChatGPT Classic" \
    "9105|1|ChatGPT|$TMP/ChatGPT.localized/Contents/MacOS/ChatGPT"
}

write_codex_crash() {
  python3 - "$1" <<'PY'
import json, sys
json.dump({
    "app_name": "ChatGPT",
    "bug_type": "309",
    "timestamp": "2026-01-01T00:00:00+00:00",
    "bundleID": "com.openai.codex",
    "procName": "ChatGPT",
}, open(sys.argv[1], "w"))
PY
}

seed_attempts() {
  python3 - "$LATCH_DIR/grok-bot-restart-attempts.json" "$1" <<'PY'
import json, os, sys, time
path, kind = sys.argv[1], sys.argv[2]
now = time.time()
if kind == "one":
    values = [now - 10]
elif kind == "three":
    values = [now - 30, now - 20, now - 10]
else:
    values = []
json.dump({"v": 2, "attempts": {"grok": values}}, open(path, "w"))
os.chmod(path, 0o600)
PY
}

t_guard_helper_loss_allow() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason=$(jget reason)"
  grep -q "restart guard allow key=grok reason=helper_missing" "$HEAL_LOG" || die "guard did not allow"
  python3 - "$HEAL_LOG" <<'PY' || die "guard allow not before heal start"
import sys
text = open(sys.argv[1]).read()
a = text.find("restart guard allow")
b = text.find("heal start")
assert a != -1 and b != -1 and a < b, (a, b)
PY
  python3 - "$LATCH_DIR/grok-bot-restart-attempts.json" <<'PY' || die "ledger"
import json, os, stat, sys
path = sys.argv[1]
mode = stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
data = json.load(open(path))
assert len(data["attempts"]["grok"]) == 1, data
PY
}

t_guard_backoff() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  seed_attempts one
  run_heal
  [[ "$(jget status)" == "restart_blocked" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "retry_backoff" ]] || die "readiness=$(jget readiness)"
  [[ "$(jget restartGuardResult)" == "retry_backoff" ]] || die "ledger block not visible"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  grep -q "heal start" "$HEAL_LOG" && die "backoff relaunched" || true
}

t_guard_circuit_open() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  seed_attempts three
  run_heal
  [[ "$(jget status)" == "restart_blocked" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "circuit_open" ]] || die "readiness=$(jget readiness)"
  grep -q "heal start" "$HEAL_LOG" && die "circuit relaunched" || true
}

t_guard_hold_wins() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  touch "$LATCH_DIR/grok-bot-restart.hold"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "restart_blocked" ]] || die "process status=$(jget status)"
  [[ "$(jget readiness)" == "maintenance_hold" ]] || die "process readiness=$(jget readiness)"
  [[ "$(jget reason)" == "boot_outcome_starting" ]] || die "process reason=$(jget reason)"
  grep -q "heal start" "$HEAL_LOG" && die "hold relaunched" || true

  : > "$HEAL_LOG"
  rm -f "$HEAL_STATE"
  beacon_env
  export HEAL_NOW_MS="$now"
  touch "$LATCH_DIR/grok-bot-restart.hold"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "held healthy status=$(jget status)"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "hold consumed a beacon request"
  grep -q "heal start" "$HEAL_LOG" && die "hold beacon relaunched" || true

  : > "$HEAL_LOG"
  rm -f "$HEAL_STATE" "$BEACON_URL"
  unset BEACON_URL BEACON_MACHINE_ID BEACON_POLL_TOKEN_FILE || true
  export HEAL_ON_HELPER_MISSING=1
  export HEAL_NOW_MS="$now"
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  touch "$LATCH_DIR/grok-bot-restart.hold"
  run_heal
  [[ "$(jget status)" == "restart_blocked" ]] || die "helper status=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "helper reason=$(jget reason)"
  [[ "$(jget readiness)" == "maintenance_hold" ]] || die "helper readiness=$(jget readiness)"
  grep -q "heal start" "$HEAL_LOG" && die "hold helper relaunched" || true

  : > "$HEAL_LOG"
  rm -f "$HEAL_STATE"
  export HEAL_ON_HELPER_MISSING=0
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  export CODEX_REOPEN_POLICY=any_exit
  codex_decoys "$TMP/codex-down.ps"
  touch "$LATCH_DIR/grok-bot-restart.hold"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "codex-hold grok status=$(jget status)"
  [[ "$(cget status)" == "maintenance_hold" ]] || die "codex readiness=$(cget status)"
  [[ "$(cget action)" == "none" ]] || die "codex action=$(cget action)"
  [[ ! -s "$CODEX_OPEN_LOG" ]] || die "codex opened under hold"
  grep -q "codex reopen start" "$HEAL_LOG" && die "codex reopen started under hold" || true
  grep -q "heal start" "$HEAL_LOG" && die "grok relaunched under hold" || true
}

t_guard_disable_wins() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.disable"
  codex_on
  export CODEX_REOPEN_POLICY=any_exit
  codex_decoys "$TMP/codex-down.ps"
  run_heal
  [[ "$(jget status)" == "disabled" ]] || die "status=$(jget status)"
  [[ "$(cget status)" == "disabled" ]] || die "codex status=$(cget status)"
  [[ -f "$LATCH_DIR/grok-bot-local-exec-heal.request" ]] || die "disable consumed request"
  [[ ! -s "$CODEX_OPEN_LOG" ]] || die "codex opened while disabled"
  grep -q "heal start" "$HEAL_LOG" && die "disabled relaunched" || true
  grep -q "codex reopen start" "$HEAL_LOG" && die "codex reopen while disabled" || true
}

t_guard_idle_opt_in() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  export HELPER_IDLE_REQUIRED=1
  stage_ps "$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jget status)" == "restart_blocked" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "idle_authorization_required" ]] || die "readiness=$(jget readiness)"
  grep -q "heal start" "$HEAL_LOG" && die "idle gate relaunched" || true
  python3 - "$LATCH_DIR/grok-bot-restart-idle.json" <<'PY'
import json, os, sys, time
path = sys.argv[1]
now = time.time()
json.dump({"issuedAt": now - 1, "expiresAt": now + 60, "pid": 4242, "idleConfirmed": True}, open(path, "w"))
os.chmod(path, 0o600)
PY
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  : > "$HEAL_LOG"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "leased status=$(jget status) readiness=$(jget readiness)"
  [[ ! -f "$LATCH_DIR/grok-bot-restart-idle.json" ]] || die "lease was not consumed"
  grep -q "heal start reason=helper_missing" "$HEAL_LOG" || die "leased heal did not start"
}

t_guard_missing_fails_closed() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  rm -f "$LATCH_DIR/bin/grok-bot-restart-guard.py"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "restart_blocked" ]] || die "status=$(jget status)"
  [[ "$(jget readiness)" == "restart_guard_missing" ]] || die "readiness=$(jget readiness)"
  grep -q "heal start" "$HEAL_LOG" && die "missing guard relaunched" || true
}

t_codex_down_reopen() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"codex\":{\"pid\":9000,\"launchedAtMs\":1000,\"running\":true}}"
  codex_decoys "$TMP/codex-down.ps"
  write_codex_crash "$CODEX_CRASH_DIR/ChatGPT.ips"
  write_codex_ps "$TMP/codex-up.ps" "9000|1|ChatGPT|$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  export CODEX_PS_AFTER_FILE="$TMP/codex-up.ps"
  export CODEX_PS_FILE="$TMP/codex-down.ps"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "grok status=$(jget status) reason=$(jget reason)"
  [[ "$(cget status)" == "reopened" ]] || die "codex status=$(cget status) readiness=$(cget readiness)"
  [[ "$(cget action)" == "reopen" ]] || die "codex action=$(cget action)"
  [[ "$(cget pid)" == "9000" ]] || die "codex pid=$(cget pid)"
  grep -q "codex reopen done" "$HEAL_LOG" || die "reopen did not finish"
  grep -q "dry-run: skip codex open" "$HEAL_LOG" || die "dry-run did not skip open"
  grep -q "heal start" "$HEAL_LOG" && die "healthy grok relaunched" || true
  python3 - "$LATCH_DIR/grok-bot-restart-attempts.json" <<'PY' || die "codex ledger"
import json, sys
data = json.load(open(sys.argv[1]))
assert "grok" not in data["attempts"], data
assert len(data["attempts"]["codex"]) == 1, data
PY
}

t_codex_healthy_noop() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  write_codex_ps "$TMP/codex-up.ps" "9000|1|ChatGPT|$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  write_codex_crash "$CODEX_CRASH_DIR/ChatGPT.ips"
  export CODEX_WAL_FILE="$TMP/old-wal"
  : > "$CODEX_WAL_FILE"
  python3 - "$CODEX_WAL_FILE" <<'PY'
import os, sys
os.utime(sys.argv[1], (1, 1))
PY
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "grok status=$(jget status)"
  [[ "$(cget status)" == "up" ]] || die "codex status=$(cget status)"
  [[ "$(cget action)" == "none" ]] || die "codex action=$(cget action)"
  [[ "$(cget running)" == "True" ]] || die "running=$(cget running)"
  grep -q "codex reopen start" "$HEAL_LOG" && die "healthy codex reopened" || true
  [[ ! -s "$CODEX_OPEN_LOG" ]] || die "open called for a running codex"
}

t_codex_pause() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  export CODEX_REOPEN_POLICY=any_exit
  codex_decoys "$TMP/codex-down.ps"
  touch "$LATCH_DIR/codex.pause"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "grok status=$(jget status)"
  [[ "$(cget status)" == "paused" ]] || die "codex status=$(cget status)"
  [[ "$(cget action)" == "none" ]] || die "codex action=$(cget action)"
  grep -q "codex reopen start" "$HEAL_LOG" && die "paused codex reopened" || true
}

t_codex_crash_only_without_report() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"codex\":{\"pid\":9000,\"launchedAtMs\":1000,\"running\":true}}"
  codex_decoys "$TMP/codex-down.ps"
  run_heal
  [[ "$(cget status)" == "crash_required" ]] || die "status=$(cget status)"
  [[ "$(cget action)" == "none" ]] || die "action=$(cget action)"
  grep -q "codex reopen start" "$HEAL_LOG" && die "reopened without a report" || true
  : > "$HEAL_LOG"
  rm -f "$HEAL_STATE"
  write_codex_crash "$CODEX_CRASH_DIR/ChatGPT.ips"
  run_heal
  [[ "$(cget status)" == "crash_required" ]] || die "unanchored status=$(cget status)"
  grep -q "codex reopen start" "$HEAL_LOG" && die "reopened without a prior launch" || true
}

t_codex_never_killed() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_DRY_RUN=0
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"codex\":{\"pid\":9000,\"launchedAtMs\":1000,\"running\":true}}"
  codex_decoys "$TMP/codex-down.ps"
  write_codex_crash "$CODEX_CRASH_DIR/ChatGPT.ips"
  write_codex_ps "$TMP/codex-up.ps" "9000|1|ChatGPT|$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  export CODEX_PS_AFTER_FILE="$TMP/codex-up.ps"
  export CODEX_PS_FILE="$TMP/codex-down.ps"
  mkdir -p "$TMP/bin"
  local name
  for name in kill pkill osascript open; do
    cat > "$TMP/bin/$name" <<EOF
#!/bin/sh
printf '%s %s\n' "$name" "\$*" >> "$TMP/killed.log"
exit 0
EOF
    chmod +x "$TMP/bin/$name"
  done
  : > "$TMP/killed.log"
  export PATH="$TMP/bin:$PATH"
  run_heal
  [[ "$(cget status)" == "reopened" ]] || die "codex status=$(cget status) readiness=$(cget readiness)"
  [[ "$(jget status)" == "ok" ]] || die "grok status=$(jget status)"
  grep -Fq -- "-g $CODEX_APP_PATH" "$CODEX_OPEN_LOG" || die "open args=$(cat "$CODEX_OPEN_LOG")"
  [[ ! -s "$TMP/killed.log" ]] || die "killed or quit: $(cat "$TMP/killed.log")"
  grep -q "kill\|osascript\|pkill" "$HEAL_LOG" && die "log mentions kill" || true
}

t_codex_app_absent() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  export CODEX_WATCH=1
  export CODEX_APP_PATH="$TMP/missing-ChatGPT.app"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "grok status=$(jget status)"
  [[ "$(cget status)" == "app_absent" ]] || die "codex status=$(cget status)"
  [[ "$(cget action)" == "none" ]] || die "action=$(cget action)"
  rm -f "$HEAL_STATE"
  unset CODEX_WATCH
  export CODEX_APP_PATH="$TMP/also-missing-ChatGPT.app"
  run_heal
  [[ "$(cget status)" == "app_absent" ]] || die "default status=$(cget status)"
  [[ "$(cget watched)" == "False" ]] || die "watched=$(cget watched)"
}

t_codex_any_exit() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  export CODEX_REOPEN_POLICY=any_exit
  codex_decoys "$TMP/codex-down.ps"
  write_codex_ps "$TMP/codex-up.ps" "9000|1|ChatGPT|$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  export CODEX_PS_AFTER_FILE="$TMP/codex-up.ps"
  export CODEX_PS_FILE="$TMP/codex-down.ps"
  run_heal
  [[ "$(cget status)" == "reopened" ]] || die "status=$(cget status)"
  [[ "$(cget policy)" == "any_exit" ]] || die "policy=$(cget policy)"
  grep -q "codex reopen start policy=any_exit" "$HEAL_LOG" || die "any_exit did not start"
}

t_codex_wal_stale() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  export CODEX_REOPEN_POLICY=any_exit
  codex_decoys "$TMP/codex-down.ps"
  write_codex_ps "$TMP/codex-up.ps" "9000|1|ChatGPT|$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  export CODEX_PS_AFTER_FILE="$TMP/codex-up.ps"
  export CODEX_PS_FILE="$TMP/codex-down.ps"
  export CODEX_WAL_FILE="$TMP/stale-wal"
  : > "$CODEX_WAL_FILE"
  python3 - "$CODEX_WAL_FILE" <<'PY'
import os, sys
os.utime(sys.argv[1], (1, 1))
PY
  run_heal
  [[ "$(cget status)" == "reopen_incomplete" ]] || die "status=$(cget status)"
  [[ "$(cget readiness)" == "wal_stale" ]] || die "readiness=$(cget readiness)"
  rm -f "$HEAL_STATE" "$LATCH_DIR/grok-bot-restart-attempts.json"
  : > "$HEAL_LOG"
  python3 - "$CODEX_WAL_FILE" <<'PY'
import os, sys, time
now = time.time()
os.utime(sys.argv[1], (now, now))
PY
  run_heal
  [[ "$(cget status)" == "reopened" ]] || die "fresh wal status=$(cget status) readiness=$(cget readiness)"
}

t_beacon_window_elapsed_honors() {
  # Inside BEACON_RELAUNCH_WINDOW_SEC a second request is suppressed.
  # At exactly the window (the comparison is strictly less-than) the request is honored.
  beacon_env
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export BEACON_RELAUNCH_WINDOW_SEC=3600
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$((now - 3599000)),\"lastBeaconHealAtMs\":$((now - 3599000))}"
  run_heal
  [[ "$(jget status)" == "beacon_suppressed" ]] || die "inside status=$(jget status)"
  grep -q "heal start" "$HEAL_LOG" && die "inside window relaunched" || true
  : > "$HEAL_LOG"
  seed_state "{\"version\":2,\"status\":\"healed\",\"pid\":4242,\"lastHealAtMs\":$((now - 3600000)),\"lastBeaconHealAtMs\":$((now - 3600000))}"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "elapsed status=$(jget status) readiness=$(jget readiness)"
  [[ "$(jget reason)" == "beacon_request" ]] || die "elapsed reason=$(jget reason)"
  grep -q "heal start reason=beacon_request" "$HEAL_LOG" || die "elapsed window did not heal"
}

run_case T-guard-helper-loss-allow t_guard_helper_loss_allow
run_case T-guard-backoff t_guard_backoff
run_case T-guard-circuit-open t_guard_circuit_open
run_case T-guard-hold-wins t_guard_hold_wins
run_case T-guard-disable-wins t_guard_disable_wins
run_case T-guard-idle-opt-in t_guard_idle_opt_in
run_case T-guard-missing-fails-closed t_guard_missing_fails_closed
run_case T-codex-down-reopen t_codex_down_reopen
run_case T-codex-healthy-noop t_codex_healthy_noop
run_case T-codex-pause t_codex_pause
run_case T-codex-crash-only-without-report t_codex_crash_only_without_report
run_case T-codex-never-killed t_codex_never_killed
run_case T-codex-app-absent t_codex_app_absent
run_case T-codex-any-exit t_codex_any_exit
run_case T-codex-wal-stale t_codex_wal_stale
run_case T-beacon-window-elapsed-honors t_beacon_window_elapsed_honors
echo
t_stage0_blocks_every_recovery() {
  unset RECOVERY_MODE
  beacon_env
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  codex_on
  export CODEX_REOPEN_POLICY=any_exit
  export CODEX_PS_FILE="$TMP/codex-empty.ps"
  : > "$CODEX_PS_FILE"
  run_heal
  [[ "$(jget status)" == "restart_blocked" && "$(jget readiness)" == "observation_only" ]] || die "stage0 Grok not blocked"
  [[ "$(cget status)" == "observation_only" ]] || die "stage0 Codex not blocked"
  [[ -f "$LATCH_DIR/grok-bot-local-exec-heal.request" ]] || die "stage0 consumed request"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "stage0 spent a recovery attempt"
  [[ ! -s "$BEACON_STUB_CALLS" ]] || die "stage0 contacted beacon"
  [[ ! -s "$CODEX_OPEN_LOG" ]] || die "stage0 opened Codex"
}

t_continuity_first_tick_and_gap() {
  unset HEAL_TEST_CONTINUOUS
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget readiness)" == "observation_required" ]] || die "first tick authorized restart"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "first tick spent budget"
  python3 - "$LATCH_DIR/grok-bot-observation-clock.json" <<'PYCLOCK'
import json, sys, time, os
path = sys.argv[1]
sample=json.load(open(path))
sample.update(wall=time.time()-600,monotonic=sample["monotonic"]-60,mode="active")
json.dump(sample,open(path,"w"))
os.chmod(path,0o600)
PYCLOCK
  run_heal
  [[ "$(jget readiness)" == "observation_required" ]] || die "wake-like gap authorized restart"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "gap spent budget"
}

t_unknown_process_identity_observes() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/dead-pid" "$GROK_SUPPORT_DIR" "$now"
  printf '{bad json' > "$GROK_SUPPORT_DIR/desktop-status.json"
  run_heal
  [[ "$(jget reason)" == "signal_unavailable" && "$(jget action)" == "none" ]] || die "unreadable identity authorized restart"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "unknown signal spent budget"
}

t_invalid_opt_in_writes_nothing() {
  local home="$TMP/invalid-home"
  if HOME="$home" INSTALL_SKIP_LAUNCHD=1 INSTALL_HELPER_HEAL=1 bash "$ROOT/install.sh" >/dev/null 2>&1; then
    die "helper opt-in without active was accepted"
  fi
  [[ ! -e "$home" ]] || die "invalid option wrote files"
  grep -q 'RunAtLoad owns' "$ROOT/install.sh" || die "installer tick ownership undocumented"
}

t_bad_heartbeat_is_not_stale_authorization() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/stale-hb" "$GROK_SUPPORT_DIR" "$now"
  local kind
  for kind in future mismatched missing; do
    python3 - "$GROK_SUPPORT_DIR/dune-reliability/sessions/test.running.json" "$kind" "$now" <<'PYHB'
import json, os, sys
path, kind, now = sys.argv[1:]
if kind == "missing":
    os.unlink(path)
else:
    json.dump({"pid":9999 if kind == "mismatched" else 4242,
               "heartbeatAtMs":int(now)+60000 if kind == "future" else int(now)-600000,
               "bootOutcome":"ready"},open(path,"w"))
PYHB
    run_heal
    [[ "$(jget action)" == "none" ]] || die "$kind heartbeat authorized restart"
    [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "$kind heartbeat spent budget"
  done
}

t_quit_timeout_stops_without_force_or_duplicate_open() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  export HEAL_DRY_RUN=0 QUIT_WAIT_SEC=1
  local shims="$TMP/quit-shims"
  mkdir -p "$shims"
  export QUIT_CALL_LOG="$TMP/quit-calls"
  printf '#!/bin/sh\nexit 0\n' > "$shims/pgrep"
  printf '#!/bin/sh\nexit 0\n' > "$shims/sleep"
  cat > "$shims/osascript" <<'EOFQUIT'
#!/bin/sh
printf 'quit-attempt\n' >> "$QUIT_CALL_LOG"
exit 0
EOFQUIT
  local name
  for name in open pkill; do
    cat > "$shims/$name" <<'EOFQUIT'
#!/bin/sh
printf 'unsafe-followup\n' >> "$QUIT_CALL_LOG"
exit 1
EOFQUIT
  done
  chmod +x "$shims/pgrep" "$shims/sleep" "$shims/osascript" "$shims/open" "$shims/pkill"
  export PATH="$shims:$PATH"
  run_heal
  [[ "$(jget status)" == "heal_incomplete" && "$(jget readiness)" == "quit_timeout" ]] || die "quit timeout not visible"
  [[ "$(jget action)" == "quit_attempt" ]] || die "quit action not recorded"
  grep -q 'quit-attempt' "$QUIT_CALL_LOG" || die "gentle quit not exercised"
  grep -q 'unsafe-followup' "$QUIT_CALL_LOG" && die "force kill or duplicate open attempted" || true
  [[ -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "attempt budget lost"
}

t_clock_status_visible_on_healthy_tick() {
  unset HEAL_TEST_CONTINUOUS
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "healthy status changed"
  [[ "$(jget recoveryMode)" == "active" ]] || die "mode invisible"
  [[ "$(jget observationStatus)" == "observation_required" ]] || die "clock block invisible"
  [[ "$(jget restartGuardResult)" == "not_evaluated" ]] || die "unrequested restart misreported"
}

run_case T-quit-timeout-no-force t_quit_timeout_stops_without_force_or_duplicate_open
run_case T-clock-status-visible t_clock_status_visible_on_healthy_tick

run_case T-invalid-opt-in-writes-nothing t_invalid_opt_in_writes_nothing
run_case T-bad-heartbeat-no-authorization t_bad_heartbeat_is_not_stale_authorization

run_case T-stage0-blocks-every-recovery t_stage0_blocks_every_recovery
run_case T-continuity-first-tick-and-gap t_continuity_first_tick_and_gap
run_case T-unknown-process-identity-observes t_unknown_process_identity_observes


t_quit_marker_blocks_requests() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  python3 - "$GROK_SUPPORT_DIR" "$now" <<'PYQUIT'
import json, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('dune-reliability/sessions/*.running.json'):
    data=json.loads(path.read_text()); data['quitRequestedAtMs']=int(sys.argv[2])-1000
    path.write_text(json.dumps(data))
PYQUIT
  touch "$LATCH_DIR/grok-bot-local-exec-heal.request"
  run_heal
  [[ "$(jget reason)" == "intentional_quit" && "$(jget action)" == "none" ]] || die "quit marker overridden"
  [[ -e "$LATCH_DIR/grok-bot-local-exec-heal.request" ]] || die "request consumed during quit"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "quit spent budget"
}

t_dangling_disable_blocks() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  ln -s "$TMP/missing-control-target" "$LATCH_DIR/grok-bot-local-exec-heal.disable"
  run_heal
  [[ "$(jget status)" == "disabled" ]] || die "dangling disable ignored"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "disabled spent budget"
}

t_grok_absence_requires_crash() {
  unset HEAL_TEST_PROCESS_DOWN_PROVEN
  export HEAL_TRUST_PID=0
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/dead-pid" "$GROK_SUPPORT_DIR" "$now"
  export GROK_CRASH_DIR="$TMP/crashes"; mkdir "$GROK_CRASH_DIR"
  run_heal
  [[ "$(jget readiness)" == "crash_required" && "$(jget action)" == "none" ]] || die "absence treated as crash"
  [[ ! -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "absence spent budget"
  python3 - "$GROK_CRASH_DIR/main.ips" <<'PYCRASH'
from datetime import datetime, timezone
import json, sys
json.dump({'app_name':'Grok Bot','procName':'Grok Bot','pid':2147483646,
           'bundleID':'com.anysphere.sand','bug_type':'309',
           'timestamp':datetime.now(timezone.utc).isoformat()},open(sys.argv[1],'w'))
PYCRASH
  run_heal
  grep -q 'heal start reason=process_down' "$HEAL_LOG" || die "matching crash not considered"
}

t_pause_arrives_after_guard() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  export HEAL_DRY_RUN=0 CODEX_REOPEN_POLICY=any_exit
  export CODEX_PS_FILE="$TMP/empty.ps"; : > "$CODEX_PS_FILE"
  mv "$LATCH_DIR/bin/grok-bot-restart-guard.py" "$LATCH_DIR/bin/original-guard.py"
  cat > "$LATCH_DIR/bin/grok-bot-restart-guard.py" <<'PYSTOP'
import pathlib, subprocess, sys
base=pathlib.Path(sys.argv[1])
result=subprocess.run([sys.executable,str(base/'bin/original-guard.py')]+sys.argv[1:],capture_output=True,text=True)
(base/'codex.pause').touch()
print(result.stdout.strip())
PYSTOP
  run_heal
  [[ "$(cget status)" == "paused" ]] || die "late pause ignored"
  [[ ! -s "$CODEX_OPEN_LOG" ]] || die "opened after pause"
  [[ -e "$LATCH_DIR/grok-bot-restart-attempts.json" ]] || die "spent attempt erased"
}

run_case T-quit-marker-wins t_quit_marker_blocks_requests
run_case T-dangling-disable t_dangling_disable_blocks
run_case T-grok-absence-needs-crash t_grok_absence_requires_crash
run_case T-late-codex-pause t_pause_arrives_after_guard


t_system_clock_allows_fixture_reopen_without_continuity_bypass() {
  unset HEAL_TEST_CONTINUOUS
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  codex_on
  export HEAL_DRY_RUN=0
  seed_state '{"version":2,"status":"ok","pid":4242,"codex":{"pid":9000,"launchedAtMs":1000,"running":true}}'
  codex_decoys "$TMP/codex-down.ps"
  write_codex_crash "$CODEX_CRASH_DIR/main.ips"
  write_codex_ps "$TMP/codex-up.ps" "9001|1|ChatGPT|$CODEX_APP_PATH/Contents/MacOS/ChatGPT"
  export CODEX_PS_AFTER_FILE="$TMP/codex-up.ps"
  export CODEX_PS_FILE="$TMP/codex-down.ps"
  # An earlier process's v2 system-clock sample, aged by a synthetic minute.
  python3 - "$ROOT/grok-bot-restart-guard.py" "$LATCH_DIR/grok-bot-observation-clock.json" <<'PYSYSTEMCLOCK'
import importlib.util, json, os, sys, time
spec=importlib.util.spec_from_file_location('guard',sys.argv[1]);guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
uptime, source=guard.observation_clock()
with open(sys.argv[2],'w') as f:
    json.dump({'v':2,'clockSource':source,'wall':time.time()-60,'monotonic':uptime-60,'mode':'active'},f)
os.chmod(sys.argv[2],0o600)
PYSYSTEMCLOCK
  run_heal
  [[ "$(jget observationStatus)" == "continuous" ]] || die "real cross-process clock did not authorize continuity"
  [[ "$(cget status)" == "reopened" ]] || die "fixture reopen status=$(cget status)"
  [[ "$(wc -l < "$CODEX_OPEN_LOG" | tr -d ' ')" == "1" ]] || die "fixture open count"
  python3 - "$LATCH_DIR/grok-bot-restart-attempts.json" <<'PYONEATTEMPT'
import json,sys
assert len(json.load(open(sys.argv[1]))['attempts']['codex'])==1
PYONEATTEMPT
}
run_case T-system-clock-cross-process-reopen t_system_clock_allows_fixture_reopen_without_continuity_bypass

echo "passed=$PASS failed=$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
