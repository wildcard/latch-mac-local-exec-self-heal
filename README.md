# Grok Bot Mac local-exec self-heal (Latch)

LaunchAgent that runs **on the Mac** and gently relaunches [Grok Bot](https://grok.com) when local readiness signals say the desktop session is down or stuck.

It does not need a cloud shell. Once the desktop link is gone, a remote agent cannot install or run this for you — it has to already be loaded.

**Version:** see `VERSION` (current **1.3.0**).

## 1.3.0 shipped vs 1.4.0 proposed

| | **1.3.0 (this tree, `VERSION`)** | **1.4.0 (proposal only)** |
|---|---|---|
| Status | Shipped. LaunchAgent, tests, install. | Docs under [`docs/1.4.0/`](docs/1.4.0/), Worker source in [`worker-beacon/`](worker-beacon/) (not deployed), optional beacon poll hook (off by default, not proven live). No version bump. |
| What it heals | Dead process, stale heartbeat, bad `bootOutcome`, frozen `heartbeatAtMs`, on-Mac `.request` file. | Same, **plus** the classes 1.3.0 cannot see — especially S-NEW-D. |
| S-NEW-D | **Not auto-healed.** Moving heartbeat under 180s stays `ok` / `local_healthy`. `cloudConnectObservable` is always `false`. Long ok streak sets `escalateHint` only. | Must identify the class and relaunch (quit + `open -ga "Grok Bot"`), or accept a heal-only beacon that does that. **Not implemented. Not proven.** |
| How S-NEW-D would be seen | It cannot. | Prefer a native connection file written by Grok Bot so a bot does not have to declare the Mac down. 2026-10-02 dig found no such file. Last resort: personal Cloudflare Worker, heal-request only, Mac outbound poll. Beacon would bypass the 300s cooldown. See [`docs/PRODUCT-BAR.md`](docs/PRODUCT-BAR.md). |

Checklist: [`docs/TASKS-1.4.0.md`](docs/TASKS-1.4.0.md).


## What it heals

| Signal on the Mac | Action |
|---|---|
| Main process not alive | Gentle quit (if needed) + `open -ga "Grok Bot"` |
| Newest dune-reliability heartbeat older than `HEARTBEAT_STALE_SEC` (180s) | Relaunch |
| `bootOutcome` present and not `ready` | Relaunch |
| Same pid and the same `heartbeatAtMs` for ≥ `STUCK_SEC` (120s) | Relaunch (`heartbeat_frozen`) |
| File `grok-bot-local-exec-heal.request` present | One-shot relaunch even if the app looks healthy (`operator_request`) |

Success (`status=healed`, `readiness=ready`) requires the process to be up **and** either a finite heartbeat younger than `HEARTBEAT_STALE_SEC` or `bootOutcome=ready`, within `READINESS_WAIT_SEC` (default 75s). Process-up alone is not success.

## What it does not heal (non-goals)

- Sleep, lid closed, or a Mac that is not running the LaunchAgent.
- Network down, VPN, or signed-out account.
- **S-NEW-D / silent disconnect:** `ListMachines.connected=false` in the cloud while this Mac still shows a live process and a **moving** heartbeat. The LaunchAgent cannot see cloud connect state (`cloudConnectObservable` is always false). A moving heartbeat under the stale threshold is treated as healthy on purpose — the 2026-10-02 incident was this case (heartbeat age about 31–45s, heal never fired).
- Waking the display or repairing WAN.

If `last.json` stays `status=ok` / `readiness=local_healthy` while the cloud link is down, restart Grok Bot yourself. After `OK_HINT_SEC` (default 300s) of continuous local health, `escalateHint` names S-NEW-D so morning triage is not an empty “healthy” with no caveat. A future fix needs a signal this kit does not have; **1.3.0 will not claim it**. The 1.4.0 section above is a proposal, not this LaunchAgent.

Someone **at the Mac** (or any path that can still write files there) can force one relaunch:

```bash
touch ~/Library/Application\ Support/Latch/grok-bot-local-exec-heal.request
```

A remote agent that is already disconnected **cannot** drop that file. The request bypasses the 300s cooldown, is deleted when the relaunch starts, and still has to pass the readiness gate.

## Scenario matrix

| ID | Scenario | In the heal loop? | Result |
|---|---|---|---|
| S1 | Main process down | Yes | Relaunch, reason `process_down`, then readiness gate |
| S2 | Heartbeat age > 180s | Yes | Relaunch, reason `heartbeat_stale_*` |
| S3 | `bootOutcome` set and not `ready` | Yes | Relaunch, reason `boot_outcome_*` |
| S4 | Healthy tick | No-op | `status=ok`, `readiness=local_healthy` |
| S5 | Disable file present | Skip | `status=disabled` (wins over a request file) |
| S6 | Cooldown (300s after a relaunch) | Skip | `status=cooldown` (operator request bypasses) |
| S7 | After relaunch, readiness | Yes | `healed` only if process + fresh heartbeat **or** `bootOutcome=ready`; else `heal_incomplete` / `heal_failed` |
| S8 | Sleep / lid closed | No | No false `healed`. Not a wake agent |
| S9 / S-NEW-D | Cloud disconnected, Mac looks healthy | No | No relaunch. Long ok streak sets `escalateHint`. Operator restart or request file |
| S10 | Intentional quit | Yes, by design | Comes back within ~60s unless `.disable` is set |
| — | Frozen heartbeat timestamp | Yes | Reason `heartbeat_frozen` when `HEAL_ON_STUCK_SESSION=1` |
| — | Operator request file | Yes | Reason `operator_request` |

This kit does **not** claim a green result for sleep or network loss.

## Install / update

On the Mac:

```bash
cd mac-local-exec-self-heal
./install.sh
```

Re-running copies the script and plist template and reloads the agent. macOS only.

## Disable / unload

```bash
touch ~/Library/Application\ Support/Latch/grok-bot-local-exec-heal.disable
launchctl bootout gui/$(id -u)/com.latch.grok-bot-local-exec-heal
```

Remove the disable file to arm the agent again. Intentional quit still relaunches within about a minute while the agent is loaded and the disable file is absent.

## Verify

```bash
launchctl print gui/$(id -u)/com.latch.grok-bot-local-exec-heal | head -40
cat ~/Library/Logs/GrokBotLocalExecHeal-last.json
```

`last.json` (schema version 2) includes `status`, `reason`, `action`, `pid`, `heartbeatAgeSec`, `heartbeatAtMs`, `bootOutcome`, `readiness`, `escalateHint`, `lastHealAtMs`, frozen/ok-streak clocks, and `cloudConnectObservable: false`.

## Tests

CI-safe fixtures (no live app, no `open`, no `osascript`):

```bash
./tests/run-tests.sh
```

Covers healthy, disable, cooldown, readiness pass / incomplete / failed, operator request (including cooldown bypass), frozen heartbeat above and under `STUCK_SEC`, stale-vs-frozen priority, moving-heartbeat no-heal (S-NEW-D regression), long-ok escalate hint, and missing app.

Live prove — **quits Grok Bot.app** — only on macOS, only when you set `LIVE=1`, and only after 1.3.0 is installed:

```bash
LIVE=1 ./tests/live-process-down.sh
```

Without `LIVE=1` the live script exits 2 and does nothing. It is not called by `run-tests.sh`.

## Paths

| Piece | Path |
|---|---|
| Script | `~/Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh` |
| LaunchAgent | `~/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist` |
| Label | `com.latch.grok-bot-local-exec-heal` · StartInterval 60s · RunAtLoad |
| Log | `~/Library/Logs/GrokBotLocalExecHeal.log` |
| Last state | `~/Library/Logs/GrokBotLocalExecHeal-last.json` |
| Disable | `~/Library/Application Support/Latch/grok-bot-local-exec-heal.disable` |
| Force once | `~/Library/Application Support/Latch/grok-bot-local-exec-heal.request` |

Cursor is not relaunched unless `HEAL_CURSOR=1`. The local-exec path is Grok Bot.app.

## Risk

If you quit Grok Bot on purpose, this agent brings it back unless the disable file is set. A relaunch can briefly bounce the Dock icon. Duplicate instances are mitigated by quit-first.

## Optional: worker-beacon poll (unreleased, off by default)

Set all three in the LaunchAgent environment to enable one outbound `POST /v1/poll` per tick: `BEACON_URL`, `BEACON_MACHINE_ID`, `BEACON_POLL_TOKEN_FILE` (a file outside this repo holding the poller bearer token). Worker source: [`worker-beacon/`](worker-beacon/). A pending request relaunches like `operator_request` with reason `beacon_request` and bypasses the 300s cooldown. `.disable` wins and skips the poll, so the request stays queued until its `exp`. A second beacon request inside `BEACON_RELAUNCH_WINDOW_SEC` (3600) of a beacon relaunch is not honored (`beacon_suppressed`, escalate). Worker unreachable or malformed reply: no-op. Not deployed, not proven live.
