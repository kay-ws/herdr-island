#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/_config.sh"

island_edit_config add
rc=$?
case $rc in
  0)  echo "Added the reason line." ;;
  10) echo "Already added. No changes made." ;;
esac
exit $rc
