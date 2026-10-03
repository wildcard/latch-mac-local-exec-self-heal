> **Prove record for shipped 1.3.0** (2026-10-02 22:55–22:56 PT). Does not prove 1.4.0. S-NEW-D was not auto-healed.

# Prove: mac-local-exec-self-heal 1.3.0

**When:** 2026-10-02 22:55–22:56 PT  
**Mac:** `DEMO-MAC` (`machineId <redacted>`, `hostname <redacted>`), Darwin, user `<user>`  
**Kit source:** `/workspace/latch-public/mac-local-exec-self-heal` (`VERSION` = `1.3.0`), tar copied to the Mac  
**Install path (kit tree):** `/Users/<user>/.../mac-local-exec-self-heal-1.3.0/`  
**Installed by:** `./install.sh` at 22:55:50 PT  

| Piece | Path |
|---|---|
| Script | `/Users/<user>/Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh` (`KIT_VERSION="1.3.0"`, installed ~22:55 PT) |
| LaunchAgent | `/Users/<user>/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist` |
| Label | `com.latch.grok-bot-local-exec-heal` |
| Last state | `/Users/<user>/Library/Logs/GrokBotLocalExecHeal-last.json` |

Prior install was the Oct 1 22:24 script (schema `version` 1, no `kitVersion`). After 1.3.0 load, `launchctl print gui/<uid>/com.latch.grok-bot-local-exec-heal` shows `run interval = 60 seconds`, env `READINESS_WAIT_SEC=75`, `HEAL_ON_STUCK_SESSION=1`, `STUCK_SEC=120`, `OK_HINT_SEC=300`, `HEARTBEAT_STALE_SEC=180`, `HEAL_CURSOR=0`, `last exit code = 0`.

Install's own "dry-run" `cat` of `last.json` still showed the previous schema-v1 blob (`checkedAtIso` 22:54:52). That run lost the single-flight lock to the kickstarted LaunchAgent. The LaunchAgent tick at 22:56:01 wrote schema v2. Not a failed install.

No HID keystrokes were sent for the prove. Unrelated work apps were not driven. The Grok Bot main pid was left running (not quit).

## Fixture tests

`LIVE` unset. `./tests/run-tests.sh` on the Mac.

```
passed=16 failed=0
```

PASS: T-healthy, T-disable, T-cooldown, T-readiness-pass, T-readiness-incomplete, T-readiness-failed, T-operator_request, T-operator-bypasses-cooldown, T-heartbeat-frozen, T-frozen-under-threshold, T-stale-beats-frozen, T-moving-heartbeat-no-heal, T-ok-escalate-hint, T-no-heartbeat-soft, T-stuck-flag-off, T-app-missing.

## Live checks (installed script, not fixtures)

### T-healthy — PASS

Ran `$HOME/Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh` once.

- `status=ok`
- `reason=healthy`
- `action=none`
- `readiness=local_healthy` (this is the healthy-tick value; `readiness=ready` is only written when `status=healed` after a relaunch)
- `bootOutcome=ready`
- `kitVersion=1.3.0`
- `version=2`

### T-disable — PASS

Touched `~/Library/Application Support/Latch/grok-bot-local-exec-heal.disable`, ran the script, then removed the file.

- `status=disabled`
- `reason=disable_file`
- `readiness=disabled`
- `action=none`
- `kitVersion=1.3.0`

File confirmed absent afterward. A follow-up tick restored `status=ok` / `readiness=local_healthy` so the disable file is not left armed.

### T-process-down — SKIP

`LIVE=1` was **not** set. `tests/live-process-down.sh` with `LIVE` unset exited **2** and printed the refuse message. It did not quit Grok Bot.

SKIP reason: default tonight is no live quit. Soft-park of the Mac session was **not** confirmed. HID idle stayed short through the live checks. Grok Bot was up with a moving heartbeat (age in the tens of seconds, `heartbeatAtMs` advanced) and `bootOutcome=ready`. The operator may still have been at the Mac. Unrelated work apps were not driven.

## last.json shape (after restore, ~22:56 PT)

Generalized example. Real pid and epoch timestamps are omitted.

```json
{
  "version": 2,
  "kitVersion": "1.3.0",
  "checkedAtMs": "<redacted>",
  "checkedAtIso": "2026-10-02T22:56:00-0700",
  "status": "ok",
  "reason": "healthy",
  "action": "none",
  "pid": "<redacted>",
  "heartbeatAgeSec": 22,
  "heartbeatAtMs": "<redacted>",
  "bootOutcome": "ready",
  "readiness": "local_healthy",
  "escalateHint": null,
  "heartbeatFrozenSinceMs": null,
  "heartbeatUnchangedForSec": null,
  "okStreakSinceMs": "<redacted>",
  "app": "/Applications/Grok Bot.app",
  "cloudConnectObservable": false
}
```

`okStreakSinceMs` reset on this manual run (new streak), so `escalateHint` is null. A continuous local-ok streak of `OK_HINT_SEC` (300s) is what sets the S-NEW-D hint. This sample does not show that hint yet.

## Lease

`$HOME/.../release-mac-lease.sh` exit 0 at the end of the prove (~22:57 PT). Printed `lease-released`. Disable file and request file both absent at release.

## Class reminder

**S-NEW-D is still not auto-healed.** The LaunchAgent cannot see cloud `ListMachines.connected`. `cloudConnectObservable` is `false`. A live process plus a moving heartbeat under 180s stays `status=ok` / `readiness=local_healthy` and does not relaunch. Tonight's Mac link happened to be up (local-exec shell worked). That does not mean a silent cloud disconnect would be repaired.
