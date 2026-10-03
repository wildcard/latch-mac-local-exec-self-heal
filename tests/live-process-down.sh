#!/usr/bin/env bash
# Live prove: quit Grok Bot.app and wait for the installed LaunchAgent to relaunch
# it to readiness. NOT part of tests/run-tests.sh.
#
# This WILL quit the desktop app and drop local-exec until relaunch finishes.
# Refuses to run unless LIVE=1 on Darwin.
#
# Usage (on the Mac, after kit 1.3.0 is installed and the LaunchAgent is loaded):
#   LIVE=1 ./tests/live-process-down.sh
#
# Optional:
#   WAIT_SEC=180 STATE=~/Library/Logs/GrokBotLocalExecHeal-last.json
set -euo pipefail

if [[ "${LIVE:-0}" != "1" ]]; then
  echo "Refusing to run. This script quits Grok Bot.app." >&2
  echo "Set LIVE=1 on macOS after kit 1.3.0 is installed. Default CI harness is tests/run-tests.sh." >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "live-process-down is macOS-only (uname=$(uname -s))." >&2
  exit 2
fi

APP="/Applications/Grok Bot.app"
STATE="${STATE:-$HOME/Library/Logs/GrokBotLocalExecHeal-last.json}"
WAIT_SEC="${WAIT_SEC:-180}"

if [[ ! -d "$APP" ]]; then
  echo "Grok Bot.app not found at $APP" >&2
  exit 1
fi

echo "LIVE prove starting. This quits Grok Bot and waits up to ${WAIT_SEC}s for last.json status=healed readiness=ready."
echo "State file: $STATE"
if [[ -f "$STATE" ]]; then
  echo "---- last.json before ----"
  cat "$STATE"
  echo
fi

osascript -e 'tell application "Grok Bot" to quit' >/dev/null 2>&1 || true

deadline=$(( $(date +%s) + WAIT_SEC ))
last_status=""
while (( $(date +%s) < deadline )); do
  if [[ -f "$STATE" ]]; then
    last_status="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit
print("%s %s %s" % (d.get("status"), d.get("readiness"), d.get("reason")))' "$STATE" 2>/dev/null || true)"
    case "$last_status" in
      healed\ ready\ *)
        echo "PASS live process-down: $last_status"
        echo "---- last.json after ----"
        cat "$STATE"
        exit 0
        ;;
      heal_incomplete\ *|heal_failed\ *)
        echo "FAIL live process-down: $last_status" >&2
        cat "$STATE" >&2 || true
        exit 1
        ;;
    esac
  fi
  sleep 2
done

echo "FAIL live process-down: timed out after ${WAIT_SEC}s (last: ${last_status:-none})" >&2
echo "If the installed script is still 1.2.0 it marks healed on process-up only; install 1.3.0 first." >&2
[[ -f "$STATE" ]] && cat "$STATE" >&2 || true
exit 1
