# Capability checks

Single source of truth: each capability, the hermetic test that covers it, the live proof, and the honest status. Test IDs are `run_case` names in `tests/run-tests.sh` (kit) or test names in `worker-beacon/test/` (Worker).

Status: **PASS** = hermetic test passes; **LIVE** = also proven on a real Mac; **OPEN** = not proven; **N/A** = documented non-goal.

## Kit (LaunchAgent)

| Capability | Hermetic test(s) | Live proof | Status |
|---|---|---|---|
| S1 main process down | `T-readiness-pass`, `T-readiness-incomplete`, `T-readiness-failed` | Live process-down prove **skipped** in 1.3.0 ([PROVE-1.3.0](1.4.0/PROVE-1.3.0.md)); incident record ([INCIDENT](INCIDENT-2026-10-02.md)). The quit + `open -ga` relaunch path itself was exercised live by Prove C via `beacon_request` | PASS; no dedicated live process-down prove |
| S2 heartbeat stale > 180s | `T-stale-beats-frozen` | none | PASS |
| Process up, no heartbeat file: soft ok, no relaunch | `T-no-heartbeat-soft` | none | PASS |
| S3 `bootOutcome` not `ready` | `T-readiness-incomplete` (readiness gate path), `T-boot-outcome-pub-token`, `T-boot-outcome-reason-capped` | none | PASS (partial: boot-outcome relaunch is exercised through the readiness cases; the reason token is sanitized and capped at 32 characters) |
| S4 healthy tick is a no-op | `T-healthy` | long healthy streak on the operator Mac (1.1.0 changelog) | LIVE |
| S5 / `.disable` wins | `T-disable`, `T-beacon-disabled-stays-queued`, `T-beacon-operator-request-wins` | [PROVE-DISABLE](1.4.0/PROVE-DISABLE-2026-10-05.md) (2026-10-05 11:29-11:32 PT) | LIVE |
| S6 cooldown 300s | `T-cooldown`, `T-beacon-skip-poll-local-cooldown` | none | PASS |
| S7 readiness gate | `T-readiness-pass`, `T-readiness-incomplete`, `T-readiness-failed` | [PROVE-C](1.4.0/PROVE-C-2026-10-05.md) (`healed`, `readiness=ready`) | LIVE |
| S8 sleep / lid closed | none | none | N/A (documented non-goal) |
| S9 / S-NEW-D silent disconnect | `T-moving-heartbeat-no-heal`, `T-ok-escalate-hint` (regression: no false heal, hint only) | [Prove D FAIL 2026-10-07](1.5.0/PROVE-D-FAIL-2026-10-07.md): real S-NEW-D, kit logged healthy, no agent POSTed, app self-recovered after ~50 min | **Prove D FAIL (2026-10-07); still open.** Agent runbook rule B (immediate relaunch) is a proposal, not kit behavior. A process kill is S1, not S-NEW-D. |
| S-NEW-D helper-exit signature (1.5.0) | `T-helper-fields-healthy`, `T-helper-learn-baseline`, `T-helper-learn-needs-stable-window`, `T-helper-learn-not-while-unhealthy`, `T-helper-baseline-never-lowers`, `T-helper-baseline-never-rises`, `T-helper-transient-high-at-launch`, `T-helper-low-count-needs-two-ticks`, `T-helper-learn-needs-three-samples`, `T-helper-expected-mitigates-late-drop`, `T-bash32-command-subst-heredoc-no-apostrophe`, `T-snapshot-backoff-resets-on-ok`, `T-install-helper-missing-opt-in-survives`, `T-helper-under-threshold`, `T-helper-missing-log-only`, `T-helper-missing-relaunch`, `T-helper-missing-cooldown`, `T-helper-one-relaunch-per-window`, `T-helper-floor-met-allows-new-outage`, `T-helper-dip-recovers-within-grace`, `T-helper-operator-request-wins`, `T-helper-log-only-beacon-still-heals`, `T-helper-disable-wins`, `T-helper-expected-override`, `T-helper-pid-change-resets`, `T-helper-config-expected-pid-change-keeps-floor`, `T-helper-pid-change-healthy-resets`, `T-helper-floor-on-other-relaunches`, `T-helper-baseline-sec-clamped`, `T-helper-none-seen`, `T-helper-sec-clamped-positive`, `T-helper-check-off`, `T-helper-ps-unreadable-no-signal`, `T-helper-ps-hook-requires-test-mode`, `T-helper-ps-bin-production-path`, `T-skipped-scan-keeps-baseline` | Signature observed by hand in the 2026-10-07 outage (baseline 2 → 1 → 2); detector not yet run live | PASS (log-only default; live baseline week pending). Floor carry is frozen for that week. The baseline is learned once as the minimum positive count over the window (`T-helper-transient-high-at-launch`); a third helper does not raise it, even after hours. A late second helper was observed on the live Mac (main up 1d10h57m, NodeService helpers up 1d10h57m and 4h29m); `HELPER_EXPECTED=2` is the recommended setting for the live-baseline week (`T-helper-expected-mitigates-late-drop`). An unhealthy tick does not seed the minimum. One low tick does not lock it; two consecutive healthy ticks do. The window needs 3 healthy samples. An ok tick clears snapshot backoff. Reinstall keeps an operator `HEAL_ON_HELPER_MISSING=1`. Known limits, unchanged: a carried floor does not expire, a scan exception is swallowed, baseline identity is the bare main pid, and the ps shim uses bare comm names. `helper_none_seen` does not replace the long-ok hint. Quoted heredocs inside `$(...)` contain no apostrophe, which bash 3.2 mis-parses (`T-bash32-command-subst-heredoc-no-apostrophe`). |
| Helper socket counts (observe-only, no addresses; snapshot ticks only; `lsof` exit 1 with empty stderr is 0, stderr or other non-zero is null) | `T-helper-sockets-counts-no-addresses` | none | PASS |
| Diagnostics snapshot on non-ok ticks (rate-limited including `heartbeat_stale_*`, then the gap doubles up to 4h, pruned, mode 0600/dir 0700, no argv; known-name `exe` or `other`; `type` enum; allowlisted status fields; `before_relaunch` file before quit; `boot_outcome_*` reason capped; non-finite status numbers do not block a heal) | `T-helper-missing-log-only`, `T-helper-missing-relaunch`, `T-helper-argv-not-in-snapshot`, `T-helper-ps-bin-production-path`, `T-snapshot-mode-0600`, `T-snapshot-rate-limited-and-pruned`, `T-snapshot-stale-reason-rate-limit`, `T-boot-outcome-pub-token`, `T-boot-outcome-reason-capped`, `T-helper-sockets-counts-no-addresses`, `T-helper-disable-wins`, `T-oct7-helper-drop-replay`, `T-nonfinite-status-still-heals` | none | PASS |
| Oct 7 pattern: fresh moving heartbeat, helper 2→1, grace, then observe or opt-in relaunch to readiness | `T-oct7-helper-drop-replay` | Signature observed by hand in the 2026-10-07 outage; this replay is hermetic | PASS |
| Template ships helper observer log-only; reinstall keeps operator helper env | `T-install-template-helper-defaults`, `T-install-preserves-helper-env` | none | PASS |
| S10 intentional quit | same path as S1 (`T-readiness-*`) | none dedicated; same relaunch path as S1, which Prove C exercised live via `beacon_request` | PASS (covered by S1) |
| Frozen heartbeat | `T-heartbeat-frozen`, `T-frozen-under-threshold`, `T-stuck-flag-off` | none | PASS |
| Operator request file | `T-operator_request`, `T-operator-bypasses-cooldown` | none | PASS |
| App missing | `T-app-missing` | none | PASS |
| Version pin | `T-kit-version-matches` | n/a | PASS |

## Beacon (Mac poll hook)

| Capability | Hermetic test(s) | Live proof | Status |
|---|---|---|---|
| Beacon heal (`beacon_request`) | `T-beacon-heal`, `T-beacon-bypasses-cooldown` | [PROVE-C′](1.4.1/PROVE-C-1.4.1-2026-10-05.md), PASS 2026-10-05 on kit **1.4.1**; earlier proof [PROVE-C](1.4.0/PROVE-C-2026-10-05.md) on the pre-1.4.1 script (488ce66) | **LIVE on 1.4.1** |
| `{"heal":false}` no-op | `T-beacon-false-noop` | none | PASS |
| Malformed reply / Worker down no-op | `T-beacon-bad-response-noop`, `T-beacon-worker-down-noop` | none | PASS |
| Unconfigured = no poll | `T-beacon-unconfigured-no-poll` | none | PASS |
| One beacon heal per outage | `T-beacon-second-request-escalates` | none | PASS |
| Token-file perms (group/world readable refuses; 0600 and 0400 poll) | `T-beacon-token-world-readable`, `T-beacon-token-group-readable`, `T-beacon-token-0600-polls`, `T-beacon-token-0400-polls` | none | PASS |
| Perms unknown refuses (fail closed, probe `stat -c %a` then `stat -f %Lp`, then python) | `T-beacon-token-perms-unknown-refuses`, `T-beacon-token-junk-stat-python-fallback`, `T-beacon-token-probe-gnu-stat`, `T-beacon-token-probe-bsd-stat` (shimmed stat: probe order and validation, OS-independent); `T-token-file-mode-real-modes` (real `stat` on the host: 040 judged too open, 600, 1600) | none | PASS (suite run on macOS and Linux) |
| HTTPS-only beacon URL (non-`https://` refuses, curl pinned `--proto =https`) | `T-beacon-http-url-refuses`, `T-beacon-curl-proto-https-only` | none | PASS |
| Token quote/backslash refused; token never logged, never in argv | `T-beacon-token-quote-refuses`, `T-beacon-token-0600-polls` (log check), `T-beacon-token-never-in-argv` (python + curl argv shims) | none | PASS |
| Install preserves `BEACON_*` and custom env; drops `HEAL_TEST_MODE` | `T-install-preserves-beacon-env`, `T-install-fresh`, `T-install-merge-fail-aborts`, `T-install-reset-env` | Mac reinstall (1.4.1) | PASS |

## Worker (`worker-beacon/`)

| Capability | Test(s) | Live proof | Status |
|---|---|---|---|
| Auth (bearer, 401) and per-route tokens | `missing or wrong bearer is 401`, `writer token cannot poll; poller token cannot heal-request`, `unset secrets reject all callers`, `timingSafeEqual ...` | Prove C, [PROVE-C′](1.4.1/PROVE-C-1.4.1-2026-10-05.md) | PASS |
| Allow-list | `unknown machine is 403 for both routes` | none | PASS |
| Strict schema | `extra fields, other actions, bad types rejected and nothing stored`, `bad JSON is 400` | Prove C, [PROVE-C′](1.4.1/PROVE-C-1.4.1-2026-10-05.md) (400s) | LIVE |
| `exp` bounds | `expired and too-far exp rejected` | Prove C (expired 400) | LIVE |
| `jti` replay | `replayed jti rejected` | Prove C, [PROVE-C′](1.4.1/PROVE-C-1.4.1-2026-10-05.md) (409) | LIVE |
| Rate limit 1/5min, 3/hour | `rate limit: 5 min gap and 3/hour` (core-level unit test) | Prove C, [PROVE-C′](1.4.1/PROVE-C-1.4.1-2026-10-05.md) (429) | LIVE (1/5min); hourly cap unit-tested only |
| Consume-once poll, expired flag dropped | `valid request is accepted and consumed once`, `accept then poll consume-once via Worker routing`, `expired pending flag is not returned` | Prove C, [PROVE-C′](1.4.1/PROVE-C-1.4.1-2026-10-05.md) | LIVE |
| Routing (GET/unknown path 404) | `GET is 404; unknown path is 404` | none | PASS |

## Run the checks

- [ ] `./tests/run-tests.sh` -> `passed=91 failed=0` (macOS and Linux). Hermetic: no live app, no launchd, no network. Canned `ps`/`lsof`, and `HELPER_PS_BIN`, only when `HEAL_TEST_MODE=1`.
- [ ] `cd worker-beacon && npm test` -> 15 of 15 pass.
- [ ] `bash -n grok-bot-local-exec-heal.sh install.sh tests/run-tests.sh`

**1.5.0 (PR branch `feat/kit-1.5.0-helper-missing`):** Linux `passed=91 failed=0` on GNU bash 5.2.21 and on compiled bash 3.2.57. Learn-once is the minimum positive count over a window that needs at least three healthy samples. An unhealthy tick does not seed that minimum, and a lower count lowers it only after two consecutive healthy ticks. An ok tick clears snapshot backoff. The plist template does not pin `HEAL_ON_HELPER_MISSING`. `bash -n` is clean on both bashes.

macOS verification already recorded, on macOS 26.6.2 arm64, bash 3.2.57, python3 3.9.6, lsof 4.91:

- `d8b4de0`: `passed=66 failed=0`, including under a launchd-like `PATH`.
- `442258a`: `passed=77 failed=0`.
- Live read-only dry-run on that Mac: 2/2 NodeService helpers, and `lsof` exit 1 with no output means no established socket (the parser's zero-socket case).
- `6e1d580`: bash 3.2.57 `passed=8 failed=77`. A lone apostrophe inside a `$(...)` heredoc failed to parse (`grok-bot-local-exec-heal.sh: line 139: unexpected EOF while looking for matching ')'`).
- `69e091b`: macOS `/bin/bash` 3.2.57 with a launchd `PATH`, CC Buddy: **`passed=87 failed=0`**, `bash -n` clean.

This environment compiled GNU bash 3.2.57 and ran `bash -n` plus the suite under it. The final tip still needs a macOS re-run.

**Last verified (1.4.2):** 2026-10-05 (live beacon heal on kit 1.4.1: Prove C′ PASS), branch `fix/kit-1.4.2-token-perms-capability-checks` at the PR tip: macOS `passed=44 failed=0`, Linux with GNU `stat` `passed=44 failed=0`, worker 15/15 on both (receipts under `~/workspace/extensions/latch-receipts/kit-1.4.2/`).

- Not part of the checks: `LIVE=1 tests/live-process-down.sh` (quits the app).

## Open

- Prove D: a real cloud disconnect with a moving heartbeat, healed via the beacon or the helper observer. **FAIL on 2026-10-07** (nothing posted). Opportunistic; it cannot be staged honestly.
- Helper observer live week: confirm the learned baseline is stable across app versions, idle, and sleep. `HELPER_EXPECTED=2` is the recommended setting for that week. `HEAL_ON_HELPER_MISSING` stays `0` until that week is done. `=1` relaunches once, then stays `helper_suppressed` until the live count meets the floor.
- Known limits (no code change): a carried floor never expires; a helper-scan exception is swallowed and the count is unknown; baseline state is keyed only by the main pid; the ps shim reports bare comm names.
