#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/_config.sh"

island_edit_config remove
rc=$?
case $rc in
  0)  echo "reason の行を除去しました。" ;;
  10) echo "除去対象がありません（手で編集された行は残します）。" ;;
esac
exit $rc
