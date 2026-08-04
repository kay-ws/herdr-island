#!/bin/bash

set -uo pipefail

# Without nullglob, zero matching tests leaves the glob as the literal
# "test_*.sh", which is handed to bash and misfires as "No such file or directory"
shopt -s nullglob

here="$(cd "$(dirname "$0")" && pwd)"
fail=0

for t in "$here"/test_*.sh; do
  echo "--- $(basename "$t") ---"
  if bash "$t"; then
    :
  else
    fail=1
  fi
  echo
done

if [[ $fail -eq 0 ]]; then
  echo "=== ALL TESTS PASSED ==="
  exit 0
else
  echo "=== FAILURES DETECTED ==="
  exit 1
fi
