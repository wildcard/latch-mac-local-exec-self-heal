# Latch mac-local-exec-self-heal

## Unreleased — 1.4.0 (proposed, not shipped)

Docs only. **`VERSION` remains 1.3.0.** S-NEW-D is **not** auto-healed by the LaunchAgent in this tree.

- Proposal and research under `docs/1.4.0/` (beacon spec, Mac exposure dig, 1.3.0 prove record, pre-1.3 gap spec).
- Product bar (`docs/PRODUCT-BAR.md`): catch every `ListMachines.connected=false` class, including S-NEW-D; the only fix is restarting Grok Bot; Worker heal-only inbox is last resort; prefer a native Mac connection file so bots need not declare the machine down.
- Decision locks recorded, not built: Worker inbox is the default beacon transport; a beacon heal-request bypasses the 300s cooldown the same way the local `.request` file does.
- Research fold-in: no on-disk or localhost signal mirrored `ListMachines.connected` on 2026-10-02. Named `local-exec-*-connection` files were source strings only. Do not lower stale or frozen thresholds to fake a fix.
- Connection-signal research (`docs/1.4.0/RESEARCH-GROK-BOT-CONNECTION-20261002.md`): public docs and the 0.66.0 dig still show no LaunchAgent-usable mirror of `ListMachines.connected`. Do not scrape credential JSON or treat a missing daemon file as disconnected.
- Self-heal modes matrix (`docs/1.4.0/SELF-HEAL-MODES.md`, ~11:35 PM PT bar): none / mac-local / worker-beacon / vitals-buddy; deploy-time multi-mode pack. Product bar and tasks updated. No Worker or buddy code.
- Not in this change: Cloudflare Worker, Wrangler config, Mac poll client, plist, heal script, tests, or a version bump. No secrets.

## 1.3.0 — 2026-10-02
- Readiness gate: after `open -ga`, `healed` is written only when the process is up and (heartbeat age is finite and under `HEARTBEAT_STALE_SEC`, or `bootOutcome=ready`). Bounded wait `READINESS_WAIT_SEC` (default 75). Otherwise `heal_incomplete` or `heal_failed` with `readiness` and `escalateHint`.
- `heartbeat_frozen`: same pid and same `heartbeatAtMs` for at least `STUCK_SEC` (default 120) → relaunch. Toggle with `HEAL_ON_STUCK_SESSION` (default 1). A heartbeat that is still advancing is not frozen.
- Operator force file `~/Library/Application Support/Latch/grok-bot-local-exec-heal.request` → one-shot relaunch, reason `operator_request`, bypasses cooldown, file consumed. A remote agent that is already disconnected cannot create this file.
- `last.json` schema v2: `readiness`, `escalateHint` (long `ok` streak and stuck outcomes), `heartbeatAtMs`, frozen/ok-streak clocks, `cloudConnectObservable: false`.
- Honest non-goal: S-NEW-D (cloud `ListMachines.connected=false` while Mac process + moving heartbeat look healthy) is outside pure Mac heal. Long `ok` streaks record an escalate hint; they do not pretend to fix sleep, lid, network, or sign-in.
- Fixture test harness `tests/run-tests.sh` (default, does not touch a live app). Live quit-and-wait prove is `tests/live-process-down.sh` and refuses to run unless `LIVE=1` on macOS.

## 1.2.0 — 2026-10-02
- Same heal behavior as 1.1.0: dead process or heartbeat older than 180s, then gentle relaunch. Success was "process pid exists," with no readiness gate. 1.3.0 closes that gap.
- Shipped beside the broader Latch Mac template. This repository is only the self-heal LaunchAgent.

## 1.1.0 — 2026-10-02
- First-class Latch product feature: LaunchAgent watchdog for Grok Bot local-exec drops.
- Detects dead main process or stale dune-reliability heartbeat (>180s).
- Gentle quit + `open -ga "Grok Bot"` relaunch; 300s cooldown; Cursor auto-relaunch off by default.
- Soft disable via `~/Library/Application Support/Latch/grok-bot-local-exec-heal.disable`.
- Proven on operator Mac (hundreds of healthy ticks, last exit 0).

## 1.0.0 — 2026-09-19
- Initial public packaging of the Mac-side heal notes. The LaunchAgent itself landed in 1.1.0.
