# Grok Bot Mac local-exec self-heal (Latch)

LaunchAgent that runs **on the Mac** and gently relaunches [Grok Bot](https://grok.com) when local readiness signals say the desktop session is down or stuck.

It does not need a cloud shell. Once the desktop link is gone, a remote agent cannot install or run this for you — it has to already be loaded.

**Version:** see `VERSION` (current **1.6.0**).

## Status

- **Kit:** LaunchAgent, install and hermetic tests. Heals a dead process, a stale heartbeat, a bad `bootOutcome`, a frozen `heartbeatAtMs`, and an on-Mac `.request` file (table below).
- **Beacon (optional, off by default):** a heal-only inbox. The Worker in [`worker-beacon/`](worker-beacon/) runs on the operator's personal Cloudflare (https://<operator-worker-host>); the Mac polls it outbound over HTTPS only (non-`https://` `BEACON_URL` is refused). A pending request relaunches Grok Bot (reason `beacon_request`) and bypasses the 300s cooldown. Proven live: [Prove C′ on 1.4.1](docs/1.4.1/PROVE-C-1.4.1-2026-10-05.md), [`.disable` wins](docs/1.4.0/PROVE-DISABLE-2026-10-05.md).
- **S-NEW-D (silent disconnect, moving heartbeat):** `cloudConnectObservable` is always `false`. **1.5.0** adds a Mac-local observer for the **helper-exit signature** (one of two `Grok Bot Helper` `node.mojom.NodeService` utility processes gone while the main process stays healthy): reason `helper_missing`. **1.6.0** turns that relaunch on by default (`HEAL_ON_HELPER_MISSING=1`, policy (a): no idle authorization). Set the flag to `0` for log-only. `HELPER_IDLE_REQUIRED=1` opts back into a PID-bound one-use idle authorization. Prove D remains open: [`docs/1.5.0/PROVE-D-FAIL-2026-10-07.md`](docs/1.5.0/PROVE-D-FAIL-2026-10-07.md). The agent runbook is [`docs/1.5.0/AGENT-LOOP.md`](docs/1.5.0/AGENT-LOOP.md); its immediate-relaunch rule is a proposal, not kit behavior. Background: [`docs/PRODUCT-BAR.md`](docs/PRODUCT-BAR.md).
- **Restart guard (1.6.0):** every Grok Bot relaunch and every Codex reopen writes an attempt to `grok-bot-restart-attempts.json` before quit or `open`. Backoff starts at 300s and doubles to 1800s. Three attempts for one key inside a rolling hour return `circuit_open`. A `grok-bot-restart.hold` file blocks every restart path. A missing guard fails closed (`restart_guard_missing`). `install.sh` always installs the guard.
- **Codex keep-alive (1.6.0):** if `/Applications/ChatGPT.app` is present, the kit watches the main process (bundle id `com.openai.codex`, comm `ChatGPT`, matched by bundle path and pid). Default policy `crash_only` reopens with `open -gb com.openai.codex` only when a matching crash report is newer than the last observed launch. `CODEX_REOPEN_POLICY=any_exit` reopens whenever that main process is absent. The kit never kills a running Codex. A pause file, the global disable file, and the maintenance hold all block a reopen.
- **Every capability, its test, live proof and status:** [`docs/CAPABILITY-CHECKS.md`](docs/CAPABILITY-CHECKS.md). History by version: [`CHANGELOG.md`](CHANGELOG.md).

## What it heals

| Signal on the Mac | Action |
|---|---|
| Main process not alive | Gentle quit (if needed) + `open -ga "Grok Bot"` |
| Newest dune-reliability heartbeat older than `HEARTBEAT_STALE_SEC` (180s) | Relaunch |
| `bootOutcome` present and not `ready` | Relaunch |
| Same pid and the same `heartbeatAtMs` for ≥ `STUCK_SEC` (120s) | Relaunch (`heartbeat_frozen`) |
| File `grok-bot-local-exec-heal.request` present | One-shot relaunch even if the app looks healthy (`operator_request`) |
| NodeService helper count below expected for ≥ `HELPER_MISSING_SEC` (300s) (1.5.0) | **Relaunch by default** (`HEAL_ON_HELPER_MISSING=1`), then `helper_suppressed` while the count is still below the floor. `=0` is log-only (`status=observe`). Every relaunch also passes the restart guard |
| Codex main process absent (1.6.0) | Reopen with `open -gb com.openai.codex` when `CODEX_WATCH` is on. `crash_only` (default) needs a matching crash report newer than the last observed launch. `any_exit` reopens on any absence. Never kills a running Codex |

Success (`status=healed`, `readiness=ready`) requires the process to be up **and** either a finite heartbeat younger than `HEARTBEAT_STALE_SEC` or `bootOutcome=ready`, within `READINESS_WAIT_SEC` (default 75s). Process-up alone is not success.

## What it does not heal (non-goals)

- Sleep, lid closed, or a Mac that is not running the LaunchAgent.
- Network down, VPN, or signed-out account.
- **S-NEW-D / silent disconnect:** `ListMachines.connected=false` in the cloud while this Mac still shows a live process and a **moving** heartbeat. The LaunchAgent cannot see cloud connect state (`cloudConnectObservable` is always false). A moving heartbeat under the stale threshold is treated as healthy on purpose — the 2026-10-02 incident was this case (heartbeat age about 31–45s, heal never fired).
- Waking the display or repairing WAN.

If `last.json` stays `status=ok` / `readiness=local_healthy` while the cloud link is down, restart Grok Bot yourself. After `OK_HINT_SEC` (default 300s) of continuous local health, `escalateHint` names S-NEW-D so morning triage is not an empty “healthy” with no caveat. The LaunchAgent still cannot detect it. Since 1.4.0 a bot or operator that sees `ListMachines.connected=false` can POST a heal-request to the worker-beacon (see below), which relaunches Grok Bot; nothing auto-detects S-NEW-D, and a real-disconnect prove (Prove D) is still open.

## `last.json` values you will see

Written every tick that gets the lock (`~/Library/Logs/GrokBotLocalExecHeal-last.json`). 1.6.0 adds `restart_blocked` and a `codex` object.

| Field | Value | Meaning |
|---|---|---|
| `status` | `ok` | Local signals look healthy. No relaunch. |
| `status` | `observe` | **1.5.0.** Log-only `helper_missing`. Snapshot written. The app is not quit. |
| `status` | `helper_suppressed` | **1.5.0.** Heal is on, a `helper_missing` relaunch already ran, and the helper count is still below the floor. Stays here until the live count meets that floor. It does not relaunch every hour. |
| `status` | `cooldown` | A relaunch is due but `COOLDOWN_SEC` has not elapsed. |
| `status` | `healed` / `heal_incomplete` / `heal_failed` | Relaunch ran; readiness passed, timed out, or the process did not come up. |
| `status` | `disabled` | Disable file present. No relaunch, no snapshot. |
| `status` | `beacon_suppressed` | A second beacon request arrived inside the beacon window. After `BEACON_RELAUNCH_WINDOW_SEC` the next request is honored. |
| `status` | `restart_blocked` | **1.6.0.** The restart guard refused this relaunch (`maintenance_hold`, `retry_backoff`, `circuit_open`, `restart_guard_missing`, `restart_guard_error`, or an idle-authorization result). The request file is left in place. |
| `reason` | `helper_missing` | NodeService helper count has been below expected for ≥ `HELPER_MISSING_SEC`. Paired with `status=observe` when `HEAL_ON_HELPER_MISSING=0`, or `status=helper_suppressed` after a relaunch while the count has not recovered. |
| `reason` | `healthy` | Nothing to heal. |
| `reason` | `process_down`, `heartbeat_stale_<seconds>s`, `boot_outcome_<token>`, `heartbeat_frozen`, `operator_request`, `beacon_request` | The other relaunch causes. |
| `readiness` | `helper_missing_observe` | **1.5.0.** This tick saw `helper_missing` and did not relaunch because `HEAL_ON_HELPER_MISSING=0`. |
| `readiness` | `helper_suppressed` | **1.5.0.** Same signal, heal is on, and the floor is still unmet. |
| `readiness` | `local_healthy` / `ready` | Healthy tick / post-relaunch success. |

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
| S9 / S-NEW-D | Cloud disconnected, Mac looks healthy | Beacon | A beacon POST relaunches. The agent runbook’s immediate-relaunch rule is a proposal ([agent loop](docs/1.5.0/AGENT-LOOP.md)). Long ok streak sets `escalateHint` |
| S-NEW-D helper exit | Main healthy, one NodeService helper gone (1.5.0) | Yes, by default in 1.6.0 | `helper_missing` relaunches once, then suppressed while still short. `HEAL_ON_HELPER_MISSING=0` stays `observe` |
| Codex main down | ChatGPT.app main process absent (1.6.0) | Yes, when the app is installed | `crash_only` reopens only with a matching crash report. `any_exit` reopens on absence. Pause, disable, and hold win. A running Codex is never killed |
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

For the first live week, set `HELPER_EXPECTED=2`. Put it in the LaunchAgent plist so a reinstall keeps it, the same way `BEACON_*` is kept. The template does not pin the key. `install.sh` preserves an existing `HELPER_EXPECTED` (`T-install-preserves-helper-env`).

```bash
plutil -replace EnvironmentVariables.HELPER_EXPECTED -string 2 \
  ~/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist
launchctl bootout "gui/$(id -u)/com.latch.grok-bot-local-exec-heal" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist
```

Custom LaunchAgent `EnvironmentVariables` already on disk (`BEACON_*`, `HELPER_EXPECTED`, `HEAL_CURSOR`, `COOLDOWN_SEC`, and other operator tunables) are preserved across reinstalls; kit-owned `PATH` comes from the template. `HEAL_TEST_MODE` is removed on reinstall and is never kept. The template does not pin `HEAL_ON_HELPER_MISSING` or `HELPER_MISSING_SEC` or the other helper timings. Those are script defaults (`HEAL_ON_HELPER_MISSING` defaults to 1 when the key is absent), so a later kit change is not frozen into an existing plist. An operator who set `HEAL_ON_HELPER_MISSING=0` keeps log-only across reinstall. The template does pin `CODEX_REOPEN_POLICY=crash_only`. Switch to any-exit by setting that key to `any_exit` in the plist environment, then reloading the agent. Use `INSTALL_RESET_ENV=1` for a deliberate wipe back to template defaults. `INSTALL_SKIP_LAUNCHD=1` is for hermetic tests only — do not export it in your shell profile or the agent will never be (re)registered.

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

`last.json` (schema version 2) includes `status`, `reason`, `action`, `pid`, `heartbeatAgeSec`, `heartbeatAtMs`, `bootOutcome`, `readiness`, `escalateHint`, `lastHealAtMs`, frozen/ok-streak clocks, and `cloudConnectObservable: false`. 1.5.0 adds `helperCount`, `helperPids`, `helperExpected` (+ source and a baseline learned once per pid), `helperHealthySamples`, `helperFloorPending`, `helperNoneSeen`, `helperBaselineLow` (learned baseline is 1 and `HELPER_EXPECTED` is unset; log-only hint), `helperMissingSinceMs`, `helperSockets`, `lastHelperHealAtMs`, and `lastSnapshot`. 1.6.0 adds a `codex` object (`watched`, `appPresent`, `policy`, `bundleId`, `status`, `running`, `pid`, `launchedAtMs`, `action`, `readiness`, `lastReopenAtMs`). Crash-report file names are not stored. On any tick whose status is not `ok`/`disabled`, a `GrokBotLocalExecHeal-snap-*.json` (mode `0600`, directory `0700`) is written next to it: decision, helper fields, and main/child comm names. No argv. Rate-limited and pruned.

### Helper observer tunables (1.5.0)

| Env | Default | Meaning |
|---|---|---|
| `HEAL_ON_HELPER_MISSING` | `1` | `1` (policy (a), the 1.6.0 default) sends `helper_missing` through quit + `open -ga`, the readiness gate, the restart guard, the single-flight lock, and `COOLDOWN_SEC`. No idle authorization. `0` is log-only (`status=observe`, snapshot, no relaunch). After a relaunch the old expected count is a floor: while the live count is still short the status stays `helper_suppressed` (no second relaunch, lower count not stored), including after `HELPER_RELAUNCH_WINDOW_SEC`. A beacon, operator, heartbeat-stale, or process-down relaunch keeps that floor when a helper-short interval is already open. A new drop can relaunch only once the count has met the floor and that window has elapsed. It does not see `ListMachines.connected`. |
| `HELPER_IDLE_REQUIRED` | `0` | `1` opts `helper_missing` back into a PID-bound one-use idle authorization file (`grok-bot-restart-idle.json`). Other reasons never require it. The guard command follows the same default: an omitted flag does not require a lease |
| `HELPER_MISSING_SEC` | `300` | How long the count must stay below expected. Non-numeric values use 300; values below 1 clamp to 1 |
| `HELPER_EXPECTED` | *(empty)* | Explicit expected count. When set it wins over the learned baseline. Empty = learn once per pid. Not pinned by the plist template |
| `HELPER_BASELINE_SEC` | `600` | Window after the pid appears before the minimum positive count is learned once. Also needs at least 3 healthy samples. A higher count does not move that minimum. A lower count moves it only after 2 consecutive healthy ticks. An unhealthy tick does not seed it. The tick that would complete the window does not learn while its count is still below that minimum. An already-learned baseline is never raised or lowered. Not learned during a relaunch or the grace period. Non-numeric values use 600; values below 60 clamp to 60 |
| `HELPER_RELAUNCH_WINDOW_SEC` | `3600` | After the floor has been met, minimum gap before another `helper_missing` relaunch. Non-numeric values use 3600; values below 1 clamp to 1. While the count is still short this window does not re-arm a relaunch |
| `HELPER_SOCKET_CHECK` / `HELPER_SOCKET_PORT` | `1` / `443` | Observe-only established-socket counts on every tick that has helper pids. Logged as `helper_sockets`. Not a heal trigger. `lsof` exit 1 with empty stderr is 0 sockets per helper; any other failure leaves `helperSockets` null |
| `HELPER_CHECK` | `1` | `0` disables the scan |
| `HEAL_SNAPSHOT_MIN_SEC` / `HEAL_SNAPSHOT_KEEP` / `HEAL_SNAPSHOT_DIR` | `900` / `20` / logs dir | Snapshot rate limit, retention, location |

`HEAL_ON_HELPER_MISSING=1` still misses a silent disconnect that does not drop a NodeService helper. The baseline is learned once, as the minimum positive count over the window, so a transient 3 at launch does not make a healthy 2 look missing, and a third helper cannot raise a learned 2. A second helper that shows up only after learning was observed on the live Mac (main up 1d10h57m, NodeService helpers up 1d10h57m and 4h29m, likely a respawn mid-life). `HELPER_EXPECTED=2` is the recommended setting. The residual risk is a kit installed mid-outage that learns the short count after 600s of local health. `cloudConnectObservable` stays `false`. The app-side fix is a non-secret status file: [`docs/1.5.0/PRODUCT-STATUS-FILE.md`](docs/1.5.0/PRODUCT-STATUS-FILE.md).

### Restart guard (1.6.0)

`install.sh` copies `grok-bot-restart-guard.py` into the kit bin directory. The heal script calls it immediately before quit/`open` for Grok Bot (`key=grok`) and before `open -gb` for Codex (`key=codex`). The attempt is appended to `grok-bot-restart-attempts.json` (mode `0600`) before either command runs. A legacy flat list is accepted as the grok key and rewritten as `{"v":2,"attempts":{...}}` on the next allow. One bad element (non-number, bool, string, NaN, infinity, negative, or a future timestamp) fails the whole file closed (`restart_guard_error`) and does not rewrite it. A symlink, wrong owner, or group/world-readable state file also fails closed. A missing guard file is `restart_guard_missing` and blocks the Grok relaunch. Backoff is `min(1800, 300 * 2^(n-1))` seconds after n attempts in the rolling hour. The fourth attempt inside that hour is `circuit_open` (the cap is three). `grok-bot-restart.hold` (including a symlink) returns `maintenance_hold` before the ledger is read and blocks every key.

### Codex keep-alive (1.6.0)

| Env | Default | Meaning |
|---|---|---|
| `CODEX_WATCH` | *(empty = auto)* | Empty: watch when `CODEX_APP_PATH` exists, otherwise `app_absent` and no reopen. `0` does not scan. `1` watches and reports `app_absent` when the bundle directory is missing. Any other value is `watch_invalid` and does not reopen |
| `CODEX_APP_PATH` | `/Applications/ChatGPT.app` | Bundle directory. The main process is comm `ChatGPT` and executable `$CODEX_APP_PATH/Contents/MacOS/ChatGPT`. Helpers, ChatGPT Classic, and a `ChatGPT.localized` path do not match |
| `CODEX_BUNDLE_ID` | `com.openai.codex` | Passed to `open -gb`. Also the crash-report bundle token |
| `CODEX_REOPEN_POLICY` | `crash_only` | `crash_only` reopens only when a regular `.ips` or `.crash` file names this bundle and the main process, and is newer than the last observed launch. No prior launch means no reopen. `any_exit` reopens whenever the main process is absent. Anything else is `policy_invalid` |
| `CODEX_PAUSE` | `~/Library/Application Support/Latch/codex.pause` | Present, including as a symlink, blocks a reopen |
| `CODEX_READINESS_WAIT_SEC` | `30` | How long to wait for the main process after `open`. Optional freshness: if `CODEX_WAL_FILE` is set and is a regular file, its mtime must be at least the open time. A symlink is not fresh |

The process matcher accepts both the short name and macOS full-path `comm`, with an exact bundle executable match. A failed process scan is `process_scan_error` and cannot authorize a reopen. The watcher reads the resolved state path even when `HEAL_STATE` is not exported. Crash reports must have the primary bundle/process identity and an explicit event timestamp after the last observed launch; file modification time alone is insufficient. JSON IPS reports up to 4 MiB and legacy text `.crash` reports are supported; malformed, undated, oversized, or future reports fail closed.

The global disable file skips Codex as well as Grok Bot. The maintenance hold blocks a reopen through the same guard. Codex is evaluated even when Grok Bot.app is missing. The kit never quits or kills Codex, including on a stall. Set `CODEX_REOPEN_POLICY=any_exit` in the LaunchAgent environment to reopen on any exit. `crash_only` stays the plist default.

macOS diagnostics: the unified log can label Grok Bot under another Electron app's name — filter `log show` by `processID`; in zsh call `/usr/bin/log` (`log` is a builtin). Snapshots taken before a relaunch are `GrokBotLocalExecHeal-snap-*-before.json` (file `0600`, directory `0700`). `exe` is `Grok Bot`, `Grok Bot Helper`, or `Grok Bot Helper` with suffix `(GPU)`, `(Renderer)`, `(Plugin)`, or `(Alerts)`; anything else is `other`. `type` is `utility`, `renderer`, `gpu-process`, `zygote`, or `other`. Stored `subType` is one of the five service names or null. Full command lines are not stored. Allowlisted flags (`--type`, `--utility-sub-type`) are kept only for processes inside the app. No tokens, no app-log tails.

## Tests

CI-safe fixtures (no live app, no `open`, no `osascript`):

```bash
./tests/run-tests.sh
```

Covers healthy, disable, cooldown, readiness pass / incomplete / failed, operator request (including cooldown bypass), frozen heartbeat above and under `STUCK_SEC`, stale-vs-frozen priority, moving-heartbeat no-heal (S-NEW-D regression), long-ok escalate hint, missing app, and the kit/`VERSION` pin. It also covers the beacon poll hook (heal, no-op, bad reply, Worker down, unconfigured, cooldown bypass, `.disable` queued, a second request inside the window, a request once the window has elapsed, local-request precedence), token-file hygiene (0640/0644 refuse, 0600/0400 poll, perms-unknown fails closed, quote refused), the helper observer (learn-once baseline, floor across relaunch and pid change, grace recovery, log-only vs relaunch, cooldown, stay-suppressed while short, argv leak fixtures, snapshot mode `0600`/`0700`, socket counts on healthy ticks) with canned `ps`/`lsof` fixtures behind `HEAL_TEST_MODE=1`, the restart guard (allow, backoff, circuit open, hold, disable, idle opt-in, missing guard), Codex (down, healthy, pause, crash report, absent app, `any_exit`, no kill), and `install.sh` env preservation (temp `HOME`, launchd skipped). Python: `python3 -m unittest` (guard, Codex decision, and `beacon-heal-request`). Worker: `cd worker-beacon && npm test`. The full capability-to-test map is [`docs/CAPABILITY-CHECKS.md`](docs/CAPABILITY-CHECKS.md).

`T-bash32-command-subst-heredoc-no-apostrophe` rejects an apostrophe inside a `$(...)` heredoc. When `BASH32` is set to an executable, that test runs `bash -n` on `grok-bot-local-exec-heal.sh`, `install.sh`, and `tests/run-tests.sh` under that binary. If `BASH32` is unset and `/bin/bash` is version 3.x, it uses `/bin/bash`. Otherwise it uses `/tmp/bash-3.2-cache/bin/bash` when that binary exists. If none of those is available it prints a notice and skips the syntax check. GNU bash 3.2.57 builds from the upstream tarball (`./configure --prefix=/tmp/bash-3.2-cache --without-bash-malloc`, then `make` with `-std=gnu89 -fcommon`; the shipped `y.tab.c` is older than `parse.y`, so regenerate it with `bison -y -d parse.y` if `yacc` is not installed). Put that `bash` on `PATH` to run the whole suite under 3.2: `PATH="/tmp/bash-3.2-cache/bin:$PATH" bash tests/run-tests.sh`.

Live prove — **quits Grok Bot.app** — only on macOS, only when you set `LIVE=1`, and only after 1.3.0 is installed:

```bash
LIVE=1 ./tests/live-process-down.sh
```

Without `LIVE=1` the live script exits 2 and does nothing. It is not called by `run-tests.sh`.

## Paths

| Piece | Path |
|---|---|
| Script | `~/Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh` |
| Restart guard | `~/Library/Application Support/Latch/bin/grok-bot-restart-guard.py` |
| Codex watch | `~/Library/Application Support/Latch/bin/codex-watch.py` |
| LaunchAgent | `~/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist` |
| Label | `com.latch.grok-bot-local-exec-heal` · StartInterval 60s · RunAtLoad |
| Log | `~/Library/Logs/GrokBotLocalExecHeal.log` |
| Last state | `~/Library/Logs/GrokBotLocalExecHeal-last.json` |
| Disable | `~/Library/Application Support/Latch/grok-bot-local-exec-heal.disable` |
| Force once | `~/Library/Application Support/Latch/grok-bot-local-exec-heal.request` |
| Maintenance hold | `~/Library/Application Support/Latch/grok-bot-restart.hold` |
| Restart ledger | `~/Library/Application Support/Latch/grok-bot-restart-attempts.json` |
| Codex pause | `~/Library/Application Support/Latch/codex.pause` |

Cursor is not relaunched unless `HEAL_CURSOR=1`. The local-exec path is Grok Bot.app.

## Risk

If you quit Grok Bot on purpose, this agent brings it back unless the disable file or the maintenance hold is set. A relaunch can briefly bounce the Dock icon. Duplicate instances are mitigated by quit-first. Codex is not quit. Under `crash_only` an intentional Codex quit with no crash report stays down. Under `any_exit` an intentional quit comes back unless `codex.pause`, the disable file, or the hold is set. The restart guard caps both at three attempts per rolling hour.

## Optional: worker-beacon poll (1.4.0, off by default)

Set all three in the LaunchAgent environment to enable one outbound `POST /v1/poll` per tick: `BEACON_URL`, `BEACON_MACHINE_ID`, `BEACON_POLL_TOKEN_FILE` (a file outside this repo holding the poller bearer token). Worker source: [`worker-beacon/`](worker-beacon/). A pending request relaunches like `operator_request` with reason `beacon_request` and bypasses the 300s cooldown. `.disable` wins and skips the poll, so the request stays queued until its `exp`. A second beacon request inside `BEACON_RELAUNCH_WINDOW_SEC` (3600) of a beacon relaunch is not honored (`beacon_suppressed`, escalate). The comparison is elapsed seconds, not a permanent latch: once that window has elapsed, including at exactly 3600s, the next request is honored and still has to pass the restart guard. Worker unreachable or malformed reply: no-op. The Worker is deployed and live on the operator's personal Cloudflare at https://<operator-worker-host>. Writer and poller tokens are Worker secrets and live in a token file outside this repo, never in git. Prove C passed on the beacon path ([`docs/1.4.0/PROVE-C-2026-10-05.md`](docs/1.4.0/PROVE-C-2026-10-05.md)); Prove D is still open.

`worker-beacon/bin/beacon-heal-request` posts one heal request from the operator worker host. It is not copied onto the Mac. `BEACON_WRITER_TOKEN_FILE` is required and has no default path; point it at `<path-to-writer-token-file>`. The command refuses a non-https `BEACON_URL` and all HTTP redirects (so the writer credential stays at the configured endpoint), and prints only the HTTP status and the request id. `--dry-run` prints `dry-run` and the request id and does not connect. The token is never printed.
