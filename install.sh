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

mkdir -p "$BIN_DIR" "$LAUNCH_DIR" "$LOG_DIR" "$HOME_DIR/Library/Application Support/Latch"
install -m 755 "$SCRIPT_SRC" "$SCRIPT_DST"

# Keep operator-set EnvironmentVariables across reinstalls.
# Operator tunables (HEAL_*, *SEC, BEACON_*, custom keys) win over template defaults.
# Kit-owned PATH comes from the template unless INSTALL_RESET_ENV=1 (full wipe to template).
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

sed "s|__HOME__|$HOME_DIR|g" "$PLIST_TMPL" > "$NEW_PLIST"

if [[ -f "$PLIST_DST" && "${INSTALL_RESET_ENV:-0}" != "1" ]]; then
  OLD_PLIST="$(mktemp "${LAUNCH_DIR}/${LABEL}.plist.old.XXXXXX")"
  cp "$PLIST_DST" "$OLD_PLIST"
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
KIT_OWNED = {"PATH"}
DROP = {"HEAL_TEST_MODE"}

old_path, new_path = sys.argv[1], sys.argv[2]
try:
    with open(old_path, "rb") as f:
        old_env = plistlib.load(f).get("EnvironmentVariables") or {}
except Exception:
    sys.exit(0)  # unreadable old plist: nothing to preserve

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

mv "$NEW_PLIST" "$PLIST_DST"
NEW_PLIST=""
chmod 644 "$PLIST_DST"
if [[ -n "${OLD_PLIST:-}" ]]; then rm -f "$OLD_PLIST"; fi
OLD_PLIST=""
trap - EXIT

if [[ "$SKIP_LAUNCHD" == "1" ]]; then
  echo "INSTALL_SKIP_LAUNCHD=1: files written, launchd untouched."
  exit 0
fi

UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
# bootout is async; an immediate bootstrap can fail with "Input/output error" (5). Wait, then retry.
sleep 2
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
launchctl enable "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

echo "Installed Latch local-exec self-heal ${LABEL} version $(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
echo "  script: $SCRIPT_DST"
echo "  plist:  $PLIST_DST"
echo "  logs:   $LOG_DIR/GrokBotLocalExecHeal.log"
echo "  last:   $LOG_DIR/GrokBotLocalExecHeal-last.json"
echo "  disable: touch \"$HOME_DIR/Library/Application Support/Latch/grok-bot-local-exec-heal.disable\""
echo "  force:   touch \"$HOME_DIR/Library/Application Support/Latch/grok-bot-local-exec-heal.request\""
echo
# dry-run once (real signals on this Mac; may relaunch if the app looks down)
"$SCRIPT_DST" || true
if [[ -f "$LOG_DIR/GrokBotLocalExecHeal-last.json" ]]; then
  echo "Dry-run state:"
  cat "$LOG_DIR/GrokBotLocalExecHeal-last.json"
fi
