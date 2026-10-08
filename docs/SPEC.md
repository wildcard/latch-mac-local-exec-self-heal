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
7. `bootOutcome` present and not `ready` → `boot_outcome_<token>`. `<token>` keeps only letters, digits, `-`, and `_` (anything else becomes `_`) and is capped at 32 characters, so a raw outcome cannot land unbounded in the reason, the log, or a snapshot.
8. If `HEAL_ON_STUCK_SESSION=1` (default): pid unchanged and `heartbeatAtMs` unchanged for ≥ `STUCK_SEC` (default 120) → `heartbeat_frozen`
9. **Helper count below expected for ≥ `HELPER_MISSING_SEC` (1.5.0)** → `helper_missing`: relaunch when `HEAL_ON_HELPER_MISSING=1`; otherwise **log-only** (`status=observe`, `readiness=helper_missing_observe`, no relaunch)
10. Beacon heal-request (only polled when no local heal is needed, incl. in log-only `observe`) → `beacon_request` (bypasses cooldown)
11. Else → `ok` / `healthy`

Cooldown (`COOLDOWN_SEC`, default 300) suppresses another relaunch except `operator_request` and `beacon_request`. `helper_missing` **respects** cooldown.

One relaunch per outage window: a second `beacon_request` inside `BEACON_RELAUNCH_WINDOW_SEC` → `beacon_suppressed`. For `helper_missing`, the expected count becomes a floor after a relaunch (or across a pid change while a missing interval is already open). A `beacon_request`, `operator_request`, `heartbeat_stale_*`, or `process_down` relaunch keeps that same floor when a helper-short interval is open; a relaunch while the count meets the expected level clears it. While the live count is still short the kit stays `helper_suppressed`, including after `HELPER_RELAUNCH_WINDOW_SEC` (3600), and it does not store the lower count. A later outage can relaunch only after the count has met that floor and the window has elapsed. Both suppressed states escalate instead of looping.

## Helper-count observer (1.5.0, S-NEW-D helper-exit signature)

Background: [Prove D FAIL 2026-10-07](1.5.0/PROVE-D-FAIL-2026-10-07.md). During a real S-NEW-D, one of the two Grok Bot utility helpers of sub-type `node.mojom.NodeService` exited cleanly while the main process and its heartbeat stayed healthy; cloud `connected=false` lasted until the app respawned the helper ~50 min later.

Each tick (main pid alive, `HELPER_CHECK=1`):

- **Count** = direct children of the main pid whose `ps` comm basename starts with `HELPER_NAME` (default `Grok Bot Helper`), whose command starts with `$APP_PATH/Contents/` (a quoted path later in a shell command does not match), and whose `--utility-sub-type` is exactly `HELPER_SUBTYPE` (default `node.mojom.NodeService`). The GPU process is also named `Grok Bot Helper` on macOS; it is not counted because its subtype is not NodeService. Recorded as `helperCount` / `helperPids`.
- **Process names.** `exe` is the `ps` comm basename only when it is exactly `Grok Bot`, `Grok Bot Helper`, or `Grok Bot Helper` plus one of `(GPU)`, `(Renderer)`, `(Plugin)`, `(Alerts)`. Any other comm, including an argv[0] rewrite or any other suffix, is stored as `other`. The full command line is read only for processes inside the app path, and only `--type` / `--utility-sub-type` values matching `[A-Za-z0-9._-]` are kept. `type` is one of `utility`, `renderer`, `gpu-process`, `zygote`, `other`; anything else is `other`. Stored `subType` is one of `node.mojom.NodeService`, `network.mojom.NetworkService`, `storage.mojom.StorageService`, `audio.mojom.AudioService`, `video_capture.mojom.VideoCaptureService`, or null. The count still uses the raw subtype, so a custom `HELPER_SUBTYPE` still matches; only the stored field is filtered. Other apps’ argv (a curl `Authorization` header, a browser URL with a query secret) is not written.
- **Expected** = `HELPER_EXPECTED` when set (`helperExpectedSource=config`; this wins over a learned baseline), else the **learned baseline** (`learned`), else none (no detection). The template does not set `HELPER_EXPECTED`.
- **Learning:** one count per main pid, learned once. Over `HELPER_BASELINE_SEC` (600; values below 60 clamp to 60, non-numeric falls back to 600) the kit keeps the minimum positive count seen while that pid is locally healthy (heartbeat fresh, `bootOutcome` ready or absent, not frozen). The window starts at the first healthy sample and is not reset when the count changes. It also needs at least 3 healthy samples, so two samples across a sleep gap do not finish it. A higher count does not move the minimum, so a first scan that catches 3 helpers mid-launch or mid-update does not lock that high in; a steady 2 is what is learned. A lower count moves the minimum only after it appears on 2 consecutive healthy ticks, so one blip does not lock 1 in for the life of the pid. A count of 0 is never stored. An already-learned baseline is never raised and never lowered. Learning does not happen while a relaunch is in progress (the process is not locally healthy; that tick restarts the window and does not seed the minimum) or while the count is already below a prior expected count (`HELPER_EXPECTED` or an existing baseline), which is the grace period. A second helper that appears only after the baseline was learned does not raise it. The Oct 7 record shows both helpers present from app launch. A late second helper was observed on the live Mac: main up 1d10h57m, NodeService helpers up 1d10h57m and 4h29m, which looks like a respawn mid-life. `HELPER_EXPECTED=2` is the recommended setting for the live-baseline week. `helperNoneSeen` is set when the scan succeeds and the count is 0, so a renamed helper binary does not look like “nothing to learn” with no trace. That flag does not relaunch. Socket counts do not gate a relaunch.
- **Floor:** a `helper_missing` relaunch keeps the old expected count and points it at the new pid (`helperFloorPending`). The same carry happens on a `beacon_request`, `operator_request`, `heartbeat_stale_*`, or `process_down` relaunch when a helper-short interval is open (this tick, or the previous tick when this tick could not scan). A pid change while a missing interval is open, or while that floor is already pending, carries the effective expected count (`HELPER_EXPECTED` when set, otherwise the learned baseline). The floor clears only when the live count meets it. Until then the short count is not learned. That carry set is frozen for the log-only week: no further relaunch reasons, and socket counts do not gate a relaunch. Known limits, not changed this round: a carried floor does not expire on its own; a helper-scan exception is swallowed (the count becomes unknown and the error is not logged); baseline identity is the main pid alone, so a recycled pid can inherit the previous baseline; the ps shim reports bare comm names, matching `ps -o comm=`, and does not exercise a comm value that is a path.
- **Missing clock:** on the same pid, `helperMissingSinceMs` starts the first tick count < expected and keeps running. An external pid change that carries the floor restarts the clock, so the new process gets a fresh `HELPER_MISSING_SEC` of grace. The clock clears when the count recovers. At ≥ `HELPER_MISSING_SEC` (300; values below 1 clamp to 1, non-numeric falls back to 300) → `helper_missing`.
- **Unknown count** (`ps` failed / unreadable, or `HELPER_CHECK=0`) is never treated as missing.
- **Sockets (observe-only):** only on ticks that write a snapshot. With `HELPER_SOCKET_CHECK=1` (default), `/usr/sbin/lsof -nP -a -p <helper pids> -iTCP -sTCP:ESTABLISHED -Fpn` (absolute path, not `PATH`); per helper, the count of established connections whose remote port is `HELPER_SOCKET_PORT` (443) → `helperSockets` `{pid: n}`. macOS `lsof` exits 1 with empty stderr when no pid has a matching socket; that is recorded as 0 for each helper pid. Exit 1 with stderr, or any other non-zero exit, leaves `helperSockets` null. Counts only: no addresses or hostnames. Never triggers a relaunch. The process table is `/bin/ps`, also absolute.

Ship mode: **log-only** (`HEAL_ON_HELPER_MISSING=0`). Do not turn `=1` on until a live week shows the learned baseline is stable. What `=1` does, and what it refuses to do, is below. This is not a substitute for a product status file: [1.5.0/PRODUCT-STATUS-FILE.md](1.5.0/PRODUCT-STATUS-FILE.md).

### What `HEAL_ON_HELPER_MISSING=1` does

`=1` does not change detection. The same `helper_missing` signal, after the same grace, calls the existing quit + `open -ga "Grok Bot"` path and the readiness gate. It does not bypass cooldown. Guards:

- Count must stay below expected for ≥ `HELPER_MISSING_SEC` (300s, minimum 1). A dip that returns inside that window clears the clock and does not relaunch, snapshot, or observe. The 2026-10-07 gap was ~50 minutes.
- `ps` unreadable, `HELPER_CHECK=0`, or `helperNoneSeen` with no expected count is not “missing,” and the none-seen flag never relaunches by itself.
- Expected count is `HELPER_EXPECTED` when set. Otherwise it is learned once per pid, as the minimum positive count over `HELPER_BASELINE_SEC`, only while locally healthy, and not during the grace period. It never goes up or down after that. A pid change with no open missing interval drops the baseline. A pid change during a missing interval keeps it as a floor and restarts the missing clock.
- Single-flight lock. `COOLDOWN_SEC` (300) applies. If `helper_missing` is both inside that cooldown and still under the floor, the status is `helper_suppressed`, not `cooldown`.
- After a `helper_missing` relaunch, `helperFloorPending` stays set until the live count meets the old expected count. A beacon, operator, heartbeat-stale, or process-down relaunch sets that same floor when a helper-short interval is open. While it is still short the status is `helper_suppressed` (no second relaunch), even after `HELPER_RELAUNCH_WINDOW_SEC` (3600, minimum 1). The lower count is not stored. When the count has met the floor, a new drop can relaunch once that window has also elapsed.
- `.disable` wins. `operator_request` and `beacon_request` keep their existing precedence.
- Only direct children of the main pid, comm prefix `Grok Bot Helper`, argv0 under the app path, subtype `node.mojom.NodeService`. GPU, renderer, `NetworkService`, and another app’s helpers are not counted.

`=1` still misses a silent disconnect that does not drop a NodeService helper (the 2026-10-02 window). A kit installed in the middle of an outage can learn a short count after 600s of local health if `HELPER_EXPECTED` is unset; log-only is the default so that does not quit the app. `cloudConnectObservable` stays `false` either way.

## Diagnostics snapshot (1.5.0)

On every tick whose status is not `ok` or `disabled`, write `GrokBotLocalExecHeal-snap-<YYYYmmddTHHMMSS>-<ms>.json` next to `last.json` (or in `HEAL_SNAPSHOT_DIR`). The snapshot directory is mode `0700` (including when `HEAL_SNAPSHOT_DIR` is set) and each snapshot file is mode `0600`. Rate limit: one snapshot per status + reason class per `HEAL_SNAPSHOT_MIN_SEC` (900). The same class then waits twice as long each time, capped at 4 hours, so a long `observe` does not write every 15 minutes forever. An `ok` tick clears that backoff, so the next outage starts again at 900s. A changed class starts again at 900s. `heartbeat_stale_<seconds>s` is one class (`heartbeat_stale`), so the changing age does not defeat the limit. The stored reason text is unchanged. Pruned to the newest `HEAL_SNAPSHOT_KEEP` (20). When a tick is about to relaunch, a second file `...-before.json` (`phase=before_relaunch`) is written **before** quit/`open`, from the process tree captured at tick start, with the same modes.

Contents: decision fields, helper fields, `processTree` = main pid + direct children as `{pid, ppid, etime, exe, type, subType}`, plus allowlisted `desktopStatus` (`version`, `pid`, `appVersion`, `startedAtMs`, `signedIn`) and `dune` (`pid`, `heartbeatAtMs`, `bootOutcome`, `mainFaultSeen`, numeric `childDeaths`). `exe` is exactly `Grok Bot`, `Grok Bot Helper`, or `Grok Bot Helper` with suffix `(GPU)`, `(Renderer)`, `(Plugin)`, or `(Alerts)`; anything else is `other`. `type` is `utility`, `renderer`, `gpu-process`, `zygote`, or `other`. `subType` is kept only for processes inside the app path and only when it is one of the five service names (`NodeService`, `NetworkService`, `StorageService`, `AudioService`, `VideoCaptureService`); any other subtype is stored as null. The helper count still matches the raw subtype. Top-level `bootOutcome` goes through the same token filter as `dune.bootOutcome` (no spaces, slashes, or `@`). **No argv**, no user-data-dir path, no installId, no token. App logs are not tailed (no documented secret-free predicate). Socket diagnostics run only on these ticks and are counts on `HELPER_SOCKET_PORT` only. `last.json` records `lastSnapshot` (file name) plus the helper summary fields.

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
| `helperBaseline`, `helperBaselinePid`, `helperStableCount`, `helperStableSinceMs` | Baseline bookkeeping. `helperStableCount` is the running minimum of positive counts in the open window; `helperStableSinceMs` is when that window started. Learned once as that minimum. Never raised or lowered after that. `.disable`, `app_missing`, and a failed scan file keep the previous values |
| `helperFloorPending` | Old expected count is a floor until the live count meets it |
| `helperNoneSeen` | Scan succeeded and no NodeService helper is a child of this pid. Does not relaunch. Its hint does not replace the long-ok S-NEW-D hint |
| `helperMissingSinceMs`, `helperMissingForSec` | Missing clock |
| `helperSockets` | `{pid: established count to HELPER_SOCKET_PORT}` on snapshot ticks. Exit 1 with empty stderr is 0 per pid. `null` if not scanned, if stderr is non-empty, or if the exit is any other non-zero |
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
| S-NEW-D helper-exit signature (1.5.0) | Log-only by default | `observe` / `helper_missing` + snapshot. `HEAL_ON_HELPER_MISSING=1` relaunches once, then stays `helper_suppressed` while the count is still short |
| S10 intentional quit | Yes, by design | Relaunch unless disabled |
| Frozen timestamp | Yes | `heartbeat_frozen` |
| Operator request | Yes | `operator_request` |

## Agent loop (1.5.0)

The agent runbook in [1.5.0/AGENT-LOOP.md](1.5.0/AGENT-LOOP.md) is not kit behavior. Rule A (beacon POST after `connected=false` for ≥ 3 min) is the loop that failed open on 2026-10-07. Rule B (immediate relaunch when a user message arrives from a machine shown `connected=false`) is a **proposal pending the owner's decision**; it conflicts with the Prove D note that a mid-chat relaunch quits a session a person is using.

## macOS diagnostics gotchas

- The unified log can label Grok Bot processes under **another Electron app's name** (names resolve by binary UUID). Filter `log show` by **`processID`**, not process name.
- In zsh, `log` is a builtin: use **`/usr/bin/log`**.

## Tests

- `tests/run-tests.sh` — fixture / dry-run. Default. Must not quit a live Grok Bot.
- `tests/live-process-down.sh` — macOS only, `LIVE=1`, quits the app and waits for `healed` + `readiness=ready`. Not part of the default harness.

## Out of scope

Second remote watchdog, sleep/network heal, and any claim that a healthy-looking Mac heartbeat (or a full helper count) proves the cloud link is up.
