# Latch Mac local-exec self-heal — specification

**Kit:** `mac-local-exec-self-heal` **1.3.0**
**Date:** 2026-10-02

## Contract

A LaunchAgent on the Mac restores **Grok Bot desktop process and on-Mac readiness signals** (a dune-reliability heartbeat younger than `HEARTBEAT_STALE_SEC`, or `bootOutcome=ready`).

It does **not** observe cloud `ListMachines.connected`. It does **not** wake a sleeping Mac, open a lid, or repair WAN, VPN, or sign-in.

After a healable drop, the next ticks either:

- record `status=healed` and `readiness=ready`, or
- record `heal_incomplete` / `heal_failed` with `escalateHint`

They must not record `healed` just because a pid exists.

## Readiness (S7)

After `open -ga "Grok Bot"` (or the dry-run equivalent in tests), poll for up to `READINESS_WAIT_SEC` (default 75, target window 60–90s).

`healed` only if the process is alive **and** (`heartbeatAgeSec` is finite and **under** `HEARTBEAT_STALE_SEC` **or** `bootOutcome==ready`).

Otherwise:

- process alive but signals not ready → `heal_failed` is wrong; write `heal_incomplete`, `readiness=incomplete`
- process never appears → `heal_failed`, `readiness=failed`

Both set `action=relaunch` so the cooldown clock starts.

## Detection priority

1. Disable file → `disabled` (no relaunch; a request file is left in place)
2. App bundle missing → `error` / `app_missing`
3. `grok-bot-local-exec-heal.request` exists → `operator_request` (overrides local health, bypasses cooldown, file removed when relaunch starts)
4. Process not alive → `process_down`
5. Heartbeat age > `HEARTBEAT_STALE_SEC` → `heartbeat_stale_<sec>s`
6. `bootOutcome` present and not `ready` → `boot_outcome_<token>`
7. If `HEAL_ON_STUCK_SESSION=1` (default): pid unchanged and `heartbeatAtMs` unchanged for ≥ `STUCK_SEC` (default 120) → `heartbeat_frozen`
8. Process up but no heartbeat file → `ok` / `process_up_no_heartbeat_file` (no relaunch)
9. Else → `ok` / `healthy`

Cooldown (`COOLDOWN_SEC`, default 300) suppresses another relaunch except `operator_request`.

A heartbeat whose timestamp **keeps moving**, with age still under 180s, is **not** `heartbeat_frozen`. That pattern is S-NEW-D when the cloud link is nevertheless down. See the incident note.

## `last.json` (version 2)

Written every tick that gets the lock.

| Field | Meaning |
|---|---|
| `status` | `ok`, `disabled`, `error`, `cooldown`, `healed`, `heal_incomplete`, `heal_failed` |
| `reason` | Why this tick decided what it decided |
| `action` | `none` or `relaunch` |
| `pid`, `heartbeatAgeSec`, `heartbeatAtMs`, `bootOutcome` | Local signals |
| `readiness` | `local_healthy`, `ready`, `incomplete`, `failed`, `disabled`, `cooldown`, `app_missing`, or the pre-heal class |
| `escalateHint` | Set on incomplete/failed/cooldown, on process-up without a heartbeat file, and on `ok` once `okStreakSinceMs` is at least `OK_HINT_SEC` (default 300) |
| `heartbeatFrozenSinceMs`, `heartbeatUnchangedForSec` | Frozen-timestamp clock |
| `okStreakSinceMs` | Continuous local-healthy streak for the same pid |
| `lastHealAtMs`, `lastHealIso` | Last relaunch attempt |
| `cloudConnectObservable` | Always `false` |
| `kitVersion` | `1.3.0` |

The long-ok hint tells a person reading the file: local signals look healthy, cloud connect is invisible, restart the app or drop the request file on this Mac.

## Scenario matrix

| ID | In heal loop? | Required behavior |
|---|---|---|
| S1 process down | Yes | Relaunch, then readiness |
| S2 stale heartbeat | Yes | Relaunch |
| S3 boot not ready | Yes | Relaunch |
| S4 healthy | No-op | `ok` |
| S5 disable file | Skip | `disabled` |
| S6 cooldown | Skip | `cooldown` |
| S7 post-relaunch readiness | Yes | No premature `healed` |
| S8 sleep / lid | No | Do not claim healed |
| S9 / S-NEW-D cloud-only disconnect | No | Rich `last.json`; human restart or request file |
| S10 intentional quit | Yes, by design | Relaunch unless disabled |
| Frozen timestamp | Yes | `heartbeat_frozen` |
| Operator request | Yes | `operator_request` |

## Tests

- `tests/run-tests.sh` — fixture / dry-run. Default. Must not quit a live Grok Bot.
- `tests/live-process-down.sh` — macOS only, `LIVE=1`, quits the app and waits for `healed` + `readiness=ready`. Not part of the default harness.

## Out of scope

Second remote watchdog, sleep/network heal, and any claim that a healthy-looking Mac heartbeat proves the cloud link is up.
