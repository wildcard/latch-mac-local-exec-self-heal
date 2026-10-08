# Product follow-up — non-secret local-exec status file

**Status:** not built. Kit **1.5.0** does not read or require this file.  
**Ask:** Grok Bot (the app) should write it. This kit will not scrape credential JSON while waiting.

## What 1.5.0 does without it

1.5.0 does **not** observe `ListMachines.connected`. `cloudConnectObservable` stays `false`.

The 2026-10-02 dig ([RESEARCH-GROK-BOT-CONNECTION](../1.4.0/RESEARCH-GROK-BOT-CONNECTION-20261002.md)) found no on-disk or localhost mirror of that bit. dune-reliability heartbeat and `desktop-status.json` stayed healthy through both published silent-disconnect windows. 1.5.0 therefore does not retune `HEARTBEAT_STALE_SEC` or `STUCK_SEC`, and it does not treat a missing `local-exec-daemon*.json` as disconnected.

What it adds is a **Mac-local proxy for one observed cause**, the 2026-10-07 helper exit ([PROVE-D-FAIL](PROVE-D-FAIL-2026-10-07.md)):

- Count `Grok Bot Helper` children of the main pid whose argv contains `--utility-sub-type=node.mojom.NodeService`. Healthy baseline on that outage was 2.
- Below the learned or configured expected count for ≥ `HELPER_MISSING_SEC` (300s) → reason `helper_missing`.
- **Log-only by default** (`HEAL_ON_HELPER_MISSING=0`): `status=observe`, diagnostics snapshot, no relaunch. The beacon poll still runs.
- `HEAL_ON_HELPER_MISSING=1` relaunches through the existing quit + `open -ga` path and readiness gate. It respects the single-flight lock and `COOLDOWN_SEC`, and it allows one helper relaunch per `HELPER_RELAUNCH_WINDOW_SEC` (3600) before `helper_suppressed`.

That proxy does **not** cover every silent disconnect. The 2026-10-02 incident kept a moving heartbeat with no recorded helper exit. A full helper count is not evidence the cloud link is up. Socket counts (`helperSockets`) are diagnostics only and never trigger a relaunch.

App logs are not tailed. The 0.66 dig did not find a documented, timestamped, secret-free log line for roster state, and credential files must not be parsed.

## What we need from the app

Write a non-secret status file the LaunchAgent can poll. Suggested path (mode `0644`, atomic replace):

`~/Library/Application Support/Grok Bot/local-exec-status.json`

```json
{
  "v": 1,
  "machineId": "<same id ListMachines returns>",
  "rosterConnected": false,
  "stream": "down",
  "reason": "sse_stall",
  "lastTransitionAtMs": 0,
  "lastHeartbeatSentAtMs": 0
}
```

Contract:

- `rosterConnected` is the bit `ListMachines.connected` uses for this machine. It is not “dune heartbeat is fresh” and not “a TCP socket exists.”
- `stream` is the daemon’s own view (`up` / `down` / `backoff`), so a server-roster drop is visible before the process notices.
- Updated on every transition and at least every liveness window, **including the healthy state**. A missing file must not mean down (on 0.66 the connection JSON was already absent while `connected=true`).
- `reason` is an enum only (`sse_stall`, `unauthorized`, `liveness_window`, `no_provider`, `backoff`, `ok`). No request bodies, no commands, no tokens, no baseUrl, no headers, no installId.
- `v` is stable or explicitly versioned so a kit can ignore an unknown value.

Also, from the 2026-10-07 outage: a clean exit of one `node.mojom.NodeService` helper left `childDeaths` empty and the helper was not respawned for ~50 minutes. Please record utility-helper exits (including clean exits) in `childDeaths`, and respawn the local-exec helper without waiting for a full app restart.

## What the kit will do once the file exists

Not in 1.5.0. Proposed, unchanged from the 2026-10-02 research note:

- New reason `roster_disconnected`.
- Fire only when `rosterConnected=false` (or `stream=down`) holds for ≥ 2 LaunchAgent ticks (~2 minutes, so a 1-minute reconnect backoff does not bounce the Dock), the dune session still looks locally healthy, and the disable file is absent.
- If the file is **absent**, do not heal on it and do not set `cloudConnectObservable=true`. Fall through to the helper observer and the beacon.
- Same quit + `open -ga "Grok Bot"` and the readiness gate.
- `cloudConnectObservable=true` only for this file, with this note linked from the changelog.
- Never open `local-exec-daemon-connection.json` or `local-exec-daemon-credential.json`.

Until that file exists, saying the LaunchAgent classifies every fleet disconnect locally would be a false green.
