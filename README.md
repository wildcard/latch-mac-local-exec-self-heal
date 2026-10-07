# Grok Bot Mac local-exec self-heal (Latch)

LaunchAgent that runs **on the Mac** and gently relaunches [Grok Bot](https://grok.com) when local readiness signals say the desktop session is down or stuck.

It does not need a cloud shell. Once the desktop link is gone, a remote agent cannot install or run this for you — it has to already be loaded.

**Version:** see `VERSION` (current **1.5.0**).

## Status

- **Kit:** LaunchAgent, install and hermetic tests. Heals a dead process, a stale heartbeat, a bad `bootOutcome`, a frozen `heartbeatAtMs`, and an on-Mac `.request` file (table below).
- **Beacon (optional, off by default):** a heal-only inbox. The Worker in [`worker-beacon/`](worker-beacon/) runs on the operator's personal Cloudflare (https://latch-worker-beacon.kadosh.workers.dev); the Mac polls it outbound over HTTPS only (non-`https://` `BEACON_URL` is refused). A pending request relaunches Grok Bot (reason `beacon_request`) and bypasses the 300s cooldown. Proven live: [Prove C′ on 1.4.1](docs/1.4.1/PROVE-C-1.4.1-2026-10-05.md), [`.disable` wins](docs/1.4.0/PROVE-DISABLE-2026-10-05.md).
- **S-NEW-D (silent disconnect, moving heartbeat):** `cloudConnectObservable` is always `false`. **1.5.0** adds a Mac-local observer for the **helper-exit signature** seen in the real 2026-10-07 outage (one of two `Grok Bot Helper` `node.mojom.NodeService` utility processes gone while the main process stays healthy): reason `helper_missing`, **log-only by default** (`HEAL_ON_HELPER_MISSING=0`), relaunch opt-in. Agents must auto-POST the beacon request ([agent loop](docs/1.5.0/AGENT-LOOP.md)). Prove D **failed** on 2026-10-07 because nothing posted: [`docs/1.5.0/PROVE-D-FAIL-2026-10-07.md`](docs/1.5.0/PROVE-D-FAIL-2026-10-07.md). Background: [`docs/PRODUCT-BAR.md`](docs/PRODUCT-BAR.md).
- **Every capability, its test, live proof and status:** [`docs/CAPABILITY-CHECKS.md`](docs/CAPABILITY-CHECKS.md). History by version: [`CHANGELOG.md`](CHANGELOG.md).

## What it heals

| Signal on the Mac | Action |
|---|---|
| Main process not alive | Gentle quit (if needed) + `open -ga "Grok Bot"` |
| Newest dune-reliability heartbeat older than `HEARTBEAT_STALE_SEC` (180s) | Relaunch |
| `bootOutcome` present and not `ready` | Relaunch |
| Same pid and the same `heartbeatAtMs` for ≥ `STUCK_SEC` (120s) | Relaunch (`heartbeat_frozen`) |
| File `grok-bot-local-exec-heal.request` present | One-shot relaunch even if the app looks healthy (`operator_request`) |
| NodeService helper count below expected for ≥ `HELPER_MISSING_SEC` (300s) (1.5.0) | **Log-only by default** (`status=observe`, reason `helper_missing`, snapshot). Relaunch only with `HEAL_ON_HELPER_MISSING=1` (respects cooldown; one per `HELPER_RELAUNCH_WINDOW_SEC`) |

Success (`status=healed`, `readiness=ready`) requires the process to be up **and** either a finite heartbeat younger than `HEARTBEAT_STALE_SEC` or `bootOutcome=ready`, within `READINESS_WAIT_SEC` (default 75s). Process-up alone is not success.

## What it does not heal (non-goals)

- Sleep, lid closed, or a Mac that is not running the LaunchAgent.
- Network down, VPN, or signed-out account.
- **S-NEW-D / silent disconnect:** `ListMachines.connected=false` in the cloud while this Mac still shows a live process and a **moving** heartbeat. The LaunchAgent cannot see cloud connect state (`cloudConnectObservable` is always false). A moving heartbeat under the stale threshold is treated as healthy on purpose — the 2026-10-02 incident was this case (heartbeat age about 31–45s, heal never fired).
- Waking the display or repairing WAN.

If `last.json` stays `status=ok` / `readiness=local_healthy` while the cloud link is down, restart Grok Bot yourself. After `OK_HINT_SEC` (default 300s) of continuous local health, `escalateHint` names S-NEW-D so morning triage is not an empty “healthy” with no caveat. The LaunchAgent still cannot detect it. Since 1.4.0 a bot or operator that sees `ListMachines.connected=false` can POST a heal-request to the worker-beacon (see below), which relaunches Grok Bot; nothing auto-detects S-NEW-D, and a real-disconnect prove (Prove D) is still open.

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
| S9 / S-NEW-D | Cloud disconnected, Mac looks healthy | Beacon | Agent auto-POSTs the beacon ([agent loop](docs/1.5.0/AGENT-LOOP.md)). Long ok streak sets `escalateHint` |
| S-NEW-D helper exit | Main healthy, one NodeService helper gone (1.5.0) | Log-only default | `observe` / `helper_missing` + snapshot; `HEAL_ON_HELPER_MISSING=1` relaunches |
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
Custom LaunchAgent `EnvironmentVariables` already on disk (`BEACON_*`, `HEAL_CURSOR`, `COOLDOWN_SEC`, and other operator tunables) are preserved across reinstalls; kit-owned `PATH` comes from the template. Use `INSTALL_RESET_ENV=1` for a deliberate wipe back to template defaults. `INSTALL_SKIP_LAUNCHD=1` is for hermetic tests only — do not export it in your shell profile or the agent will never be (re)registered.

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

`last.json` (schema version 2) includes `status`, `reason`, `action`, `pid`, `heartbeatAgeSec`, `heartbeatAtMs`, `bootOutcome`, `readiness`, `escalateHint`, `lastHealAtMs`, frozen/ok-streak clocks, and `cloudConnectObservable: false`. 1.5.0 adds `helperCount`, `helperPids`, `helperExpected` (+ source and learned-baseline clocks), `helperMissingSinceMs`, `helperSockets`, `lastHelperHealAtMs`, and `lastSnapshot`. On any tick whose status is not `ok`/`disabled`, a `GrokBotLocalExecHeal-snap-*.json` (decision + helper fields + main/child process names, no argv) is written next to it, rate-limited and pruned.

### Helper observer tunables (1.5.0)

| Env | Default | Meaning |
|---|---|---|
| `HEAL_ON_HELPER_MISSING` | `0` | `0` log-only; `1` relaunch on `helper_missing` |
| `HELPER_MISSING_SEC` | `300` | How long the count must stay below expected |
| `HELPER_EXPECTED` | *(empty)* | Explicit expected count; empty = learned baseline |
| `HELPER_BASELINE_SEC` | `600` | Stable-and-healthy time before a count becomes the baseline |
| `HELPER_RELAUNCH_WINDOW_SEC` | `3600` | One `helper_missing` relaunch per window, then `helper_suppressed` |
| `HELPER_SOCKET_CHECK` / `HELPER_SOCKET_PORT` | `1` / `443` | Observe-only established-socket counts per helper |
| `HELPER_CHECK` | `1` | `0` disables the scan |
| `HEAL_SNAPSHOT_MIN_SEC` / `HEAL_SNAPSHOT_KEEP` / `HEAL_SNAPSHOT_DIR` | `900` / `20` / logs dir | Snapshot rate limit, retention, location |

macOS diagnostics: the unified log can label Grok Bot under another Electron app's name — filter `log show` by `processID`; in zsh call `/usr/bin/log` (`log` is a builtin).

## Tests

CI-safe fixtures (no live app, no `open`, no `osascript`):

```bash
./tests/run-tests.sh
```

Covers healthy, disable, cooldown, readiness pass / incomplete / failed, operator request (including cooldown bypass), frozen heartbeat above and under `STUCK_SEC`, stale-vs-frozen priority, moving-heartbeat no-heal (S-NEW-D regression), long-ok escalate hint, missing app, and the kit/`VERSION` pin. It also covers the beacon poll hook (heal, no-op, bad reply, Worker down, unconfigured, cooldown bypass, `.disable` queued, one heal per outage, local-request precedence), token-file hygiene (0640/0644 refuse, 0600/0400 poll, perms-unknown fails closed, quote refused), the 1.5.0 helper observer (baseline learning, log-only vs relaunch, cooldown, one relaunch per window, operator/beacon/disable precedence, pid-change reset, socket counts without addresses, snapshot rate-limit/prune/no-argv) with canned `ps`/`lsof` fixtures, and `install.sh` env preservation (temp `HOME`, launchd skipped). Worker: `cd worker-beacon && npm test`. The full capability-to-test map is [`docs/CAPABILITY-CHECKS.md`](docs/CAPABILITY-CHECKS.md).

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

## Optional: worker-beacon poll (1.4.0, off by default)

Set all three in the LaunchAgent environment to enable one outbound `POST /v1/poll` per tick: `BEACON_URL`, `BEACON_MACHINE_ID`, `BEACON_POLL_TOKEN_FILE` (a file outside this repo holding the poller bearer token). Worker source: [`worker-beacon/`](worker-beacon/). A pending request relaunches like `operator_request` with reason `beacon_request` and bypasses the 300s cooldown. `.disable` wins and skips the poll, so the request stays queued until its `exp`. A second beacon request inside `BEACON_RELAUNCH_WINDOW_SEC` (3600) of a beacon relaunch is not honored (`beacon_suppressed`, escalate). Worker unreachable or malformed reply: no-op. The Worker is deployed and live on the operator's personal Cloudflare at https://latch-worker-beacon.kadosh.workers.dev. Writer and poller tokens are Worker secrets and live in a token file outside this repo, never in git. Prove C passed on the beacon path ([`docs/1.4.0/PROVE-C-2026-10-05.md`](docs/1.4.0/PROVE-C-2026-10-05.md)); Prove D is still open.
