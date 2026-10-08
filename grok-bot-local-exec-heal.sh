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
# quit/open path (single-flight lock, COOLDOWN_SEC). After that relaunch the old expected count
# stays a floor: while the live count is still short the kit stays helper_suppressed, including
# after HELPER_RELAUNCH_WINDOW_SEC. A beacon, operator, heartbeat-stale, or process-down
# relaunch keeps the same floor when a helper-short interval is already open. A later outage
# can relaunch only once the count has met the floor and the window has elapsed.
HEAL_ON_HELPER_MISSING="${HEAL_ON_HELPER_MISSING:-0}"
# Helper count below the expected level for at least this long → helper_missing.
HELPER_MISSING_SEC="${HELPER_MISSING_SEC:-300}"
# Explicit expected helper count. Empty = use the baseline learned from the healthy state.
HELPER_EXPECTED="${HELPER_EXPECTED:-}"
# A count is learned once, as the minimum positive count seen over this window after the
# pid appears. The window needs at least 3 healthy samples, not only elapsed time.
# A lower count updates that minimum only after 2 consecutive healthy ticks.
# The tick that would complete the window does not learn while its count is
# still below that minimum. An unhealthy tick does not seed it.
# An already-learned baseline is never raised or
# lowered. HELPER_EXPECTED wins when set. Values under 60s would store a blip;
# non-numeric falls back to 600.
HELPER_BASELINE_SEC="${HELPER_BASELINE_SEC:-600}"
HELPER_RELAUNCH_WINDOW_SEC="${HELPER_RELAUNCH_WINDOW_SEC:-3600}"
HELPER_NAME="${HELPER_NAME:-Grok Bot Helper}"
HELPER_SUBTYPE="${HELPER_SUBTYPE:-node.mojom.NodeService}"
# Observe-only: per helper, count ESTABLISHED TCP sockets to HELPER_SOCKET_PORT (lsof). Only counts
# are recorded; no addresses, hostnames or argv.
HELPER_SOCKET_CHECK="${HELPER_SOCKET_CHECK:-1}"
HELPER_SOCKET_PORT="${HELPER_SOCKET_PORT:-443}"
# Tests only, and only when HEAL_TEST_MODE=1: canned `ps` / `lsof -F pn` instead of the real tools.
# Production always calls /bin/ps and /usr/sbin/lsof. A test-mode bin override cannot be set from
# the LaunchAgent environment unless HEAL_TEST_MODE=1, which the template does not set.
HELPER_PS_FILE="${HELPER_PS_FILE:-}"
HELPER_LSOF_FILE="${HELPER_LSOF_FILE:-}"
PS_BIN="/bin/ps"
LSOF_BIN="/usr/sbin/lsof"
if [[ "${HEAL_TEST_MODE:-}" != "1" ]]; then
  HELPER_PS_FILE=""
  HELPER_LSOF_FILE=""
else
  if [[ -n "${HELPER_PS_BIN:-}" ]]; then PS_BIN="$HELPER_PS_BIN"; fi
  if [[ -n "${HELPER_LSOF_BIN:-}" ]]; then LSOF_BIN="$HELPER_LSOF_BIN"; fi
fi
# 0 would mean "missing on the first tick" / "no relaunch gap". Clamp to at least 1s.
if [[ ! "$HELPER_MISSING_SEC" =~ ^[0-9]+$ ]]; then
  HELPER_MISSING_SEC=300
elif (( HELPER_MISSING_SEC < 1 )); then
  HELPER_MISSING_SEC=1
fi
if [[ ! "$HELPER_RELAUNCH_WINDOW_SEC" =~ ^[0-9]+$ ]]; then
  HELPER_RELAUNCH_WINDOW_SEC=3600
elif (( HELPER_RELAUNCH_WINDOW_SEC < 1 )); then
  HELPER_RELAUNCH_WINDOW_SEC=1
fi
if [[ ! "$HELPER_BASELINE_SEC" =~ ^[0-9]+$ ]]; then
  HELPER_BASELINE_SEC=600
elif (( HELPER_BASELINE_SEC < 60 )); then
  HELPER_BASELINE_SEC=60
fi
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
    H_PS_BIN="$PS_BIN" H_LSOF_BIN="$LSOF_BIN" \
    H_APP_PATH="$APP_PATH" \
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
import json, math, os, glob, re, sys, subprocess, time, shlex

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
ds = None
ds_path = os.path.join(sup, "desktop-status.json")
if os.path.isfile(ds_path):
    try:
        ds = json.load(open(ds_path))
        raw = ds.get("pid") if isinstance(ds, dict) else None
        if raw is not None and str(raw).strip() != "":
            pid = int(raw)
    except Exception:
        ds = None
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
    spid_n = spid if isinstance(spid, (int, float)) and not isinstance(spid, bool) else None
    if isinstance(spid_n, float) and not math.isfinite(spid_n):
        spid_n = None
    if spid_n is not None and pid is not None:
        try:
            if int(spid_n) != int(pid):
                reason_bits.append("pid_mismatch_session_vs_desktop_status")
        except Exception:
            pass
    if newest[1].get("quitRequestedAtMs"):
        reason_bits.append("quit_requested")

# Allowlisted copies for diagnostics. Unknown keys (installId, tokens, paths) are dropped.
def pub_num(v):
    # inf/nan must not reach int() or the snapshot. A non-finite field used to
    # abort the whole tick (set -e, no last.json, no heal).
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if isinstance(v, float) and not math.isfinite(v):
        return None
    return v

def pub_token(v, limit=64):
    # Short identifiers only: version strings, bootOutcome. No paths, hosts, or addresses.
    if not isinstance(v, str) or not v or len(v) > limit:
        return None
    if any(c in v for c in "/\\@\n\r\t "):
        return None
    return v

def pub_child_deaths(v):
    # Counts only. A string, path, or unsafe key redacts the whole map (count kept).
    if v is None:
        return None
    if not isinstance(v, dict):
        return {"redacted": True}
    out = {}
    for k, val in v.items():
        key = pub_token(k, 64)
        if key is None:
            return {"count": len(v), "redacted": True}
        if isinstance(val, bool) or val is None:
            out[key] = val
        elif isinstance(val, (int, float)):
            if isinstance(val, float) and not math.isfinite(val):
                return {"count": len(v), "redacted": True}
            out[key] = val
        else:
            return {"count": len(v), "redacted": True}
    return out

desktop_pub = None
dune_pub = None
try:
    if isinstance(ds, dict):
        desktop_pub = {}
        if pub_num(ds.get("version")) is not None:
            desktop_pub["version"] = pub_num(ds.get("version"))
        if pub_num(ds.get("pid")) is not None:
            desktop_pub["pid"] = int(ds.get("pid"))
        av = pub_token(ds.get("appVersion"), 32)
        if av:
            desktop_pub["appVersion"] = av
        if pub_num(ds.get("startedAtMs")) is not None:
            desktop_pub["startedAtMs"] = int(ds.get("startedAtMs"))
        if isinstance(ds.get("signedIn"), bool):
            desktop_pub["signedIn"] = ds.get("signedIn")

    if newest:
        j = newest[1]
        dune_pub = {}
        if pub_num(j.get("pid")) is not None:
            dune_pub["pid"] = int(j.get("pid"))
        dune_pub["heartbeatAtMs"] = hb_ms
        bo = pub_token(boot, 32) if boot else None
        if bo:
            dune_pub["bootOutcome"] = bo
        if isinstance(j.get("mainFaultSeen"), bool):
            dune_pub["mainFaultSeen"] = j.get("mainFaultSeen")
        if "childDeaths" in j:
            dune_pub["childDeaths"] = pub_child_deaths(j.get("childDeaths"))
except Exception:
    # Diagnostics are a copy of the decision. They must not block a heal.
    desktop_pub = None
    dune_pub = None

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

app_path = (os.environ.get("H_APP_PATH", "") or "").rstrip("/")
h_subtype_value = h_sub.split("=", 1)[1]

# comm is an argv[0] the process can rewrite. Only the real Grok Bot names are stored.
# Helper suffixes are exactly (GPU), (Renderer), (Plugin), (Alerts). Anything else is other.
_KNOWN_EXE = re.compile(r"^Grok Bot(?: Helper(?: \((?:GPU|Renderer|Plugin|Alerts)\))?)?$")
_SNAP_TYPES = ("utility", "renderer", "gpu-process", "zygote", "other")
_SNAP_SUBTYPES = (
    "node.mojom.NodeService",
    "network.mojom.NetworkService",
    "storage.mojom.StorageService",
    "audio.mojom.AudioService",
    "video_capture.mojom.VideoCaptureService",
)

def exe_from_comm(comm):
    base = os.path.basename((comm or "").strip())
    if _KNOWN_EXE.match(base):
        return base
    return "other"

def snap_type(value):
    if value in _SNAP_TYPES:
        return value
    return "other"

def snap_subtype(value):
    if value in _SNAP_SUBTYPES:
        return value
    return None

def safe_flag(value):
    if value is None:
        return None
    if value and all(c.isalnum() or c in "._-" for c in value):
        return value
    return None

def under_app(command):
    # argv0 must be the app bundle Contents tree. A shell that only quotes
    # "$APP/Contents/..." later in the command is not a helper.
    if not command or not app_path:
        return False
    return command.startswith(app_path + "/Contents/")

def parse_ps_line(ln):
    # "pid ppid etime comm \\t command". comm may contain spaces. command is optional
    # and is discarded unless argv0 is inside the app path.
    left, sep, command = ln.partition("\t")
    m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$", left)
    if not m:
        return None
    try:
        p_ = int(m.group(1))
        pp_ = int(m.group(2))
    except Exception:
        return None
    return p_, pp_, m.group(3), m.group(4).strip(), (command.strip() if sep else "")

def allowlisted_flags(command):
    # Whole tokens only. Anything that is not --type / --utility-sub-type is dropped.
    ptype = None
    psub = None
    for tok in command.split():
        if tok.startswith("--type="):
            ptype = safe_flag(tok[len("--type="):])
        elif tok.startswith("--utility-sub-type="):
            psub = safe_flag(tok[len("--utility-sub-type="):])
    return ptype, psub

try:
    if h_check and alive and pid:
        rows = None
        ps_file = os.environ.get("H_PS_FILE", "")
        if ps_file:
            try:
                rows = []
                for ln in open(ps_file).read().splitlines():
                    parsed = parse_ps_line(ln)
                    if parsed:
                        rows.append(parsed)
            except Exception:
                rows = None
        else:
            try:
                ps_bin = os.environ.get("H_PS_BIN") or "/bin/ps"
                # Two calls on purpose. exe comes from comm, and the command line is
                # read only for app-path processes. One ps line cannot split those
                # safely when comm contains spaces (slicing it would put argv back
                # into the snapshot). A helper that starts or exits between the two
                # calls can be miscounted for this tick only. HELPER_MISSING_SEC and
                # HELPER_BASELINE_SEC are both much longer than one tick, so that
                # skew cannot by itself open helper_missing or become the learned baseline.
                rc = subprocess.run([ps_bin, "-axww", "-o", "pid=,ppid=,etime=,comm="],
                                    capture_output=True, text=True, timeout=10)
                rcmd = subprocess.run([ps_bin, "-axww", "-o", "pid=,command="],
                                      capture_output=True, text=True, timeout=10)
                if rc.returncode == 0 and rcmd.returncode == 0:
                    commands = {}
                    for ln in rcmd.stdout.splitlines():
                        m = re.match(r"\s*(\d+)\s+(.*)$", ln)
                        if m:
                            commands[int(m.group(1))] = m.group(2).strip()
                    rows = []
                    for ln in rc.stdout.splitlines():
                        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$", ln)
                        if not m:
                            continue
                        p_ = int(m.group(1))
                        cmd = commands.get(p_, "")
                        # Keep the command string only long enough to classify app-path processes.
                        if not under_app(cmd):
                            cmd = ""
                        rows.append((p_, int(m.group(2)), m.group(3), m.group(4).strip(), cmd))
            except Exception:
                rows = None
        if rows is not None:
            helper_count = 0
            for p_, pp_, etime, comm, cmd in rows:
                if p_ != pid and pp_ != pid:
                    continue
                in_app = under_app(cmd)
                if in_app:
                    ptype, raw_sub = allowlisted_flags(cmd)
                    ptype = snap_type(ptype)
                    # Count uses the raw subtype so a custom HELPER_SUBTYPE still matches.
                    # The stored field is the allowlist only, so an unknown subtype
                    # cannot land in a snapshot.
                    psub = snap_subtype(raw_sub)
                else:
                    ptype, raw_sub, psub = "other", None, None
                    cmd = ""
                exe = exe_from_comm(comm)
                tree.append({"pid": p_, "ppid": pp_, "etime": etime, "exe": exe,
                             "type": ptype, "subType": psub})
                if pp_ == pid and in_app and exe.startswith(h_name) and raw_sub == h_subtype_value:
                    helper_pids.append(p_)
            helper_pids.sort()
            helper_count = len(helper_pids)
except Exception:
    # A helper-scan failure must not abort the tick. Unknown count is not missing.
    helper_count = None
    helper_pids = []
    helper_sockets = None
    tree = []


helper_none_seen = None
if helper_count is not None:
    helper_none_seen = helper_count == 0

same_pid = prev_pid is not None and pid is not None and prev_pid == pid
prev_bpid = as_int(prev.get("helperBaselinePid"))
prev_baseline = as_int(prev.get("helperBaseline"))
prev_missing_was = as_int(prev.get("helperMissingSinceMs"))
prev_floor_pending = prev.get("helperFloorPending") is True
# Config expected counts even when nothing has been learned. A pid change while
# short must carry that number, not only a learned baseline.
carry_count = None
if h_expected_cfg is not None and h_expected_cfg > 0:
    carry_count = h_expected_cfg
elif prev_baseline is not None and prev_baseline > 0:
    carry_count = prev_baseline
# A helper_missing relaunch, or a pid change while helpers are still short, keeps the
# old expected count as a floor. Do not learn the short count as the new healthy baseline.
floor_carry = (
    (not same_pid)
    and carry_count is not None
    and (prev_missing_was is not None or prev_floor_pending)
)
if same_pid and prev_bpid == pid:
    baseline = prev_baseline
    stable_count = as_int(prev.get("helperStableCount"))
    stable_since = as_int(prev.get("helperStableSinceMs"))
    healthy_samples = as_int(prev.get("helperHealthySamples")) or 0
elif floor_carry:
    baseline = prev_baseline
    stable_count = None
    stable_since = None
    healthy_samples = 0
else:
    baseline = None
    stable_count = None
    stable_since = None
    healthy_samples = 0
locally_healthy = bool(
    alive and heartbeat_age is not None and heartbeat_age <= stale_sec
    and (not boot or boot == "ready") and not frozen_hit
)
# Running minimum of positive counts on this pid. helperStableCount is that
# minimum. helperStableSinceMs is the window start. helperHealthySamples counts
# healthy ticks in the window. The window starts at the first locally healthy
# sample and is not reset when the count changes. A higher count does not move
# the minimum. A lower count moves it only after two consecutive healthy ticks
# at that count, so one blip does not lock the low value in. The tick that
# would complete the window does not learn while its count is still below
# that minimum. A count of 0 is not a candidate and is never learned. Learn
# once, after HELPER_BASELINE_SEC and at least 3 healthy samples, as that
# minimum. An already-learned baseline
# is never raised or lowered. Do not learn while the process is not locally
# healthy (a relaunch is in progress; that tick does not seed the minimum) or
# while this count is already below a prior expected count (config, or an
# existing baseline). That short interval is the grace period.
prior_expected = None
if h_expected_cfg is not None and h_expected_cfg > 0:
    prior_expected = h_expected_cfg
elif baseline is not None and baseline > 0:
    prior_expected = baseline
below_prior = (
    helper_count is not None
    and prior_expected is not None
    and helper_count < prior_expected
)
if helper_count is not None:
    if not locally_healthy:
        stable_since = now_ms
        stable_count = None
        healthy_samples = 0
    elif helper_count > 0 and not below_prior:
        prev_samples = as_int(prev.get("helperHealthySamples")) if same_pid else None
        prev_count = as_int(prev.get("helperCount")) if same_pid else None
        if stable_count is None or stable_count <= 0:
            # First healthy sample. An unhealthy tick stamps the clock but
            # must not start the window or seed the minimum.
            if stable_since is None or not prev_samples:
                stable_since = now_ms
            stable_count = helper_count
        elif (
            helper_count < stable_count
            and prev_count == helper_count
            and prev_samples
        ):
            stable_count = helper_count
        healthy_samples = healthy_samples + 1
        # A window-completing tick whose count is still below the minimum
        # must not learn. One low sample stays a blip.
        if (
            baseline is None
            and stable_count is not None
            and stable_count > 0
            and helper_count >= stable_count
            and stable_since is not None
            and healthy_samples >= 3
            and (now_ms - stable_since) / 1000.0 >= h_baseline_sec
        ):
            baseline = stable_count

if h_expected_cfg is not None:
    expected, expected_src = h_expected_cfg, "config"
elif baseline is not None:
    expected, expected_src = baseline, "learned"
else:
    expected, expected_src = None, None

floor_pending = prev_floor_pending if (same_pid or floor_carry) else False
missing_since = None
missing_for = None
helper_hit = False
if helper_count is not None and expected is not None and expected > 0 and helper_count >= expected:
    floor_pending = False
elif helper_count is not None and expected is not None and expected > 0 and helper_count < expected:
    # Same pid keeps the open clock. An external pid change (floor_carry) restarts
    # it so the new process gets a fresh HELPER_MISSING_SEC of grace.
    if same_pid and prev_missing_was is not None:
        missing_since = prev_missing_was
    else:
        missing_since = now_ms
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
    # Alphanumeric, dash, underscore only, and only the first 32 characters.
    # A raw bootOutcome must not land unbounded in reason, the log, or a snapshot.
    raw_boot = str(boot)[:32]
    token = "".join(ch if (ch.isalnum() or ch in "-_") else "_" for ch in raw_boot) or "unknown"
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
        "%s helpers have been present for %ds (2026-10-07 helper-exit shape). "
        "This tick does not relaunch. cloud ListMachines.connected is not visible from the Mac. "
        "A beacon heal-request or grok-bot-local-exec-heal.request still relaunches."
        % (helper_count, expected, h_subtype_value, int(missing_for))
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
# The long-ok S-NEW-D hint wins when both apply. Zero helpers on a long healthy
# streak is still the cloud-invisible case; helperNoneSeen stays set either way.
if helper_none_seen and str(reason).startswith("healthy") and not hint:
    hint = (
        "helper_none_seen: no node.mojom.NodeService helper is a child of this pid. "
        "A renamed helper binary would look the same, so helper_missing cannot learn a baseline of 0. "
        "Not relaunching from this flag alone."
    )
# Log and state only. A learned 1 with no operator expected count must not
# change status, action, or whether this tick relaunches. The long-ok hint
# stays in place when it is already set.
helper_baseline_low = bool(
    baseline == 1 and not (h_expected_cfg is not None and h_expected_cfg > 0)
)
if helper_baseline_low and str(reason).startswith("healthy") and not hint:
    hint = (
        "helper_baseline_low: learned helper baseline is 1 and HELPER_EXPECTED is unset. "
        "Set HELPER_EXPECTED=2 for the live-baseline week if this Mac runs two NodeService helpers. "
        "This flag does not relaunch."
    )

# Socket counts only on ticks that will snapshot (not every healthy tick).
# macOS lsof 4.91 exits 1 with empty stdout and empty stderr when none of the
# pids has an ESTABLISHED TCP socket. That is the zero-socket outage, not a
# failed scan. Exit 1 with stderr, or any other non-zero exit, leaves the field null.
want_sockets = h_sock_check and helper_pids and (need or helper_observe)
if want_sockets:
    out_lines = None
    lsof_ok = False
    lsof_file = os.environ.get("H_LSOF_FILE", "")
    if lsof_file:
        try:
            out_lines = open(lsof_file).read().splitlines()
            lsof_ok = True
        except Exception:
            out_lines = None
    else:
        try:
            lsof_bin = os.environ.get("H_LSOF_BIN") or "/usr/sbin/lsof"
            r = subprocess.run([lsof_bin, "-nP", "-a", "-p", ",".join(str(x) for x in helper_pids),
                                "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"],
                               capture_output=True, text=True, timeout=10)
            no_match = r.returncode == 1 and not (r.stderr or "").strip()
            if r.returncode == 0 or no_match:
                out_lines = (r.stdout or "").splitlines()
                lsof_ok = True
        except Exception:
            out_lines = None
    if lsof_ok and out_lines is not None:
        helper_sockets = {str(x): 0 for x in helper_pids}
        cur = None
        for ln in out_lines:
            if ln.startswith("p") and len(ln) > 1 and ln[1:].strip().isdigit():
                cur = ln[1:].strip()
            elif ln.startswith("n") and cur in helper_sockets and "->" in ln:
                remote = ln[1:].split("->", 1)[1]
                port = remote.rsplit(":", 1)[-1] if ":" in remote else ""
                if not h_sock_port or port == h_sock_port:
                    helper_sockets[cur] += 1

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
boot_pub = pub_token(boot, 32) if boot else None
emit("BOOT", "" if not boot_pub else str(boot_pub))
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
emit("HELPER_FLOOR_PENDING", "1" if floor_pending else "0")
emit("HELPER_BASELINE_LOW", "1" if helper_baseline_low else "0")

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
        "helperHealthySamples": healthy_samples,
        "helperMissingSinceMs": missing_since,
        "helperMissingForSec": missing_for,
        "helperSockets": helper_sockets,
        "helperFloorPending": floor_pending,
        "helperNoneSeen": helper_none_seen,
        "helperBaselineLow": helper_baseline_low,
        "desktopStatus": desktop_pub,
        "dune": dune_pub,
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
          "helperStableSinceMs", "helperHealthySamples", "helperMissingSinceMs", "helperMissingForSec", "helperSockets",
          "helperFloorPending", "helperNoneSeen", "helperBaselineLow"):
    data[k] = scan.get(k)
# .disable and app_missing return before the scan. An empty scan must not wipe a
# learned baseline or an open missing clock. A relaunch still has its own rules below.
if action != "relaunch" and "helperCheck" not in scan:
    for k in ("helperExpected", "helperExpectedSource", "helperBaseline", "helperBaselinePid",
              "helperStableCount", "helperStableSinceMs", "helperHealthySamples", "helperMissingSinceMs",
              "helperMissingForSec", "helperFloorPending", "helperBaselineLow"):
        if k in prev and data.get(k) is None:
            data[k] = prev.get(k)
def short_interval_open(scan_obj, prev_obj):
    # This tick saw the count below expected.
    if scan_obj.get("helperMissingSinceMs") is not None:
        return True
    # Not scanned (process down, or ps failed). An interval already open, or a
    # floor already pending, is still the best knowledge we have.
    if scan_obj.get("helperCount") is None and (
        prev_obj.get("helperMissingSinceMs") is not None or prev_obj.get("helperFloorPending") is True
    ):
        return True
    return False

def arm_helper_floor(data_obj, prev_obj, new_pid):
    # Keep the pre-relaunch expected count as a floor on the new pid. Restart the
    # missing grace, but do not store the short count as a learned baseline.
    if data_obj.get("helperBaseline") is None:
        kept = prev_obj.get("helperBaseline")
        if isinstance(kept, int) and not isinstance(kept, bool) and kept > 0:
            data_obj["helperBaseline"] = kept
    data_obj["helperFloorPending"] = True
    if new_pid is not None:
        data_obj["helperBaselinePid"] = new_pid
    data_obj["helperStableCount"] = None
    data_obj["helperStableSinceMs"] = None
    data_obj["helperHealthySamples"] = None
    data_obj["helperMissingSinceMs"] = None
    data_obj["helperMissingForSec"] = None

if action == "relaunch" and (reason == "helper_missing" or short_interval_open(scan, prev)):
    # helper_missing, and also beacon / operator / heartbeat_stale / process_down
    # when a helper-short interval is still open. A relaunch that is not short
    # still clears the floor below.
    arm_helper_floor(data, prev, pint(pid))
elif action == "relaunch":
    for k in ("helperBaseline", "helperBaselinePid", "helperStableCount", "helperStableSinceMs",
              "helperHealthySamples", "helperMissingSinceMs", "helperMissingForSec", "helperFloorPending"):
        data[k] = None
    data["helperBaselineLow"] = False

# Diagnostics snapshot on non-ok ticks, rate-limited per status+reason.
for k in ("lastSnapshotAtMs", "lastSnapshot", "lastSnapshotStatus", "lastSnapshotReason",
          "snapshotBackoffMs"):
    if prev.get(k) is not None:
        data[k] = prev.get(k)
# An ok tick clears the doubled gap. The next outage starts again at
# HEAL_SNAPSHOT_MIN_SEC instead of waiting out a backoff that grew to 4h.
if status == "ok":
    data["snapshotBackoffMs"] = None
if status not in ("ok", "disabled"):
    try:
        min_ms = int(float(os.environ.get("W_SNAP_MIN") or 900) * 1000)
    except Exception:
        min_ms = 900000
    try:
        keep = max(1, int(os.environ.get("W_SNAP_KEEP") or 20))
    except Exception:
        keep = 20
    def snap_key(value):
        # heartbeat_stale_<seconds>s changes every tick; rate-limit on the class.
        text = "" if value is None else str(value)
        if text.startswith("heartbeat_stale_"):
            return "heartbeat_stale"
        return text

    last_at = pint(prev.get("lastSnapshotAtMs"))
    # Same status+reason backs off: 900s, then double, capped at 4h.
    cap_ms = 4 * 3600 * 1000
    same_class = (
        prev.get("lastSnapshotStatus") == status
        and snap_key(prev.get("lastSnapshotReason")) == snap_key(reason)
        and last_at is not None
    )
    gap_ms = min_ms
    if same_class:
        stored_gap = pint(prev.get("snapshotBackoffMs"))
        if stored_gap is not None and stored_gap >= min_ms:
            gap_ms = stored_gap
    fresh = (not same_class) or (now_ms - last_at >= gap_ms)
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
        snap["processTreeAt"] = "tick_start"
        snap["phase"] = "tick"
        snap["desktopStatus"] = scan.get("desktopStatus")
        snap["dune"] = scan.get("dune")
        try:
            os.makedirs(snap_dir, exist_ok=True)
            os.chmod(snap_dir, 0o700)
            dest = os.path.join(snap_dir, name)
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(snap, f, indent=2)
                f.write("\n")
            os.chmod(dest, 0o600)
            os.chmod(snap_dir, 0o700)
            data["lastSnapshotAtMs"] = now_ms
            data["lastSnapshot"] = name
            data["lastSnapshotStatus"] = status
            data["lastSnapshotReason"] = reason
            if same_class:
                data["snapshotBackoffMs"] = min(gap_ms * 2, cap_ms)
            else:
                data["snapshotBackoffMs"] = min_ms
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

# Write the diagnostics snapshot BEFORE quit/open. The scan file already holds the
# pre-relaunch process tree and allowlisted status fields. Outcome snapshots still
# go through write_state after the readiness gate; this file is the detection record.
snapshot_before_relaunch() {
  local name
  name="$(W_SCAN="${SCAN_FILE:-}" \
    W_SNAP_DIR="${HEAL_SNAPSHOT_DIR:-$(dirname "$STATE")}" \
    W_REASON="${ORIG_REASON:-}" W_PID="${PID:-}" W_AGE="${HEARTBEAT_AGE:-}" \
    W_BOOT="${BOOT:-}" W_READINESS="${READINESS:-}" W_HINT="${ESCALATE_HINT:-}" \
    W_KIT="$KIT_VERSION" W_KEEP="${HEAL_SNAPSHOT_KEEP:-20}" \
    "$PYTHON" - <<'PY'
import glob, json, os, sys, time

scan_path = os.environ.get("W_SCAN", "")
scan = {}
if scan_path:
    try:
        with open(scan_path) as f:
            scan = json.load(f) or {}
    except Exception:
        scan = {}
if not isinstance(scan, dict):
    scan = {}
tree = scan.get("tree") or []
if os.environ.get("HEAL_NOW_MS"):
    now_ms = int(os.environ["HEAL_NOW_MS"])
else:
    now_ms = int(time.time() * 1000)
iso = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now_ms / 1000.0))
snap_dir = os.environ.get("W_SNAP_DIR") or "."
try:
    keep = max(1, int(os.environ.get("W_KEEP") or 20))
except Exception:
    keep = 20

def pfloat(s):
    try:
        if s is None or str(s).strip() == "":
            return None
        return float(s)
    except Exception:
        return None

def pint(s):
    try:
        if s is None or str(s).strip() == "":
            return None
        return int(str(s).strip())
    except Exception:
        return None

stamp = time.strftime("%Y%m%dT%H%M%S", time.localtime(now_ms / 1000.0)) + "-%03d" % (now_ms % 1000)
name = "GrokBotLocalExecHeal-snap-%s-before.json" % stamp
snap = {
    "phase": "before_relaunch",
    "processTreeAt": "tick_start",
    "kitVersion": os.environ.get("W_KIT", ""),
    "checkedAtMs": now_ms,
    "checkedAtIso": iso,
    "status": "pre_relaunch",
    "reason": os.environ.get("W_REASON", ""),
    "action": "relaunch",
    "pid": pint(os.environ.get("W_PID", "")),
    "heartbeatAgeSec": pfloat(os.environ.get("W_AGE", "")),
    "bootOutcome": os.environ.get("W_BOOT") or None,
    "readiness": os.environ.get("W_READINESS") or None,
    "escalateHint": os.environ.get("W_HINT") or None,
    "helperCount": scan.get("helperCount"),
    "helperPids": scan.get("helperPids"),
    "helperExpected": scan.get("helperExpected"),
    "helperExpectedSource": scan.get("helperExpectedSource"),
    "helperMissingForSec": scan.get("helperMissingForSec"),
    "helperSockets": scan.get("helperSockets"),
    "desktopStatus": scan.get("desktopStatus"),
    "dune": scan.get("dune"),
    "processTree": tree,
}
os.makedirs(snap_dir, exist_ok=True)
os.chmod(snap_dir, 0o700)
dest = os.path.join(snap_dir, name)
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(snap, f, indent=2)
    f.write("\n")
os.chmod(dest, 0o600)
os.chmod(snap_dir, 0o700)
snaps = sorted(glob.glob(os.path.join(snap_dir, "GrokBotLocalExecHeal-snap-*.json")))
for old in snaps[:-keep]:
    try:
        os.remove(old)
    except Exception:
        pass
print(name)
PY
)" || true
  if [[ -n "${name:-}" ]]; then
    log "snapshot before relaunch: $name"
  fi
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
if [[ -z "${SCAN_FILE:-}" ]]; then
  log "warning: mktemp failed; helper fields will not be recorded from this tick's scan"
fi
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
if [[ "${HELPER_BASELINE_LOW:-0}" == "1" ]]; then
  log "helper_baseline_low: learned baseline is 1 and HELPER_EXPECTED is unset; set HELPER_EXPECTED=2 for the live-baseline week"
fi

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

# Floor suppression before cooldown. Both can apply after a recent heal; the status
# should say the count is still short, not that the 300s cooldown is the reason.
if [[ "${REASON}" == "helper_missing" && "${NEED_HEAL}" == "1" ]]; then
  HELPER_SUPPRESS=0
  HELAPSED=0
  if [[ "$LAST_HELPER_MS" != "0" ]]; then
    HELAPSED=$(( (NOW_MS - LAST_HELPER_MS) / 1000 ))
  fi
  if [[ "${HELPER_FLOOR_PENDING:-0}" == "1" ]]; then
    HELPER_SUPPRESS=1
  elif [[ "$LAST_HELPER_MS" != "0" && "$HELAPSED" -lt "$HELPER_RELAUNCH_WINDOW_SEC" ]]; then
    HELPER_SUPPRESS=1
  fi
  if [[ "$HELPER_SUPPRESS" == "1" ]]; then
    log "helper_missing: helpers=${HELPER_COUNT:-?}/${HELPER_EXPECTED_EFF:-?} still short ${HELAPSED}s after a helper relaunch; not relaunching, escalate"
    READINESS="helper_suppressed"
    ESCALATE_HINT="helper_suppressed: the helper count is still below the floor after a helper_missing relaunch. Staying suppressed (not learning the lower count, not relaunching again) until the live count meets the floor."
    OK_SINCE=""
    write_state "helper_suppressed" "helper_missing" "none"
    exit 0
  fi
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
snapshot_before_relaunch

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
