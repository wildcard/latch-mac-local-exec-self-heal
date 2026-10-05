#!/bin/bash
# Grok Bot local-exec self-heal (LaunchAgent). Kit 1.4.2 (+ optional worker-beacon poll).
# Runs on the Mac without cloud connectivity.
# Relaunches Grok Bot.app when the desktop process is down, the dune-reliability
# heartbeat is stale, bootOutcome is not ready, the heartbeat timestamp is frozen,
# or an operator drops grok-bot-local-exec-heal.request.
#
# Does NOT observe cloud ListMachines.connected. A Mac that still looks healthy
# while the cloud link is down (S-NEW-D) is outside pure Mac heal: this script
# records an escalate hint after a long ok streak and can honor a local request
# file, but it will not invent a cloud signal.
#
# Cursor is NOT auto-relaunched (local-exec path is Grok Bot.app).
# Set HEAL_CURSOR=1 to also ensure Cursor.app is up.
set -euo pipefail

KIT_VERSION="1.4.2"
APP_NAME="Grok Bot"
APP_PATH="${GROK_APP_PATH:-/Applications/Grok Bot.app}"
SUP="${GROK_SUPPORT_DIR:-$HOME/Library/Application Support/Grok Bot}"
LATCH_DIR="${LATCH_DIR:-$HOME/Library/Application Support/Latch}"
DISABLE="$LATCH_DIR/grok-bot-local-exec-heal.disable"
REQUEST="$LATCH_DIR/grok-bot-local-exec-heal.request"
LOG="${HEAL_LOG:-$HOME/Library/Logs/GrokBotLocalExecHeal.log}"
STATE="${HEAL_STATE:-$HOME/Library/Logs/GrokBotLocalExecHeal-last.json}"
LOCKDIR="$LATCH_DIR/grok-bot-local-exec-heal.lock"

HEARTBEAT_STALE_SEC="${HEARTBEAT_STALE_SEC:-180}"
COOLDOWN_SEC="${COOLDOWN_SEC:-300}"
QUIT_WAIT_SEC="${QUIT_WAIT_SEC:-20}"
HEAL_CURSOR="${HEAL_CURSOR:-0}"
# Heartbeat timestamp unchanged (same pid) for at least this many seconds → heartbeat_frozen.
STUCK_SEC="${STUCK_SEC:-120}"
# After relaunch, wait this long for process + fresh heartbeat or bootOutcome=ready.
READINESS_WAIT_SEC="${READINESS_WAIT_SEC:-75}"
READINESS_POLL_SEC="${READINESS_POLL_SEC:-1}"
# status=ok this long with the same pid → escalateHint for S-NEW-D (cloud not visible).
OK_HINT_SEC="${OK_HINT_SEC:-300}"
HEAL_ON_STUCK_SESSION="${HEAL_ON_STUCK_SESSION:-1}"
HEAL_DRY_RUN="${HEAL_DRY_RUN:-0}"
HEAL_TRUST_PID="${HEAL_TRUST_PID:-0}"
HEAL_DISABLE_PGREP="${HEAL_DISABLE_PGREP:-0}"
# worker-beacon (optional, off unless all three are set). One outbound POST per tick.
# Token lives in a file outside this repo; it is never logged or put on a command line.
BEACON_URL="${BEACON_URL:-}"
BEACON_POLL_TOKEN_FILE="${BEACON_POLL_TOKEN_FILE:-}"
BEACON_MACHINE_ID="${BEACON_MACHINE_ID:-}"
BEACON_CURL="${BEACON_CURL:-curl}"
# One beacon relaunch per outage: a second beacon request inside this window stops and escalates.
BEACON_RELAUNCH_WINDOW_SEC="${BEACON_RELAUNCH_WINDOW_SEC:-3600}"

PYTHON="${PYTHON:-/usr/bin/python3}"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")" "$LATCH_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"
}

file_mtime() {
  local t
  t="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  printf '%s\n' "${t:-0}"
}

# Populate PID ALIVE HEARTBEAT_AGE HEARTBEAT_AT_MS BOOT NEED_HEAL REASON
# READINESS ESCALATE_HINT FROZEN_SINCE OK_SINCE UNCHANGED_FOR_SEC
run_inspect() {
  local out
  out="$("$PYTHON" - \
    "$SUP" \
    "$HEARTBEAT_STALE_SEC" \
    "$STUCK_SEC" \
    "$STATE" \
    "$REQUEST" \
    "$HEAL_TRUST_PID" \
    "$HEAL_DISABLE_PGREP" \
    "$OK_HINT_SEC" \
    "$HEAL_ON_STUCK_SESSION" <<'PY'
import json, os, glob, sys, subprocess, time, shlex

sup = sys.argv[1]
stale_sec = float(sys.argv[2])
stuck_sec = float(sys.argv[3])
state_path = sys.argv[4]
request_path = sys.argv[5]
trust_pid = sys.argv[6] == "1"
disable_pgrep = sys.argv[7] == "1"
ok_hint_sec = float(sys.argv[8])
heal_on_stuck = sys.argv[9] == "1"

if os.environ.get("HEAL_NOW_MS"):
    now_ms = int(os.environ["HEAL_NOW_MS"])
else:
    now_ms = int(time.time() * 1000)
now = now_ms  # ms

prev = {}
try:
    with open(state_path) as f:
        prev = json.load(f)
except Exception:
    prev = {}

pid = None
reason_bits = []
ds_path = os.path.join(sup, "desktop-status.json")
if os.path.isfile(ds_path):
    try:
        ds = json.load(open(ds_path))
        raw = ds.get("pid")
        if raw is not None and str(raw).strip() != "":
            pid = int(raw)
    except Exception:
        reason_bits.append("desktop_status_unreadable")

alive = False
if pid:
    if trust_pid:
        alive = True
    else:
        r = subprocess.run(["kill", "-0", str(pid)], capture_output=True)
        alive = r.returncode == 0
if not alive and not pid and not disable_pgrep:
    r = subprocess.run(
        ["pgrep", "-f", r"/Applications/Grok Bot\.app/Contents/MacOS/Grok Bot$"],
        capture_output=True, text=True,
    )
    if r.returncode == 0 and r.stdout.strip():
        try:
            pid = int(r.stdout.strip().splitlines()[0])
            alive = True
        except Exception:
            pass
elif not alive and pid and not trust_pid and not disable_pgrep:
    # pid from desktop-status was dead; do not pgrep-replace it.
    pass

sessions = glob.glob(os.path.join(sup, "dune-reliability", "sessions", "*.running.json"))
newest = None
for fpath in sessions:
    try:
        j = json.load(open(fpath))
        hb = j.get("heartbeatAtMs")
        if hb is None:
            continue
        hb = int(hb)
        if newest is None or hb > newest[0]:
            newest = (hb, j, fpath)
    except Exception:
        pass

heartbeat_age = None
hb_ms = None
boot = None
if newest:
    hb_ms = newest[0]
    heartbeat_age = (now_ms - hb_ms) / 1000.0
    boot = newest[1].get("bootOutcome")
    spid = newest[1].get("pid")
    if spid and pid and int(spid) != int(pid):
        reason_bits.append("pid_mismatch_session_vs_desktop_status")
    if newest[1].get("quitRequestedAtMs"):
        reason_bits.append("quit_requested")

def as_int(v):
    try:
        if v is None or v == "":
            return None
        return int(v)
    except Exception:
        return None

prev_pid = as_int(prev.get("pid"))
prev_hb = as_int(prev.get("heartbeatAtMs"))
frozen_since = None
unchanged_for = None
if alive and hb_ms is not None and prev_pid is not None and prev_hb is not None and prev_pid == pid and prev_hb == hb_ms:
    frozen_since = as_int(prev.get("heartbeatFrozenSinceMs"))
    if frozen_since is None:
        frozen_since = as_int(prev.get("checkedAtMs")) or now_ms
    unchanged_for = (now_ms - frozen_since) / 1000.0

frozen_hit = (
    heal_on_stuck
    and unchanged_for is not None
    and unchanged_for >= stuck_sec
)

need = False
reason = "healthy"
readiness = "local_healthy"
hint = ""

if not alive:
    need = True
    reason = "process_down"
    readiness = "process_down"
elif heartbeat_age is None:
    reason = "process_up_no_heartbeat_file"
    readiness = "process_up_no_heartbeat"
    hint = (
        "process is up but no dune-reliability heartbeat file yet; not relaunching. "
        "If this persists and the cloud link is down, restart Grok Bot or drop "
        "grok-bot-local-exec-heal.request on this Mac."
    )
elif heartbeat_age > stale_sec:
    need = True
    reason = "heartbeat_stale_%ds" % int(heartbeat_age)
    readiness = "heartbeat_stale"
elif boot and boot != "ready":
    token = "".join(ch if (ch.isalnum() or ch in "-_") else "_" for ch in str(boot))
    need = True
    reason = "boot_outcome_%s" % token
    readiness = "boot_not_ready"
elif frozen_hit:
    need = True
    reason = "heartbeat_frozen"
    readiness = "heartbeat_frozen"
else:
    reason = "healthy"
    readiness = "local_healthy"
    if reason_bits:
        reason = reason + "+" + ",".join(reason_bits)

request_exists = os.path.isfile(request_path)
if request_exists:
    # Force relaunch even when local signals look healthy. Consumed by the shell on heal start.
    need = True
    reason = "operator_request"
    readiness = "operator_request"

ok_since = None
if (not need) and str(reason).startswith("healthy"):
    prev_ok = as_int(prev.get("okStreakSinceMs"))
    if prev.get("status") == "ok" and prev_ok is not None and prev_pid == pid:
        ok_since = prev_ok
    else:
        ok_since = now_ms
    streak_for = (now_ms - ok_since) / 1000.0
    if streak_for >= ok_hint_sec and not hint:
        hint = (
            "S-NEW-D: local process and heartbeat look healthy, so this LaunchAgent will not relaunch. "
            "It cannot see cloud ListMachines.connected. If the link is down, restart Grok Bot or create "
            "grok-bot-local-exec-heal.request on this Mac (a disconnected remote agent cannot drop that file). "
            "Sleep, lid, and network are outside this heal."
        )

SNEW = hint

def emit(k, v):
    if v is None:
        print("%s=" % k)
    else:
        print("%s=%s" % (k, shlex.quote(str(v))))

emit("PID", pid if pid is not None else "")
emit("ALIVE", "1" if alive else "0")
emit("HEARTBEAT_AGE", "" if heartbeat_age is None else ("%.3f" % heartbeat_age))
emit("HEARTBEAT_AT_MS", "" if hb_ms is None else str(int(hb_ms)))
emit("BOOT", "" if not boot else str(boot))
emit("NEED_HEAL", "1" if need else "0")
emit("REASON", reason)
emit("READINESS", readiness)
emit("ESCALATE_HINT", SNEW)
emit("FROZEN_SINCE", "" if frozen_since is None else str(int(frozen_since)))
emit("OK_SINCE", "" if ok_since is None else str(int(ok_since)))
emit("UNCHANGED_FOR_SEC", "" if unchanged_for is None else ("%.3f" % unchanged_for))
PY
)"
  # shellcheck disable=SC2086
  eval "$out"
}

# Readiness probe only. Does not change heal reason. Sets R_* and copies into PID/ALIVE/heartbeat fields.
probe_ready() {
  local out
  out="$("$PYTHON" - "$SUP" "$HEARTBEAT_STALE_SEC" "$HEAL_TRUST_PID" "$HEAL_DISABLE_PGREP" <<'PY'
import json, os, glob, sys, subprocess, time, shlex
sup, stale_s, trust_s, disable_s = sys.argv[1:5]
stale_sec = float(stale_s)
trust_pid = trust_s == "1"
disable_pgrep = disable_s == "1"
if os.environ.get("HEAL_NOW_MS"):
    now_ms = int(os.environ["HEAL_NOW_MS"])
else:
    now_ms = int(time.time() * 1000)

pid = None
ds_path = os.path.join(sup, "desktop-status.json")
if os.path.isfile(ds_path):
    try:
        raw = json.load(open(ds_path)).get("pid")
        if raw is not None and str(raw).strip() != "":
            pid = int(raw)
    except Exception:
        pid = None

alive = False
if pid:
    if trust_pid:
        alive = True
    else:
        r = subprocess.run(["kill", "-0", str(pid)], capture_output=True)
        alive = r.returncode == 0

heartbeat_age = None
hb_ms = None
boot = None
sessions = glob.glob(os.path.join(sup, "dune-reliability", "sessions", "*.running.json"))
newest = None
for fpath in sessions:
    try:
        j = json.load(open(fpath))
        hb = j.get("heartbeatAtMs")
        if hb is None:
            continue
        hb = int(hb)
        if newest is None or hb > newest[0]:
            newest = (hb, j)
    except Exception:
        pass
if newest:
    hb_ms = newest[0]
    heartbeat_age = (now_ms - hb_ms) / 1000.0
    boot = newest[1].get("bootOutcome") or ""

hb_ok = heartbeat_age is not None and heartbeat_age >= 0 and heartbeat_age < stale_sec
boot_ok = boot == "ready"
ready = bool(alive and (hb_ok or boot_ok))

def emit(k, v):
    if v is None or v == "":
        print("%s=" % k)
    else:
        print("%s=%s" % (k, shlex.quote(str(v))))

emit("R_PID", "" if pid is None else str(pid))
emit("R_ALIVE", "1" if alive else "0")
emit("R_HEARTBEAT_AGE", "" if heartbeat_age is None else ("%.3f" % heartbeat_age))
emit("R_HEARTBEAT_AT_MS", "" if hb_ms is None else str(int(hb_ms)))
emit("R_BOOT", boot or "")
emit("R_READY", "1" if ready else "0")
PY
)"
  eval "$out"
  PID="${R_PID:-}"
  ALIVE="${R_ALIVE:-0}"
  HEARTBEAT_AGE="${R_HEARTBEAT_AGE:-}"
  HEARTBEAT_AT_MS="${R_HEARTBEAT_AT_MS:-}"
  BOOT="${R_BOOT:-}"
}

# Prints the octal permission bits of $1 (3-4 digits), or nothing if they cannot be determined.
# stat flavour is chosen by OS: BSD/macOS `stat -f %Lp`; GNU `stat -c %a` (on GNU, `stat -f` is a
# filesystem stat that exits 0 with junk, which used to fail the check open). Output is validated
# strictly, then a python fallback is tried. BEACON_TEST_NO_PY_PERMS=1 disables the fallback (tests only).
token_file_mode() {
  local f="$1" m=""
  case "$(uname -s 2>/dev/null)" in
    Darwin|*BSD) m="$(stat -f %Lp "$f" 2>/dev/null || true)" ;;
    *) m="$(stat -c %a "$f" 2>/dev/null || true)" ;;
  esac
  if [[ "$m" =~ ^[0-7]{3,4}$ ]]; then printf '%s\n' "$m"; return 0; fi
  if [[ "${BEACON_TEST_NO_PY_PERMS:-0}" != "1" ]]; then
    m="$("$PYTHON" -c 'import os,stat,sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$f" 2>/dev/null || true)"
    if [[ "$m" =~ ^[0-7]{3,4}$ ]]; then printf '%s\n' "$m"; return 0; fi
  fi
  return 0
}

# Sets BEACON_PENDING=1 only when the Worker returns exactly {"heal":true} (boolean true, sole key).
# Any failure is a no-op: a dead Worker must never block or trigger local heal.
beacon_poll() {
  BEACON_PENDING=0
  [[ -n "$BEACON_URL" && -n "$BEACON_POLL_TOKEN_FILE" && -n "$BEACON_MACHINE_ID" ]] || return 0
  [[ -r "$BEACON_POLL_TOKEN_FILE" ]] || { log "beacon: token file unreadable"; return 0; }
  # Refuse group/world-readable token files. Fail closed: unknown mode means no poll.
  local perms
  perms="$(token_file_mode "$BEACON_POLL_TOKEN_FILE")"
  if [[ -z "$perms" ]]; then
    log "beacon: token file perms unknown; refuse"
    return 0
  fi
  if (( (8#$perms & 077) != 0 )); then
    log "beacon: token file perms too open ($perms); want 600 or tighter"
    return 0
  fi
  local token body resp curl_cfg
  # Strip CR/LF; reject chars that break curl -K double-quoted header lines (" or \).
  token="$(tr -d '\n\r' < "$BEACON_POLL_TOKEN_FILE")"
  if [[ -z "$token" ]]; then
    log "beacon: token file empty"
    return 0
  fi
  if [[ "$token" == *[\"\\]* ]]; then
    log "beacon: token contains quote or backslash; refuse"
    return 0
  fi
  body="$("$PYTHON" -c 'import json,sys; print(json.dumps({"machineId": sys.argv[1]}))' "$BEACON_MACHINE_ID")"
  # Auth header via curl -K on stdin so the token never appears in ps. Escape for curl config quotes.
  curl_cfg="$("$PYTHON" -c 'import sys
t = sys.argv[1]
# Defense in depth: escape \ and " even though we already refused them above.
esc = t.replace("\\", "\\\\").replace("\"", "\\\"")
print("header = \"Authorization: Bearer " + esc + "\"")
' "$token")"
  resp="$(printf '%s\n' "$curl_cfg"     | "$BEACON_CURL" -sS --max-time 10 -X POST -H 'content-type: application/json'         --data "$body" -K - "${BEACON_URL%/}/v1/poll" 2>/dev/null)" || { log "beacon: poll failed"; return 0; }
  if [[ "$("$PYTHON" -c 'import json,sys
try:
    r = json.loads(sys.argv[1])
    print("1" if isinstance(r, dict) and len(r) == 1 and r.get("heal") is True else "0")
except Exception:
    print("0")' "$resp")" == "1" ]]; then
    BEACON_PENDING=1
    log "beacon: heal request pending"
  fi
}

write_state() {
  local status="$1" reason="$2" action="$3"
  STATUS="$status" REASON="$reason" ACTION="$action" \
  W_PID="${PID:-}" W_AGE="${HEARTBEAT_AGE:-}" W_HB="${HEARTBEAT_AT_MS:-}" \
  W_BOOT="${BOOT:-}" W_READINESS="${READINESS:-}" W_HINT="${ESCALATE_HINT:-}" \
  W_FROZEN="${FROZEN_SINCE:-}" W_OK="${OK_SINCE:-}" W_UNCHANGED="${UNCHANGED_FOR_SEC:-}" \
  W_KIT="$KIT_VERSION" W_APP="$APP_PATH" \
    "$PYTHON" - "$STATE" <<'PY'
import json, os, sys, time

path = sys.argv[1]
status = os.environ.get("STATUS", "")
reason = os.environ.get("REASON", "")
action = os.environ.get("ACTION", "")
pid = os.environ.get("W_PID", "")
age = os.environ.get("W_AGE", "")
hb = os.environ.get("W_HB", "")
boot = os.environ.get("W_BOOT", "")
readiness = os.environ.get("W_READINESS", "")
hint = os.environ.get("W_HINT", "")
frozen = os.environ.get("W_FROZEN", "")
ok_since = os.environ.get("W_OK", "")
unchanged = os.environ.get("W_UNCHANGED", "")
kit = os.environ.get("W_KIT", "")
app = os.environ.get("W_APP", "")

if os.environ.get("HEAL_NOW_MS"):
    now_ms = int(os.environ["HEAL_NOW_MS"])
else:
    now_ms = int(time.time() * 1000)

def pint(s):
    try:
        if s is None or str(s).strip() == "":
            return None
        return int(str(s).strip())
    except Exception:
        return None

def pfloat(s):
    try:
        if s is None or str(s).strip() == "":
            return None
        return float(s)
    except Exception:
        return None

prev = {}
try:
    with open(path) as f:
        prev = json.load(f)
except Exception:
    prev = {}

iso = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now_ms / 1000.0))
data = {
    "version": 2,
    "kitVersion": kit,
    "checkedAtMs": now_ms,
    "checkedAtIso": iso,
    "status": status,
    "reason": reason,
    "action": action,
    "pid": pint(pid),
    "heartbeatAgeSec": pfloat(age),
    "heartbeatAtMs": pint(hb),
    "bootOutcome": boot or None,
    "readiness": readiness or None,
    "escalateHint": hint or None,
    "heartbeatFrozenSinceMs": pint(frozen),
    "heartbeatUnchangedForSec": pfloat(unchanged),
    "okStreakSinceMs": pint(ok_since),
    "app": app,
    "cloudConnectObservable": False,
}
if action == "relaunch":
    data["lastHealAtMs"] = now_ms
    data["lastHealIso"] = iso
elif prev.get("lastHealAtMs"):
    data["lastHealAtMs"] = prev.get("lastHealAtMs")
    data["lastHealIso"] = prev.get("lastHealIso")
if action == "relaunch" and reason == "beacon_request":
    data["lastBeaconHealAtMs"] = now_ms
elif prev.get("lastBeaconHealAtMs"):
    data["lastBeaconHealAtMs"] = prev.get("lastBeaconHealAtMs")

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# single-flight
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [[ -d "$LOCKDIR" ]]; then
    now_s="$(date +%s)"
    age=$(( now_s - $(file_mtime "$LOCKDIR") ))
    if (( age > 600 )); then
      rmdir "$LOCKDIR" 2>/dev/null || true
      mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

if [[ -f "$DISABLE" ]]; then
  log "skip: disable file present ($DISABLE)"
  PID="" ALIVE=0 HEARTBEAT_AGE="" HEARTBEAT_AT_MS="" BOOT=""
  READINESS="disabled" ESCALATE_HINT="" FROZEN_SINCE="" OK_SINCE="" UNCHANGED_FOR_SEC=""
  write_state "disabled" "disable_file" "none"
  exit 0
fi

if [[ ! -d "$APP_PATH" ]]; then
  log "error: app missing at $APP_PATH"
  PID="" ALIVE=0 HEARTBEAT_AGE="" HEARTBEAT_AT_MS="" BOOT=""
  READINESS="app_missing"
  ESCALATE_HINT="Grok Bot.app not found; heal cannot relaunch until the app is installed."
  FROZEN_SINCE="" OK_SINCE="" UNCHANGED_FOR_SEC=""
  write_state "error" "app_missing" "none"
  exit 0
fi

run_inspect

LAST_HEAL_MS=0
LAST_BEACON_MS=0
if [[ -f "$STATE" ]]; then
  LAST_HEAL_MS="$("$PYTHON" -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("lastHealAtMs") or 0))
except Exception:
    print(0)' "$STATE" 2>/dev/null || echo 0)"
fi
if [[ -f "$STATE" ]]; then
  LAST_BEACON_MS="$("$PYTHON" -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("lastBeaconHealAtMs") or 0))
except Exception:
    print(0)' "$STATE" 2>/dev/null || echo 0)"
fi
if [[ -n "${HEAL_NOW_MS:-}" ]]; then
  NOW_MS="$HEAL_NOW_MS"
else
  NOW_MS="$("$PYTHON" -c 'import time; print(int(time.time()*1000))')"
fi

# Poll only here: past the disable check, so a disabled Mac never consumes (request stays queued
# in the Worker until its exp). Do not poll when a local heal is already needed — ack-on-read would
# burn the flag if cooldown then skips the relaunch (Worker 5m lockout). Still poll inside the
# beacon suppress window so a second request can escalate. A local operator_request wins when we do poll.
if [[ "${NEED_HEAL}" != "1" ]]; then
  beacon_poll
fi
if [[ "${BEACON_PENDING:-0}" == "1" && "${REASON}" != "operator_request" && "${NEED_HEAL}" != "1" ]]; then
  NEED_HEAL=1
  REASON="beacon_request"
  READINESS="beacon_request"
  ESCALATE_HINT=""
fi

if [[ "${NEED_HEAL}" == "1" && "$LAST_HEAL_MS" != "0" && "${REASON}" != "operator_request" && "${REASON}" != "beacon_request" ]]; then
  ELAPSED=$(( (NOW_MS - LAST_HEAL_MS) / 1000 ))
  if (( ELAPSED < COOLDOWN_SEC )); then
    log "skip heal (cooldown ${ELAPSED}s/${COOLDOWN_SEC}s) reason=$REASON pid=${PID:-}"
    READINESS="cooldown"
    ESCALATE_HINT="cooldown_active: relaunch suppressed until COOLDOWN_SEC elapses (last heal too recent)."
    OK_SINCE=""
    write_state "cooldown" "$REASON" "none"
    exit 0
  fi
fi

# Q5: one beacon relaunch per outage. If the previous beacon relaunch did not restore the link the
# bot will send again; stop and escalate instead of looping (relaunch is not a WAN fix).
if [[ "${REASON}" == "beacon_request" && "$LAST_BEACON_MS" != "0" ]]; then
  BELAPSED=$(( (NOW_MS - LAST_BEACON_MS) / 1000 ))
  if (( BELAPSED < BEACON_RELAUNCH_WINDOW_SEC )); then
    log "beacon: second request ${BELAPSED}s after a beacon relaunch; not relaunching, escalate"
    READINESS="beacon_suppressed"
    ESCALATE_HINT="beacon_second_request: a beacon relaunch ${BELAPSED}s ago did not restore the link. Stop and escalate to a human; relaunch does not fix network, sign-in, or WAN."
    OK_SINCE=""
    write_state "beacon_suppressed" "beacon_request" "none"
    exit 0
  fi
fi

if [[ "${NEED_HEAL}" != "1" ]]; then
  log "ok reason=$REASON pid=${PID:-} heartbeat_age=${HEARTBEAT_AGE:-n/a} readiness=$READINESS"
  write_state "ok" "$REASON" "none"
  exit 0
fi

ORIG_REASON="$REASON"
log "heal start reason=$ORIG_REASON pid=${PID:-none} heartbeat_age=${HEARTBEAT_AGE:-n/a}"

if [[ -f "$REQUEST" ]]; then
  rm -f "$REQUEST"
  log "consumed operator request file ($REQUEST)"
fi

if [[ "$HEAL_DRY_RUN" == "1" ]]; then
  log "dry-run: skip quit/open"
  if [[ -n "${HEAL_SWAP_SUPPORT_ON_RELAUNCH:-}" ]]; then
    SUP="$HEAL_SWAP_SUPPORT_ON_RELAUNCH"
    log "dry-run: support dir swapped for readiness probe"
  fi
else
  if pgrep -f "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot" >/dev/null 2>&1; then
    log "gentle quit via AppleScript"
    osascript -e 'tell application "Grok Bot" to quit' >/dev/null 2>&1 || true
    for _i in $(seq 1 "$QUIT_WAIT_SEC"); do
      if ! pgrep -f "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if pgrep -f "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot" >/dev/null 2>&1; then
      log "force kill remaining Grok Bot main/helpers"
      pkill -f "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot" 2>/dev/null || true
      pkill -f "/Applications/Grok Bot.app/Contents/Frameworks/Grok Bot Helper" 2>/dev/null || true
      sleep 2
    fi
  fi

  log "open -ga Grok Bot"
  open -ga "Grok Bot" || open -a "Grok Bot"

  if [[ "$HEAL_CURSOR" == "1" ]]; then
    if ! pgrep -f "/Applications/Cursor.app/Contents/MacOS/Cursor" >/dev/null 2>&1; then
      log "Cursor down; open -ga Cursor (HEAL_CURSOR=1)"
      open -ga "Cursor" || true
    fi
  fi
fi

tries="$READINESS_WAIT_SEC"
if (( tries < 1 )); then tries=1; fi
ready_ok=0
i=1
while (( i <= tries )); do
  probe_ready
  if [[ "${R_READY:-0}" == "1" ]]; then
    ready_ok=1
    break
  fi
  if (( i < tries )) && [[ "$READINESS_POLL_SEC" != "0" ]]; then
    sleep "$READINESS_POLL_SEC"
  fi
  i=$((i + 1))
done

# Frozen/ok-streak bookkeeping resets after a relaunch attempt.
FROZEN_SINCE=""
OK_SINCE=""
UNCHANGED_FOR_SEC=""

if [[ "$ready_ok" == "1" ]]; then
  log "heal done status=healed reason=$ORIG_REASON new_pid=${PID:-} heartbeat_age=${HEARTBEAT_AGE:-n/a} boot=${BOOT:-}"
  READINESS="ready"
  ESCALATE_HINT=""
  write_state "healed" "$ORIG_REASON" "relaunch"
  exit 0
fi

if [[ "${R_ALIVE:-0}" == "1" ]]; then
  log "heal incomplete reason=$ORIG_REASON pid=${PID:-} heartbeat_age=${HEARTBEAT_AGE:-n/a} boot=${BOOT:-}"
  READINESS="incomplete"
  ESCALATE_HINT="readiness_timeout: process is up but heartbeat was not under ${HEARTBEAT_STALE_SEC}s and bootOutcome was not ready within ${READINESS_WAIT_SEC}s. Not marking healed."
  write_state "heal_incomplete" "$ORIG_REASON" "relaunch"
  exit 0
fi

log "heal failed: process did not come up reason=$ORIG_REASON"
READINESS="failed"
ESCALATE_HINT="heal_failed: Grok Bot process was not alive after relaunch and the readiness wait (${READINESS_WAIT_SEC}s)."
PID=""
HEARTBEAT_AGE=""
HEARTBEAT_AT_MS=""
BOOT=""
write_state "heal_failed" "$ORIG_REASON" "relaunch"
exit 0
