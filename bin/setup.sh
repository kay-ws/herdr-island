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

echo "Island — 待っているエージェントを見つける"
echo

# 1. 旧 herdr-jump の痕跡
if bash "$root/lib/legacy.sh" detect > /tmp/island-legacy.$$ 2>/dev/null; then
  echo "旧 herdr-jump の痕跡が見つかりました:"
  sed 's/^/  /' /tmp/island-legacy.$$
  echo
  if confirm "撤去しますか？"; then
    bash "$root/lib/legacy.sh" purge && echo "撤去しました。"
  fi
  echo
fi
rm -f /tmp/island-legacy.$$

# 2. rows_by_agent の影。complete override で新しい行が効かなくなる
if [ -f "$cfg" ] && grep -q 'rows_by_agent' "$cfg" 2>/dev/null; then
  echo "警告: config.toml に rows_by_agent があります。"
  echo "  rows_by_agent は complete override です。該当エージェントには"
  echo "  ui.sidebar.agents.rows が一切参照されず、追加した行が"
  echo "  エラーも警告も無しに表示されません。"
  echo "  手で確認して除去することを勧めます。"
  echo
fi

# 3. reason 行の追加
echo "追加する行:"
echo '  [{ token = "$reason", fg = "#f38ba8", bold = true }]'
echo
if confirm "config.toml に追加しますか？"; then
  island_edit_config add
  case $? in
    0)  echo "追加しました。" ;;
    10) echo "既に追加済みです。" ;;
    *)  echo "追加できませんでした。設定は変更していません。" ;;
  esac
else
  echo "config は変更しませんでした。絞り込み機能だけなら設定不要で使えます。"
fi

# 4. agent CLI 側の hook 配線
echo
echo "停止理由を取得するには、Claude Code / Codex 側に hook を 1 本入れる必要があります。"
echo "  対象: PermissionRequest（全ツール）と PreToolUse（AskUserQuestion のみ）"
echo "  消す側の配線は入れません（herdr のイベントが担当します）"
echo
if confirm "hook を配線しますか？"; then
  bash "$root/lib/hooks.sh" install
  case $? in
    0)  echo "配線しました。" ;;
    10) echo "既に配線済みです。" ;;
    *)  echo "配線できませんでした。設定は変更していません。" ;;
  esac
fi

echo
echo "使い方: plugin action 'focus' で待っているエージェントだけに絞れます。"
