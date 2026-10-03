> **Documentation only.** Research from 2026-10-02. Not an implementation. `VERSION` stays **1.3.0**.

# Grok Bot Mac — where ListMachines / connected lives

**When:** 2026-10-02 ~11:07–11:12 PM PT  
**App:** Grok Bot 0.66.0 (`/Applications/Grok Bot.app`)  
**Machine:** `DEMO-MAC` (`machineId <redacted>`, `hostname <redacted>`)

## Short answer

There is **no separate CLI or executable** bots call for `ListMachines`. That tool is a **cloud/box Cursor tool**: the backend already knows whether this Mac’s local-exec channel is up. Bots never run a `list-machines` binary on the Mac.

What *does* run on the Mac is inside the Electron app:

| Piece | Role |
|---|---|
| `Contents/MacOS/Grok Bot` | Electron shell |
| `Resources/app.asar` → `dist/local-exec-daemon/main.cjs` | Local-exec daemon (SSE to cloud, Shell/Read execution) |
| `Resources/app.asar` → `dist/node-agent-coordinator/main.cjs` | Agent coordinator / gateway |
| Helpers (GPU / Renderer / Plugin) | Standard Electron helpers — not a separate local-exec CLI |

Extracted inspect tree on Mac:  
a local asar extract (path not published)

## On-disk signals the heal kit already / can use

Under `~/Library/Application Support/Grok Bot/`:

| File | What we saw tonight (healthy / connected=true) |
|---|---|
| `desktop-status.json` | `{"version":1,"pid":<pid>,"appVersion":"0.66.0","startedAtMs":<redacted>,"signedIn":true}` — **no `connected` field** |
| `dune-reliability/sessions/*.running.json` | pid, `heartbeatAtMs` (moving), `bootOutcome:"ready"` — **what 1.3.0 already watches** |
| `gateway-descriptor.json` | Encrypted gateway handoff blob — not a plain connected bit |
| `sand-client-persistence/*.blob` | Opaque client persistence — not usable as a heal signal without decoding |

**Not found on disk** (despite being named in daemon source):  
`local-exec-daemon.json`, `local-exec-daemon-connection.json`, `local-exec-daemon-credential.json`, `local-exec-supervisor.json`, `local-exec-update-lease.json`, `local-exec-backend-return.json`.

Those names exist in `local-exec-daemon/main.cjs` but a live find under `~/Library` returned **zero** matches while local-exec was connected. Connection state for the daemon appears **in-process** (SSE loop events: `connected` / `disconnected` / `unauthorized` / stall), not a durable JSON the LaunchAgent can poll today.

## How the daemon talks to the cloud (from strings)

- Backend path: `POST /sand-box/local-exec-connection` (handoff / credential)
- Control/data posts + **SSE** (`local-exec-sse-connect`, `local-exec-sse-reconnect`, `local-exec-sse-stall`)
- Internal heartbeat name: `local-exec-heartbeat` (interval in code; distinct from dune-reliability file heartbeat)
- Error copy when Mac looks down to bots: *“is unavailable — it looks disconnected…”*
- Waiting state: *“local-exec daemon has no gateway connection yet (waiting for the desktop to hand one off)”*

`ListMachines` string appears in the same bundle as **agent-facing tool copy** (“Call ListMachines and retry with machineId…”), i.e. documentation of the cloud tool — not a Mac binary entrypoint.

## Implications for S-NEW-D / 1.4.0

1. **Cannot** “run the same ListMachines the bots run” from LaunchAgent — that capability is server-side.
2. **Can** keep using process + dune heartbeat + bootOutcome (1.3.0).
3. **Preferred Mac signal** for zombie disconnect: need something the daemon already knows in memory but does not currently write — e.g. ask product to expose `local-exec-daemon-connection.json` with `{connected, lastSseAtMs, reason}`, **or** detect SSE stall via a new file the app writes on `disconnected`.
4. Until that exists, **Worker beacon** (operator GO) is the way a disconnected bot injects heal when cloud sees `connected=false` and Mac still looks healthy.

## Decisions locked tonight

- Beacon default: Cloudflare Worker heal-only inbox  
- Beacon heal-request **bypasses** 300s cooldown (same as `.request`)
