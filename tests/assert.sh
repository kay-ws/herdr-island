#!/bin/bash

set -uo pipefail

_fail=0

assert_eq() {
  local exp="$1" act="$2" msg="${3:-eq}"
  if [[ "$exp" != "$act" ]]; then
    printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$msg" "$exp" "$act" >&2
    _fail=1
  else
    printf 'ok   %s\n' "$msg"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" msg="${3:-contains}"
  if [[ "$hay" != *"$needle"* ]]; then
    printf 'FAIL %s\n  %q not found in %q\n' "$msg" "$needle" "$hay" >&2
    _fail=1
  else
    printf 'ok   %s\n' "$msg"
  fi
}

assert_exit_nonzero() {
  local cmd="$1" msg="${2:-nonzero}"
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL %s  (expected non-zero exit)\n' "$msg" >&2
    _fail=1
  else
    printf 'ok   %s\n' "$msg"
  fi
}

finish() {
  if [[ $_fail -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
}
