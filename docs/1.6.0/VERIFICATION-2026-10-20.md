# Maintenance follow-up verification

Baseline: `9d3e28c6850572c2389b8a30a31efd382e21cef6`. Prior code review
clearance applies to the earlier runtime baseline, not this follow-up. The new
source remains a draft pending independent review and owner maintenance approval.

## Validation

- Apple Python 3.9: 55 tests passed. New tests cover production policy refusal,
  Codex and ChatGPT identities, modern Codex executable naming, private candidate
  rendering and drift, crash read budget, malformed prior plist, and maintenance
  refusal before executable replacement.
- Worker: 15 tests passed. No Worker source or deployed service changed.
- Apple Bash 3.2: 121 shell cases passed, 0 failed, with executable source held
  stable. Shell syntax and whitespace checks pass. New shell regressions cover
  quit-marker priority, dangling disable, Grok absent-versus-crash evidence and a
  desktop pause arriving after restart authorization.
- The private candidate was prepared and checked against the real prior installed
  file hashes. No installed file was changed; the candidate check passes.
- A read-only process check outside the restricted process sandbox recognized the
  selected installed bundle and main process. Only booleans were emitted. Within
  the restricted process sandbox the scan failed closed. This is identity evidence,
  not a crash/reopen, readiness or cloud connectivity proof.
- Supplementary current-file identifying/credential-pattern review found no new
  machine/user/workplace identifiers or credential literals in changed source/docs.
  Broad matches in existing files were synthetic fixture paths and legal copyright
  attribution. Private config/history evidence stays ignored by Git. Earlier
  commits and PR revisions retain prior metadata; history was not rewritten.

The initial broad runs had a changed held-beacon expectation and transient fixture
failures while source was being edited. The held-beacon expectation was corrected:
a hold must preserve queued beacon work. Focused regressions passed. The full run
with executable source held stable passed 121 cases and is the final shell acceptance check; no
failed run is represented as a pass.

## Evidence limits

No install/load/unload, live fault, app restart, live beacon call, permission or
security change, remote-agent wake-up, outgoing bot message, history rewrite or
merge occurred. Native UI history reading exposed only a menu and no screenshot;
no primary transcript was captured. Earlier bounded coordination/review receipts
and prior engineering summaries were read. Full retained review-bot history and
cross-bot exchanges remain gaps in the private coverage ledger.

A real process crash/reopen and remote execution after reconnect remain unproven.
An absent process or synthetic report is not silent-disconnect proof. The optional
beacon remains the existing supported inbox and has not been activated or called.
An owner-approved maintenance window, protected work, exact-head review and
separate bounded live-proof authorization remain necessary before runtime action.
