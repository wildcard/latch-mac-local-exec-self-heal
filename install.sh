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
sed "s|__HOME__|$HOME_DIR|g" "$PLIST_TMPL" > "$PLIST_DST"
chmod 644 "$PLIST_DST"

UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DST"
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
