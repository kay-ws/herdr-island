#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/fake_socket.sh"

WORK="$(mktemp -d -p /tmp)"
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

start_fake_socket || { echo "setup failed" >&2; exit 1; }
trap 'stop_fake_socket; rm -rf "$WORK"' EXIT

V="$here/../lib/view.py"

# --- set ---
reset_capture
python3 "$V" set
assert_eq "0" "$?" "set returns 0"
assert_eq "agent.view.set"  "$(sent '.method')"        "the method is agent.view.set"
assert_eq "plugin:island"   "$(sent '.params.source')" "the source is plugin:island"
assert_eq "exists"          "$(sent '.params.filter.op')"           "the filter is exists"
assert_eq "reason"          "$(sent '.params.filter.field.token')"  "it filters on the presence of the reason token"
assert_eq "attention"       "$(sent '.params.sort[0].field')"       "attention sorts first"
assert_eq "desc"            "$(sent '.params.sort[0].order')"       "attention is descending"
assert_eq "state_change_seq" "$(sent '.params.sort[1].field')"      "then the most recent state transition"
assert_eq "desc"            "$(sent '.params.sort[1].order')"       "state_change_seq is descending too"
assert_eq "yes" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "it saves to state"

# --- startup re-applies ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "agent.view.set" "$(sent '.method')" "startup re-applies the saved view"
# Checking only the method would also pass for a restore that dropped the params
assert_eq "plugin:island" "$(sent '.params.source')"       "restore forwards source too"
assert_eq "exists"        "$(sent '.params.filter.op')"    "restore forwards filter too"
assert_eq "reason"        "$(sent '.params.filter.field.token')" "restore forwards the filter token too"
assert_eq "2"             "$(sent '.params.sort | length')" "restore forwards both sort entries"

# --- clear ---
reset_capture
python3 "$V" clear
assert_eq "0" "$?" "clear returns 0"
assert_eq "agent.view.clear" "$(sent '.method')"        "the method is agent.view.clear"
assert_eq "plugin:island"    "$(sent '.params.source')" "naming a source avoids stealing anyone else's view"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "clear deletes the state"

# --- with no state, startup does nothing ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "with nothing saved, startup sends nothing"

# --- an unreachable socket must not write state ---
# A test that only looks at the exit code was powerless against this
# inconsistency. Writing state without having sent makes startup go and restore
# a "view that was never applied" on every single start.
rm -f "$HERDR_PLUGIN_STATE_DIR/view.json"
reset_capture
HERDR_SOCKET_PATH=/nonexistent/sock python3 "$V" set >/dev/null 2>&1
assert_eq "1" "$?" "it returns 1 when the socket will not connect"
assert_eq "yes" "$(nothing_sent)" "nothing was sent to an unreachable socket"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "no state is written when the send failed"

# --- startup exits 0 even with no socket (it runs on every server start) ---
HERDR_SOCKET_PATH=/nonexistent/sock bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "0" "$?" "startup exits 0 even with no socket"

finish
