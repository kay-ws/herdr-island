#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

E="$here/../bin/on-status-changed.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

fire() {
  : > "$FAKE_HERDR_LOG"
  HERDR_PLUGIN_EVENT_JSON="$1" bash "$E" >/dev/null 2>&1
}
logged() { cat "$FAKE_HERDR_LOG"; }
nothing_sent() { [ -s "$FAKE_HERDR_LOG" ] && echo no || echo yes; }

# --- leaving blocked clears it ---
fire '{"pane_id":"w0:p1","workspace_id":"w0","agent_status":"working"}'
assert_contains "$(logged)" "--clear-token reason" "a transition to anything but blocked clears reason"
assert_contains "$(logged)" "--source island"      "the source is island"
assert_eq "w0:p1" "$(logged | awk '{print $3}')"   "PANE_ID comes before the flags"

# --- staying blocked does not clear ---
fire '{"pane_id":"w0:p1","workspace_id":"w0","agent_status":"blocked"}'
assert_eq "yes" "$(nothing_sent)" "nothing is cleared while blocked"

# --- malformed payloads ---
fire 'not json'
assert_eq "yes" "$(nothing_sent)" "broken JSON does nothing"

fire '{"workspace_id":"w0","agent_status":"working"}'
assert_eq "yes" "$(nothing_sent)" "no pane_id means do nothing"

# --- an empty or missing agent_status must not clear ---
# Over-clearing here erases a reason the user has not looked at yet.
# Removing the guard has been confirmed to break these (mutation test in review).
fire '{"pane_id":"w0:p1","workspace_id":"w0","agent_status":""}'
assert_eq "yes" "$(nothing_sent)" "an empty agent_status does not clear"

fire '{"pane_id":"w0:p1","workspace_id":"w0"}'
assert_eq "yes" "$(nothing_sent)" "a missing agent_status key does not clear"

# --- an unset HERDR_PLUGIN_EVENT_JSON must not break anything ---
: > "$FAKE_HERDR_LOG"
env -u HERDR_PLUGIN_EVENT_JSON bash "$E" >/dev/null 2>&1
assert_eq "0" "$?" "exit 0 even with the env var unset"
assert_eq "yes" "$(nothing_sent)" "an unset env var does nothing"

# --- exit codes ---
HERDR_PLUGIN_EVENT_JSON='not json' bash "$E" >/dev/null 2>&1
assert_eq "0" "$?" "exit 0 even on broken JSON"

finish
