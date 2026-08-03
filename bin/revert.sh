#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/_config.sh"

island_edit_config remove
rc=$?
case $rc in
  0)  echo "Removed the reason line." ;;
  10) echo "Nothing to remove (hand-edited lines are left as-is)." ;;
esac
exit $rc
