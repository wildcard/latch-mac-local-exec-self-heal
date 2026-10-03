# 1.4.0 proposal (not shipped)

**Kit on `main`:** **1.3.0** (`VERSION`). Do not bump until a Worker poll client or a proven native connection file is actually installed and proven.

**Honest status:** S-NEW-D is **not** auto-healed. A live Grok Bot process plus a moving dune heartbeat under 180s still logs `status=ok` / `readiness=local_healthy`. `cloudConnectObservable` stays `false`.

## What these files are

| File | Role |
|---|---|
| [SELF-HEAL-MODES.md](SELF-HEAL-MODES.md) | Deploy-time modes pack: none / mac-local / worker-beacon / vitals-buddy. Trade-offs only; not implemented beyond mac-local. |
| [SPEC-1.4.0-beacon.md](SPEC-1.4.0-beacon.md) | Proposal. Worker inbox default. Beacon heal bypasses the 300s cooldown. Nothing here is code. |
| [LISTMACHINES-MAC-EXPOSURE-20261002.md](LISTMACHINES-MAC-EXPOSURE-20261002.md) | Dig: no on-disk mirror of `ListMachines.connected`. |
| [RESEARCH-GROK-BOT-CONNECTION-20261002.md](RESEARCH-GROK-BOT-CONNECTION-20261002.md) | Public docs + 0.66.0 dig: no LaunchAgent-usable mirror of `ListMachines.connected`. Native heal waits on a non-secret status file. |
| [GROK-BOT-LOCAL-EXEC-INSPECT.md](GROK-BOT-LOCAL-EXEC-INSPECT.md) | Where the cloud bit lives (in the daemon process, not a file). |
| [PROVE-1.3.0.md](PROVE-1.3.0.md) | 1.3.0 install prove. Fixtures 16/16. Live process-down skipped. S-NEW-D still open. |
| [INCIDENT-2026-10-02-notes.md](INCIDENT-2026-10-02-notes.md) | Working notes for the 22:08–22:27 PT outage. Public narrative: [../INCIDENT-2026-10-02.md](../INCIDENT-2026-10-02.md). |
| [SPEC-gap-20261002.md](SPEC-gap-20261002.md) | Pre-1.3.0 gap spec. Historical. Shipped contract is [../SPEC.md](../SPEC.md). |

Product bar: [../PRODUCT-BAR.md](../PRODUCT-BAR.md). Checklist: [../TASKS-1.4.0.md](../TASKS-1.4.0.md).

## Decisions locked (docs only)

1. **2026-10-02 ~11:04 PM PT.** Default beacon transport is a Cloudflare Worker heal-only inbox. Tailscale listener and “hold for a local signal only” are deferred. A Mac-side signal is still preferred before relying on the Worker in production.
2. **2026-10-02 ~11:07 PM PT.** A Worker heal-request **bypasses** the 300s relaunch cooldown, same as the local `.request` file.
3. **2026-10-02 ~11:13 PM PT.** No native signal was found. Product should write connection JSON. Worker remains last resort, not a shipped feature.
4. **2026-10-02 ~11:35 PM PT.** Self-heal is a **multi-mode pack**: none, mac-local (1.3.0), worker-beacon (proposed), vitals-buddy (proposed). Latch presents trade-offs; user picks mode(s). Worker and buddy are not built in this change.

## What this directory does not do

- No script, plist, test, or `VERSION` change.
- No Worker, no Wrangler config, no keys, no vitals-buddy implementation.
- No claim that posting a heal-request today relaunches the Mac.
