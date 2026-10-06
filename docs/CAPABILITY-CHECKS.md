# Capability checks

Single source of truth: each capability, the hermetic test that covers it, the live proof, and the honest status. Test IDs are `run_case` names in `tests/run-tests.sh` (kit) or test names in `worker-beacon/test/` (Worker).

Status: **PASS** = hermetic test passes; **LIVE** = also proven on a real Mac; **OPEN** = not proven; **N/A** = documented non-goal.

## Kit (LaunchAgent)

| Capability | Hermetic test(s) | Live proof | Status |
|---|---|---|---|
| S1 main process down | `T-readiness-pass`, `T-readiness-incomplete`, `T-readiness-failed` | Live process-down prove **skipped** in 1.3.0 ([PROVE-1.3.0](1.4.0/PROVE-1.3.0.md)); incident record ([INCIDENT](INCIDENT-2026-10-02.md)). The quit + `open -ga` relaunch path itself was exercised live by Prove C via `beacon_request` | PASS; no dedicated live process-down prove |
| S2 heartbeat stale > 180s | `T-stale-beats-frozen` | none | PASS |
| Process up, no heartbeat file: soft ok, no relaunch | `T-no-heartbeat-soft` | none | PASS |
| S3 `bootOutcome` not `ready` | `T-readiness-incomplete` (readiness gate path) | none | PASS (partial: boot-outcome relaunch is exercised through the readiness cases) |
| S4 healthy tick is a no-op | `T-healthy` | long healthy streak on the operator Mac (1.1.0 changelog) | LIVE |
| S5 / `.disable` wins | `T-disable`, `T-beacon-disabled-stays-queued`, `T-beacon-operator-request-wins` | [PROVE-DISABLE](1.4.0/PROVE-DISABLE-2026-10-05.md) (2026-10-05 11:29-11:32 PT) | LIVE |
| S6 cooldown 300s | `T-cooldown`, `T-beacon-skip-poll-local-cooldown` | none | PASS |
| S7 readiness gate | `T-readiness-pass`, `T-readiness-incomplete`, `T-readiness-failed` | [PROVE-C](1.4.0/PROVE-C-2026-10-05.md) (`healed`, `readiness=ready`) | LIVE |
| S8 sleep / lid closed | none | none | N/A (documented non-goal) |
| S9 / S-NEW-D silent disconnect | `T-moving-heartbeat-no-heal`, `T-ok-escalate-hint` (regression: no false heal, hint only) | none | **Prove D OPEN / opportunistic.** Nothing detects S-NEW-D by itself; a bot or operator must POST to the beacon. A process kill is S1, not S-NEW-D. |
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
| Perms unknown refuses (fail closed, portable stat) | `T-beacon-token-perms-unknown-refuses`, `T-beacon-token-junk-stat-python-fallback` | none | PASS (macOS and Linux) |
| HTTPS-only beacon URL (non-`https://` refuses, curl pinned `--proto =https`) | `T-beacon-http-url-refuses`, `T-beacon-curl-proto-https-only` | none | PASS |
| Token quote/backslash refused; token never logged | `T-beacon-token-quote-refuses`, `T-beacon-token-0600-polls` (log check) | none | PASS |
| Install preserves `BEACON_*` and custom env | `T-install-preserves-beacon-env`, `T-install-fresh`, `T-install-merge-fail-aborts`, `T-install-reset-env` | Mac reinstall (1.4.1) | PASS |

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

- [ ] `./tests/run-tests.sh` -> `passed=40 failed=0` (macOS and Linux). Hermetic: no live app, no launchd, no network.
- [ ] `cd worker-beacon && npm test` -> 15 of 15 pass.
- [ ] `bash -n grok-bot-local-exec-heal.sh install.sh tests/run-tests.sh`

**Last verified:** 2026-10-05 (live beacon heal on kit 1.4.1: Prove C′ PASS), branch `fix/kit-1.4.2-token-perms-capability-checks` at the PR tip (first verified commit `1542fb4`): macOS `passed=38 failed=0` at `fd9034a` (receipts under `~/workspace/extensions/latch-receipts/kit-1.4.2/`), Linux with GNU `stat` `passed=38 failed=0`, worker 15/15; with the HTTPS-only check added: Linux `passed=40 failed=0`, worker 15/15.

- Not part of the checks: `LIVE=1 tests/live-process-down.sh` (quits the app).

## Open

- Prove D: a real cloud disconnect with a moving heartbeat, healed via the beacon. Opportunistic; it cannot be staged honestly.
