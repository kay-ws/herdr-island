#!/bin/bash
# Interactive setup. Meant to be launched from a popup pane — actions have no TTY.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

cfg="$(island_config_path)"

# confirm <question> : always yes when ISLAND_ASSUME_YES=1.
# With no TTY it returns no rather than defaulting to yes — never edit
# someone's config without being asked to.
confirm() {
  [ "${ISLAND_ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || return 1
  local ans
  printf '%s [y/N] ' "$1"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

echo "Island — find agents that are waiting"
echo

# 1. Traces of the old herdr-jump
#
# Create the temp file with mktemp. A name like /tmp/island-legacy.$$ is
# predictable from the PID, and someone who plants a symlink there first can
# make us clobber an arbitrary file. Leave the cleanup to a trap as well — a
# plain rm is never reached on SIGINT (Ctrl-C at the prompt), which is a real
# possibility on this interactive path.
legacy_out="$(mktemp)" || exit 1
trap 'rm -f "$legacy_out"' EXIT
if bash "$root/lib/legacy.sh" detect > "$legacy_out" 2>/dev/null; then
  echo "Found traces of the old herdr-jump:"
  sed 's/^/  /' "$legacy_out"
  echo
  if confirm "Remove them?"; then
    bash "$root/lib/legacy.sh" purge && echo "Removed."
  fi
  echo
fi

# 2. The shadow cast by rows_by_agent — a complete override that stops the
#    added row from taking effect
if [ -f "$cfg" ] && grep -q 'rows_by_agent' "$cfg" 2>/dev/null; then
  echo "Warning: config.toml contains rows_by_agent."
  echo "  rows_by_agent is a complete override in herdr. For any agent it lists,"
  echo "  ui.sidebar.agents.rows is never consulted, so the row Island adds"
  echo "  will not appear there — with no error or warning from herdr."
  echo "  Recommend reviewing it by hand and removing it."
  echo
fi

# 3. Add the reason row
echo "Row to add:"
echo '  [{ token = "$reason", fg = "#f38ba8", bold = true }]'
echo
if confirm "Add it to config.toml?"; then
  island_edit_config add
  case $? in
    0)  echo "Added." ;;
    10) echo "Already added." ;;
    *)  echo "Could not add it. Configuration was not modified." ;;
  esac
else
  echo "config was not modified. The filtering feature alone works without configuration."
fi

# 4. Wire the hooks on the agent CLI side
echo
echo "To capture stop reasons, a hook must be wired into Claude Code / Codex."
echo "  Sets the reason: PermissionRequest (all tools), PreToolUse (AskUserQuestion only)"
echo "  Clears it:       PostToolUse (all tools)"
echo "  Only agents you already have are wired — Island never creates a config directory."
echo
if confirm "Wire the hook?"; then
  bash "$root/lib/hooks.sh" install
  case $? in
    0)  echo "Wired." ;;
    10) echo "Already wired." ;;
    12) echo "Wiring was only partially applied. See the message above for which file changed and which did not." ;;
    *)  echo "Could not wire it. Configuration was not modified." ;;
  esac
fi

echo
echo "Usage: plugin action 'focus' narrows the view to only waiting agents."
