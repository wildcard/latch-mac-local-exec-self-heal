# Prove D: FAIL, 2026-10-07 (real S-NEW-D on the operator Mac)

**Kit installed:** 1.4.2 (+ worker-beacon poll configured). **Grok Bot:** 0.68.1 stable, darwin arm64.
All times PT (UTC-7). Evidence was gathered read-only on the operator Mac after it reconnected; nothing on the Mac was changed during the investigation.

## Verdict

**Prove D = FAIL.** The kit did not heal. The app recovered on its own after roughly 50 minutes.

- The LaunchAgent ran every ~60s for the whole outage and logged `ok reason=healthy readiness=local_healthy` each tick. By design it could not see the problem (`cloudConnectObservable:false`).
- **No beacon heal-request was posted** for this outage. The Mac's beacon poll ran every tick without errors, so the Worker answered `{"heal":false}` all day. The beacon path was armed; nothing pulled the trigger.
- Recovery came from **inside the app**: the main Grok Bot process (pid unchanged for the whole incident) spawned a new `node.mojom.NodeService` utility helper. It was not a kit heal, not a beacon heal, and not a manual restart.
- A beacon heal-request was deliberately **not** posted after the fact: by the time the agent host was usable again the Mac was already `connected=true` and in active use, and a beacon request forces quit + relaunch of a healthy session.

## Timeline

| Time (PT) | Source | Event |
|---|---|---|
| 13:49–14:07 | agents | Intermittent "temporarily unreachable" on remote shell to the Mac. Helper **B**'s ~30s DNS cadence to the local-exec backend host thins out but helper B stays alive. |
| ~14:07, 14:11 | agents | Last good remote reads. |
| **14:37:47** | unified log | **Helper B** (a `Grok Bot Helper`, `--utility-sub-type=node.mojom.NodeService`, child of the main process since app launch the previous day) runs its exit handlers and exits. **Clean, graceful exit** (exit handlers ran: not SIGKILL / jetsam, no crash report). In the same second helper **A** (the other NodeService helper) stops its own backend-host DNS traffic. |
| 14:37–15:27 | Mac | No Grok Bot helper polls the local-exec backend host. The main process keeps heartbeating; chat and renderer keep working (the operator chats from the app during this window). |
| ~14:46 | cloud | `ListMachines.connected=false` first observed (~8 min after the helper exit). |
| 14:47–14:50 | coordinating agent | Soft-parked ~4 min, then escalated to the operator. **No beacon POST.** |
| every tick | heal log | `ok reason=healthy heartbeat_age≈4–58s`. dune-reliability heartbeat: `bootOutcome=ready`, `childDeaths:{}`, `mainFaultSeen:false`. **The app's own reliability heartbeat did not record the helper exit.** |
| 15:09:07 | Mac | Helper A's backend DNS traffic resumes. |
| 15:13–15:48 | agent host | The agent host itself was unresponsive (load average in the hundreds). No host-side POST would have been possible in this window either way. |
| **15:27:18** | `ps` + unified log | Main spawns **new helper C** (`node.mojom.NodeService`). It resumes the ~30s cadence to the same backend host and holds established 443 connections. **This is the recovery**; trigger unknown. |
| ≤15:42 | cloud | `ListMachines.connected=true`. First remote shell succeeded 15:42:33. |
| 15:41:57 | last.json | `status ok, reason healthy, action none, readiness local_healthy`, `lastHealIso` still from 2026-10-05. |

Outage ≈ 14:37:47 → ~15:27–15:42 (cloud-observed ~14:46 → ≤15:42).

## Ruled out

- **Sleep:** `pmset -g log` has no Sleep / Wake / DarkWake in the window.
- **Network:** the main process kept resolving its hosts every 10–20s through the outage; the chat path stayed up.
- **App restart / kit heal:** main pid unchanged, `lastHealAtMs` from 2026-10-05, no non-ok heal-log line that day.
- **Memory kill:** the helper exit was graceful. Load was elevated (a browser test walk was running) — contributing at most, unproven.

## S-NEW-D helper-exit signature (Mac-local, observable)

1. Main Grok Bot pid alive; dune-reliability heartbeat fresh (<60s); `bootOutcome=ready`; `childDeaths:{}`.
2. **One fewer `Grok Bot Helper` of utility sub-type `node.mojom.NodeService`** than the healthy baseline (baseline 2 → 1 during the outage → 2 after recovery).
3. No Grok Bot helper issuing the ~30s backend-host DNS query or holding 443 connections to the local-exec backend.
4. Cloud `connected=false` while the app's chat works.

Signal 2 is what kit 1.5.0 counts (`helper_missing`). Signal 3 is recorded observe-only (`helperSockets`). The correlation with the cloud window is strong, **not proof**; 1.5.0 therefore ships the detector **log-only** by default.

## Findings

1. **The kit cannot see this class by process/heartbeat, and nothing posted the beacon.** Before 1.5.0, S-NEW-D healing depended 100% on an agent POSTing to the beacon.
2. **Root-cause candidate:** a single utility helper exited cleanly while the main process stayed healthy; the app's reliability heartbeat missed it and took ~50 min to respawn it.
3. **The agent-host path is fragile.** The agent host was down for ~35 min exactly when a POST was needed. A Mac-local detector does not inherit that.
4. **Diagnostics gotchas (macOS):**
   - The unified log can label Grok Bot processes with **another Electron app's name** (on the operator Mac, an unrelated meeting-notes app and its helper): names are resolved by binary UUID. `log show --predicate 'process == "Grok Bot"'` returns nothing. **Filter by pid** (`processID == N`), or use mDNSResponder's `client pid: N (Grok Bot…)` lines.
   - In **zsh**, `log` is a shell builtin. Use **`/usr/bin/log`**.

## What changed because of this

Kit 1.5.0: helper-count observer (`helper_missing`, log-only default), observe-only helper socket counts, `helperPids`/`helperCount` in last.json, diagnostics snapshot on non-ok ticks (and a `before_relaunch` snapshot before quit/`open`), and the agent-loop auto-POST rule ([AGENT-LOOP.md](AGENT-LOOP.md)).

The helper count is a proxy for this outage, not a `ListMachines` signal (`cloudConnectObservable` stays `false`). The product ask — a non-secret `local-exec-status.json`, plus recording clean utility-helper exits in `childDeaths` and respawning that helper promptly — is written up in [PRODUCT-STATUS-FILE.md](PRODUCT-STATUS-FILE.md). 1.5.0 does not implement that file.
