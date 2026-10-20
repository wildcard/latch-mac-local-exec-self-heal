#!/usr/bin/env bash
# Legacy intentional-quit prove is incompatible with current crash-only recovery.
# A deliberate quit must stay down; LIVE=1 must not silently revive old semantics.
# No live app command is executed by this entry point.
set -euo pipefail
echo "Legacy quit/reopen prove is retired: intentional quits now remain stopped." >&2
echo "Use the separately approved maintenance crash-proof plan; fixture tests are tests/run-tests.sh." >&2
exit 2
