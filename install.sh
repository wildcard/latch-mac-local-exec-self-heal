#!/bin/bash
# Install Latch Grok Bot local-exec self-heal (LaunchAgent) on this Mac.
# Safe to re-run. Does not require a cloud agent to be online after install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:?}"
BIN_DIR="$HOME_DIR/Library/Application Support/Latch/bin"
LAUNCH_DIR="$HOME_DIR/Library/LaunchAgents"
LOG_DIR="$HOME_DIR/Library/Logs"
LABEL="com.latch.grok-bot-local-exec-heal"
SCRIPT_SRC="$ROOT/grok-bot-local-exec-heal.sh"
PLIST_TMPL="$ROOT/com.latch.grok-bot-local-exec-heal.plist.tmpl"
SCRIPT_DST="$BIN_DIR/grok-bot-local-exec-heal.sh"
PLIST_DST="$LAUNCH_DIR/${LABEL}.plist"
VERSION_FILE="$ROOT/VERSION"

# Stage 0 intentionally demotes old active/helper settings on every default install.
INSTALL_RECOVERY_MODE="${INSTALL_RECOVERY_MODE:-observe}"
INSTALL_HELPER_HEAL="${INSTALL_HELPER_HEAL:-0}"
if [[ "$INSTALL_RECOVERY_MODE" != "observe" && "$INSTALL_RECOVERY_MODE" != "active" ]] || \
   [[ "$INSTALL_HELPER_HEAL" != "0" && "$INSTALL_HELPER_HEAL" != "1" ]] || \
   [[ "$INSTALL_HELPER_HEAL" == "1" && "$INSTALL_RECOVERY_MODE" != "active" ]]; then
  echo "Invalid recovery opt-in: use INSTALL_RECOVERY_MODE=observe|active and INSTALL_HELPER_HEAL=0|1 (helper heal requires active)." >&2
  exit 2
fi

# INSTALL_SKIP_LAUNCHD=1 is for hermetic tests only: write files, touch no LaunchAgent, run no heal.
# Also skips the Darwin-only gate so merge/plist logic can be exercised on Linux CI.
SKIP_LAUNCHD=0
if [[ "${INSTALL_SKIP_LAUNCHD:-0}" == "1" ]]; then
  SKIP_LAUNCHD=1
fi

if [[ "$(uname -s)" != "Darwin" && "$SKIP_LAUNCHD" != "1" ]]; then
  echo "This installer is macOS-only." >&2
  exit 1
fi

if [[ ! -f "$PLIST_TMPL" ]]; then
  echo "Missing plist template: $PLIST_TMPL" >&2
  exit 1
fi

PYTHON="${PYTHON:-/usr/bin/python3}"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3 || true)"
fi
if [[ -z "${PYTHON}" || ! -x "$PYTHON" ]]; then
  echo "python3 is required for plist merge/lint." >&2
  exit 1
fi

if [[ "$SKIP_LAUNCHD" != "1" && ! -d "/Applications/Grok Bot.app" ]]; then
  echo "Warning: /Applications/Grok Bot.app not found. Install Grok Bot first; heal will no-op until it exists." >&2
fi

# Preparation renders a complete candidate outside the installed tree. HOME is
# still the real target home so ProgramArguments/log paths remain exact.
EXISTING_PLIST="$PLIST_DST"
PREPARE_DIR="${INSTALL_PREPARE_DIR:-}"
if [[ -n "$PREPARE_DIR" ]]; then
  if [[ -e "$PREPARE_DIR" || -L "$PREPARE_DIR" ]]; then
    echo "Preparation destination must not exist." >&2
    exit 2
  fi
  umask 077
  mkdir -m 700 "$PREPARE_DIR"
  BIN_DIR="$PREPARE_DIR/bin"
  LAUNCH_DIR="$PREPARE_DIR"
  LOG_DIR="$PREPARE_DIR/logs"
  SCRIPT_DST="$BIN_DIR/grok-bot-local-exec-heal.sh"
  PLIST_DST="$LAUNCH_DIR/${LABEL}.plist"
  SKIP_LAUNCHD=1
fi

mkdir -p "$BIN_DIR" "$LAUNCH_DIR" "$LOG_DIR"

# Keep operator-set EnvironmentVariables across reinstalls.
# Operator tunables (*SEC, BEACON_*, custom keys) win except Stage 0 recovery gates.
# Kit-owned PATH and Stage 0 RECOVERY_MODE/HEAL_ON_HELPER_MISSING come from this install unless INSTALL_RESET_ENV=1 (full wipe to template).
# HEAL_TEST_MODE is never preserved and is removed if an existing plist has it.
# Merge into a temp file in LAUNCH_DIR, lint, then mv into place. Merge failure leaves
# the existing plist untouched and exits non-zero before any launchctl bootstrap.
NEW_PLIST="$(mktemp "${LAUNCH_DIR}/${LABEL}.plist.new.XXXXXX")"
OLD_PLIST=""
cleanup_install_temps() {
  [[ -n "${NEW_PLIST:-}" ]] && rm -f "$NEW_PLIST"
  [[ -n "${OLD_PLIST:-}" ]] && rm -f "$OLD_PLIST"
  return 0
}
trap cleanup_install_temps EXIT

"$PYTHON" - "$PLIST_TMPL" "$NEW_PLIST" "$HOME_DIR" <<'PYRENDER'
import plistlib, sys
source, target, home = sys.argv[1:]
def render(value):
    if isinstance(value, str):
        return value.replace("__HOME__", home)
    if isinstance(value, list):
        return [render(v) for v in value]
    if isinstance(value, dict):
        return {k: render(v) for k, v in value.items()}
    return value
with open(source, "rb") as handle:
    data = render(plistlib.load(handle))
with open(target, "wb") as handle:
    plistlib.dump(data, handle)
PYRENDER

if [[ -f "$EXISTING_PLIST" && "${INSTALL_RESET_ENV:-0}" != "1" ]]; then
  OLD_PLIST="$(mktemp "${LAUNCH_DIR}/${LABEL}.plist.old.XXXXXX")"
  cp "$EXISTING_PLIST" "$OLD_PLIST"
  # INSTALL_TEST_MERGE_FAIL=1 is for hermetic tests only: force the merge step to fail.
  if ! "$PYTHON" - "$OLD_PLIST" "$NEW_PLIST" <<'PY'
import os, plistlib, sys

if os.environ.get("INSTALL_TEST_MERGE_FAIL") == "1":
    sys.exit(1)

# PATH is kit-owned (template wins). HEAL_TEST_MODE is a test hook and is never
# preserved, and is stripped if a plist already has it. All other string keys from
# the existing plist are preserved over template defaults: documented tunables
# (HEAL_CURSOR, *SEC, HEAL_ON_STUCK_SESSION, BEACON_*), plus any custom operator keys.
# Set INSTALL_RESET_ENV=1 to wipe back to the template.
KIT_OWNED = {"PATH", "RECOVERY_MODE", "HEAL_ON_HELPER_MISSING"}
DROP = {"HEAL_TEST_MODE"}

old_path, new_path = sys.argv[1], sys.argv[2]
try:
    with open(old_path, "rb") as f:
        old_env = plistlib.load(f).get("EnvironmentVariables") or {}
except Exception:
    sys.exit(1)  # unsafe migration must not silently discard operator policy

with open(new_path, "rb") as f:
    new = plistlib.load(f)
env = new.setdefault("EnvironmentVariables", {})

kept = []
for k, v in old_env.items():
    if not isinstance(v, str) or k in KIT_OWNED or k in DROP:
        continue
    if env.get(k) != v:
        env[k] = v
        kept.append(k)
for k in DROP:
    env.pop(k, None)

with open(new_path, "wb") as f:
    plistlib.dump(new, f)
if kept:
    print("Preserved operator env from existing plist: " + ", ".join(sorted(kept)))
PY
  then
    echo "Error: could not merge previous plist EnvironmentVariables; existing LaunchAgent plist left unchanged." >&2
    exit 1
  fi
fi

# Explicit invocation-only opt-ins; old plist values cannot silently enable recovery.
"$PYTHON" - "$NEW_PLIST" "$INSTALL_RECOVERY_MODE" "$INSTALL_HELPER_HEAL" <<'PYOPT'
import plistlib, sys
path, mode, helper = sys.argv[1:]
with open(path, "rb") as handle:
    data = plistlib.load(handle)
data["EnvironmentVariables"].update(RECOVERY_MODE=mode, HEAL_ON_HELPER_MISSING=helper)
with open(path, "wb") as handle:
    plistlib.dump(data, handle)
PYOPT

# A reviewed policy file persists these keys; shell exports alone do not.
if [[ -n "${INSTALL_POLICY_FILE:-}" ]]; then
  "$PYTHON" - "$NEW_PLIST" "$INSTALL_POLICY_FILE" <<'PYPOLICY'
import json, os, plistlib, stat, sys
path, policy_path = sys.argv[1:]
try:
    fd = os.open(policy_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as handle:
        st = os.fstat(handle.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600 or st.st_size > 8192:
            raise ValueError()
        policy = json.load(handle)
    allowed = {"RECOVERY_MODE": {"observe", "active"}, "HEAL_ON_HELPER_MISSING": {"0", "1"},
               "HELPER_IDLE_REQUIRED": {"1"}, "HELPER_MISSING_SEC": {"300"},
               "CODEX_WATCH": {"0", "1"}, "CODEX_REOPEN_POLICY": {"crash_only"},
               "CODEX_BUNDLE_ID": {"com.openai.codex", "com.openai.chat"},
               "CODEX_APP_PATH": None}
    if not isinstance(policy, dict) or set(policy) != set(allowed) or any(type(v) is not str or (allowed[k] is not None and v not in allowed[k]) for k, v in policy.items()):
        raise ValueError()
    app = policy["CODEX_APP_PATH"]
    if not os.path.isabs(app) or not app.endswith(".app") or any(c in app for c in "\0\r\n"):
        raise ValueError()
    if policy["RECOVERY_MODE"] != "active" and policy["HEAL_ON_HELPER_MISSING"] != "0":
        raise ValueError()
    with open(path, "rb") as handle:
        data = plistlib.load(handle)
    data["EnvironmentVariables"].update(policy)
    with open(path, "wb") as handle:
        plistlib.dump(data, handle)
except Exception:
    print("Invalid private installation policy; no installed executable replaced.", file=sys.stderr)
    sys.exit(2)
PYPOLICY
fi

# Lint before replace (plutil on macOS; python load elsewhere / when plutil missing).
if command -v plutil >/dev/null 2>&1; then
  if ! plutil -lint "$NEW_PLIST" >/dev/null; then
    echo "Error: new plist failed plutil -lint; existing LaunchAgent plist left unchanged." >&2
    exit 1
  fi
else
  if ! "$PYTHON" -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$NEW_PLIST"; then
    echo "Error: new plist failed python lint; existing LaunchAgent plist left unchanged." >&2
    exit 1
  fi
fi

# A live install needs an explicitly confirmed maintenance window and a hold.
# Never silently re-enable a job disabled by its owner.
if [[ "$SKIP_LAUNCHD" != "1" ]]; then
  hold="$HOME_DIR/Library/Application Support/Latch/grok-bot-restart.hold"
  if [[ "${INSTALL_MAINTENANCE_CONFIRMED:-0}" != "1" || ( ! -e "$hold" && ! -L "$hold" ) ]]; then
    echo "Live installation requires a confirmed maintenance window and an existing hold." >&2
    exit 2
  fi
  if [[ -e "$HOME_DIR/Library/Application Support/Latch/grok-bot-local-exec-heal.lock" ]]; then
    echo "Watchdog tick/lock is present; leave installation for a verified quiet boundary." >&2
    exit 2
  fi
  UID_NUM="$(id -u)"
  if [[ "${INSTALL_PREVIOUSLY_UNLOADED:-0}" == "1" ]]; then
    # The approved rollback runbook unloads before its consistent snapshot.
    # Establish readable domain access; a denied lookup is not proof of absence.
    if ! launchctl print "gui/${UID_NUM}" >/dev/null 2>&1; then
      echo "Cannot verify launchd domain access; installed files left unchanged." >&2
      exit 5
    fi
  elif [[ -f "$EXISTING_PLIST" ]]; then
    if ! launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null; then
      echo "Could not unload existing watchdog; installed files left unchanged." >&2
      exit 5
    fi
  fi
  sleep 2
  if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
    echo "Watchdog is still loaded; installed files left unchanged." >&2
    exit 5
  fi
fi

# Source executables are copied only after complete candidate validation.
install -m 755 "$SCRIPT_SRC" "$SCRIPT_DST"
install -m 755 "$ROOT/grok-bot-restart-guard.py" "$BIN_DIR/grok-bot-restart-guard.py"
install -m 755 "$ROOT/codex-watch.py" "$BIN_DIR/codex-watch.py"
mv "$NEW_PLIST" "$PLIST_DST"
NEW_PLIST=""
if [[ -n "$PREPARE_DIR" ]]; then chmod 600 "$PLIST_DST"; else chmod 644 "$PLIST_DST"; fi
if [[ -n "${OLD_PLIST:-}" ]]; then rm -f "$OLD_PLIST"; fi
OLD_PLIST=""
trap - EXIT

if [[ "$SKIP_LAUNCHD" == "1" ]]; then
  echo "INSTALL_SKIP_LAUNCHD=1: files written, launchd untouched."
  exit 0
fi

BOOT_OK=0
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DST"; then
    BOOT_OK=1
    break
  fi
  if [[ "$attempt" -lt 5 ]]; then
    echo "bootstrap attempt ${attempt} failed; retrying..." >&2
    launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
    sleep 2
  else
    echo "bootstrap attempt ${attempt} failed." >&2
  fi
done
if [[ "$BOOT_OK" != "1" ]]; then
  echo "launchctl bootstrap failed after retries." >&2
  echo "Recovery: launchctl bootstrap \"gui/${UID_NUM}\" \"$PLIST_DST\"" >&2
  exit 5
fi

echo "Installed Latch local-exec self-heal ${LABEL} version $(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
echo "  script: $SCRIPT_DST"
echo "  plist:  $PLIST_DST"
echo "  logs:   $LOG_DIR/GrokBotLocalExecHeal.log"
echo "  last:   $LOG_DIR/GrokBotLocalExecHeal-last.json"
echo "  guard:  $BIN_DIR/grok-bot-restart-guard.py"
echo "  disable: touch \"$HOME_DIR/Library/Application Support/Latch/grok-bot-local-exec-heal.disable\""
echo "  force:   touch \"$HOME_DIR/Library/Application Support/Latch/grok-bot-local-exec-heal.request\""
echo "  codex pause: touch \"$HOME_DIR/Library/Application Support/Latch/codex.pause\""
echo "  maintenance hold: touch \"$HOME_DIR/Library/Application Support/Latch/grok-bot-restart.hold\""
echo
# RunAtLoad is the only immediate tick. Do not kickstart or invoke the script
# again here: a second tick would shorten the first-observation barrier.
echo "LaunchAgent registered. RunAtLoad owns the initial observation tick."
echo "Default reinstall disables all automatic app recovery; active installation requires an explicit owner policy."
