# Product bar — Mac local-exec self-heal

**Set:** 2026-10-02 ~11:01 PM PT; transport locks ~11:04 and ~11:07 PM PT; modes pack ~11:35 PM PT  
**Applies to:** kit **1.5.0** (current). The worker-beacon inbox is deployed and live on the operator's personal Cloudflare; its tokens are Worker secrets plus a token file outside the repo.

**Honest status against bar 1:** S-NEW-D is covered when an agent POSTs a heal-request to the beacon (now a mandatory auto-POST, [agent loop](1.5.0/AGENT-LOOP.md)). 1.5.0 adds a Mac-local **observer** for one S-NEW-D cause (helper exit, `helper_missing`), log-only by default; it is a correlation, not a cloud signal. Prove D **failed** 2026-10-07 because no agent posted ([record](1.5.0/PROVE-D-FAIL-2026-10-07.md)). Prove C (beacon path) and the live `.disable` check passed; Prove D (a real silent disconnect healed via the beacon) is open. See [CAPABILITY-CHECKS.md](CAPABILITY-CHECKS.md).

## Bars

1. **Catch every class fleet bots treat as `ListMachines.connected=false`.**  
   That includes process-down, stale heartbeat, boot not ready, frozen heartbeat, **and S-NEW-D** (process up, dune heartbeat moving and young, cloud link down). Silent `status=ok` while the cloud link is down is only acceptable until a bot or operator reports it; there is no auto-detection yet.

2. **The fix is restarting Grok Bot.**  
   Gentle quit + `open -ga "Grok Bot"`, then the 1.3.0 readiness gate. No new remote-control surface. No shell in the beacon payload. No WAN, VPN, sign-in, sleep, or lid repair.

3. **Worker heal-only inbox is last resort.**  
   Use it only for classes Mac-local signals cannot see. Outbound poll (no inbound port). Heal-request messages only. The operator locked this as the default transport (2026-10-02 ~11:04 PM PT) and locked cooldown bypass (same as the local `.request` file, ~11:07 PM PT). Further locked 2026-10-05: while `.disable` is present a pending heal-request stays queued and disable still blocks relaunch; one beacon relaunch per outage, then stop and escalate if `connected` is still false. Auth v1 is Bearer tokens (HMAC documented as the alternative). Source lives in `worker-beacon/`; it is **deployed and live** on the operator's personal Cloudflare. A Tailscale listener stays deferred.

The inbox uses the operator's **personal Cloudflare** account and **Wrangler**. Not an employer Cloudflare account. Not a blog post. This repository holds the Worker **source** and a `wrangler.toml` with no account id; it never holds keys, tokens, or secrets.

4. **Prefer a native Mac signal so bots do not have to declare the machine down.**  
   The 2026-10-02 dig found no such file. 1.5.0's helper-count observer is a proxy for one outage (a NodeService helper exited), log-only by default, and is not that signal. The ask is for Grok Bot to write a non-secret `local-exec-status.json` (`rosterConnected`, `stream`, `reason`, no token). Contract and the explicit non-goals until it exists: [1.5.0/PRODUCT-STATUS-FILE.md](1.5.0/PRODUCT-STATUS-FILE.md). If that signal is proven against a real `connected=false` window and a healthy-hour baseline, the LaunchAgent heals on it and `cloudConnectObservable` may become true **for that signal only**. Until then the flag stays `false`.

## Modes pack (2026-10-02 ~11:35 PM PT)

Latch offers a **deploy-time choice** of self-heal modes the user can pack together. Full matrix: [1.4.0/SELF-HEAL-MODES.md](1.4.0/SELF-HEAL-MODES.md).

- **none** — no self-heal.
- **mac-local** (shipped 1.3.0) — LaunchAgent process / heartbeat / boot / frozen / request file; no cloud; **misses S-NEW-D**.
- **worker-beacon** (shipped 1.4.0) — personal Cloudflare Worker heal-only inbox; Mac outbound poll; cooldown bypass; needs remote CF; **low token cost** for bots that already see `connected=false`.
- **vitals-buddy** (proposed) — paired audit bot with Latch that periodically checks vitals (`ListMachines.connected` + other live signals) and writes a pullable health log the Mac kit reads. Stale or missing vitals → prompt buddy resume or restart Grok Bot. **More token-intensive**, but hermetic: the bot under test need not self-report down. Optional future Latch-hosted relay for users who do not want their own Worker.

Present the trade-offs; let the user pick mode(s). Worker source and Mac poll hook are in `worker-beacon/` and the heal script; vitals-buddy is not built.

## What 1.3.0 already meets

| Class | 1.3.0 |
|---|---|
| Process not alive | Relaunch |
| Heartbeat age > 180s | Relaunch |
| `bootOutcome` set and not `ready` | Relaunch |
| Same pid, same `heartbeatAtMs` ≥ 120s | Relaunch (`heartbeat_frozen`) |
| Keyboard / on-Mac `.request` file | Relaunch, cooldown bypass |
| S-NEW-D | **Does not relaunch.** `escalateHint` after 300s of local-ok. Operator restart. 1.5.0 can *observe* a helper-exit shape (`helper_missing`, log-only unless `HEAL_ON_HELPER_MISSING=1`). That is not detection of `ListMachines.connected`. |

## Non-negotiable honesty

- Do not claim S-NEW-D auto-detection of `ListMachines.connected`. The 1.5.0 helper observer is a correlation and ships log-only. Prove D stays open until a real disconnect is healed via the beacon or an opted-in helper relaunch, without a hand-edited `last.json`.
- Do not treat “kill the process” as proof of S-NEW-D.
- Disable file wins over beacon and over `.request`. A beacon request received while disabled stays queued; it is not ack-and-dropped.
- Keys stay out of this repo.
