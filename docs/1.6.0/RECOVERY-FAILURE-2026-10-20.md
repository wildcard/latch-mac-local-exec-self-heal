# Failed recovery: cross-process clock incompatibility

Installed revision: `7ed4b662ab19d70f4c9e7425e3472dacf6d9496b`.
The one approved live test failed to establish automatic usable-client recovery.
The client is usable again through fresh supported tool interactions, but that
later restoration is not attributed to this kit. Automatic recovery remains held.
This follow-up changes source/tests only: no reinstall, hold release, additional
fault, observer rerun, budget reset or merge is performed.

## Evidence and cause

The preserved private observer receipt records one GUI crash signal, zero
automatic reopen attempts and a 180-second timeout. It records restoration of the
maintenance hold. The ledger is still absent, not reset or recreated. Exact process
identities, report contents and epoch times remain private.

Read-only inspection independently matched a primary crash report to the test's
main PID, bundle, process name and event after the prior observed launch. The
watchdog log contains two `codex reopen blocked guard=observation_required`
messages in the bounded test interval. That message is written only after the
watcher proposes `action=reopen`. The continuity gate blocks before invoking the
budget guard, explaining both zero attempts and the absent ledger. This was not
an `open` failure or a missing matching crash report.

Each periodic guard invocation starts a new Apple Python 3.9 interpreter. On this
runtime, `time.monotonic()` uses a process-relative origin; saved samples were near
interpreter startup instead of system uptime. Comparing successive processes'
values therefore gives roughly zero or negative elapsed uptime while wall time
advances by a minute. The continuity rule correctly refuses those incomparable
samples, but consequently refuses every recovery.

A read-only two-interpreter reproduction confirmed the discrepancy: approximately
0.334 seconds elapsed on the system clocks while the independently rebased
`monotonic()` values differed by approximately 0.004 seconds. Python's documentation
states that the macOS monotonic clock became system-wide in Python 3.10.
[Official Python time documentation](https://docs.python.org/3.10/library/time.html#time.monotonic).

## Source fix and review

Darwin now samples `clock_gettime(CLOCK_UPTIME_RAW)` directly. This clock is shared
between processes and excludes sleep, preserving the conservative wall/uptime
comparison. Other supported POSIX runtimes use `CLOCK_MONOTONIC`. A missing or
failed OS clock fails closed; there is no fallback to process-relative values.
[Clock semantics](https://docs.python.org/3.10/library/time.html#time.CLOCK_UPTIME_RAW).

The private observation record gains version 2 and a `clockSource` discriminator.
A legacy record, unknown source or changed clock domain requires a new observation
before continuity may be granted. Old numeric origins are never compared to the
new system-wide origin. Invalid/failed current clocks do not rewrite state.

The elapsed-time, backwards-clock, wake-like divergence, first-sample and unsafe
state checks remain. No idle authorization, stop control, attempt cap or backoff
is weakened, and no attempt ledger migration/reset is introduced. The code still
does not supply an authoritative wake or all-lanes-idle signal.

This is an implementing-agent review, not new independent reviewer clearance.
The earlier unit tests supplied compatible numeric clocks; most recovery fixtures
explicitly bypassed continuity. They did not exercise separate Apple Python 3.9
interpreters and missed this platform integration defect. The live-proof readiness
check also accepted healthy app observations without requiring continuity; the
next proof must refuse to inject a fault unless continuity is actually confirmed.

## Non-disruptive validation

- Apple Python 3.9: 61 tests pass. Added tests cover OS clock selection, no relative
  fallback, failed-clock non-rewrite, clock-domain/legacy refusal, real separate
  interpreters and one-time safe legacy migration.
- Ten focused shell cases pass: continuity/gap, clock status, seven restart-guard
  cases, and an end-to-end fixture reopen using the real cross-process OS clock
  with the continuity bypass disabled. The last case writes one temporary attempt
  and calls one stubbed open. It touches no real app, job or installed ledger.
- Shell syntax and whitespace checks pass. Installed guard bytes still match the
  prior installed candidate, the maintenance hold remains present and the installed
  ledger remains absent. The new clock fix has not been installed.

## Exact next validation for review

Normal lanes may continue under the retained hold. Do not run another live fault
or install this source while those lanes are active.

1. Review this cause, clock selection/migration and the bypass-free fixture result.
2. In a separately coordinated approved window, prepare/sign a new exact candidate,
   freeze a fresh rollback snapshot and approve its installation under hold. Do not
   reuse the old candidate as though it contains this fix.
3. First perform an observation-only continuity validation with no fault: establish
   a new v2 clock sample, then verify real scheduled tick-to-tick continuity with
   the expected clock source. Legacy migration must initially refuse continuity.
4. If release into observation is authorized, require two distinct normal healthy
   client ticks **and `observationStatus=continuous`** before considering a fault.
   An unknown/required/error status must stop the test before disruption. Never
   use the test-only continuity bypass against the live installation.
5. Only after reviewing those observations should a new single-fault proof be
   authorized. Use an independent control route, one automatic attempt, the bounded
   deadline, hold restoration and a fresh usable-client interaction criterion.
   Preserve every prior receipt and attempt; no retry or budget reset is implied.
6. Review the actual installed-source/result/privacy evidence before any merge.
   No positive recovery or continuous-availability claim is warranted yet.

Full retained prior-bot and cross-bot transcript coverage remains incomplete. The
cause above follows independently from saved receipts, log control flow, actual
crash identity and the supported runtime clock reproduction.
