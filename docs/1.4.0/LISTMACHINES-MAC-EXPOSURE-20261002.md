> **Documentation only.** Research from 2026-10-02. Verdict: no on-disk mirror of `ListMachines.connected`. `VERSION` stays **1.3.0**.

# ListMachines / connected — Mac exposure (S-NEW-D)

**When:** 2026-10-02 ~11:10–11:13 PM PT (verify after false-stop; no LIVE=1 re-run)  
**Machine:** `DEMO-MAC` (`machineId <redacted>`, `hostname <redacted>`)  
**App:** Grok Bot 0.66.0 (`com.anysphere.sand`)  
**Consolidates:** `GROK-BOT-LOCAL-EXEC-INSPECT.md` + this Mac verify  
**Dumps:** not published. Local verify notes stayed off this repository.

## Verdict

| Question | Answer |
|---|---|
| On-disk or localhost signal that mirrors cloud `ListMachines.connected`? | **N** |
| Usable LaunchAgent S-NEW-D trigger (fire when cloud says disconnected while dune still looks healthy)? | **N** |
| Fallback | Worker heal-only inbox stays the path. Cooldown bypass already decided (same as `.request`). Not implemented here. |

Cloud `ListMachines` at verify time: **connected=true**, kind=desktop. That bit is **not** written anywhere this dig could read.

## Candidates (path + evidence)

| Candidate | Evidence | Mirrors `connected`? |
|---|---|---|
| Cloud `ListMachines` | Live call: connected=true, label `hostname <redacted>`. Not a Mac binary. `ListMachines` appears **2×** in `dist/local-exec-daemon/main.cjs` as agent copy (“Pick a desktop from ListMachines”), not an entrypoint. | This *is* the cloud bit. Not pollable from LaunchAgent. |
| `~/Library/Application Support/Grok Bot/desktop-status.json` | `version`, a live pid, `appVersion:0.66.0`, `startedAtMs`, `signedIn:true`. **No `connected` key.** Writer string in `electron-main/main-app.cjs`. | **N** (process + signed-in only) |
| `dune-reliability/sessions/*.running.json` | Same live pid, `bootOutcome:"ready"`, `heartbeatAtMs` ~17s old at verify, `mainFaultSeen:false`, empty `childDeaths`. Identity keys include installId (value not published). This is what heal 1.3.0 already watches. | **N** for zombie disconnect. Fresh while connected tonight; source does not emit SSE up/down here. |
| `gateway-descriptor.json` | version 2, one encrypted blob. Not a plain connected flag. | **N** |
| Named daemon files (`local-exec-daemon.json`, `local-exec-daemon-connection.json`, `local-exec-daemon-credential.json`, `local-exec-supervisor.json`, `local-exec-update-lease.json`, `local-exec-backend-return.json`, `local-exec-daemon.log`, account-retire/generation) | **String literals only** in daemon / coordinator / main-core. `find` under App Support, Logs, and `Caches/com.anysphere.sand*` returned **zero** of these while ListMachines was connected. | **N** (not on disk) |
| `SingletonSocket` | Electron single-instance unix socket under `/var/folders/.../scoped_dir*/SingletonSocket`. Main pid **no TCP LISTEN**. Node helpers were unix-only. | **N** |
| `Contents/MacOS/Grok Bot` | 52KB arm64 stub. `strings` ~2 hits (`ELECTRON_RUN_AS_NODE`). Real logic is `Resources/app.asar` (37MB). | **N** |
| PATH CLI | `grok` not on PATH. `/usr/local/bin/cursor` is Cursor.app. Unpacked natives: `sand-op-launcher`, `sand-webauthn-signer` only. | **N** |
| LaunchAgents | Only `~/Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist` (Latch, StartInterval 60, dune heartbeat stale / stuck session). `com.anysphere.sand.ShipIt` is Squirrel updater, not running. **No Grok agent watches SSE connected.** | **N** |

## SSE connected / disconnected (in-process)

From the asar extract `dist/local-exec-daemon/main.cjs`:

- Handoff: `POST /sand-box/local-exec-connection`; credential path `/sand-box/local-exec-daemon-credential`
- Data/control: `/local-exec/requests`, `/local-exec/responses`, `local-exec-data-post`, `local-exec-control-post`, `local-exec-response-post`
- SSE loop names: `local-exec-sse-connect`, `local-exec-sse-reconnect`, `local-exec-sse-stall`, plus `local-exec-heartbeat` (distinct from `dune-reliability-heartbeat`)
- State words in the same bundle: `connected`, `disconnected`, `CONNECTED`, `NOT_CONNECTED`, `unauthorized`
- User-facing down copy: “is unavailable — it looks disconnected…”
- Waiting copy: “local-exec daemon has no gateway connection yet (waiting for the desktop to hand one off)”
- Coordinator also has `gateway-sse-connect` / `gateway-sse-stall` and a stall-watchdog string (transcript stream silent). That is the box gateway, not a Mac status file.

`main-core.cjs` explains the cloud side of the same channel: refuse when no desktop is on the reverse local-exec channel, or when none heartbeated inside the liveness window, or when `machineId` was omitted. That liveness is **server-side**. The Mac does not persist it.

## Why LaunchAgent cannot be the S-NEW-D trigger

S-NEW-D needs “cloud `connected=false` while the Mac still looks alive.” Tonight’s healthy files (pid up, dune heartbeat fresh, `bootOutcome:ready`, `signedIn:true`) are exactly the alive look. The SSE `connected`/`disconnected` transition is **inside the daemon process** and is not flushed to `local-exec-daemon-connection.json` (named, not created). No localhost listen port exposes it. A LaunchAgent can only see the files and the process, which is the 1.3.0 signal, not ListMachines.

Until the app writes something like `{connected, lastSseAtMs, reason}`, the disconnected-bot path stays the **Worker heal-only inbox**. Cooldown bypass for that beacon is already decided; this dig does not implement it.

## Verify vs prior inspect

Agreed with `GROK-BOT-LOCAL-EXEC-INSPECT.md`. Added: live ListMachines receipt, heartbeat age ~17s on the same pid as `desktop-status`, no TCP listen, ShipIt is updater-only, `local-exec-daemon.log` also absent, string counts from the asar extract.
