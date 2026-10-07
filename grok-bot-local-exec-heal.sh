#!/bin/bash
# Grok Bot local-exec self-heal (LaunchAgent). Kit 1.5.0 (+ optional worker-beacon poll,
# + helper-count observer for the S-NEW-D helper-exit signature).
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
# 1.5.0: counts Grok Bot Helper processes of the node.mojom.NodeService utility type under the
# main pid. One fewer than the learned (or configured) baseline for >= HELPER_MISSING_SEC is the
# S-NEW-D helper-exit signature (2026-10-07). LOG-ONLY by default (HEAL_ON_HELPER_MISSING=0).
#
# Cursor is NOT auto-relaunched (local-exec path is Grok Bot.app).
# Set HEAL_CURSOR=1 to also ensure Cursor.app is up.
set -euo pipefail

KIT_VERSION="1.5.0"
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

# --- helper-count observer (1.5.0) ---
# HELPER_CHECK=0 turns the scan off entirely.
HELPER_CHECK="${HELPER_CHECK:-1}"
# 0 = log-only (status=observe, reason=helper_missing, no relaunch). 1 = relaunch via the normal
# quit/open path (single-flight lock, COOLDOWN_SEC, one helper relaunch per HELPER_RELAUNCH_WINDOW_SEC).
HEAL_ON_HELPER_MISSING="${HEAL_ON_HELPER_MISSING:-0}"
# Helper count below the expected level for at least this long → helper_missing.
HELPER_MISSING_SEC="${HELPER_MISSING_SEC:-300}"
# Explicit expected helper count. Empty = use the baseline learned from the healthy state.
HELPER_EXPECTED="${HELPER_EXPECTED:-}"
# A count must hold this long, with the main pid locally healthy, before it becomes the baseline.
# The learned baseline only ever rises for a given main pid and resets when the pid changes.
HELPER_BASELINE_SEC="${HELPER_BASELINE_SEC:-600}"
HELPER_RELAUNCH_WINDOW_SEC="${HELPER_RELAUNCH_WINDOW_SEC:-3600}"
HELPER_NAME="${HELPER_NAME:-Grok Bot Helper}"
HELPER_SUBTYPE="${HELPER_SUBTYPE:-node.mojom.NodeService}"
# Observe-only: per helper, count ESTABLISHED TCP sockets to HELPER_SOCKET_PORT (lsof). Only counts
# are recorded; no addresses, hostnames or argv.
HELPER_SOCKET_CHECK="${HELPER_SOCKET_CHECK:-1}"
HELPER_SOCKET_PORT="${HELPER_SOCKET_PORT:-443}"
# Tests only: read canned `ps` / `lsof -F pn` output from these files instead of running the tools.
HELPER_PS_FILE="${HELPER_PS_FILE:-}"
HELPER_LSOF_FILE="${HELPER_LSOF_FILE:-}"
# Diagnostics snapshot on non-ok ticks (not ok / disabled). Rate-limited per status+reason.
HEAL_SNAPSHOT_DIR="${HEAL_SNAPSHOT_DIR:-}"
HEAL_SNAPSHOT_MIN_SEC="${HEAL_SNAPSHOT_MIN_SEC:-900}"
HEAL_SNAPSHOT_KEEP="${HEAL_SNAPSHOT_KEEP:-20}"

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
  out="$(H_CHECK="$HELPER_CHECK" H_HEAL="$HEAL_ON_HELPER_MISSING" H_MISSING_SEC="$HELPER_MISSING_SEC" \
    H_EXPECTED="$HELPER_EXPECTED" H_BASELINE_SEC="$HELPER_BASELINE_SEC" H_NAME="$HELPER_NAME" \
    H_SUBTYPE="$HELPER_SUBTYPE" H_SOCKET_CHECK="$HELPER_SOCKET_CHECK" H_SOCKET_PORT="$HELPER_SOCKET_PORT" \
    H_PS_FILE="$HELPER_PS_FILE" H_LSOF_FILE="$HELPER_LSOF_FILE" H_SCAN_OUT="$SCAN_FILE" \
    "$PYTHON" - \
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

# ---- helper-count observer (1.5.0, S-NEW-D helper-exit signature) ----
def env_int(name, default=None):
    v = os.environ.get(name, "")
    try:
        return int(str(v).strip()) if str(v).strip() != "" else default
    except Exception:
        return default

h_check = os.environ.get("H_CHECK", "1") == "1"
h_heal = os.environ.get("H_HEAL", "0") == "1"
h_missing_sec = float(env_int("H_MISSING_SEC", 300))
h_baseline_sec = float(env_int("H_BASELINE_SEC", 600))
h_expected_cfg = env_int("H_EXPECTED", None)
if h_expected_cfg is not None and h_expected_cfg < 0:
    h_expected_cfg = None
h_name = os.environ.get("H_NAME", "Grok Bot Helper") or "Grok Bot Helper"
h_sub = "--utility-sub-type=" + (os.environ.get("H_SUBTYPE", "node.mojom.NodeService") or "node.mojom.NodeService")
h_sock_check = os.environ.get("H_SOCKET_CHECK", "1") == "1"
h_sock_port = (os.environ.get("H_SOCKET_PORT", "443") or "").strip()

helper_count = None
helper_pids = []
helper_sockets = None
tree = []

def exe_name(cmd):
    # Executable name only, never argv: Grok Bot also spawns local-exec shells whose argv can
    # carry anything. App bundles: the name after /Contents/MacOS/ up to the first " --" flag.
    m = "/Contents/MacOS/"
    if m in cmd:
        return cmd.split(m, 1)[1].split(" --", 1)[0].strip()
    first = cmd.split(None, 1)[0] if cmd.split() else ""
    return os.path.basename(first)

def flag(tokens, prefix):
    for t in tokens:
        if t.startswith(prefix):
            return t[len(prefix):]
    return None

if h_check and alive and pid:
    lines = None
    ps_file = os.environ.get("H_PS_FILE", "")
    if ps_file:
        try:
            lines = open(ps_file).read().splitlines()
        except Exception:
            lines = None
    else:
        try:
            r = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,etime=,command="],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                lines = r.stdout.splitlines()
        except Exception:
            lines = None
    if lines is not None:
        helper_count = 0
        for ln in lines:
            parts = ln.split(None, 3)
            if len(parts) < 4:
                continue
            try:
                p_, pp_ = int(parts[0]), int(parts[1])
            except Exception:
                continue
            if p_ != pid and pp_ != pid:
                continue
            cmd = parts[3]
            exe = exe_name(cmd)
            toks = cmd.split()
            in_bundle = "/Contents/MacOS/" in cmd
            # Type flags only for app-bundle processes, and only a safe charset.
            ptype = flag(toks, "--type=") if in_bundle else None
            psub = flag(toks, "--utility-sub-type=") if in_bundle else None
            safe = lambda v: v if v is None or all(c.isalnum() or c in "._-" for c in v) else "?"
            ptype, psub = safe(ptype), safe(psub)
            # Snapshot keeps only pid, ppid, etime, exe basename and the two type flags: no argv,
            # no user-data-dir path (it carries the username), no handles or tokens.
            tree.append({"pid": p_, "ppid": pp_, "etime": parts[2], "exe": exe,
                         "type": ptype, "subType": psub})
            if pp_ == pid and in_bundle and exe.startswith(h_name) and h_sub in toks:
                helper_pids.append(p_)
        helper_pids.sort()
        helper_count = len(helper_pids)

    if h_sock_check and helper_pids:
        out_lines = None
        lsof_file = os.environ.get("H_LSOF_FILE", "")
        if lsof_file:
            try:
                out_lines = open(lsof_file).read().splitlines()
            except Exception:
                out_lines = None
        else:
            try:
                r = subprocess.run(["lsof", "-nP", "-a", "-p", ",".join(str(x) for x in helper_pids),
                                    "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"],
                                   capture_output=True, text=True, timeout=10)
                # lsof exits 1 when nothing matched; that is still a valid (empty) answer.
                if r.returncode in (0, 1):
                    out_lines = r.stdout.splitlines()
            except Exception:
                out_lines = None
        if out_lines is not None:
            helper_sockets = {str(x): 0 for x in helper_pids}
            cur = None
            for ln in out_lines:
                if ln.startswith("p"):
                    cur = ln[1:].strip()
                elif ln.startswith("n") and cur in helper_sockets and "->" in ln:
                    remote = ln[1:].split("->", 1)[1]
                    port = remote.rsplit(":", 1)[-1] if ":" in remote else ""
                    if not h_sock_port or port == h_sock_port:
                        helper_sockets[cur] += 1

same_pid = prev_pid is not None and pid is not None and prev_pid == pid
prev_bpid = as_int(prev.get("helperBaselinePid"))
carry = same_pid and prev_bpid == pid
baseline = as_int(prev.get("helperBaseline")) if carry else None
stable_count = as_int(prev.get("helperStableCount")) if carry else None
stable_since = as_int(prev.get("helperStableSinceMs")) if carry else None
locally_healthy = bool(
    alive and heartbeat_age is not None and heartbeat_age <= stale_sec
    and (not boot or boot == "ready") and not frozen_hit
)
if helper_count is not None:
    # The stability clock restarts whenever the count changes or the main pid is not locally healthy.
    if (not locally_healthy) or stable_count != helper_count or stable_since is None:
        stable_since = now_ms
    stable_count = helper_count
    if locally_healthy and (now_ms - stable_since) / 1000.0 >= h_baseline_sec:
        if baseline is None or helper_count > baseline:
            baseline = helper_count

if h_expected_cfg is not None:
    expected, expected_src = h_expected_cfg, "config"
elif baseline is not None:
    expected, expected_src = baseline, "learned"
else:
    expected, expected_src = None, None

missing_since = None
missing_for = None
helper_hit = False
if helper_count is not None and expected is not None and expected > 0 and helper_count < expected:
    pms = as_int(prev.get("helperMissingSinceMs")) if same_pid else None
    missing_since = pms if pms is not None else now_ms
    missing_for = (now_ms - missing_since) / 1000.0
    helper_hit = missing_for >= h_missing_sec
helper_observe = False

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
elif helper_hit and h_heal:
    need = True
    reason = "helper_missing"
    readiness = "helper_missing"
elif helper_hit:
    helper_observe = True
    reason = "helper_missing"
    readiness = "helper_missing_observe"
    hint = (
        "helper_missing (log-only): Grok Bot is up and its heartbeat is fresh, but only %d of %d "
        "%s helpers have run for %ds. This matches the S-NEW-D helper-exit signature (2026-10-07). "
        "Not relaunching because HEAL_ON_HELPER_MISSING=0. If cloud ListMachines.connected=false, "
        "POST a beacon heal-request, drop grok-bot-local-exec-heal.request, or set HEAL_ON_HELPER_MISSING=1."
        % (helper_count, expected, h_sub.split("=", 1)[1], int(missing_for))
    )
else:
    reason = "healthy"
    readiness = "local_healthy"
    if reason_bits:
        reason = reason + "+" + ",".join(reason_bits)

request_exists = os.path.isfile(request_path)
if request_exists:
    # Force relaunch even when local signals look healthy. Consumed by the shell on heal start.
    need = True
    helper_observe = False
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
emit("HELPER_OBSERVE", "1" if helper_observe else "0")
emit("HELPER_COUNT", "" if helper_count is None else str(helper_count))
emit("HELPER_EXPECTED_EFF", "" if expected is None else str(expected))
emit("HELPER_MISSING_FOR", "" if missing_for is None else str(int(missing_for)))

scan_out = os.environ.get("H_SCAN_OUT", "")
if scan_out:
    scan = {
        "helperCheck": h_check,
        "healOnHelperMissing": h_heal,
        "helperCount": helper_count,
        "helperPids": helper_pids if helper_count is not None else None,
        "helperExpected": expected,
        "helperExpectedSource": expected_src,
        "helperBaseline": baseline,
        "helperBaselinePid": pid if (baseline is not None or stable_count is not None) else None,
        "helperStableCount": stable_count,
        "helperStableSinceMs": stable_since,
        "helperMissingSinceMs": missing_since,
        "helperMissingForSec": missing_for,
        "helperSockets": helper_sockets,
        "tree": tree,
    }
    try:
        with open(scan_out, "w") as f:
            json.dump(scan, f)
    except Exception:
        pass
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
# stat flavour is found by probing, not by OS name (GNU coreutils stat can be first on PATH on macOS):
# `stat -c %a` (GNU), then `stat -f %Lp` (BSD/macOS). On GNU, `stat -f` is a filesystem stat that
# exits 0 with junk, so every result is validated strictly before use. Last resort: python, whose
# output is zero-padded so a short mode such as 040 is still judged (as too open) rather than unknown.
# BEACON_TEST_NO_PY_PERMS=1 disables the python fallback (tests only; it can only make this stricter).
token_file_mode() {
  local f="$1" m=""
  m="$(stat -c %a "$f" 2>/dev/null || true)"
  if [[ "$m" =~ ^[0-7]{3,4}$ ]]; then printf '%s\n' "$m"; return 0; fi
  m="$(stat -f %Lp "$f" 2>/dev/null || true)"
  if [[ "$m" =~ ^[0-7]{3,4}$ ]]; then printf '%s\n' "$m"; return 0; fi
  if [[ "${BEACON_TEST_NO_PY_PERMS:-0}" != "1" ]]; then
    m="$("$PYTHON" -c 'import os,stat,sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "03o"))' "$f" 2>/dev/null || true)"
    if [[ "$m" =~ ^[0-7]{3,4}$ ]]; then printf '%s\n' "$m"; return 0; fi
  fi
  return 0
}

# Sets BEACON_PENDING=1 only when the Worker returns exactly {"heal":true} (boolean true, sole key).
# Any failure is a no-op: a dead Worker must never block or trigger local heal.
beacon_poll() {
  BEACON_PENDING=0
  [[ -n "$BEACON_URL" && -n "$BEACON_POLL_TOKEN_FILE" && -n "$BEACON_MACHINE_ID" ]] || return 0
  # Fail closed: the poller bearer only ever goes over HTTPS (no http://, no other curl schemes).
  if [[ "$BEACON_URL" != https://?* ]]; then
    log "beacon: BEACON_URL is not https; refuse"
    return 0
  fi
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
  # Auth header via curl -K on stdin so the token never appears in any argv (ps): it reaches python
  # on stdin (printf is a builtin) and curl on stdin. Escape for curl config quotes.
  curl_cfg="$(printf '%s' "$token" | "$PYTHON" -c 'import sys
t = sys.stdin.read()
# Defense in depth: escape \ and " even though we already refused them above.
esc = t.replace("\\", "\\\\").replace("\"", "\\\"")
print("header = \"Authorization: Bearer " + esc + "\"")
')"
  resp="$(printf '%s\n' "$curl_cfg"     | "$BEACON_CURL" -sS --proto =https --max-time 10 -X POST -H 'content-type: application/json'         --data "$body" -K - "${BEACON_URL%/}/v1/poll" 2>/dev/null)" || { log "beacon: poll failed"; return 0; }
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
  W_KIT="$KIT_VERSION" W_APP="$APP_PATH" W_SCAN="${SCAN_FILE:-}" \
  W_SNAP_DIR="${HEAL_SNAPSHOT_DIR:-}" W_SNAP_MIN="$HEAL_SNAPSHOT_MIN_SEC" W_SNAP_KEEP="$HEAL_SNAPSHOT_KEEP" \
    "$PYTHON" - "$STATE" <<'PY'
import glob, json, os, sys, time

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
if action == "relaunch" and reason == "helper_missing":
    data["lastHelperHealAtMs"] = now_ms
elif prev.get("lastHelperHealAtMs"):
    data["lastHelperHealAtMs"] = prev.get("lastHelperHealAtMs")

# Helper-count observer fields (1.5.0). helperCount/helperPids/helperSockets are as observed at
# the start of this tick (before any relaunch).
scan = {}
scan_path = os.environ.get("W_SCAN", "")
if scan_path:
    try:
        with open(scan_path) as f:
            scan = json.load(f) or {}
    except Exception:
        scan = {}
tree = scan.pop("tree", []) if isinstance(scan, dict) else []
for k in ("helperCheck", "healOnHelperMissing", "helperCount", "helperPids", "helperExpected",
          "helperExpectedSource", "helperBaseline", "helperBaselinePid", "helperStableCount",
          "helperStableSinceMs", "helperMissingSinceMs", "helperMissingForSec", "helperSockets"):
    data[k] = scan.get(k)
if action == "relaunch":
    # New process: the learned baseline and missing clock belong to the old pid.
    for k in ("helperBaseline", "helperBaselinePid", "helperStableCount", "helperStableSinceMs",
              "helperMissingSinceMs", "helperMissingForSec"):
        data[k] = None

# Diagnostics snapshot on non-ok ticks, rate-limited per status+reason.
for k in ("lastSnapshotAtMs", "lastSnapshot", "lastSnapshotStatus", "lastSnapshotReason"):
    if prev.get(k) is not None:
        data[k] = prev.get(k)
if status not in ("ok", "disabled"):
    try:
        min_ms = int(float(os.environ.get("W_SNAP_MIN") or 900) * 1000)
    except Exception:
        min_ms = 900000
    try:
        keep = max(1, int(os.environ.get("W_SNAP_KEEP") or 20))
    except Exception:
        keep = 20
    last_at = pint(prev.get("lastSnapshotAtMs"))
    fresh = (
        prev.get("lastSnapshotStatus") != status
        or prev.get("lastSnapshotReason") != reason
        or last_at is None
        or now_ms - last_at >= min_ms
    )
    if fresh:
        snap_dir = os.environ.get("W_SNAP_DIR") or os.path.dirname(os.path.abspath(path))
        stamp = time.strftime("%Y%m%dT%H%M%S", time.localtime(now_ms / 1000.0)) + "-%03d" % (now_ms % 1000)
        name = "GrokBotLocalExecHeal-snap-%s.json" % stamp
        snap = {k: data.get(k) for k in (
            "kitVersion", "checkedAtMs", "checkedAtIso", "status", "reason", "action", "pid",
            "heartbeatAgeSec", "bootOutcome", "readiness", "escalateHint", "helperCount", "helperPids",
            "helperExpected", "helperExpectedSource", "helperMissingForSec", "helperSockets",
            "lastHealAtMs", "lastBeaconHealAtMs", "lastHelperHealAtMs")}
        snap["processTree"] = tree
        try:
            os.makedirs(snap_dir, exist_ok=True)
            with open(os.path.join(snap_dir, name), "w") as f:
                json.dump(snap, f, indent=2)
                f.write("\n")
            data["lastSnapshotAtMs"] = now_ms
            data["lastSnapshot"] = name
            data["lastSnapshotStatus"] = status
            data["lastSnapshotReason"] = reason
            snaps = sorted(glob.glob(os.path.join(snap_dir, "GrokBotLocalExecHeal-snap-*.json")))
            for old in snaps[:-keep]:
                try:
                    os.remove(old)
                except Exception:
                    pass
        except Exception:
            pass

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
SCAN_FILE="$(mktemp "${TMPDIR:-/tmp}/grok-heal-scan.XXXXXX" 2>/dev/null || true)"
trap 'rmdir "$LOCKDIR" 2>/dev/null || true; [[ -n "${SCAN_FILE:-}" ]] && rm -f "$SCAN_FILE"' EXIT

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
LAST_HELPER_MS=0
if [[ -f "$STATE" ]]; then
  LAST_HELPER_MS="$("$PYTHON" -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("lastHelperHealAtMs") or 0))
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
  HELPER_OBSERVE=0
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

# One helper_missing relaunch per outage window (same rule as beacon): if the previous helper
# relaunch did not bring the helper back, stop and escalate instead of looping.
if [[ "${REASON}" == "helper_missing" && "${NEED_HEAL}" == "1" && "$LAST_HELPER_MS" != "0" ]]; then
  HELAPSED=$(( (NOW_MS - LAST_HELPER_MS) / 1000 ))
  if (( HELAPSED < HELPER_RELAUNCH_WINDOW_SEC )); then
    log "helper_missing: helpers=${HELPER_COUNT:-?}/${HELPER_EXPECTED_EFF:-?} ${HELAPSED}s after a helper relaunch; not relaunching, escalate"
    READINESS="helper_suppressed"
    ESCALATE_HINT="helper_second_relaunch: a helper_missing relaunch ${HELAPSED}s ago did not restore the helper count. Stop and escalate to a human; if this app version runs fewer helpers, set HELPER_EXPECTED or HEAL_ON_HELPER_MISSING=0."
    OK_SINCE=""
    write_state "helper_suppressed" "helper_missing" "none"
    exit 0
  fi
fi

if [[ "${NEED_HEAL}" != "1" ]]; then
  if [[ "${HELPER_OBSERVE:-0}" == "1" ]]; then
    log "observe reason=helper_missing pid=${PID:-} helpers=${HELPER_COUNT:-?}/${HELPER_EXPECTED_EFF:-?} missing_for=${HELPER_MISSING_FOR:-?}s heal_on_helper_missing=0 (log-only)"
    write_state "observe" "helper_missing" "none"
    exit 0
  fi
  log "ok reason=$REASON pid=${PID:-} heartbeat_age=${HEARTBEAT_AGE:-n/a} readiness=$READINESS helpers=${HELPER_COUNT:-n/a}/${HELPER_EXPECTED_EFF:-n/a}"
  write_state "ok" "$REASON" "none"
  exit 0
fi

ORIG_REASON="$REASON"
log "heal start reason=$ORIG_REASON pid=${PID:-none} heartbeat_age=${HEARTBEAT_AGE:-n/a} helpers=${HELPER_COUNT:-n/a}/${HELPER_EXPECTED_EFF:-n/a}"

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
