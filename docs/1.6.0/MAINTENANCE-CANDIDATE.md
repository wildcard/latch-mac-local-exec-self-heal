# Maintenance candidate and recovery boundaries

This packet supersedes the earlier installation examples for this code revision.
It prepares the owner's selected direction: retain Grok recovery intent with
stricter safeguards and add explicit Codex/ChatGPT desktop crash watching.
Preparation is authorized; the maintenance window and any disruptive proof still
need confirmation. Nothing in this packet claims installation or live recovery.
The existing installed kit remains unchanged.

## Concrete preparation

From the reviewed checkout:

```sh
mkdir -p .latch-local
python3 prepare-install.py .latch-local/maintenance-candidate
python3 prepare-install.py .latch-local/maintenance-candidate --check
```

The new destination must not exist. The preparation directory is private (0700),
and policy, manifest, log and complete candidate plist are 0600. The plist retains
existing operator settings privately, including existing beacon configuration;
never attach this directory to a PR. It is ignored by Git. Rendered paths target
the real installation, not the staging directory. No launchctl, app command,
installed executable replacement, installed ledger write or network request runs.
The manifest binds source files, candidate executables/plist/policy and the prior
installed script/guard/watcher/plist bytes. `--check` refuses source, candidate or
installed-file drift. Hashes are consistency checks, not code signing or approval.

The explicit persisted candidate policy is:

| Setting | Candidate | Reason |
|---|---|---|
| `RECOVERY_MODE` | `active` | Retain reviewed Grok recovery intent |
| `HEAL_ON_HELPER_MISSING` | `1` | Retain helper-loss recovery after grace |
| `HELPER_MISSING_SEC` | `300` | Pin the existing observed grace |
| `HELPER_IDLE_REQUIRED` | `1` | Require a fresh PID-bound one-use owner idle lease for helper recovery |
| `CODEX_WATCH` | `1` | Explicit desktop watcher opt-in |
| `CODEX_REOPEN_POLICY` | `crash_only` | Respect intentional normal exits |
| `CODEX_BUNDLE_ID` | `com.openai.codex` | Default profile; must match local Info.plist |
| `CODEX_APP_PATH` | `/Applications/ChatGPT.app` | Default installed bundle layout; opened by exact path |

This changes the prior idle-lease default and enables a new watcher, so it is an
explicit mapping, not preservation of every previous behavior. The existing
configured helper expectation and timing settings remain merged. The single
existing LaunchAgent label and 60-second interval remain visible to the owner.
No extra daemon, hidden persistence or platform service is created.

For a modern Codex bundle, prepare a different new destination with
`--desktop-app /Applications/Codex.app`. For the separate ChatGPT consumer app,
select `--desktop-bundle com.openai.chat` and its actual installed app path. Only
one desktop profile is watched per installation, using the existing `codex`
budget/status key. Info.plist must match the selected bundle and executable:
`ChatGPT` or `Codex` for Codex, and `ChatGPT` for ChatGPT. Incorrect, missing or
unsupported identities cannot authorize recovery. Alternate layouts are covered
by synthetic fixtures, not live installation/recovery proof.

## Exact future installation invocation

The following command is **for the confirmed maintenance window only**, after the
private backups and hold/unload ordering in
[INSTALLATION-POLICY.md](INSTALLATION-POLICY.md). Do not execute it during review.

```sh
python3 prepare-install.py .latch-local/maintenance-candidate --check
INSTALL_MAINTENANCE_CONFIRMED=1 \
INSTALL_PREVIOUSLY_UNLOADED=1 \
INSTALL_POLICY_FILE="$PWD/.latch-local/maintenance-candidate/recovery-policy.json" \
  bash ./install.sh
```

Stop if the precheck fails. Reprepare and review after any source, installed
configuration or candidate change. The installer reads the owned 0600 policy
file, validates the complete allowlisted schema and applies it after the existing
plist merge. A malformed prior plist fails instead of silently dropping policy.
Candidate lint and policy validation finish before executable replacement.

Before this invocation, checkpoint and park all affected work, verify the watchdog
is between ticks, create the maintenance hold under the window authorization, and
make the private byte-for-byte snapshot described in the rollback runbook. The
installer requires an existing hold and rejects a present watchdog lock. It must
successfully unload an existing job, then verify it is not loaded, before changing
executables. If the approved rollback runbook already unloaded it for the snapshot,
`INSTALL_PREVIOUSLY_UNLOADED=1` skips the duplicate unload only after verifying
readable launchd domain access; the exact job must still be absent. A denied
domain lookup or still-loaded job stops before executable replacement. Installation failure leaves the hold set for review; do not retry
blindly. It does not restore files automatically after a partial filesystem or
bootstrap failure: use the preserved private backup and budget-preserving rollback.

The installer never runs `launchctl enable`, removes hold/disable/pause controls,
or takes an extra watchdog tick. A user-disabled job is not silently enabled.
The initial loaded observation runs under the hold. Releasing that hold and any
helper idle lease require the agreed owner maintenance authorization and verified
protected work. Other pre-existing controls must remain in their original state.
Installing this kit does not authorize a fault injection or app restart proof.

## Recovery and stop behavior

- Grok's recorded `quitRequestedAtMs` wins over heartbeat, boot, helper and local
  request triggers. Beacon polling is skipped while intentional quit is observed.
  A normal manual app launch resumes observation with new app state.
- An absent Grok process needs a primary crash report for the exact dead PID,
  bundle and process name after its last valid heartbeat. Missing report, missing
  heartbeat, intentional quit, shutdown or ambiguous absence stays observe-only.
  Abrupt SIGKILL without a report is not automatically treated as a crash.
- Codex/ChatGPT never gets quit or killed by its watcher. Production rejects the
  historical `any_exit` setting. A matching primary crash after a prior observed
  launch is required. A fresh identity/process decision can cancel an already
  budgeted reopen; the actual open uses the configured app path.
- Disable, global hold and desktop pause controls are rechecked at app-action
  boundaries and during waits. Any filesystem entry, including dangling symlinks,
  blocks. A stop arriving after authorization retains the spent budget. A control
  cannot retract an OS command already issued; there remains a small check/action
  race. Keep the hold set before a planned quit or maintenance operation.
- Existing per-key three-per-hour cap, 300-second exponential backoff, continuity,
  helper floor suppression and no-force-kill rule remain. Invalid clock or ledger
  state fails closed. A hold now skips beacon polling so queued work is preserved.
- Crash scanning reads at most 128 report files of up to 4 MiB each. More reports,
  denied access, malformed data or unsafe file types produce no crash proof.
  It emits no report contents. No private desktop database is a default readiness
  source; process presence is not authentication or cloud recovery proof.

No code changes execution permissions, sign-in, security settings, app internals,
models, platform services, network settings, sleep policy or OS shutdown behavior.
A live silent disconnect has no supported local Codex/ChatGPT signal here. Grok
helper loss is still only a proxy. Weak freeze/socket hints remain observe-only.
Authoritative wake detection, all-lanes-idle verification and genuine remote
reconnection/execution proof remain open.

## Context coverage and interface map

Prior engineering history and bounded historical review receipts informed this
work. They cover earlier review findings and the later code-clearance receipt;
no new external reviewer clearance is claimed. Full retained review-bot history
and cross-bot exchanges remain unavailable through an authenticated supported
reader. Native UI reading exposed no transcript navigation and no screenshot in
this environment. Fixture transcript archives are not live evidence. The private
coverage ledger records dates, sources and these gaps. No outbound bot message,
credential extraction or hidden IPC was used.

Independently inspected interfaces:

| Interface | Boundary |
|---|---|
| Existing LaunchAgent → shell | One periodic tick, single-flight lock; visible owner controls |
| Local status/session/helper inputs → shell | Health evidence only; unknown data fails closed |
| Shell → restart guard | Mode/continuity, hold, per-app budget and optional PID-bound lease |
| Shell → desktop watcher | Verified process path, primary crash identity/time; returns a decision |
| Shell → apps | Gentle Grok quit/open; Codex/ChatGPT open only; no forced kill |
| Shell → optional beacon | Outbound HTTPS poll, existing private poller-token file; no new access |
| Beacon request helper → Worker | Existing separate writer token and bounded heal-only inbox |
| Shell → local status/snapshots | Allowlisted health evidence; not public raw telemetry |

Historical receipts are bounded evidence, not the complete design conversation.
The current source/PR and interface map can be reviewed independently while full
history remains blocked. Current-tree privacy review does not erase earlier
commits or prior PR revisions; no history rewrite is authorized or performed.
