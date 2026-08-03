#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

confirm() {
  [ "${ISLAND_ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || return 1
  local ans
  printf '%s [y/N] ' "$1"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

echo "Island を取り外します。"
echo

python3 "$root/lib/view.py" clear >/dev/null 2>&1
echo "絞り込みを解除しました。"

if confirm "agent CLI 側の hook を外しますか？"; then
  bash "$root/lib/hooks.sh" uninstall
  case $? in
    0)  echo "外しました。" ;;
    10) echo "配線がありません。" ;;
    *)  echo "外せませんでした。" ;;
  esac
fi

if confirm "config.toml から reason の行を除去しますか？"; then
  island_edit_config remove
  case $? in
    0)  echo "除去しました。" ;;
    10) echo "除去対象がありません（手で編集された行は残します）。" ;;
    *)  echo "除去できませんでした。" ;;
  esac
fi
