#!/bin/bash
# 旧 herdr-jump の痕跡を 4 箇所から除去する。
# install.sh に uninstall 経路が無かったため、撤去はここで新規に実装する。
set -uo pipefail

PAT='herdr-jump|herdr-usage-push'

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }
herdr_config()    { printf '%s' "${ISLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"; }
ccstatus()        { printf '%s' "${ISLAND_CCSTATUS:-$HOME/.local/bin/ccstatus}"; }

legacy_detect() {
  local found=1 f
  for f in "$(claude_settings)" "$(codex_hooks)" "$(herdr_config)" "$(ccstatus)"; do
    [ -f "$f" ] || continue
    if grep -qE "$PAT" "$f" 2>/dev/null; then
      echo "$f"
      found=0
    fi
  done
  [ "$found" -eq 0 ] && return 0
  return 10
}

_backup() { [ -f "$1" ] && cp -p "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; return 0; }

# hook JSON から自分のエントリだけを取り除く。他人の hook には触らない
_purge_hooks() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f"
  local tmp; tmp="$(mktemp)"
  jq '
    def purge:
      (. // [])
      | map(.hooks |= ((. // []) | map(select(
          ((.command // "") | test("herdr-jump-reason|herdr-codex-usage")) | not))))
      | map(select((.hooks | length) > 0));
    if (.hooks | type) == "object"
    then .hooks |= with_entries(.value |= purge)
         | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
}

# config.toml は 2 箇所。マーカーブロックと [ui] 内の単独行
_purge_config() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f"
  local tmp; tmp="$(mktemp)"
  awk '
    /^# >>> herdr-jump \(managed\) >>>/ { skip = 1 }
    skip && /^# <<< herdr-jump \(managed\) <<</ { skip = 0; next }
    skip { next }
    /herdr-jump/ { next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

# ccstatus は利用者自身のスクリプト。該当行だけ落とす
_purge_ccstatus() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q 'herdr-usage-push' "$f" 2>/dev/null || return 0
  _backup "$f"
  local tmp; tmp="$(mktemp)"
  grep -v 'herdr-usage-push' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

legacy_purge() {
  _purge_hooks    "$(claude_settings)"
  _purge_hooks    "$(codex_hooks)"
  _purge_config   "$(herdr_config)"
  _purge_ccstatus "$(ccstatus)"
  return 0
}

case "${1:-}" in
  detect) legacy_detect ;;
  purge)  legacy_purge ;;
  *) echo "usage: legacy.sh {detect|purge}" >&2; exit 1 ;;
esac
