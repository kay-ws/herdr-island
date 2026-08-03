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

echo "Removing Island."
echo

python3 "$root/lib/view.py" clear >/dev/null 2>&1
echo "Filtering has been cleared."

if confirm "Remove the hook from the agent CLI?"; then
  bash "$root/lib/hooks.sh" uninstall
  case $? in
    0)  echo "Removed." ;;
    10) echo "Nothing was wired." ;;
    *)  echo "Could not remove it." ;;
  esac
fi

if confirm "Remove the reason line from config.toml?"; then
  island_edit_config remove
  case $? in
    0)  echo "Removed." ;;
    10) echo "Nothing to remove (hand-edited lines are left as-is)." ;;
    *)  echo "Could not remove it." ;;
  esac
fi
