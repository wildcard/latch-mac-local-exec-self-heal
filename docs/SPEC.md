# Latch Mac local-exec self-heal — specification

**Kit:** `mac-local-exec-self-heal` **1.5.0** (contract first written for 1.3.0, 2026-10-02)
**Date:** 2026-10-07

## Contract

A LaunchAgent on the Mac restores **Grok Bot desktop process and on-Mac readiness signals** (a dune-reliability heartbeat younger than `HEARTBEAT_STALE_SEC`, or `bootOutcome=ready`).

It does **not** observe cloud `ListMachines.connected`. Since 1.5.0 it observes one Mac-local proxy for the S-NEW-D helper-exit signature (helper count, below); `cloudConnectObservable` stays `false`. It does **not** wake a sleeping Mac, open a lid, or repair WAN, VPN, or sign-in.

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

1. Disable file → `disabled` (no relaunch; a request file is left in place; no beacon poll)
2. App bundle missing → `error` / `app_missing`
3. `grok-bot-local-exec-heal.request` exists → `operator_request` (overrides local health, bypasses cooldown, file removed when relaunch starts)
4. Process not alive → `process_down`
5. Process up but no heartbeat file → `ok` / `process_up_no_heartbeat_file` (no relaunch)
6. Heartbeat age > `HEARTBEAT_STALE_SEC` → `heartbeat_stale_<sec>s`
7. `bootOutcome` present and not `ready` → `boot_outcome_<token>`
8. If `HEAL_ON_STUCK_SESSION=1` (default): pid unchanged and `heartbeatAtMs` unchanged for ≥ `STUCK_SEC` (default 120) → `heartbeat_frozen`
9. **Helper count below expected for ≥ `HELPER_MISSING_SEC` (1.5.0)** → `helper_missing`: relaunch when `HEAL_ON_HELPER_MISSING=1`; otherwise **log-only** (`status=observe`, `readiness=helper_missing_observe`, no relaunch)
10. Beacon heal-request (only polled when no local heal is needed, incl. in log-only `observe`) → `beacon_request` (bypasses cooldown)
11. Else → `ok` / `healthy`

Cooldown (`COOLDOWN_SEC`, default 300) suppresses another relaunch except `operator_request` and `beacon_request`. `helper_missing` **respects** cooldown.

One relaunch per outage window: a second `beacon_request` inside `BEACON_RELAUNCH_WINDOW_SEC` → `beacon_suppressed`; a second `helper_missing` relaunch inside `HELPER_RELAUNCH_WINDOW_SEC` (3600) → `helper_suppressed`. Both escalate instead of looping.

## Helper-count observer (1.5.0, S-NEW-D helper-exit signature)

Background: [Prove D FAIL 2026-10-07](1.5.0/PROVE-D-FAIL-2026-10-07.md). During a real S-NEW-D, one of the two Grok Bot utility helpers of sub-type `node.mojom.NodeService` exited cleanly while the main process and its heartbeat stayed healthy; cloud `connected=false` lasted until the app respawned the helper ~50 min later.

Each tick (main pid alive, `HELPER_CHECK=1`):

- **Count** = children of the main pid whose executable is `HELPER_NAME*` (default `Grok Bot Helper`, inside an app bundle) and whose argv carries `--utility-sub-type=HELPER_SUBTYPE` (default `node.mojom.NodeService`). Source: `ps -axww -o pid=,ppid=,etime=,command=`. Recorded as `helperCount` / `helperPids`.
- **Expected** = `HELPER_EXPECTED` when set (`helperExpectedSource=config`), else the **learned baseline** (`learned`), else none (no detection).
- **Learning:** a count that holds for ≥ `HELPER_BASELINE_SEC` (600) while the main pid is locally healthy (heartbeat fresh, `bootOutcome` ready or absent, not frozen) becomes the baseline. For a given main pid the baseline only rises; it resets when the pid changes or after any relaunch. A baseline of 0 never fires.
- **Missing clock:** `helperMissingSinceMs` starts the first tick count < expected (same pid) and clears when the count recovers. At ≥ `HELPER_MISSING_SEC` (300) → `helper_missing`.
- **Unknown count** (ps failed / unreadable) is never treated as missing.
- **Sockets (observe-only):** with `HELPER_SOCKET_CHECK=1` (default), `lsof -nP -a -p <helper pids> -iTCP -sTCP:ESTABLISHED -Fpn`; per helper, the count of established connections whose remote port is `HELPER_SOCKET_PORT` (443) → `helperSockets` `{pid: n}`. Counts only: no addresses, hostnames or argv are stored. Never triggers a relaunch.

Ship mode: **log-only** (`HEAL_ON_HELPER_MISSING=0`). `HEAL_ON_HELPER_MISSING=1` turns the same signal into a relaunch. Do that only after real ticks show the learned baseline is stable. What `=1` does, and what it refuses to do, is in the false-positive section below. This is not a substitute for a product status file: [1.5.0/PRODUCT-STATUS-FILE.md](1.5.0/PRODUCT-STATUS-FILE.md).

### `HEAL_ON_HELPER_MISSING=1` and false positives

`=1` uses the existing quit + `open -ga "Grok Bot"` path and the readiness gate. Guards:

- Count must stay below expected for ≥ `HELPER_MISSING_SEC` (300s). A helper that exits and returns inside that window does not relaunch. The 2026-10-07 gap was ~50 minutes; a staff-described ~1 minute reconnect backoff does not trip this.
- `ps` unreadable or `HELPER_CHECK=0` is not “missing.”
- Expected count is learned only while the main pid is locally healthy (fresh heartbeat, boot ready or absent, not frozen) and the count is stable for ≥ `HELPER_BASELINE_SEC` (600s). It never lowers for that pid, and a baseline of 0 never fires. It resets when the main pid changes or after any relaunch.
- Single-flight lock. `COOLDOWN_SEC` (300) applies (`helper_missing` does not bypass cooldown). One helper relaunch per `HELPER_RELAUNCH_WINDOW_SEC` (3600), then `helper_suppressed` and an escalate hint.
- `.disable` wins. `operator_request` and `beacon_request` keep their existing precedence.
- Only direct children of the main pid, name prefix `Grok Bot Helper`, subtype `node.mojom.NodeService`. GPU, renderer, `NetworkService`, and another app’s helpers are not counted.

Residual false-positive risk if `=1` is on: the learned baseline only rises. A third NodeService helper that stays up for 600s locks the expected count at 3, and a later healthy count of 2 looks missing. Set `HELPER_EXPECTED` or turn heal back off. The signal is also a false negative for silent disconnects that do not drop a helper (the 2026-10-02 window). `cloudConnectObservable` stays `false` either way.

## Diagnostics snapshot (1.5.0)

On every tick whose status is not `ok` or `disabled`, write `GrokBotLocalExecHeal-snap-<YYYYmmddTHHMMSS>-<ms>.json` next to `last.json` (or in `HEAL_SNAPSHOT_DIR`), rate-limited to one per status+reason per `HEAL_SNAPSHOT_MIN_SEC` (900), pruned to the newest `HEAL_SNAPSHOT_KEEP` (20). When a tick is about to relaunch, a second file `...-before.json` (`phase=before_relaunch`) is written **before** quit/`open`, from the process tree captured at tick start.

Contents: decision fields, helper fields, `processTree` = main pid + direct children as `{pid, ppid, etime, exe, type, subType}`, plus allowlisted `desktopStatus` (`version`, `pid`, `appVersion`, `startedAtMs`, `signedIn`) and `dune` (`pid`, `heartbeatAtMs`, `bootOutcome`, `mainFaultSeen`, numeric `childDeaths`). `exe` is the executable name only; `type`/`subType` only for app-bundle processes and only `[A-Za-z0-9._-]`. **No argv**, no user-data-dir path, no installId, no token. App logs are not tailed (no documented secret-free predicate). Socket diagnostics are counts on `HELPER_SOCKET_PORT` only. `last.json` records `lastSnapshot` (file name) plus the helper summary fields.

A heartbeat whose timestamp **keeps moving**, with age still under 180s, is **not** `heartbeat_frozen`. That pattern is S-NEW-D when the cloud link is nevertheless down. See the incident note.

## `last.json` (version 2)

Written every tick that gets the lock.

| Field | Meaning |
|---|---|
| `status` | `ok`, `observe` (1.5.0 log-only `helper_missing`), `disabled`, `error`, `cooldown`, `healed`, `heal_incomplete`, `heal_failed`, `beacon_suppressed`, `helper_suppressed` |
| `reason` | Why this tick decided what it decided |
| `action` | `none` or `relaunch` |
| `pid`, `heartbeatAgeSec`, `heartbeatAtMs`, `bootOutcome` | Local signals |
| `readiness` | `local_healthy`, `ready`, `incomplete`, `failed`, `disabled`, `cooldown`, `app_missing`, or the pre-heal class |
| `escalateHint` | Set on incomplete/failed/cooldown, on process-up without a heartbeat file, and on `ok` once `okStreakSinceMs` is at least `OK_HINT_SEC` (default 300) |
| `heartbeatFrozenSinceMs`, `heartbeatUnchangedForSec` | Frozen-timestamp clock |
| `okStreakSinceMs` | Continuous local-healthy streak for the same pid |
| `lastHealAtMs`, `lastHealIso` | Last relaunch attempt |
| `lastBeaconHealAtMs` | Last `beacon_request` relaunch (1.4.0) |
| `cloudConnectObservable` | Always `false` |
| `kitVersion` | `1.5.0` |
| `helperCount`, `helperPids` | NodeService helpers under the main pid at tick start (`null` = not scanned / unknown) |
| `helperExpected`, `helperExpectedSource` | Expected count and where it came from (`config` / `learned` / `null`) |
| `helperBaseline`, `helperBaselinePid`, `helperStableCount`, `helperStableSinceMs` | Learned-baseline bookkeeping |
| `helperMissingSinceMs`, `helperMissingForSec` | Missing clock |
| `helperSockets` | `{pid: established count to HELPER_SOCKET_PORT}` or `null` |
| `helperCheck`, `healOnHelperMissing` | Effective switches |
| `lastHelperHealAtMs` | Last `helper_missing` relaunch |
| `lastSnapshot`, `lastSnapshotAtMs`, `lastSnapshotStatus`, `lastSnapshotReason` | Newest diagnostics snapshot (file name only) |

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
| S9 / S-NEW-D cloud-only disconnect | Beacon / helper | Beacon POST by an agent ([agent loop](1.5.0/AGENT-LOOP.md)); human restart or request file |
| S-NEW-D helper-exit signature (1.5.0) | Log-only by default | `observe` / `helper_missing` + snapshot; relaunch only with `HEAL_ON_HELPER_MISSING=1` (cooldown + one per window) |
| S10 intentional quit | Yes, by design | Relaunch unless disabled |
| Frozen timestamp | Yes | `heartbeat_frozen` |
| Operator request | Yes | `operator_request` |

## Agent loop (1.5.0)

Agents **auto-POST** a beacon heal-request, with no human in the loop, after `connected=false` for ≥ 3 min, **or immediately** when a user message arrives from a machine that `ListMachines` shows `connected=false`. Full rule and brakes: [1.5.0/AGENT-LOOP.md](1.5.0/AGENT-LOOP.md).

## macOS diagnostics gotchas

- The unified log can label Grok Bot processes under **another Electron app's name** (names resolve by binary UUID). Filter `log show` by **`processID`**, not process name.
- In zsh, `log` is a builtin: use **`/usr/bin/log`**.

## Tests

- `tests/run-tests.sh` — fixture / dry-run. Default. Must not quit a live Grok Bot.
- `tests/live-process-down.sh` — macOS only, `LIVE=1`, quits the app and waits for `healed` + `readiness=ready`. Not part of the default harness.

## Out of scope

Second remote watchdog, sleep/network heal, and any claim that a healthy-looking Mac heartbeat (or a full helper count) proves the cloud link is up.
