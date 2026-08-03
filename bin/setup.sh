#!/bin/bash
# 対話つきの導入。popup pane から呼ばれる前提（action には TTY が無い）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

cfg="$(island_config_path)"

# confirm <質問> : ISLAND_ASSUME_YES=1 なら常に yes。
# TTY が無い場合も yes に倒さず no を返す（勝手に書き換えない）
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

# 1. 旧 herdr-jump の痕跡
if bash "$root/lib/legacy.sh" detect > /tmp/island-legacy.$$ 2>/dev/null; then
  echo "Found traces of the old herdr-jump:"
  sed 's/^/  /' /tmp/island-legacy.$$
  echo
  if confirm "Remove them?"; then
    bash "$root/lib/legacy.sh" purge && echo "Removed."
  fi
  echo
fi
rm -f /tmp/island-legacy.$$

# 2. rows_by_agent の影。complete override で新しい行が効かなくなる
if [ -f "$cfg" ] && grep -q 'rows_by_agent' "$cfg" 2>/dev/null; then
  echo "Warning: config.toml contains rows_by_agent."
  echo "  rows_by_agent is a complete override in herdr. For any agent it lists,"
  echo "  ui.sidebar.agents.rows is never consulted, so the row Island adds"
  echo "  will not appear there — with no error or warning from herdr."
  echo "  Recommend reviewing it by hand and removing it."
  echo
fi

# 3. reason 行の追加
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

# 4. agent CLI 側の hook 配線
echo
echo "To capture stop reasons, a hook must be wired into Claude Code / Codex."
echo "  Targets: PermissionRequest (all tools) and PreToolUse (AskUserQuestion only)"
echo "  The clearing side is not wired here (herdr's own event handles that)."
echo
if confirm "Wire the hook?"; then
  bash "$root/lib/hooks.sh" install
  case $? in
    0)  echo "Wired." ;;
    10) echo "Already wired." ;;
    *)  echo "Could not wire it. Configuration was not modified." ;;
  esac
fi

echo
echo "Usage: plugin action 'focus' narrows the view to only waiting agents."
