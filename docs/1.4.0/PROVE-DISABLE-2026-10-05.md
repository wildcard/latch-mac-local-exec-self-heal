# Prove: `.disable` blocks a beacon heal-request (2026-10-05)

**Result: PASS.** A soft-park `.disable` file wins over a beacon heal-request. No relaunch happened, and the pending request was not consumed while disabled.

This is **not** Prove D (a real cloud disconnect while the heartbeat is moving), which is still open.

Ran on the pre-1.4.1 script (the Prove C build). The disable gate code is unchanged since.

## Timeline (PT)

- Before: pid 3731, healthy after Prove C.
- `.disable` present. LaunchAgent ticks at 11:29:18 and 11:30:18 logged `skip: disable file present`; `last.json` showed `status=disabled`, `reason=disable_file`.
- 11:29:21: a remote box POSTed a heal-request. Worker replied HTTP 202 `{"ok":true}`, `exp` about 90s ahead.
- While disabled: pid stayed 3731. No `beacon: heal request pending` and no heal start in the log.
- `.disable` removed. Ticks at 11:31:20 and 11:32:22 logged `ok reason=healthy pid=3731`.

## Not claimed

- Prove D.
- That the 11:29 request was consumed later. It expired at about 11:30:51 PT, before `.disable` was removed.
