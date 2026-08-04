#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

M="$here/../herdr-plugin.toml"

assert_eq "yes" "$([ -f "$M" ] && echo yes || echo no)" "the manifest exists"

# Safety net so a failure or early exit never leaves a plugin link behind
cleanup() { herdr plugin unlink island >/dev/null 2>&1; }
trap cleanup EXIT

# Let herdr itself validate it — being linkable is the only real verdict.
# Without herdr this would merely surface as an assert_contains failure (the
# expected string is missing), which says nothing about the cause, so single
# that case out and name it explicitly.
if ! command -v herdr >/dev/null 2>&1; then
  printf 'FAIL herdr is not on PATH, so the manifest cannot be validated\n' >&2
  _fail=1
else
  out="$(herdr plugin link "$here/.." 2>&1)"
  assert_contains "$out" '"plugin_id":"island"' "the id is island"
fi
# unlink is left to the EXIT trap, so it runs even on an early exit

# Nothing in the repository may *write* to rows_by_agent (a global constraint).
# Detecting it and warning about it is a requirement in its own right, so
# banning the mere mention of the string (the grep that detects it, the warning
# text) would contradict that requirement. What is banned is the TOML
# assignment form (`rows_by_agent = ...`); with none of those, we do not write it.
# wc -l is space-padded on BSD/macOS, so normalise it to a bare number.
hits="$(grep -rlE 'rows_by_agent[[:space:]]*=' "$here/../bin" "$here/../lib" 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "0" "$hits" "bin/ and lib/ never write rows_by_agent (no assignment form)"

finish
