# Tasks — 1.4.0 (proposed)

**Shipped:** 1.3.0. **`VERSION` file stays `1.3.0`** until the Mac poll client (or a proven native connection file) is installed and a real prove is written up.

**S-NEW-D today:** not auto-healed. See [1.4.0/PROVE-1.3.0.md](1.4.0/PROVE-1.3.0.md) and [INCIDENT-2026-10-02.md](INCIDENT-2026-10-02.md).

Bar: [PRODUCT-BAR.md](PRODUCT-BAR.md).

## Checklist

- [x] **Repo docs.** This change. Proposal, research, product bar, task list, README pointer, unreleased CHANGELOG stub. No kit code.
- [ ] **Personal Cloudflare Worker (heal-only inbox).** Operator account, Wrangler signed in with the personal Gmail Cloudflare login. Not this repository. Accept only `{v, action: "heal_request", machineId, jti, exp}`. Reject every other action. Single-use `jti`, short `exp` (≤120s), one pending flag per machine, rate limit. **No secrets in git.**
- [ ] **Mac poll client.** One HTTPS GET per existing 60s LaunchAgent tick. Valid pending flag → same quit + `open -ga "Grok Bot"` as `operator_request`, then the 1.3.0 readiness gate. New `last.json` reason distinct from keyboard `operator_request`. Disable file still wins. Beacon **bypasses** the 300s cooldown (locked 2026-10-02 ~11:07 PM PT). Do not upload logs on this channel.
- [ ] **Prove S-NEW-D via beacon.** Plan C then D in [1.4.0/SPEC-1.4.0-beacon.md](1.4.0/SPEC-1.4.0-beacon.md). From the box, POST one valid heal-request **without** using a live Mac shell to touch the `.request` file. Pass: pid changes and `last.json` shows the beacon reason, then `healed`/`ready` or an honest `heal_incomplete`. Replay, expired `exp`, and bad schema must not relaunch. Disable file must block. Do not edit `last.json` by hand. Do not call a process kill S-NEW-D (that is S1, already in 1.3.0).
- [ ] **Product ask: connection JSON.** Ask for a durable local file, working name `local-exec-daemon-connection.json`, shaped `{connected, lastSseAtMs, reason}`, written on SSE connect, disconnect, and stall. That is the preferred signal so bots do not have to declare the Mac down. Track the ask outside this repo; do not invent the file here.
- [x] **Deep research folded in** (2026-10-02 ~11:07–11:13 PM PT). Sources: [1.4.0/GROK-BOT-LOCAL-EXEC-INSPECT.md](1.4.0/GROK-BOT-LOCAL-EXEC-INSPECT.md), [1.4.0/LISTMACHINES-MAC-EXPOSURE-20261002.md](1.4.0/LISTMACHINES-MAC-EXPOSURE-20261002.md).

## Deep research findings (fold-in)

| Question | Finding |
|---|---|
| Can the LaunchAgent run the same `ListMachines` bots run? | **No.** That bit is cloud-side. The string in the app bundle is agent-facing copy, not a Mac CLI. |
| On-disk or localhost mirror of `connected`? | **No**, while `ListMachines` was `connected=true` on Grok Bot 0.66.0. |
| What 1.3.0 already watches | Process liveness, dune-reliability `heartbeatAtMs` / age, `bootOutcome`. Those stayed healthy through S-NEW-D (pre-restart pid unchanged, heartbeat age ~31–45s, moving). |
| Named daemon JSON (`local-exec-daemon-connection.json` and siblings) | **String literals only.** Not created on disk during a connected session. |
| Where SSE state lives | In the local-exec daemon process (`connected` / `disconnected` / `unauthorized` / stall). No TCP listen to poll. |
| Implication | Do not tighten stale (180s) or frozen (120s) thresholds. That would relaunch a healthy moving heartbeat. Prefer a product-written connection file. Worker inbox is last resort for classes Mac files cannot see. |

## Explicitly not in 1.4.0 scope

- Sleep, lid closed, WAN, VPN, or sign-in repair. Relaunch is the only fix. If `connected` stays false after one relaunch, escalate. Do not loop.
- A general remote shell or log upload on the beacon.
- Shipping 1.4.0 by editing `VERSION` before the Worker or the native file exists.
