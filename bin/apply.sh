#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/_config.sh"

island_edit_config add
rc=$?
case $rc in
  0)  echo "reason の行を追加しました。" ;;
  10) echo "既に追加済みです。変更はありません。" ;;
esac
exit $rc
