#!/bin/bash
# I7: if send() returns True without reading herdr's reply, then even when herdr
# rejects the request (a misspelled parameter, a missing required field, …)
# focus reports "success", writes view.json, and [[startup]] goes on resending
# the rejected request forever. This is caught with fake_socket_error.sh, which
# always returns an error reply — separate from fake_socket.sh, which must not
# change and always replies with success.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/fake_socket.sh"        # reuse sent / nothing_sent / reset_capture
source "$here/fake_socket_error.sh"  # start/stop_fake_error_socket

WORK="$(mktemp -d -p /tmp)"
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

start_fake_error_socket || { echo "setup failed" >&2; exit 1; }
trap 'stop_fake_error_socket; rm -rf "$WORK"' EXIT

V="$here/../lib/view.py"

# --- set: an error from herdr must be treated as a failure ---
reset_capture
err_out="$(python3 "$V" set 2>&1)"
rc=$?
assert_eq "1" "$rc" "set returns 1 when herdr replies with an error"
assert_contains "$err_out" "missing field" "the error message reaches stderr (the rejection is diagnosable)"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "an error reply writes no view.json (no resending a rejected request forever)"

# --- startup: exit 0 must hold even with a state file present ---
# startup.sh runs on every server start, so it has to exit 0 regardless of what
# the send returned. Prepare the state up front so restore actually sends —
# without it restore would not even attempt a send, and this would test nothing.
cat > "$HERDR_PLUGIN_STATE_DIR/view.json" <<'EOF'
{"source":"plugin:island","label":"waiting"}
EOF
reset_capture
bash "$here/../bin/startup.sh" >/tmp/island-startup-err.$$ 2>&1
rc2=$?
assert_eq "0" "$rc2" "startup.sh still exits 0 when herdr replies with an error"
assert_eq "yes" "$([ -s "$CAPTURE" ] && echo yes || echo no)" \
  "startup really did attempt a send (state is present, so restore runs)"
rm -f /tmp/island-startup-err.$$

finish
