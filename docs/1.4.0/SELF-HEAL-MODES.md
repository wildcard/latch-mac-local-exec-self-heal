# Self-heal modes — deploy-time pack (proposed)

**Status:** product docs only. Nothing here is implemented beyond **mode mac-local** (shipped as kit **1.3.0**).  
**Bar:** operator, 2026-10-02 ~11:35 PM PT  
**Kit today:** **1.3.0** (`VERSION`). Do not bump until a chosen pack is installed and proven.  
**Does not implement:** Cloudflare Worker, vitals-buddy bot, Latch-hosted relay, or multi-mode installer UI.

Latch presents these trade-offs at deploy time. The user picks **one or more modes** that can be packed together (for example mac-local + worker-beacon, or mac-local + vitals-buddy). Modes are not mutually exclusive unless the user chooses **none**.

## Modes matrix

| Mode | Status | How it detects | How it heals | Needs remote / cloud? | Token cost (bots) | Catches S-NEW-D? | Main trade-off |
|---|---|---|---|---|---|---|---|
| **none** | Always available | — | No self-heal | No | None | No | Simplest; operator restarts by hand |
| **mac-local** | **Shipped 1.3.0** | LaunchAgent: process / heartbeat / boot / frozen / `.request` file | Quit + `open -ga "Grok Bot"`; readiness gate; disable wins; `.request` bypasses cooldown | No cloud for heal | None (Mac-only) | **No** — process + moving heartbeat look `healthy` | Hermetic and free of bot tokens; blind to cloud-only disconnect |
| **worker-beacon** | **1.4.0 proposed** | Personal Cloudflare Worker heal-only inbox; Mac **outbound** poll each tick | Same heal as `operator_request` (cooldown bypass locked ~11:07 PM PT); disable still wins | Yes — personal CF Worker + Wrangler (personal Cloudflare account; not an employer Cloudflare account; keys out of this repo) | **Low** — box bot POSTs a heal-request only when it already sees `connected=false` / shell dead | Yes, if a bot posts when cloud is down | Needs remote CF; no inbound Mac port; heal-request schema only |
| **vitals-buddy** | **Proposed** | Paired “audit” bot with Latch that periodically checks vitals (`ListMachines.connected` + other live signals) and writes a **pullable health log** the Mac kit reads | Stale / missing vitals → prompt buddy resume **or** restart Grok Bot (same gentle quit + open path) | Optional future Latch-hosted relay for users who do not want their own Worker; otherwise buddy writes somewhere the Mac can pull | **More token-intensive** (periodic audit turns) | Yes — hermetic to the bot-under-test: buddy does **not** require the under-test bot to self-report “I am down” | Higher ongoing token use; needs a paired buddy schedule; optional Latch relay is future |

## Mode notes

### none

- No LaunchAgent heal pack, or heal explicitly disabled and left that way.
- User accepts manual restart (Dock / keyboard / on-Mac `.request` if they drop one themselves).

### mac-local (1.3.0)

- Covers S1–S3, frozen heartbeat, disable, cooldown, operator `.request`.
- Honest: `cloudConnectObservable=false`. S-NEW-D stays outside the relaunch loop (see [INCIDENT-2026-10-02.md](../INCIDENT-2026-10-02.md), [SPEC-1.4.0-beacon.md](SPEC-1.4.0-beacon.md)).
- No Worker, no buddy, no WAN repair claim.

### worker-beacon (1.4.0 proposed)

- Default beacon transport locked ~11:04 PM PT: outbound poll of an authenticated heal-only inbox.
- Payload is heal-request only (`{v, action: "heal_request", machineId, jti, exp}`). No shell, path, or log upload.
- Built (when built) on **personal** Cloudflare via Wrangler — not this repository, and not an employer Cloudflare account.
- Low token cost relative to vitals-buddy: bots act only when they already know the Mac is unreachable from the fleet side.

### vitals-buddy (proposed)

- A **paired audit bot** (not the bot under test) periodically runs live checks, including `ListMachines.connected` and any other Latch-visible vitals Latch documents for the pack.
- Writes a **health log** the Mac kit can pull (path / relay TBD). Stale or missing entries mean: nudge the buddy to resume, or trigger the same Grok Bot restart the LaunchAgent already knows.
- **Hermetic advantage:** the under-test bot does not have to admit it is down. The buddy observes from outside.
- **Cost:** more tokens than a rare beacon POST, because the buddy runs on a schedule whether or not anything is wrong.
- **Optional future:** Latch-hosted relay so users who refuse a personal Worker still get a pullable log. Not designed or scheduled here.

## Deploy-time choice

1. Latch shows this matrix (or a short UI paraphrase) with the trade-offs above.
2. User selects **mode(s)** packable together — e.g. keep **mac-local** always-on and add **worker-beacon** and/or **vitals-buddy**.
3. Packager installs only the chosen pieces. Secrets and Worker config stay out of the public kit repo.
4. Until a chosen non-mac-local mode is installed and proven, **`VERSION` stays 1.3.0** and docs must not claim S-NEW-D is auto-healed.

## Explicitly out of this document

- Implementing the Worker, the Mac poll client, or the buddy.
- Bumping `VERSION`.
- Claiming a Latch-hosted relay exists today.
