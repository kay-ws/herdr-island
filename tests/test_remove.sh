#!/bin/bash
# I6: remove.sh used to discard the exit code of view.py clear and always print
# "cleared" (bin/unfocus.sh branches correctly in the same situation). This
# checks that when the socket is unreachable, remove.sh reports the failure and
# says the view.json — the record of what actually reached the server — is still
# there, rather than lying that it was deleted.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export HERDR_PLUGIN_ROOT="$here/.."
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"
echo '{"source":"plugin:island","label":"waiting"}' > "$HERDR_PLUGIN_STATE_DIR/view.json"

# Simulate an unreachable socket
export HERDR_SOCKET_PATH="/nonexistent/sock"
# Non-interactive. ISLAND_ASSUME_YES stays unset, so confirm always answers no
# (the hook/config removal steps are never entered; this focuses on clearing
# the filter).
export ISLAND_ASSUME_YES=0

out="$(bash "$here/../bin/remove.sh" </dev/null 2>&1)"

assert_contains "$out" "Could not clear the filter" "an unreachable socket makes remove.sh report the failure"
assert_contains "$out" "still present" "it says the saved filter is still there"
assert_eq "0" "$(printf '%s' "$out" | grep -cF 'Filtering has been cleared')" \
  "it never claims it cleared (it branches like unfocus.sh)"
assert_eq "yes" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "nothing was sent, so view.json really does remain (by design)"

finish
