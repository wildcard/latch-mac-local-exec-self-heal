# Agent loop when the Mac link drops (1.5.0)

Applies to any agent (coordinator, watch routine, or worker) that depends on the operator Mac and can see `ListMachines`. Lesson from [Prove D FAIL 2026-10-07](PROVE-D-FAIL-2026-10-07.md): the beacon was armed, but no agent posted, because the loop said "soft-park, then ask the operator".

## Rule

**POST a beacon heal-request automatically — no human in the loop — when either holds:**

- **A.** `ListMachines` has shown the Mac `connected=false` for **≥ 3 minutes** (two polls at least ~60s apart, first and last ≥ 3 min apart), **or**
- **B.** **Immediately**, when a user message arrives from a machine (`[Sent from machine <id>]`) that `ListMachines` shows `connected=false`. The app's chat is up while local-exec is down: that is the definitive S-NEW-D signal; do not soft-park first.

Do **not** POST when the Mac is `connected=true`, when the operator has said they quit Grok Bot on purpose, or when the agent cannot reach the Worker (then escalate).

## Brakes (unchanged)

- Worker limits: 1 accepted request per 5 min, 3 per hour per machine; `jti` single-use; `exp` ≤ 120s.
- Mac side: one beacon relaunch per outage (`BEACON_RELAUNCH_WINDOW_SEC`, 3600s). A second request inside the window is not honored (`beacon_suppressed`) — that is the signal to escalate to the operator.
- `.disable` on the Mac wins; the request stays queued until its `exp`.

## Steps

1. `ListMachines`. If `connected=false`, stop issuing `Shell(machineId)` against that Mac.
2. Soft-park Mac-dependent work and note the first `connected=false` time.
3. When rule A or B fires: POST one heal-request to the beacon (writer token from the agent host's token file; never print or log it).
4. Wait ~60–90s, re-poll `ListMachines`.
5. On `connected=true`: read `~/Library/Logs/GrokBotLocalExecHeal-last.json` (status, reason, `lastBeaconHealAtMs`, `helperCount`, `lastSnapshot`) and the newest `GrokBotLocalExecHeal-snap-*.json`.
6. Still `connected=false` after the beacon relaunch plus ~3 min, or the POST was refused / rate-limited: escalate to the operator once, with the evidence.

## Why not only the agent loop

The agent host can be down too (it was, for ~35 min, on 2026-10-07). The Mac-local `helper_missing` detector in 1.5.0 does not depend on any agent; once its log-only week confirms the baseline is stable, `HEAL_ON_HELPER_MISSING=1` lets the Mac heal itself.

## Diagnostics after reconnect

- `/usr/bin/log show --start '<t0>' --end '<t1>' --predicate 'processID == <pid>'` — filter by **pid**, not process name (the unified log can label Grok Bot under another Electron app's name). In zsh, `log` is a builtin; call `/usr/bin/log`.
- `ps -axww -o pid,ppid,etime,command | grep 'Grok Bot Helper'` — count `--utility-sub-type=node.mojom.NodeService` children of the main pid (healthy baseline was 2).
