# Latch mac-local-exec-self-heal

## 1.4.2 — 2026-10-05

- Token-permission check in the beacon poll is now portable and fails closed. The old `stat -f %Lp || stat -c %a` form failed open on GNU/Linux, where `stat -f` is a filesystem stat that exits 0 with junk, so a 0644 token was still used. Now `token_file_mode` picks the stat flavour by OS, validates the result as 3-4 octal digits, falls back to python, and the poll is refused (`beacon: token file perms unknown; refuse`) when the mode cannot be determined. Group/world-readable still refuses with the existing log text. 0600 and 0400 poll as before. The token is never logged.
- Beacon poll refuses a non-HTTPS `BEACON_URL` (`beacon: BEACON_URL is not https; refuse`, no poll) and pins curl to `--proto =https`, so the poller bearer can never leave the Mac in cleartext. Tests: `T-beacon-http-url-refuses`, `T-beacon-curl-proto-https-only`.
- README collapsed to one current-`VERSION` story; the 1.3.0 vs 1.4.x comparison lives in this changelog and `docs/1.4.0/`.
- New tests: `T-beacon-token-group-readable`, `T-beacon-token-0400-polls`, `T-beacon-token-0600-polls`, `T-beacon-token-perms-unknown-refuses`, `T-beacon-token-junk-stat-python-fallback`. `BEACON_TEST_NO_PY_PERMS=1` is a test-only hook that disables the python fallback.
- `docs/CAPABILITY-CHECKS.md`: every capability mapped to its test, live proof and honest status.
- `docs/1.4.0/PROVE-DISABLE-2026-10-05.md`: live record that `.disable` wins over a beacon heal-request (PASS).
- Stale docs fixed (README, PRODUCT-BAR, worker-beacon README). Prove C′ PASS: a live beacon heal on kit 1.4.1 ([`docs/1.4.1/PROVE-C-1.4.1-2026-10-05.md`](docs/1.4.1/PROVE-C-1.4.1-2026-10-05.md)). Prove D remains open.

## 1.4.1 — 2026-10-05

- `install.sh` no longer wipes operator-set LaunchAgent `EnvironmentVariables` on reinstall. Operator tunables (`BEACON_*`, `HEAL_CURSOR`, `COOLDOWN_SEC`, `STUCK_SEC`, `HEARTBEAT_STALE_SEC`, `READINESS_WAIT_SEC`, `OK_HINT_SEC`, `HEAL_ON_STUCK_SESSION`, and any other custom string keys) win over template defaults; kit-owned `PATH` comes from the template. `INSTALL_RESET_ENV=1` deliberately wipes back to the template. Only what is already on disk is preserved; nothing secret is stored in git.
- Plist replace is atomic (temp in LaunchAgents dir → lint → `mv`). Merge failure is fail-loud: existing plist left unchanged, non-zero exit before any `launchctl bootstrap`.
- `install.sh` waits and retries `launchctl bootstrap` (up to 5 tries) after `bootout`, fixing the intermittent `Bootstrap failed: 5: Input/output error` race; prints a recovery `bootstrap` command on final failure and skips the extra sleep/bootout after the last attempt.
- `INSTALL_SKIP_LAUNCHD=1` (tests only) writes files and exits without touching launchd or running a heal; also skips the Darwin-only gate so hermetic install tests run on Linux CI. Do not leave it exported in a shell profile.
- Hermetic tests cover preserve (incl. ProgramArguments + tunable keep), fresh install, merge-failure abort, and `INSTALL_RESET_ENV`.
- `KIT_VERSION`, `VERSION` and fixture pins bumped to 1.4.1.

## 1.4.0 — 2026-10-05

Worker-beacon heal-only inbox: a Cloudflare Worker plus an optional Mac poll hook. Prove C passed on the beacon path. Prove D (a real cloud disconnect while the heartbeat is still moving) is still open.

- Proposal and research under `docs/1.4.0/` (beacon spec, Mac exposure dig, 1.3.0 prove record, pre-1.3 gap spec).
- Product bar (`docs/PRODUCT-BAR.md`): catch every `ListMachines.connected=false` class, including S-NEW-D; the only fix is restarting Grok Bot; Worker heal-only inbox is last resort; prefer a native Mac connection file so bots need not declare the machine down.
- Decision locks: Worker inbox is the default beacon transport; a beacon heal-request bypasses the 300s cooldown the same way the local `.request` file does.
- Research fold-in: no on-disk or localhost signal mirrored `ListMachines.connected` on 2026-10-02. Named `local-exec-*-connection` files were source strings only. Do not lower stale or frozen thresholds to fake a fix.
- Connection-signal research (`docs/1.4.0/RESEARCH-GROK-BOT-CONNECTION-20261002.md`): public docs and the 0.66.0 dig still show no LaunchAgent-usable mirror of `ListMachines.connected`. Do not scrape credential JSON or treat a missing daemon file as disconnected.
- Self-heal modes matrix (`docs/1.4.0/SELF-HEAL-MODES.md`): none / mac-local / worker-beacon / vitals-buddy; deploy-time multi-mode pack. vitals-buddy is not built.
- Decision locks 2026-10-05: while `.disable` is present a beacon heal-request stays queued and disable still blocks relaunch; one beacon relaunch per outage then stop and escalate; auth v1 is Bearer tokens (HMAC documented alternative).
- `worker-beacon/`: heal-only inbox Worker (strict `heal_request` schema, single-use `jti`, `exp` <=120s, per-machine Durable Object, 1/5min and 3/hour limit) with unit tests. Deployed and live on the operator's personal Cloudflare at https://latch-worker-beacon.kadosh.workers.dev. Tokens are Worker secrets plus a token file outside the repo; none are in git. No account id in the repo.
- Heal script: optional outbound beacon poll once per tick (`BEACON_URL`, `BEACON_POLL_TOKEN_FILE`, `BEACON_MACHINE_ID`), off unless configured. Distinct reason `beacon_request`. Fixture tests plus the live Prove C below.
- **Prove C: PASS** on the beacon path ([`docs/1.4.0/PROVE-C-2026-10-05.md`](docs/1.4.0/PROVE-C-2026-10-05.md)). A heal request POSTed from a remote box (not by creating the local `.request` file) relaunched Grok Bot with reason `beacon_request`: old pid replaced, `status=healed`, `readiness=ready`. Bad requests (missing `exp`, expired, unsupported action) were each rejected with 400; a replayed `jti` got 409 and a second accept inside 5 minutes got 429. This is **not** Prove D. S-NEW-D under a real cloud disconnect with a moving heartbeat is still unproven. Not done: Prove D. The live `.disable`-blocks-beacon check later passed 2026-10-05 ([`docs/1.4.0/PROVE-DISABLE-2026-10-05.md`](docs/1.4.0/PROVE-DISABLE-2026-10-05.md)).
- `.gitignore`: `.wrangler/` and `node_modules/`.
- Follow-up on `feat/worker-beacon-inbox`: `KIT_VERSION` stamped 1.4.0; poll skipped when a local heal is already needed (avoids consuming a beacon request into cooldown); token file must not be group/world-readable and must not contain `"`/`\`; poll accepts only `{"heal":true}`; Worker index + `timingSafeEqual` covered by tests; poll unknown-machine status aligned to 403.


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
