# Owner installation policy and rollback

> Historical decision packet. The current preparation and stricter installation
> interface are documented in [MAINTENANCE-CANDIDATE.md](MAINTENANCE-CANDIDATE.md).
> The rollback and budget-preservation requirements below remain applicable.

This is a decision packet and future maintenance runbook, not permission to install
or activate anything. No commands that install, reload, restart, change policy or
write the installed ledger were run for this documentation update. Default behavior
remains observe-only. Installation and any later activation require separate owner
approval, protected work and an agreed maintenance window.

## Installed policy established read-only

The loaded job's allowlisted environment and installed script/guard defaults were
checked directly; no machine identifier, process ID, credential or attempt timestamp
is needed here. At that inspection:

| Policy | Established value |
|---|---|
| Helper healing | Enabled by installed job environment |
| Helper missing threshold | Environment unset; installed script default 300 seconds |
| Helper idle lease | Environment/global value unset; installed guard defaults to off |
| Expected helpers | Explicitly configured as 2 |
| Cursor keep-alive | Off |
| Frozen-heartbeat recovery | Enabled in the installed older policy; threshold 120 seconds |
| Heartbeat stale threshold / cooldown | 180 / 300 seconds |
| Codex watcher | Not installed |
| Global hold / disable | Neither present at inspection |
| Attempt ledger | Absent at inspection; no ledger content was read or changed |

These are configuration observations, not recovery proof or evidence that work is
idle. Recheck before a maintenance decision; the current installation may change.
Ledger absence is not proof that no historical attempt ever occurred.

## Three distinct owner choices

### A. Install Stage 0 observation

A default invocation of `install.sh` writes `RECOVERY_MODE=observe` and
`HEAL_ON_HELPER_MISSING=0`, even if the prior plist enabled healing. **It disables
all automatic app healing**, including the previously enabled Grok policy. Requests
remain unconsumed, and no new attempt is spent. Other existing operator settings
and beacon configuration are preserved, except the documented kit-owned values.
This is the default, not a preservation of the previous active policy.

### B. Explicitly retain the existing Grok recovery intent in the new draft

There is no automatic `preserve-existing-policy` installer flag. The owner can
instead approve a reviewed, explicit policy mapping. For the configuration above,
these installer options select active recovery and helper healing:

```sh
INSTALL_RECOVERY_MODE=active INSTALL_HELPER_HEAL=1 bash ./install.sh
```

**This is an explanation of effects, not a recommendation or instruction to run it.**
Code verification confirms both values are written to the plist. With
`HELPER_IDLE_REQUIRED` absent, the new guard defaults it to off, matching the
installed helper authorization policy. With `HELPER_MISSING_SEC` absent, both
installed and draft scripts default to 300 seconds. Existing explicit timing and
helper-count settings are otherwise retained by the merge.

That command alone is not full policy preservation. Before an approved load, a
reviewed candidate plist must also explicitly set `CODEX_WATCH=0` to preserve the
absence of Codex automatic recovery. Pin `HELPER_MISSING_SEC=300` if the owner wants
the observed threshold made explicit. Retain the prior idle choice, or separately
approve a changed choice; an idle lease cannot establish all-lanes idleness.

The installer preserves these custom keys **from an existing plist**. Merely
exporting `CODEX_WATCH`, `HELPER_MISSING_SEC` or `HELPER_IDLE_REQUIRED` in the invoking
shell does not set them in the installed plist. Under a separately approved
maintenance hold, with the watchdog unloaded and the original policy backed up,
put the reviewed keys into the existing plist on disk **before** invoking the
installer. Its merge then carries them into the generated configuration before
bootstrap. Keep the hold set and verify the resulting plist before any approved
release of recovery. Editing after bootstrap is too late to protect an initial
tick. Do not mistake shell exports for persisted policy, and do not set
`INSTALL_RESET_ENV=1` for preservation. None of these preparation writes was run here.

Even with that mapping, behavior is deliberately stricter: continuity gates are
new, frozen-heartbeat hints no longer authorize recovery, forced killing is gone,
and budgets are keyed by app. These changes require explicit acceptance. If exact
old behavior is required, choose C; the draft has no exact-legacy-behavior mode.

### C. Preserve the current installation exactly

Do not install or activate this draft. Keep the current files, plist and budget
unchanged while review/proof remains open. This is the only choice that preserves
all current behavior, including behavior intentionally removed from the draft.

None of these choices establishes idleness. Before any active maintenance operation,
checkpoint and park all affected work and verify with its owners. No authoritative
all-lanes-idle signal exists. Genuine Prove D and authoritative wake handling remain open.

## Read-only installed-ledger precheck

Run this only as a read-only check. It reports categories and booleans, never attempt
values, paths, account identifiers or telemetry. It does not create, chmod, repair,
prune, convert or invoke the guard against the installed ledger. An absent file is
reported explicitly; do not fabricate one merely to make a precheck pass.

```python
# ledger-precheck
import json, math, os, re, stat, sys, time
from pathlib import Path

path = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path.home() / "Library/Application Support/Latch/grok-bot-restart-attempts.json")
result = {"present": False}
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except FileNotFoundError:
    print(json.dumps(result))
    raise SystemExit(0)
except OSError:
    print(json.dumps({"readable_regular_owned_0600": False}))
    raise SystemExit(1)
with os.fdopen(fd) as handle:
    st = os.fstat(handle.fileno())
    safe = stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) == 0o600
    result.update(present=True, readable_regular_owned_0600=safe)
    if not safe or st.st_size > 8192:
        print(json.dumps(result))
        raise SystemExit(1)
    try:
        data = json.loads(handle.read(8193))
        attempts = data.get("attempts") if isinstance(data, dict) else None
        legacy = isinstance(attempts, list)
        keyed = isinstance(attempts, dict) and all(
            isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,32}", key)
            and isinstance(values, list) for key, values in attempts.items())
        lists = [attempts] if legacy else list(attempts.values()) if keyed else None
        now = time.time()
        valid = lists is not None and all(
            type(value) in (int, float) and math.isfinite(value) and 0 <= value <= now
            for values in lists for value in values)
    except (ValueError, TypeError, OverflowError):
        legacy = keyed = valid = False
    result.update(attempts_shape="legacy_array" if legacy else "keyed_arrays" if keyed else "invalid",
                  timestamps_valid=valid, compatible_with_older_list_guard=legacy and valid)
print(json.dumps(result))
raise SystemExit(0 if valid else 1)
```

Use `python3 <saved-precheck.py>` for the generic installed location, or pass a
specific fixture path when validating the check. An owned 0600 legacy
`{"attempts":[timestamps]}` file is accepted by both guards. The draft upgrades it
only on an allowed attempt. A blocked attempt leaves it unchanged. Keyed arrays are
valid for the draft but not for the older installed list-only guard. Other private
modes may be readable by a guard; this precheck deliberately requires exactly 0600.
Malformed, future, unsafe-owner or unsafe-mode state is a stop condition, not a
reason to delete the file or reset the budget.

## Concrete rollback: restore policy, retain the latest budget

The following is a future, separately approved maintenance procedure. Do not run a
rollback or launchctl operation during review. Stopping/reloading the watchdog does
not authorize restarting applications.

1. **Before any approved installation**, record the owner policy choice. Park and
   checkpoint all affected work; verify the watchdog is between ticks. Record
   whether hold, disable and pause controls already exist, then establish a
   maintenance hold under the approval. Stop/unload the watchdog job before taking
   a consistent snapshot. Keep apps/work parked throughout.
2. Create a private owner-only backup directory (mode 0700) outside Git. Preserve bytes,
   ownership/modes and private checksums for the complete installed `bin` directory,
   the LaunchAgent plist and current status. Copy a present ledger with its 0600
   mode intact; otherwise record an **absence marker**. Never copy token contents
   into source, public evidence or this runbook. Retain existing configuration
   references without printing their values. Keep this pre-install snapshot intact.
3. **If rollback is approved**, keep the hold set and the job unloaded. First capture
   another private snapshot of the current plist, status, full bin and latest
   ledger. That latest snapshot protects all post-install attempts and keyed app
   budgets. Do not run the old installer: it can rewrite policy, enable/load the
   job or take an extra tick.
4. Restore the pre-install `bin` directory and original plist **byte for byte** from
   the private snapshot; restore their ownership/modes and check their saved
   checksums. Preserve the added hold while doing so. This restores the prior
   policy, rather than silently applying the draft's observe-only installation
   default. Do not restore a stale status over a newer valid compatible status:
   retain conservative cooldown and helper-suppression state. If compatibility is
   uncertain, leave the job held and stopped for review.
5. **Do not restore the old ledger blindly.** Start from the frozen latest ledger.
   The older guard requires `{"attempts":[...]}`. For a keyed draft ledger, project
   the `grok` array into that legacy shape. Merge any pre-install Grok attempts
   conservatively: for a timestamp present in both snapshots retain the greater
   multiplicity, rather than counting the same recorded attempt twice or dropping
   duplicates that represent attempts. Retain all valid timestamps without pruning
   during rollback. Preserve the complete keyed ledger, including any Codex array,
   in the private rollback snapshot; the old kit has no Codex recovery budget.
   Before a later re-upgrade enables Codex recovery, merge that retained keyed
   history back conservatively if any attempts may still be in-window. An older
   list without a Codex key does not prove the Codex budget was empty.
6. Validate every merged value as finite, non-negative, non-boolean and not future
   dated, and require the correct current owner. Stage the legacy object in an
   owner-only 0600 file on the same filesystem, then atomically replace the installed
   ledger under the maintenance hold. Validate using the read-only precheck. No
   new attempt is added by conversion. A pre-install absence marker does **not**
   permit deleting attempts recorded after installation. If no ledger exists in
   either snapshot, preserve absence; do not invent attempt history. On malformed
   data, future timestamps, uncertain merging or inability to preserve budget,
   **stop with the hold set and the job unloaded**; do not discard/reset evidence.
7. Validate the restored plist without loading it. Compare only allowlisted policy
   keys with the private pre-install policy record; verify the original script and
   guard checksums, ledger precheck and preserved control-file states. Record the
   result privately without publishing telemetry. These checks do not invoke heal.
8. Only after the owner explicitly approves resuming the restored policy may the
   existing LaunchAgent be reloaded. Leave the hold in place for read-only status
   verification. Removing a hold or releasing active recovery needs the agreed
   maintenance authorization and owner verification of protected work. Restore
   pre-existing hold/disable/pause controls exactly; never remove an original hold
   merely because rollback completed. Any app recovery/live proof remains separate.

This procedure preserves policy and attempts, rather than treating rollback as a
fresh budget. It does not claim a completed rollback, a live recovery proof, or an
automatic way to establish idleness. No rollback command was executed here.

## Privacy and publication scope

The current tree and PR prose are minimized; configuration values above are included
only to explain the owner's policy decision. Earlier commits retain metadata removed
from current prose, and prior PR revisions/caches may also retain it. No history
rewrite or visibility change was made. Current sanitization is not complete erasure
or a repository-wide privacy clearance. Keep private snapshots and rollback receipts
out of Git and out of public PR evidence.
