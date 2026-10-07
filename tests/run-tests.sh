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
  # Helper observer: canned ps/lsof so no test reads the host process table.
  export HELPER_CHECK=1
  export HEAL_ON_HELPER_MISSING=0
  export HELPER_MISSING_SEC=300
  export HELPER_BASELINE_SEC=600
  export HELPER_SOCKET_CHECK=1
  export HELPER_PS_FILE="$FIX/helpers/two-helpers.ps"
  export HELPER_LSOF_FILE="$FIX/helpers/sockets.lsof"
  unset HELPER_EXPECTED HEAL_SNAPSHOT_DIR HEAL_SNAPSHOT_KEEP HEAL_SNAPSHOT_MIN_SEC || true
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
  [[ "$(jget kitVersion)" == "1.5.0" ]] || die "kit=$(jget kitVersion)"
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
  [[ "$ver" == "1.5.0" ]] || die "VERSION=$ver"
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

t_helper_fields_healthy() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget reason)" == "healthy" ]] || die "reason=$(jget reason)"
  [[ "$(jget helperCount)" == "2" ]] || die "helperCount=$(jget helperCount)"
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
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":4242,\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000))}"
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
  # boot not ready: count may be stable, but it must not become the baseline.
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  materialize "$FIX/boot-not-ready" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"cooldown\",\"pid\":4242,\"lastHealAtMs\":$((now - 10000)),\"helperBaselinePid\":4242,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 700000))}"
  run_heal
  [[ "$(jget status)" == "cooldown" ]] || die "status=$(jget status)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "learned while unhealthy"
  [[ "$(jget helperStableSinceMs)" == "$now" ]] || die "stable clock not reset while unhealthy"
}

t_helper_baseline_never_lowers() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
PY
}

t_helper_missing_relaunch() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  [[ "$(jget helperBaseline)" == "None" ]] || die "baseline kept across relaunch"
  [[ "$(jget helperCount)" == "1" ]] || die "pre-heal helperCount=$(jget helperCount)"
  grep -q "heal start reason=helper_missing" "$HEAL_LOG" || die "missing heal start"
  grep -q "dry-run: skip quit/open" "$HEAL_LOG" || die "dry-run did not skip quit/open"
  [[ "$(snap_count)" == "1" ]] || die "snapshots=$(snap_count)"
}

t_helper_missing_cooldown() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  # Cooldown over (last heal from another reason 400s ago): helper_missing relaunches.
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 400000))"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status after cooldown=$(jget status)"
  [[ "$(jget reason)" == "helper_missing" ]] || die "reason after cooldown=$(jget reason)"
}

t_helper_one_relaunch_per_window() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HEAL_ON_HELPER_MISSING=1
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  materialize "$FIX/post-ready" "$TMP/post" "$now"
  export HEAL_SWAP_SUPPORT_ON_RELAUNCH="$TMP/post"
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 600000)),\"lastHelperHealAtMs\":$((now - 600000))"
  run_heal
  [[ "$(jget status)" == "helper_suppressed" ]] || die "status=$(jget status)"
  [[ "$(jget action)" == "none" ]] || die "action=$(jget action)"
  [[ "$(jget escalateHint)" == *"escalate"* ]] || die "hint=$(jget escalateHint)"
  grep -q "heal start" "$HEAL_LOG" && die "second helper relaunch inside window" || true
  # Outside HELPER_RELAUNCH_WINDOW_SEC a new outage may relaunch again.
  seed_helper_missing "$now" 400000 ",\"lastHealAtMs\":$((now - 7200000)),\"lastHelperHealAtMs\":$((now - 7200000))"
  run_heal
  [[ "$(jget status)" == "healed" ]] || die "status after window=$(jget status)"
}

t_helper_operator_request_wins() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_state "{\"version\":2,\"status\":\"ok\",\"pid\":9999,\"helperBaseline\":2,\"helperBaselinePid\":9999,\"helperStableCount\":2,\"helperStableSinceMs\":$((now - 900000)),\"helperMissingSinceMs\":$((now - 900000))}"
  run_heal
  [[ "$(jget status)" == "ok" ]] || die "status=$(jget status)"
  [[ "$(jget helperBaseline)" == "None" ]] || die "baseline carried across pid change"
  [[ "$(jget helperMissingSinceMs)" == "None" ]] || die "missing clock carried across pid change"
}

t_helper_check_off() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_CHECK=0 HEAL_ON_HELPER_MISSING=1
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
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
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(jraw helperSockets)" == '{"4300": 2}' ]] || die "helperSockets=$(jraw helperSockets)"
  local f; for f in "$HEAL_STATE" "$HEAL_LOG" "$(newest_snap)"; do
    ! grep -q "203.0.113\|192.0.2" "$f" || die "address leaked into $f"
    ! grep -q "fixture-user\|fixture-handle\|fixture-secret\|fixture-grandchild" "$f" || die "argv leaked into $f"
  done
  # Two helpers: the second has only a non-443 socket.
  export HELPER_PS_FILE="$FIX/helpers/two-helpers.ps"
  rm -f "$HEAL_STATE"
  run_heal
  [[ "$(jraw helperSockets)" == '{"4300": 2, "4301": 0}' ]] || die "helperSockets(2)=$(jraw helperSockets)"
  export HELPER_SOCKET_CHECK=0; rm -f "$HEAL_STATE"
  run_heal
  [[ "$(jget helperSockets)" == "None" ]] || die "socket check not off"
}

t_snapshot_rate_limited_and_pruned() {
  local now; now="$(now_ms)"; export HEAL_NOW_MS="$now"
  export HELPER_PS_FILE="$FIX/helpers/one-helper.ps"
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$now"
  seed_helper_missing "$now" 400000
  run_heal
  [[ "$(snap_count)" == "1" ]] || die "first snapshots=$(snap_count)"
  export HEAL_NOW_MS=$((now + 60000))
  run_heal
  [[ "$(jget status)" == "observe" ]] || die "second status=$(jget status)"
  [[ "$(snap_count)" == "1" ]] || die "not rate-limited: $(snap_count)"
  [[ "$(jget lastSnapshotAtMs)" == "$now" ]] || die "lastSnapshotAtMs=$(jget lastSnapshotAtMs)"
  export HEAL_NOW_MS=$((now + 960000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(snap_count)" == "2" ]] || die "no snapshot after HEAL_SNAPSHOT_MIN_SEC: $(snap_count)"
  export HEAL_SNAPSHOT_KEEP=2 HEAL_NOW_MS=$((now + 1920000))
  materialize "$FIX/healthy" "$GROK_SUPPORT_DIR" "$HEAL_NOW_MS"
  run_heal
  [[ "$(snap_count)" == "2" ]] || die "not pruned to HEAL_SNAPSHOT_KEEP: $(snap_count)"
}

t_install_template_helper_defaults() {
  local home="$TMP/home3"; local pl="$home/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist"
  mkdir -p "$home"
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "fresh install failed"
  t_install_env_check "$pl" "HEAL_ON_HELPER_MISSING=0;HELPER_MISSING_SEC=300" || die "template helper defaults"
  python3 - "$pl" <<'PY' || die "HELPER_EXPECTED must not be pinned by the template"
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]
assert "HELPER_EXPECTED" not in env, env
PY
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
    "HEAL_CURSOR": "1", "PATH": "/opt/custom/bin:/usr/bin:/bin"}},
    open(sys.argv[1], "wb"))
PY
  HOME="$home" INSTALL_SKIP_LAUNCHD=1 bash "$ROOT/install.sh" >/dev/null 2>&1 || die "install failed"
  # Operator tunables + BEACON_* + custom survive; kit-owned PATH comes from template; missing STUCK_SEC from template.
  t_install_env_check "$pl" "BEACON_URL=https://example.invalid;BEACON_POLL_TOKEN_FILE=/nonexistent/tok;BEACON_MACHINE_ID=fixture-machine;MY_CUSTOM=1;COOLDOWN_SEC=999;HEAL_CURSOR=1;STUCK_SEC=120;PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    || die "env not preserved or template key lost"
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
  t_install_env_check "$pl" "COOLDOWN_SEC=300" || die "fresh plist wrong"
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
run_case T-helper-check-off t_helper_check_off
run_case T-helper-ps-unreadable-no-signal t_helper_ps_unreadable_no_signal
run_case T-helper-sockets-counts-no-addresses t_helper_sockets_counts_no_addresses
run_case T-snapshot-rate-limited-and-pruned t_snapshot_rate_limited_and_pruned
run_case T-install-template-helper-defaults t_install_template_helper_defaults
echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
