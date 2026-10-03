# Research — Grok Bot Mac connection signal (ListMachines.connected)

**When:** 2026-10-02 ~11:22–11:40 PM PT  
**Question:** Can a LaunchAgent on the Mac mirror cloud `ListMachines.connected` without a bot beacon?  
**App in our dig:** Grok Bot **0.66.0**, bundle `com.anysphere.sand`, machine `DEMO-MAC` (`machineId <redacted>`)  
**Asar extract:** not on this box. This note uses local verify notes that are not in this repository, plus the receipts named below. No new Mac `machineId` call. No install id, gateway ciphertext, or raw `last.json` is published.

## Verdict

**No usable Mac signal that mirrors `ListMachines.connected` was found.**

Public docs do not publish a status file, CLI, or localhost port for that bit. On 0.66.0, while cloud `ListMachines` was `connected=true`, the files a LaunchAgent can read (`desktop-status.json`, dune-reliability session) do not carry it, and the connection JSON names inside the app were not on the searched disk paths.

**Until the app writes a non-secret status (or an equivalent stable log the vendor documents), native auto-heal of S-NEW-D needs that app write. The Worker heal-only inbox remains the path that can fire while the cloud roster says disconnected.** Do not treat any scrape below as green.

S-NEW-D, restated from `S-NEW-D-DIG-20261002.md`: process up, dune `heartbeatAtMs` still moving (~31–46s in the 22:08–22:27 PT incident), `bootOutcome=ready`, `signedIn=true`, heal log `ok/healthy`, cloud `connected=false` until a manual restart. A signal that is also healthy in that shape is not a trigger.

## Sources

### Public (fetched or searched 2026-10-02)

| Source | URL | What it actually says about connection status |
|---|---|---|
| xAI: Use the computer and apps | https://docs.x.ai/grok-bot/computer-and-apps | Cloud computer vs “your local computer” is a **permission** split. No status file, CLI, or connected bit. |
| xAI: Approvals, security, and privacy | https://docs.x.ai/grok-bot/approvals-security-and-privacy | Settings → Execution on Local Computer: Always / Ask / Never. Not a link-health signal. |
| xAI: Troubleshooting | https://docs.x.ai/grok-bot/troubleshooting | “Computer cannot be reached” is the **Agent Computer** (cloud). Local section is only “work is refused” → check the permission. Support ask is version, time, request ID. No `~/.grokbot` path, no `log show` predicate. |
| xAI: Settings | https://docs.x.ai/grok-bot/settings-and-notifications | Execution on Local Computer is per desktop. No online/offline indicator documented. |
| Cursor: TLS-inspecting proxies | https://cursor.com/docs/grok-bot/proxies | Desktop talks to `*.cursor.sh` (chat, sign-in, approvals) and nested `*.*.cursorvm.com` (hosted computer: setup, screen, shell). SSE must not be buffered. This is **device → cloud computer**, not a published reverse local-exec status file. Chat can work while the computer link does not. |
| shadown teardown **0.18.0** (2026-09-03) | https://shadown.github.io/blog/posts/2026-09-03_grok_bot_how-it-works/ | **Old build.** Claims coordinator rewrites `~/.grokbot/local-exec-daemon-connection.json` every 30s (`{baseUrl, token, headers}`, mode 0600), plus `local-exec-daemon.json`, credential JSON, supervisor JSON, and `logs/local-exec-daemon.log`. Daemon: `GET {baseUrl}/local-exec/requests` (SSE), `POST /local-exec/responses`. **Those files hold gateway credentials. They are not a `connected` boolean, and they must not be parsed by a heal kit.** |
| Parker Rex teardown **0.47.0** (2026-09-11) | https://parkerrex.com/writing/how-grok-bot-works | Code read only, app not run. Two transports in the bundle: older SSE `/local-exec/requests` + `/local-exec/responses`, and newer `aiserver.v1.GrokBotService` watch/poll (watch stalled after 35s, backup poll 30s). He could not tell which transport a normal account uses. `host-main.cjs` no longer ships in the desktop app. Quit: SIGTERM, 40×100ms, then SIGKILL. Update path writes an update-lease and leaves the daemon up. **No on-disk `connected` flag described.** |
| Forum: daemon dies, 30s liveness (macOS) | https://forum.cursor.com/t/grok-bot-local-exec-daemon-on-macos-dies-after-staying-healthy-mac-unreachable-until-leftover-processes-are-killed/168548 | User-reported constant `SAND_LOCAL_EXEC_LIVENESS_WINDOW_MS = 30000`. Staff: a fix was coming after that report. Not a status-file spec. |
| Forum: Mac mini flap, 0.29.0 | https://forum.cursor.com/t/grok-bot-computers-local-exec-keeps-dropping-while-mac-mini-stays-on/169848 | Staff: idle cloud env made the helper think the desktop was gone. Often self-heals within about a minute; else quit and reopen. |
| Forum: offline while chat works | https://forum.cursor.com/t/local-execution-stays-offline-while-chat-still-works/169821 | Log tags users pasted: `[sand-local-exec-daemon]`, `[local-exec-provider]` `http_417`, then `cli_unknown_command`, SIGTERM. Staff asked for `~/.grokbot/local-exec-daemon.log`. Registration is automatic once the helper connection holds. No manual attach. |
| Forum: empty `ListMachines` / privacy-mode incident | https://forum.cursor.com/t/grok-bot-computers-local-exec-still-flapping-after-update/170488 | `ListMachines` returned `{"machines":[]}` while Settings stayed Always allow. Staff: server-side (account looked like Legacy Privacy Mode). Restart would not have helped during that window. Later residual: 0.30.0 Mac dropped out and returned in about a minute. |
| Forum: flap on **0.57.1** | https://forum.cursor.com/t/grok-bot-local-exec-still-flapping-on-0-57-1-residual-from-170488/172658 | Daemon process can stay up for days while `ListMachines` goes empty. Log: `user-computer-provider` `ConnectError` / `ECONNRESET` / `DeadlineExceededError`. **Log lines have no timestamps** (user). Staff: stream loss, growing backoff, Mac can leave the computer list for a minute or two, then return. Their debug recipe is `tail -F ~/.grokbot/local-exec-daemon.log` wrapped with `date`, plus Copy Request ID. Not a LaunchAgent contract. |
| Forum: never connects, Linux  | https://forum.cursor.com/t/grok-bot-local-execution-never-connects-listmachines-connected-false-while-desktop-chat-works/172307 | `ListMachines.connected=false` while chat works. User: Settings → Computer → Computers showed only “this is the computer you are using now” with **no online/offline**, and **no Network debugger row** on that build. Staff: helper failed to start (libstdc++). |
| Forum: Network Debugger (Windows, Agent Computer) | https://forum.cursor.com/t/grok-bot-0-30-0-recover-failed-computer-inaccessible-after-windows-update-bots-visible/171344 | Staff: Settings → General → System → **Network Debugger**. Lines they care about: “Api tls”, “Api unary”, “Computer tls”, “Updates feed”. That checker is **reachability of API and the hosted computer**, not the Mac local-exec roster bit. Linux report above says the row was absent on that build. Our 0.66 Mac dig did not open this UI. |
| Cua driver doc | https://cua.ai/docs/use-cua-with/grok-bot | Local commands need the computer reachable and the approval policy. No status API. |

**Searched, no public hit this pass:** `connectors-gateway.grok.com`, `dune-reliability`, `desktop-status.json`, a Grok Bot `ListMachines` CLI, a documented `log show` predicate for `com.anysphere.sand`. Absence from search is not proof the host is unused. Do not put that hostname in a heal rule.

### Ours (inferred from the 0.66.0 asar dig and live files)

Receipts in this repo: `LISTMACHINES-MAC-EXPOSURE-20261002.md`, `GROK-BOT-LOCAL-EXEC-INSPECT.md`.  
Raw dumps (string hits, socket notes, dune session, `desktop-status.json`, listmachines receipt) are not published.

Live at verify (~11:10 PM PT), cloud **`connected=true`**:

| Artifact | Observed | Mirrors `connected`? |
|---|---|---|
| `~/Library/Application Support/Grok Bot/desktop-status.json` | `version, pid, appVersion 0.66.0, startedAtMs, signedIn:true`. Writer string is in `electron-main/main-app.cjs`. | **No** |
| `dune-reliability/sessions/*.running.json` | Same pid, `bootOutcome:ready`, heartbeat ~17s old at that verify, `mainFaultSeen:false`, empty `childDeaths`. Identity is app/version/track/platform/arch/installId. **No SSE up/down field.** This is what heal **1.3.0** already watches, and it **kept moving through S-NEW-D**. | **No** |
| `gateway-descriptor.json` | Encrypted blob (not copied). | **No** |
| Named daemon files | Strings only in `local-exec-daemon/main.cjs`, coordinator, and `main-core.cjs`: `local-exec-daemon.json`, `local-exec-daemon-connection.json`, `local-exec-daemon-credential.json`, `local-exec-supervisor.json`, `local-exec-update-lease.json`, `local-exec-backend-return.json`, `local-exec-daemon.log`. **Find returned zero** under Application Support/Grok Bot, `~/Library/Logs`, `Caches/com.anysphere.sand*`, and `~/Library` maxdepth 5, **while connected=true**. | **No.** Missing file ≠ disconnected. |
| Sockets | Main pid: **no TCP LISTEN**; Electron `SingletonSocket` (unix). Two node helpers: unix only, no TCP listen. **Outbound ESTABLISHED was not inventoried.** | **Not a measured signal** |
| CLI | `grok` not on PATH. `/usr/local/bin/cursor` is Cursor.app. Unpacked natives: `sand-op-launcher`, `sand-webauthn-signer` only. `Contents/MacOS/Grok Bot` is a ~52KB arm64 stub. | **No** |
| LaunchAgents | Latch heal kit (60s, dune stale/stuck). `com.anysphere.sand.ShipIt` is Squirrel, not running. No Grok agent watches SSE. | **No** |
| `ListMachines` string in the daemon bundle | 2 hits, agent copy (“Pick a desktop from ListMachines”), not an entrypoint. | Cloud tool only |

In-bundle themes (string hits, not runtime proof of which path 0.66 uses):

- Handoff paths: `POST /sand-box/local-exec-connection`, `/sand-box/local-exec-daemon-credential`
- Data plane names: `/local-exec/requests`, `/local-exec/responses`, `local-exec-sse-connect|reconnect|stall`, `local-exec-heartbeat` (distinct from `dune-reliability-heartbeat`)
- Proto names: `WatchGrokBotUserComputerRequestsEvent` with `connected|notify|heartbeat`; `ExecClientControlMessage` heartbeat
- Coordinator: `gateway-sse-connect|reconnect-backoff|stall` and a transcript stall-watchdog string (box gateway, not a Mac status file)
- `main-core.cjs` refusal copy (server-side liveness, three different failures): no desktop on the reverse channel; desktops registered but **none heartbeated inside the liveness window**; `machineId` omitted when several computers are registered
- One daemon string that matters for scrapers: “local-exec daemon serves the backend user-computer bridge; **the box dial stays idle while the server credential is present**.” If that branch is live, a TCP session to `cursorvm.com` can be the computer UI while local-exec is elsewhere, or the reverse. **Not proven by a packet capture tonight.**
- UI-ish strings in `main-app.cjs`, not seen as files: `transport-connected`, `authenticated-api-connected`, `screen-websocket-connected`, `not_connected`

`cloudConnectObservable` in 1.3.0 `last.json` is hardcoded `false`. That is still the honest value.

### Version trap (do not mix)

| Claim | 0.18 public teardown | Forum through 0.57.1 | Our 0.66.0 disk dig |
|---|---|---|---|
| `~/.grokbot/local-exec-daemon-connection.json` rewritten every 30s | Asserted, and it would contain a token | Not re-verified by us | **Filename is a string. Not found on the Library paths searched, during `connected=true`.** |
| `~/.grokbot/local-exec-daemon.log` | Asserted under `logs/` | Staff and users still use this path; lines have **no timestamps** | **Not found** on the same Library/App Support/Caches search. **`$HOME/.grokbot` was not a listed find root in `absent-and-sockets.txt`.** Treat “log absent” as proven only for those roots. |
| What “connected” means | SSE to the box gateway | Staff: long-lived stream to their servers; roster drop during backoff even if the helper process lives | Bundle contains **both** SSE and `GrokBotService` watch/poll, plus the “box dial stays idle” string. Live transport not observed. |

A heal rule copied from the 0.18 blog (“if connection JSON is stale, relaunch”) is **wrong on 0.66**: the file was absent while the cloud bit was true. Reading it if it ever appears would also touch a **credential** (`baseUrl`, token, headers). Do not.

## Candidate signals — ask product, or scrape only with these false-positive rules

None of the scrapes are adoptable from tonight’s evidence. Each needs a labeled `connected=true` hour **and** a labeled S-NEW-D window before `cloudConnectObservable` may flip. One window is the minimum (`SPEC-1.4.0-beacon.md` prove plan B). Do not simulate S-NEW-D by freezing the dune heartbeat.

### 1. Product: non-secret status file (the ask)

Ask xAI / Anysphere to **resume writing a status the 0.18 design almost had, without the secret**.

Suggested path (mode `0644`, atomic replace, no token, no baseUrl, no headers, no installId):

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

Contract we need in writing:

- `rosterConnected` is the bit `ListMachines.connected` uses for this machine, not “dune heartbeat is fresh” and not “TCP socket exists.”
- `stream` is the daemon’s own view (`up` / `down` / `backoff`), so we can see server-roster drops that the process has not noticed yet.
- Updated on every transition and at least every liveness window, including the healthy state (a missing file must **not** mean down — 0.66 already has that false positive).
- Reason enum only (`sse_stall`, `unauthorized`, `liveness_window`, `no_provider`, `backoff`, `ok`). No request bodies, no commands.
- Documented as stable across 0.66+ or versioned so a kit can ignore unknown `v`.

**Why this is the only clean native trigger:** S-NEW-D is exactly “local health files stay good while the roster bit is false.” The writer has to be the component that knows the roster or the stream, which today does not flush that to disk.

### 2. Product: unified log, if they will not write a file

Predicate a LaunchAgent could run without scraping secrets, **only if they commit to stable subsystem and message text**:

```text
log show --style compact --last 2m --predicate 'subsystem == "com.anysphere.sand.local-exec" AND (eventMessage CONTAINS "roster connected" OR eventMessage CONTAINS "roster disconnected")'
```

Rules before any use:

- Subsystem and wording must be **documented**. Tonight there is **no public predicate**, and the 0.66 dig did not record `log show` output. Do not guess `com.anysphere.sand`.
- Messages must be state transitions, not every heartbeat (a 60s agent cannot diff a firehose safely).
- No tokens in the message. If the line includes a URL or bearer, do not ship the scraper.
- Forum’s `~/.grokbot/local-exec-daemon.log` is a **poor substitute** even if `ls ~/.grokbot` later shows it: no timestamps, historical `ECONNRESET` lines linger, staff say the roster returns on its own in a minute or two, and the privacy-mode incident emptied `ListMachines` **without** a local-exec bug. A kit that relaunches on every `ConnectError` will bounce a healthy app during normal backoff.

### 3. Product: read-only CLI

`Grok Bot --local-exec-status` printing the same JSON as (1) to stdout, exit 0 even when `rosterConnected` is false (exit 1 only when the app is not running — that case is already S1). No such binary on PATH in the 0.66 dig. Do not wrap the Electron stub.

### 4. Scrape we should not ship: `lsof` to Grok endpoints

Clue only. Dump checked **LISTEN**, not established clients.

False-positive / false-negative rules:

| Observation | Why it is not `ListMachines.connected` |
|---|---|
| Any TCP to `*.cursor.sh` | Chat, sign-in, approvals, telemetry (`api2.cursor.sh` in public docs and both teardowns). Stays up when local-exec is down (forum: chat works, `connected=false`). |
| Any TCP to `*.cursorvm.com` | Hosted **computer** link (screen, shell, setup). Proxy doc. The 0.66 string says the box dial can sit **idle** while a server credential is in use. |
| Socket present | Half-open or “registered but not inside the liveness window” still looks connected locally. That is one of the three refusal strings in `main-core.cjs`. |
| Socket absent for one tick | Staff-described reconnect backoff (grows; roster gone 1–2 minutes) is normal. VPN blips and sleep wake do the same. Relaunching every tick fights the app’s own retry. |
| No TCP LISTEN | Expected. The daemon dials out. Absence of a listen port was true while `connected=true`. |
| Process name `local-exec-daemon` | 0.47 teardown: the daemon is the Grok Bot binary with `ELECTRON_RUN_AS_NODE=1`. A `pgrep` miss is not a roster bit. Tonight’s helpers were generic node processes with unix sockets. |

If someone still samples `lsof` during the next real S-NEW-D, store counts per remote suffix only (no URLs with tokens, no `lsof` command lines that include auth headers). Compare to a `connected=true` baseline of at least an hour. Until that diff exists, **do not heal on it.**

### 5. Scrape we should not ship: “connection JSON missing or older than 30s”

False at both ends on the evidence we have.

- **False down:** files were absent at `connected=true` on 0.66 (Library search).
- **Secret:** 0.18 file schema is `{baseUrl, token, headers}`.
- **False up if it returns:** a fresh credential file means the coordinator rewrote a handoff, not that the server still counts a heartbeat inside the liveness window.
- **Wrong home:** 0.18 used `~/.grokbot` (`SAND_DATA_ROOT`). 0.66 status that *does* exist lives under Application Support. A watcher on only one root will lie.

### 6. Scrape we should not ship: dune heartbeat, `desktop-status`, `signedIn`

Already proven healthy during S-NEW-D. Keep them for 1.3.0 classes (process down, stale heartbeat, bad `bootOutcome`, frozen heartbeat). Do not lower `HEARTBEAT_STALE_SEC` or `STUCK_SEC` to “catch” S-NEW-D. That false-heals a normal moving heartbeat (`SPEC-1.4.0-beacon.md`).

### 7. Network Debugger UI

Public Windows staff steps check API and **Computer tls** (hosted computer), not the Mac provider roster. One Linux user had no such row. Not a file a LaunchAgent can read. Ignore for heal.

## Recommended SPEC additions

Kit today remains **1.3.0**. Nothing in this note is implemented.

### 1.4.0 — beacon, not a fake local bit

Close the open question “is there a Grok Bot local artifact we are not reading?” with **no, not on 0.66.0 as dug.** `cloudConnectObservable` stays `false`.

Add to the 1.4.0 spec (wording, not code):

1. **Non-goal, strengthened:** do not treat a missing `local-exec-daemon*.json` or a missing `~/.grokbot/local-exec-daemon.log` as disconnected. That absence was observed while `connected=true` on the paths searched.
2. **Non-goal:** do not `lsof`, do not parse gateway-descriptor ciphertext, do not tail a log that contains tokens or untimestamped historical errors.
3. **Do not** retune dune stale/frozen thresholds to cover S-NEW-D.
4. S-NEW-D heal trigger is the **Worker heal-only inbox** already chosen (operator GO ~11:04 PM PT), cooldown bypass same as `.request` (GO ~11:07 PM PT). Reason in `last.json` must say the trigger was the beacon, not a local observation of `connected`.
5. One relaunch per accepted inbox item. If the roster is still false afterward, escalate. Do not loop. Staff incidents include cases where restart cannot fix a server-side empty list (privacy-mode window, 2026 thread 170488).
6. Optional pre-ship check, not a trigger: on the Mac, `ls -la ~/.grokbot` (and `logs/`) once during `connected=true` and once during a real S-NEW-D. Record names and mtimes only. If a non-secret status file appears, stop and re-open the 1.5.0 section. If only credential JSON appears, leave it unread.

### 1.5.0 — native heal, only after an app write

Do not start 1.5.0 until product ships (1) or (2) above, or a labeled capture proves some other field.

Proposed behavior when `local-exec-status.json` exists and `v` is known:

- New reason `roster_disconnected` (name TBD).
- Fire only when **all** of: file `rosterConnected=false` (or `stream=down`) continuously for **≥2** LaunchAgent ticks (about 2 minutes, so a staff-described 1-minute backoff does not bounce the Dock), dune session still the 1.3.0 “looks healthy” shape, disable file absent.
- If the file is **absent**, do **not** heal and do **not** set `cloudConnectObservable=true`. Fall through to 1.4.0 beacon.
- Same quit + `open -ga "Grok Bot"` and the 1.3.0 readiness gate. No new remote control.
- `cloudConnectObservable=true` only for this file, with the vendor note linked in CHANGELOG.
- Never open `local-exec-daemon-connection.json` or `local-exec-daemon-credential.json`.

Until that file exists, **1.5.0 is not a heal path.** Saying the LaunchAgent “classifies every fleet disconnect” locally would be a false green.

## Open questions for xAI / product

1. On 0.66 stable, which transport is live for a normal account: box SSE `GET /local-exec/requests`, or `GrokBotService` watch/poll to the backend? The bundle has both, and a string that the box dial stays idle when a server credential is present. Parker Rex could not settle this on 0.47 either.
2. What hostname does that stream use (`*.cursor.sh`, `*.*.cursorvm.com`, something else)? We found **no public doc** for `connectors-gateway.grok.com`. Please name the host pattern operators may allow on a TLS gateway without logging tokens.
3. Did 0.66 **stop writing** `~/.grokbot/local-exec-daemon-connection.json` and `local-exec-daemon.log` on purpose? Forum staff were still asking for that log on 0.57.1 (2026-09-22). If the log moved, where, and does it include timestamps and a roster line without secrets?
4. Is dune-reliability **intentionally independent** of local-exec liveness? Our incident says yes in practice (heartbeat moved while `connected=false`). If that is by design, a desktop status file is the only native fix.
5. Please confirm the server liveness window (users cited 30s) and that a roster drop can outlive the process heartbeat. Three refusal strings in the 0.66 bundle need a public mapping to `ListMachines.connected` vs empty `machines` vs a specific error.
6. Will you write the non-secret `local-exec-status.json` in (1), or a unified-log subsystem in (2)? We will not ship a parser for credential JSON.
7. Settings → Computer on at least one build shows no online/offline, and Network Debugger (when present) checks API and hosted-computer TLS. Can that debugger grow a “local computer provider” row that matches `ListMachines`, and can that row be exported to the status file?
8. For S-NEW-D specifically: when the helper is up and dune heartbeat is fresh but the roster is false, is **relaunch** the supported recovery, or can it make a server-side drop worse (privacy-mode incident: restart would not have helped)?

## What this does not claim

- It does not claim 0.66 never opens a TCP connection. LISTEN was empty; established sockets were not listed.
- It does not claim `~/.grokbot` was listed. The recorded find roots are Application Support, Logs, Caches, and `~/Library` maxdepth 5.
- It does not claim the 0.18 or 0.47 teardowns match 0.66 runtime. They are public code-reading notes.
- It does not claim a Worker, a status file, or 1.4.0/1.5.0 is built.
