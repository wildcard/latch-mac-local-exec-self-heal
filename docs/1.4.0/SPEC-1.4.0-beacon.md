> **Documentation only (published 2026-10-02, ~11:22 PM PT).** Proposal. `VERSION` remains **1.3.0**. No LaunchAgent, plist, install, or Worker is in this commit. The “no `gh` write” line in [Out of this addendum](#out-of-this-addendum) was the authoring constraint when the addendum was drafted; publishing the addendum does not implement it.
>
> **Research update, same night (~11:13 PM PT):** a Mac exposure dig found **no** on-disk or localhost signal that mirrors `ListMachines.connected`. See [`LISTMACHINES-MAC-EXPOSURE-20261002.md`](LISTMACHINES-MAC-EXPOSURE-20261002.md) and [`GROK-BOT-LOCAL-EXEC-INSPECT.md`](GROK-BOT-LOCAL-EXEC-INSPECT.md). Preferred long-term fix is still a native file the app writes (product ask). Until that exists, the Worker heal-only inbox is the fallback, not a claim that 1.4.0 is built.

# SPEC addendum — mac-local-exec-self-heal 1.4.0 (proposed)

**Status:** proposal only. Nothing in this document is implemented.  
**Date:** 2026-10-02 ~11:01 PM PT  
**Supersedes:** the 1.3.0 decision that S-NEW-D stays outside the relaunch loop.  
**Does not supersede:** 1.3.0 readiness gate, disable file, cooldown, or “no sleep / no WAN repair” honesty.  
**Kit today:** **1.3.0** (public: https://github.com/wildcard/latch-mac-local-exec-self-heal). Installed on `DEMO-MAC` at ~22:55 PT. `cloudConnectObservable` is always `false`.  
**Proposed version:** **1.4.0**. No code, plist, install, or publish in this addendum.

## Product bar (operator, 2026-10-02 ~11:01 PM PT)

1. The Mac LaunchAgent must **identify every scenario fleet bots treat as `ListMachines.connected=false`**, including **S-NEW-D** (Mac process + moving heartbeat look healthy, cloud link is down).
2. The **only fix** is the existing heal: gentle quit + `open -ga "Grok Bot"`. No new remote control surface.
3. If a class cannot be seen from Mac-local signals, a **one-way external beacon** lets an agent (especially Grok Bot on the box) **request that same heal** when `Shell(machineId)` is dead. The transport may carry **heal-request messages only**.

Tonight’s instance of (1): ~22:08–22:27 PT, pre-restart pid unchanged, heartbeat age ~31–45s and moving, LaunchAgent ticks `ok/healthy`, no relaunch. Cloud stayed `connected=false` until a manual Grok Bot restart (~22:28 PT, new pid). See `INCIDENT-2026-10-02.md`.

## Goals

- When fleet bots see `connected=false` and the Mac is awake and the agent is loaded, 1.4.0 either relaunches Grok Bot.app or records a specific “cannot see this class” reason that arms the beacon path. Silent `status=ok` for a cloud-down Mac is no longer acceptable.
- Preferred: a **Mac-local signal** that correlates with cloud disconnect, including S-NEW-D, and feeds the existing heal reasons.
- Fallback only: beacon → same heal path as `operator_request` (drop or equivalent of `~/Library/Application Support/Latch/grok-bot-local-exec-heal.request`).
- Threat model below is part of the design, not a follow-up.

## Non-goals

- Claiming 1.4.0 is built, installed, or proven.
- A general remote shell, file read, log upload, or arbitrary command channel. Beacon payload must not be interpolated into a shell.
- Healing sleep, lid-closed, or a Mac with no network. The agent cannot run, and an outbound poll cannot complete. On wake, the next tick must classify and heal if the link is still down.
- Repairing sign-in, VPN, or WAN. Relaunch is the only action; if relaunch does not restore `connected=true`, escalate, do not loop.
- Observing `ListMachines` from the LaunchAgent. 1.3.0 cannot; 1.4.0 must not pretend a local file is that bit unless a real correlation is proven.
- Waking the display. `HEAL_CURSOR` stays off unless already configured.

## What 1.3.0 already covers vs what 1.4.0 must add

| Fleet view | Mac-local in 1.3.0 | 1.3.0 action | 1.4.0 must |
|---|---|---|---|
| `connected=false`, process dead (S1) | process not alive | relaunch `process_down` | keep |
| `connected=false`, heartbeat age >180s (S2) | stale heartbeat | relaunch | keep |
| `connected=false`, `bootOutcome` ≠ ready (S3) | boot outcome | relaunch | keep |
| `connected=false`, frozen `heartbeatAtMs` ≥120s | frozen clock | relaunch if `HEAL_ON_STUCK_SESSION=1` | keep |
| **S-NEW-D** — process up, heartbeat **moving** ~31–45s, cloud false | looks `healthy` | **no relaunch**. `escalateHint` only after `OK_HINT_SEC` (300s) of continuous ok. Does not fix the link | **identify and relaunch** (same quit+open), or accept a beacon heal-request that does |
| Disable file | file present | skip, wins over request | keep; beacon must not override disable |
| Cooldown 300s | after a heal | skip; **operator_request bypasses** | keep for keyboard request. Beacon **bypasses** the 300s cooldown (locked); abuse is bounded by the Worker rate limit instead (see Decision locks) |
| Operator request file | `grok-bot-local-exec-heal.request` | `operator_request`, bypass cooldown, consumed at heal start | keep. **Disconnected agents cannot create this file** — that is why a beacon exists |
| Cloud connect bit | `cloudConnectObservable=false` | honest | still false until a proven signal or beacon. Do not flip the flag without evidence |

1.3.0 tests that must stay green: moving heartbeat does **not** count as `heartbeat_frozen`. 1.4.0 heals S-NEW-D by a **new** signal or by beacon, not by lowering the stale/frozen thresholds (that would false-heal a healthy moving heartbeat).

## Preferred path — Mac-side signal

Hypothesis only. Not observed as a distinct artifact during the 22:08–22:27 window (the heal log only shows healthy ticks).

Find a file, socket, or log on the Mac that **stops, sticks, or changes** when the cloud session is gone, **while** dune-reliability heartbeat and pid still look healthy.

Candidates to check on a future real disconnect (or any xAI-supported repro), and to reject if they also move during a healthy `connected=true` hour:

- Anything under Grok Bot Application Support / Logs **other than** the dune heartbeat already proven to keep moving through S-NEW-D.
- A cloud-session or websocket status the app already writes locally (name unknown — do not invent one).
- `log show` lines for the Grok Bot subsystem during a labeled `connected=false` window vs a labeled `connected=true` window.
- Established connections (`lsof` / `netstat`) to Grok endpoints. Treat as a clue, not a heal trigger, until false-positive rate is measured. VPN blips must not reboot the app every tick.

**Heal rule if a signal is adopted:** one new reason (name TBD, e.g. `cloud_session_stale`). Same quit+open and the 1.3.0 readiness gate. Require the bad state to hold for ≥1–2 ticks so a single stale read does not relaunch. `cloudConnectObservable` may become `true` only for that signal, with the evidence linked in CHANGELOG.

**If no candidate survives a real S-NEW-D:** say so in the kit docs and ship the beacon. Do not fake a signal.

## Fallback — beacon (ranked)

Use only for classes local signals cannot see. Side effect on the Mac is **only** the existing heal (write the request file or call the same relaunch function). Disable file still wins.

| Rank | Option | Why |
|---|---|---|
| **1 — default** | **Outbound poll of an authenticated heal-only inbox** (Cloudflare Worker or equivalent). Box POSTs a heal-request. Each LaunchAgent tick GETs “pending for this machine?” and, if valid, consumes it and runs the existing heal. | No inbound port. Works through NAT. Box can POST while `Shell(machineId)` is dead. Schema can be rejected server-side and on the Mac. |
| 2 | Tiny HTTPS listener **on Tailscale only** (not `0.0.0.0`, not public LAN). POST body is the same heal-request schema. Handler writes the `.request` file and returns 204. | Lower latency, no third party, but an always-on listener on the Mac. Public or LAN bind is out. |
| 3 | “Signed POST drops `.request`” as a phrase, not a third design | This is the **handler** for (1) or (2), not a transport. The signature is checked; the only write is the request file. |
| 4 — last | iCloud / Dropbox file drop | Sync is slow, bidirectional, and not a security boundary. Other files in the account are not heal-requests. Easy to desync or to smuggle extra content. Do not use unless the operator rejects (1) and (2). |

### Recommended default

**Worker inbox + Mac outbound poll**, mapped onto the existing request file:

1. Allowed writer (box Grok Bot) sends `POST` with a **fixed schema** (additional properties forbidden): `{ "v": 1, "action": "heal_request", "machineId": "<redacted>", "jti": "<uuid>", "exp": <unix> }`. No command string, path, or shell.
2. Worker checks auth, `exp` (short, ≤120s), single-use `jti`, machine id, and rate limit. Stores at most **one pending flag** per machine. Rejects every other `action` with 400 and stores nothing.
3. LaunchAgent, inside the existing 60s script, performs one HTTPS GET. On a valid pending flag: delete it (ack) and create `grok-bot-local-exec-heal.request` **or** call the same relaunch used for `operator_request`. Then the 1.3.0 readiness gate applies.
4. `last.json` gains a reason that distinguishes beacon-triggered heal from a local signal and from a keyboard `operator_request` (names TBD). Still `cloudConnectObservable=false` if the trigger was the beacon.

### Threat model (default)

| Threat | Control |
|---|---|
| Stolen writer credential restarts Grok Bot repeatedly | Worker rate limit (proposal: ≤1 accepted request / 5 min / machine, ≤3 / hour). Mac still obeys cooldown unless the operator says beacon bypasses it. Restart is the worst local effect — no shell. |
| Replay of a captured POST | `exp` ≤120s + single-use `jti` on the worker and checked again on the Mac if the body is fetched. |
| Extra fields or a second message type | Schema allow-list. Unknown `action` dropped. Poll response is a boolean or the same object, never a string to execute. |
| Inbox used as a backchannel (logs, chat, files) | No GET of arbitrary data. Mac does not upload `last.json` or heal logs on this channel. |
| Listener exposure (rank 2 only) | Tailscale interface only. Rank 1 has no listener. |
| Disable file ignored | Disable wins. While `.disable` is present the Mac does not poll-consume: the pending flag stays queued (Worker `exp` ≤120s then drops it) and no relaunch happens. Locked, see Q4. |
| Key in git | Machine key or signing secret stays off the public repo. Provision out of band. |
| Confused deputy (any agent) | Only credentials held by named operators (at least box Grok Bot for this Mac id). |

Auth (decided, v1): two **Bearer tokens**, `WRITER_TOKEN` (box Grok Bot, may POST a heal-request) and `POLLER_TOKEN` (Mac, may poll), plus a machine-id allow-list, all provisioned out of band as Wrangler secrets. Neither is the user’s Google/xAI session. A per-request HMAC over the body is the documented alternative if bearer replay ever matters more than simplicity. This is a design choice, not a secret; no key material is ever committed.

## Prove plan for S-NEW-D (no fake state)

Do not mark `healed` by editing `last.json`. Do not treat “kill the process” as S-NEW-D (that is S1, already in 1.3.0).

**A — Retrospective (already true, not a 1.4.0 pass).**  
22:08–22:27 PT: heal log `ok/healthy` on the pre-restart pid, heartbeat moving 31–45s, `connected=false`, no `heal_*` line, pid changed only at manual restart 22:28. This is the bug 1.4.0 must close. It does not prove 1.4.0.

**B — Correlation study (preferred path).**  
While `connected=true`, sample candidate signals for ≥1 hour (false-positive baseline). On the next real `connected=false` with the process still up, capture the same signals from the Mac **after** the link returns (logs already on disk). A signal is adoptable only if it was healthy in B-baseline and bad across the cloud-down window. One labeled window minimum. If the link never drops again, the signal stays unproven — do not simulate it by freezing the heartbeat file.

**C — Beacon path (does not prove a local signal).**  
With the Mac awake and 1.4.0 installed, from the box, POST one valid heal-request **without** using `Shell(machineId)` to touch the request file. Pass: pid changes, `last.json` shows beacon reason then readiness `healed`/`ready` or an honest `heal_incomplete`, and a second POST inside the rate limit does not stack relaunches. Invalid schema, expired `exp`, and replayed `jti` must not relaunch. Disable file must block the relaunch.

**D — End-to-end S-NEW-D.**  
Only a real cloud disconnect while local heartbeat keeps moving. Pass: either the new local reason relaunches during the window, or a box agent sends the beacon (because it sees `connected=false` and shell fails) and the Mac relaunches without someone SSHing or clicking. Compare heal log timestamps to the `ListMachines` false interval. If relaunch returns and `connected` is still false, record escalate — do not claim network heal.

Live quit tests still need a soft-park and `LIVE=1`. C and D bounce the Dock icon.

## Open questions (resolved)

Resolved 2026-10-05 per operator standing ask; locks are recorded under Decision locks below. Original wording kept short for history.

1. **Worker inbox vs Tailscale-only:** Worker inbox. Locked 2026-10-02 ~11:04 PM PT. Tailscale deferred.
2. **Who may hold the writer credential:** the box Grok Bot, scoped to the allow-listed machine id(s) only. Not every Latch Mac, not an operator’s session.
3. **Cooldown bypass:** beacon heal **bypasses** the 300s cooldown, same as `.request`. Locked 2026-10-02 ~11:07 PM PT. Abuse bound is the Worker rate limit (1 accepted / 5 min, 3 / hour per machine).
4. **While `.disable` is present:** **leave the request queued.** Do not ack-and-drop. Disable still blocks the relaunch. The Worker `exp` (≤120s) expires the flag, so removing `.disable` later does not fire a stale heal.
5. **After one beacon relaunch, `connected` still false:** **stop and escalate.** One beacon relaunch per outage, no second try inside the hour for the same outage. Relaunch is the only action; it is not a WAN fix.
6. **Known local artifact for cloud session state:** none on Grok Bot 0.66.0 (see research docs). The Worker stays last resort until a native connection file exists.
7. **Version bump and public CHANGELOG:** only after prove B or D passes; publish stays behind operator GO.

## Out of this addendum

No patch, no install, no `gh` write, no change to 1.3.0 files. Implementation of the Worker source and the Mac poll hook may proceed now that 1, 3, 4, and 5 are locked. Deploy and secrets stay with a human.


## Decision lock (2026-10-02 ~11:04 PM PT)

The operator chose **Worker inbox (recommended)** as the 1.4.0 default beacon transport. Tailscale and hold-for-signal deferred. Mac-side correlation dig still preferred before relying on the Worker in production.


## Decision lock (2026-10-02 ~11:07 PM PT)

Operator: Worker heal-request **bypasses** the 300s relaunch cooldown (same as local `.request`).

## Research update (2026-10-02 ~11:13 PM PT)

Appended when these notes were published. Does not change the decision locks above.

The preferred Mac-side signal was checked on a **connected** Mac (Grok Bot 0.66.0) and compared to daemon source strings. Result: **no adoptable trigger**.

- `desktop-status.json` has pid and `signedIn`, not `connected`.
- Dune-reliability session files (what 1.3.0 already reads) keep a moving heartbeat through the look of health. That is the S-NEW-D false-healthy pattern, not a fix.
- Files the daemon source names (`local-exec-daemon-connection.json` and the other `local-exec-*` JSON names) were **not on disk** while `ListMachines.connected=true`.
- SSE `connected` / `disconnected` / stall is **in-process**. The main process had no TCP listen that a LaunchAgent can poll.
- Therefore 1.4.0 must not lower `HEARTBEAT_STALE_SEC` or `STUCK_SEC` to “catch” S-NEW-D. A moving heartbeat under 180s stays healthy in 1.3.0 on purpose.

**Product ask:** have Grok Bot write a durable file (working name `local-exec-daemon-connection.json`) with `{connected, lastSseAtMs, reason}` on connect, disconnect, and stall. The LaunchAgent can then heal that class with the existing quit + `open -ga "Grok Bot"` without a bot declaring the Mac down.

**Until that file exists:** Worker heal-only inbox (decision lock) is the last resort. Not implemented in 1.3.0.


## Decision lock (2026-10-05)

Operator standing ask, recorded so no doc still reads these as open:

- **Q1** Worker inbox is the default beacon transport (unchanged from 2026-10-02 ~11:04 PM PT).
- **Q3** Beacon bypasses the 300s cooldown (unchanged from ~11:07 PM PT).
- **Q4** While `.disable` is present the heal-request stays queued (not ack-and-dropped); disable still blocks the relaunch; `exp` ≤120s expires it.
- **Q5** One beacon relaunch, then stop and escalate if `connected` is still false. No second try inside the hour for the same outage.
- **Auth** Bearer tokens (`WRITER_TOKEN`, `POLLER_TOKEN`) for v1; per-request HMAC is a documented alternative. A design choice, not a secret. No keys in git.
