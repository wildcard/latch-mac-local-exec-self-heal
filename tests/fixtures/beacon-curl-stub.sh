#!/bin/bash
# Stand-in for curl in beacon tests. Records that it ran and its argv; never touches the network.
# BEACON_STUB_RESPONSE = body to print; BEACON_STUB_FAIL=1 = exit non-zero like a dead Worker.
cat >/dev/null
printf '%s\n' "$*" >> "${BEACON_STUB_CALLS:?}"
[[ "${BEACON_STUB_FAIL:-0}" == "1" ]] && exit 7
printf '%s' "${BEACON_STUB_RESPONSE-"{\"heal\":false}"}"
