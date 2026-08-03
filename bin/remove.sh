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

if python3 "$root/lib/view.py" clear; then
  echo "Filtering has been cleared."
else
  echo "Could not clear the filter. The saved filter state is still present and may be re-applied the next time herdr starts." >&2
fi

if confirm "Remove the hook from the agent CLI?"; then
  bash "$root/lib/hooks.sh" uninstall
  case $? in
    0)  echo "Removed." ;;
    10) echo "Nothing was wired." ;;
    12) echo "Removal was only partially applied. See the message above for which file changed and which did not." ;;
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
