# Tasks — 1.4.0

**Released 2026-10-05 as 1.4.0** (`VERSION`): Worker deployed, Mac poll hook installed, Prove C passed ([1.4.0/PROVE-C-2026-10-05.md](1.4.0/PROVE-C-2026-10-05.md)). Prove D is still open.

**S-NEW-D today:** not auto-detected; a beacon request can heal it (Prove C proved the path, not a real disconnect). See [1.4.0/PROVE-1.3.0.md](1.4.0/PROVE-1.3.0.md) and [INCIDENT-2026-10-02.md](INCIDENT-2026-10-02.md).

Bar: [PRODUCT-BAR.md](PRODUCT-BAR.md). Modes matrix: [1.4.0/SELF-HEAL-MODES.md](1.4.0/SELF-HEAL-MODES.md).

**Modes pack (2026-10-02 ~11:35 PM PT).** Deploy-time choice: none, mac-local (1.3.0), worker-beacon (1.4.0 proposed), vitals-buddy (proposed). Modes may pack together. worker-beacon stays the low-token S-NEW-D path when a bot can POST a heal-request. vitals-buddy is the hermetic audit path (paired bot checks `ListMachines.connected` and writes a pullable health log; stale/missing → resume buddy or restart Grok Bot; more tokens; optional future Latch-hosted relay). vitals-buddy is not built; the Worker source and Mac poll hook are.

## Decisions locked (2026-10-05)

Q1 Worker inbox default. Q3 beacon bypasses the 300s cooldown. **Q4** while `.disable` is present the pending heal-request stays queued (not ack-and-dropped); disable still blocks relaunch; Worker `exp` ≤120s expires it. **Q5** one beacon relaunch per outage, then stop and escalate if `connected` is still false (no second try inside the hour). **Auth** Bearer tokens (`WRITER_TOKEN`, `POLLER_TOKEN`) for v1, per-request HMAC documented as the alternative; a design choice, not a secret, no keys in git. Deploy (`wrangler secret put`, `wrangler deploy`) is a human step on the personal Gmail Cloudflare account only.

## Checklist

- [x] **Repo docs.** This change. Proposal, research, product bar, task list, README pointer, unreleased CHANGELOG stub. No kit code.
- [x] **Self-heal modes matrix** (2026-10-02 ~11:35 PM PT). [1.4.0/SELF-HEAL-MODES.md](1.4.0/SELF-HEAL-MODES.md): none / mac-local / worker-beacon / vitals-buddy; deploy-time multi-mode pack. Docs only.
- [ ] **vitals-buddy (proposed).** Paired audit bot + pullable health log for the Mac kit. Not designed or built in this repo yet. Optional Latch-hosted relay is future.
- [x] **Personal Cloudflare Worker source (heal-only inbox)** in `worker-beacon/`. **Deployed and live** at https://latch-worker-beacon.kadosh.workers.dev on the operator's personal Cloudflare. Deploy was a human step. Secrets are Worker secrets plus a token file outside the repo, never in git. Accept only `{v, action: "heal_request", machineId, jti, exp}`. Reject every other action. Single-use `jti`, short `exp` (≤120s), one pending flag per machine, rate limit. **No secrets in git.**
- [x] **Mac poll client (hook + fixture tests; proven live in Prove C).** One HTTPS GET per existing 60s LaunchAgent tick. Valid pending flag → same quit + `open -ga "Grok Bot"` as `operator_request`, then the 1.3.0 readiness gate. New `last.json` reason distinct from keyboard `operator_request`. Disable file still wins. Beacon **bypasses** the 300s cooldown (locked 2026-10-02 ~11:07 PM PT). Do not upload logs on this channel. While `.disable` is present: no poll-consume, request stays queued. After one beacon relaunch with `connected` still false: stop and escalate.
- [x] **Prove C (beacon path) passed 2026-10-05.** See [1.4.0/PROVE-C-2026-10-05.md](1.4.0/PROVE-C-2026-10-05.md).
- [ ] **Prove D (S-NEW-D via beacon, real cloud disconnect).** Plan C then D in [1.4.0/SPEC-1.4.0-beacon.md](1.4.0/SPEC-1.4.0-beacon.md). From the box, POST one valid heal-request **without** using a live Mac shell to touch the `.request` file. Pass: pid changes and `last.json` shows the beacon reason, then `healed`/`ready` or an honest `heal_incomplete`. Replay, expired `exp`, and bad schema must not relaunch. Disable file must block. Do not edit `last.json` by hand. Do not call a process kill S-NEW-D (that is S1, already in 1.3.0).
- [ ] **Product ask: connection JSON.** Ask for a durable local file, working name `local-exec-daemon-connection.json`, shaped `{connected, lastSseAtMs, reason}`, written on SSE connect, disconnect, and stall. That is the preferred signal so bots do not have to declare the Mac down. Track the ask outside this repo; do not invent the file here.
- [x] **Deep research folded in** (2026-10-02 ~11:07–11:13 PM PT). Sources: [1.4.0/GROK-BOT-LOCAL-EXEC-INSPECT.md](1.4.0/GROK-BOT-LOCAL-EXEC-INSPECT.md), [1.4.0/LISTMACHINES-MAC-EXPOSURE-20261002.md](1.4.0/LISTMACHINES-MAC-EXPOSURE-20261002.md).
- [x] **Connection-signal research** (2026-10-02 ~11:22–11:40 PM PT). [1.4.0/RESEARCH-GROK-BOT-CONNECTION-20261002.md](1.4.0/RESEARCH-GROK-BOT-CONNECTION-20261002.md). No usable Mac mirror of `ListMachines.connected` on 0.66.0. Native auto-heal waits on a non-secret status file the app does not write today.

## Deep research findings (fold-in)

| Question | Finding |
|---|---|
| Can the LaunchAgent run the same `ListMachines` bots run? | **No.** That bit is cloud-side. The string in the app bundle is agent-facing copy, not a Mac CLI. |
| On-disk or localhost mirror of `connected`? | **No**, while `ListMachines` was `connected=true` on Grok Bot 0.66.0. |
| What 1.3.0 already watches | Process liveness, dune-reliability `heartbeatAtMs` / age, `bootOutcome`. Those stayed healthy through S-NEW-D (pre-restart pid unchanged, heartbeat age ~31–45s, moving). |
| Named daemon JSON (`local-exec-daemon-connection.json` and siblings) | **String literals only.** Not created on disk during a connected session. |
| Where SSE state lives | In the local-exec daemon process (`connected` / `disconnected` / `unauthorized` / stall). No TCP listen to poll. |
| Implication | Do not tighten stale (180s) or frozen (120s) thresholds. That would relaunch a healthy moving heartbeat. Prefer a product-written connection file. Worker inbox is last resort for classes Mac files cannot see. |

## Where the Worker is built

The inbox deploys to the operator's **personal Cloudflare** account via **Wrangler**. Not an employer Cloudflare account. Not a blog post. This repository holds the Worker source and a `wrangler.toml` with no account id; keys and secrets stay out of it.

## Explicitly not in 1.4.0 scope

- Sleep, lid closed, WAN, VPN, or sign-in repair. Relaunch is the only fix. If `connected` stays false after one relaunch, escalate. Do not loop.
- A general remote shell or log upload on the beacon.
- Implementing vitals-buddy, a Latch-hosted relay, or a multi-mode installer UI.
- Claiming Prove D. Prove C only exercised the beacon path.
