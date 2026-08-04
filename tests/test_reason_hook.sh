#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

HOOK="$here/../hooks/island-reason.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# Fake herdr — records argv as a single line
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

run_hook() {
  : > "$FAKE_HERDR_LOG"
  printf '%s' "$1" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
}
logged() { cat "$FAKE_HERDR_LOG"; }
nothing_sent() { [ -s "$FAKE_HERDR_LOG" ] && echo no || echo yes; }

# --- what gets sent ---
run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_contains "$(logged)" "pane report-metadata" "it calls report-metadata"
assert_contains "$(logged)" "--source island"      "the source is island"
assert_contains "$(logged)" "reason=Bash: ls -la"  "the body rides along in reason"
assert_contains "$(logged)" "--ttl-ms 900000"      "the TTL is 15 minutes"

# --- argument-order regression: PANE_ID must come before the flags ---
# Put it after and herdr dies with "unknown option" (measured on 0.7.5)
first_arg="$(logged | awk '{print $3}')"
assert_eq "w0:p1" "$first_arg" "PANE_ID sits right after report-metadata, before any flag"

# --- guards: each of these must bail without calling anything ---
: > "$FAKE_HERDR_LOG"
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "nothing happens unless HERDR_ENV is 1"

: > "$FAKE_HERDR_LOG"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "nothing happens when HERDR_PANE_ID is empty"

run_hook 'this is not json'
assert_eq "yes" "$(nothing_sent)" "broken JSON does nothing"

run_hook '{"tool_name":"Bash","tool_input":"oops"}'
assert_eq "yes" "$(nothing_sent)" "a wrongly-typed tool_input does nothing"

# --- clear mode ---
# The path called from PostToolUse, pairing the set and clear triggers
: > "$FAKE_HERDR_LOG"
HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" clear >/dev/null 2>&1
assert_contains "$(logged)" "--clear-token reason" "the clear argument clears reason"
assert_contains "$(logged)" "--source island"      "clear uses the island source too"
assert_eq "w0:p1" "$(logged | awk '{print $3}')"   "clear also puts PANE_ID before the flags"
assert_eq "no" "$(grep -q 'ttl-ms' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "clear carries no TTL"

# clear does not read stdin (a PostToolUse payload is not reason material)
: > "$FAKE_HERDR_LOG"
printf 'this is not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" clear >/dev/null 2>&1
assert_contains "$(logged)" "--clear-token reason" "clear still works with broken stdin"

# An unknown mode does nothing
: > "$FAKE_HERDR_LOG"
HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" bogus >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "an unknown mode does nothing"

HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" clear >/dev/null 2>&1
assert_eq "0" "$?" "clear exits 0 as well"

# --- it must not depend on python3 ---
# What is banned is *launching* python3, not the word "python3" appearing. A
# bare grep fails on the comment explaining why python3 is not called — which
# actually happened. So judge with comment lines excluded.
assert_eq "no" \
  "$(grep -v '^[[:space:]]*#' "$HOOK" | grep -q 'python3' && echo yes || echo no)" \
  "the hook never launches python3 (mentioning it in a comment is fine)"

# --- exit codes ---
printf 'not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "exit 0 even on broken JSON"

printf '{}' | HERDR_ENV=0 bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "exit 0 when bailing out at a guard, too"

BASH_ABS="$(command -v bash)"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -u PATH HERDR_ENV=1 HERDR_PANE_ID=w0:p1 "$BASH_ABS" "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "exit 0 even when jq / herdr cannot be found"

finish
