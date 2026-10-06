# Prove C′: worker-beacon heal on kit 1.4.1 (2026-10-05)

**Result: PASS** on the beacon path with kit **1.4.1** installed.

This is **not** Prove D (a real silent cloud disconnect healed via the beacon), which stays open and opportunistic.

## Timeline (PT)

- Preflight: `last.json` reported `kitVersion=1.4.1`, idle `status=ok`. Token file mode 600 (permissions checked only; contents never read). No `.disable`, no `.request`. `BEACON_*` set on the LaunchAgent. Pre pid 3731. The previous beacon heal was at 11:23, outside the 3600s one-per-outage window.
- Negatives before accept (see table).
- 17:03:06: a remote box POSTed a heal-request. Worker replied HTTP 202 `{"ok":true}`.
- 17:04:05: Mac log `beacon: heal request pending`, then heal start with `reason=beacon_request` (pid 3731).
- 17:04:12: heal done, `status=healed`, `reason=beacon_request`, new pid 60699, `readiness=ready`, `boot=ready`. `last.json`: kitVersion 1.4.1, status healed, reason beacon_request, readiness ready.
- After accept: a replayed `jti` got 409 (`replayed jti`); a second accept inside 5 minutes got 429 (`rate limited`).

## Negatives (before accept)

| Request | Result |
|---|---|
| Missing `exp` | 400 (unexpected or missing fields) |
| Unsupported action | 400 (unsupported action) |

## Notes

- The remote shell session to the Mac dropped while Grok Bot relaunched (expected local-exec bounce) and then reconnected.
- Beacon heals are suppressed for about an hour from 17:04 (`BEACON_RELAUNCH_WINDOW_SEC`).

## Not claimed

- Prove D.
- Anything about the Linux or fail-closed token-permission paths; this run used a 0600 token file.
