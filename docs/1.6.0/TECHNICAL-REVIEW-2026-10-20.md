# Pre-install technical review

This is the implementing agent's technical review, not independent reviewer
clearance. It precedes installation and does not replace the owner-requested
post-test review before merge. No runtime action occurred.

## Finding corrected

**Maintenance runbook/installer handoff conflict.** The rollback runbook unloads
the watchdog before taking a consistent backup, while the installer unconditionally
attempted another unload when the old plist remained. That second unload can fail
for an already-absent job and prevent the approved installation.

The explicit `INSTALL_PREVIOUSLY_UNLOADED=1` handoff now verifies readable user
launchd domain access, then requires the exact job to remain absent. It preserves
maintenance confirmation, hold and no-active-lock gates. Domain denial or a
still-loaded job stops before executable replacement. The default path still
requires a successful unload of an existing job. No `launchctl enable` is used.

A hermetic regression covers the three meaningful outcomes: accessible domain
with absent job succeeds; inaccessible domain fails; still-loaded job fails.
It checks no duplicate bootout, no enable, no bootstrap on refusal and no executable
replacement on refusal. All commands target temporary HOME and fake launchctl.

## Reviewed boundaries and residual risks

The review followed candidate rendering/hash binding, installer migration and
write ordering, stop-control precedence, crash/identity checks, attempt accounting,
app-opening scope, optional beacon boundaries and private/public evidence handling.

- Candidate signature and source-commit signature are private preflight checks;
  the installer does not independently authenticate a signed plan. The execution
  procedure must stop on failed signature/hash checks and bind the exact reviewed
  source/policy. Filesystem-copy/bootstrap failure requires held manual rollback.
- Stop controls are checked at action boundaries; they cannot retract an OS
  command already issued. No atomic stop guarantee is claimed.
- A helper lease covers helper recovery only and does not prove all-lanes idle.
  Parent/owner checkpointing remains necessary before any app disruption.
- Crash-only matching is distinct from actual usable-client recovery. The bounded
  proof must establish one budgeted reopen and a successful fresh user interaction.
- Process/heartbeat/helper observations do not prove cloud connectivity. Wake,
  silent transport disconnect and genuine remote reconnection proof remain open.
- Full retained prior-bot and cross-bot transcript coverage remains incomplete;
  older summaries and bounded historical receipts are the available context.

No further code blocker was found in this scoped pre-install pass. Runtime/test
and post-test review gates are still open; do not merge based on this pass alone.
