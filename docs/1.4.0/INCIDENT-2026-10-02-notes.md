> **Working notes** from the same night as the public incident. The shipped narrative is [`docs/INCIDENT-2026-10-02.md`](../INCIDENT-2026-10-02.md). These notes keep the kit-at-the-time classification (1.2.0, S-NEW-D outside the relaunch loop). 1.4.0 proposes to close that gap and is **not** shipped.

# Incident 2026-10-02 — S-NEW-D silent disconnect

**Machine:** `DEMO-MAC` (`machineId <redacted>`, `hostname <redacted>`)
**Kit installed at the time:** `mac-local-exec-self-heal` **1.2.0**
**Window:** ~22:08–22:27 PT, Friday 2 Oct 2026 (America/Vancouver)
**Cloud:** `ListMachines.connected=false` for the window (Latch + Grok Bot checks; still false after ≥2× ~60s waits before the manual restart)
**Classification:** **S-NEW-D / silent disconnect**

## Forensics gathered on the Mac after the operator restarted Grok Bot (~22:28 PT)

| Check | Result |
|---|---|
| LaunchAgent `com.latch.grok-bot-local-exec-heal` | Loaded |
| `runs` | long run count (exact count omitted) |
| Last exit | 0 |
| Disable file | **Absent** |
| Heal log during ~22:08–22:27 PT | Continuous `ok reason=healthy` on the **pre-restart pid**, `heartbeat_age` only ~**31–45s** (under 180s stale threshold) |
| Did heal fire? | **No** |
| After manual restart ~22:28 PT | **New pid**, `status=ok`, reason healthy |

Heartbeat age was **updating** (about 16→45 in the notes, sitting in the 31–45s band in the log sample). `heartbeatAtMs` was not stuck. Process was alive. 1.2.0 has no cloud connect bit, so every tick correctly chose `healthy`.

## Classification against the spec matrix

| Subcase | Fit? |
|---|---|
| S-NEW-A process down, heal did not run | No — process stayed up, agent was loaded, not disabled |
| S-NEW-B process down, relaunch failed | No |
| S-NEW-C process up, heartbeat/boot never ready | No — heartbeat was fresh and reason was `healthy` |
| **S-NEW-D** process + heartbeat look healthy, cloud still disconnected | **Yes** |
| S8 sleep / lid | Not indicated — ticks continued every interval with exit 0 |

S-NEW-D stays **outside the relaunch loop**. 1.3.0 does not auto-heal a moving healthy heartbeat. It records `escalateHint` after a long `ok` streak, adds `operator_request`, and states the limit in the README. Primary fix for this exact outage remains operator restart, or a future cloud-side signal.

## Not claimed

Sleep/network heal is not green. This incident was an awake Mac whose local signals lied about the cloud link.
