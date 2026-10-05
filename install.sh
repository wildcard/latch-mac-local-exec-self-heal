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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is macOS-only." >&2
  exit 1
fi

if [[ ! -f "$PLIST_TMPL" ]]; then
  echo "Missing plist template: $PLIST_TMPL" >&2
  exit 1
fi

if [[ ! -d "/Applications/Grok Bot.app" ]]; then
  echo "Warning: /Applications/Grok Bot.app not found. Install Grok Bot first; heal will no-op until it exists." >&2
fi

mkdir -p "$BIN_DIR" "$LAUNCH_DIR" "$LOG_DIR" "$HOME_DIR/Library/Application Support/Latch"
install -m 755 "$SCRIPT_SRC" "$SCRIPT_DST"

# Keep operator-set EnvironmentVariables (BEACON_* and any other custom keys) across reinstalls.
# Template keys win on conflict; only keys the template does not define are carried over.
OLD_PLIST=""
if [[ -f "$PLIST_DST" ]]; then
  OLD_PLIST="$(mktemp)"
  cp "$PLIST_DST" "$OLD_PLIST"
fi
sed "s|__HOME__|$HOME_DIR|g" "$PLIST_TMPL" > "$PLIST_DST"
if [[ -n "$OLD_PLIST" ]]; then
  /usr/bin/python3 - "$OLD_PLIST" "$PLIST_DST" <<'PY' || echo "Warning: could not merge previous plist env; custom env not preserved." >&2
import plistlib, sys
old_path, new_path = sys.argv[1], sys.argv[2]
try:
    with open(old_path, "rb") as f:
        old_env = plistlib.load(f).get("EnvironmentVariables") or {}
except Exception:
    sys.exit(0)  # unreadable old plist: nothing to preserve
with open(new_path, "rb") as f:
    new = plistlib.load(f)
env = new.setdefault("EnvironmentVariables", {})
kept = [k for k, v in old_env.items() if k not in env and isinstance(v, str)]
for k in kept:
    env[k] = old_env[k]
with open(new_path, "wb") as f:
    plistlib.dump(new, f)
if kept:
    print("Preserved custom env from existing plist: " + ", ".join(sorted(kept)))
PY
  rm -f "$OLD_PLIST"
fi
chmod 644 "$PLIST_DST"

# INSTALL_SKIP_LAUNCHD=1 is for hermetic tests only: write files, touch no LaunchAgent, run no heal.
if [[ "${INSTALL_SKIP_LAUNCHD:-0}" == "1" ]]; then
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
  echo "bootstrap attempt ${attempt} failed; retrying..." >&2
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
  sleep 2
done
if [[ "$BOOT_OK" != "1" ]]; then
  echo "launchctl bootstrap failed after retries." >&2
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
