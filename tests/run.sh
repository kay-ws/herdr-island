#!/bin/bash

set -uo pipefail

# nullglob が無いと、テストが 0 件のとき glob がリテラル "test_*.sh" のまま
# bash に渡り「No such file or directory」で誤爆する
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
