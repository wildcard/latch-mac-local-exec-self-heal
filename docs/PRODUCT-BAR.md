# Product bar — Mac local-exec self-heal

**Set:** 2026-10-02 ~11:01 PM PT, with transport locks ~11:04 and ~11:07 PM PT  
**Applies to:** proposed **1.4.0**. The shipped kit is **1.3.0** and does not meet this bar yet.

## Bars

1. **Catch every class fleet bots treat as `ListMachines.connected=false`.**  
   That includes process-down, stale heartbeat, boot not ready, frozen heartbeat, **and S-NEW-D** (process up, dune heartbeat moving and young, cloud link down). Silent `status=ok` while the cloud link is down is not acceptable for 1.4.0.

2. **The fix is restarting Grok Bot.**  
   Gentle quit + `open -ga "Grok Bot"`, then the 1.3.0 readiness gate. No new remote-control surface. No shell in the beacon payload. No WAN, VPN, sign-in, sleep, or lid repair.

3. **Worker heal-only inbox is last resort.**  
   Use it only for classes Mac-local signals cannot see. Outbound poll (no inbound port). Heal-request messages only. The operator locked this as the default transport (2026-10-02 ~11:04 PM PT) and locked cooldown bypass (same as the local `.request` file, ~11:07 PM PT). It is still **not built**. A Tailscale listener stays deferred.

When that inbox is built, it uses the operator's **personal Cloudflare** account and **Wrangler**. Not an employer Cloudflare account. Not a blog post. This repository still does not hold Wrangler config or keys.

4. **Prefer a native Mac signal so bots do not have to declare the machine down.**  
   The 2026-10-02 dig found no such file. The ask is for Grok Bot to write connection state locally (working name `local-exec-daemon-connection.json`: `connected`, `lastSseAtMs`, `reason`) when the daemon’s SSE session connects, drops, or stalls. If that signal is proven against a real `connected=false` window and a healthy-hour baseline, the LaunchAgent heals on it and `cloudConnectObservable` may become true **for that signal only**. Until then the flag stays `false`.

## What 1.3.0 already meets

| Class | 1.3.0 |
|---|---|
| Process not alive | Relaunch |
| Heartbeat age > 180s | Relaunch |
| `bootOutcome` set and not `ready` | Relaunch |
| Same pid, same `heartbeatAtMs` ≥ 120s | Relaunch (`heartbeat_frozen`) |
| Keyboard / on-Mac `.request` file | Relaunch, cooldown bypass |
| S-NEW-D | **Does not relaunch.** `escalateHint` after 300s of local-ok. Operator restart. |

## Non-negotiable honesty

- Do not mark 1.4.0 shipped, and do not change `VERSION`, until the poll client or the native file is installed and a prove exists that is not a hand-edited `last.json`.
- Do not treat “kill the process” as proof of S-NEW-D.
- Disable file wins over beacon and over `.request`.
- Keys stay out of this repo.
