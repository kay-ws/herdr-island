#!/bin/bash
# 旧 herdr-jump の痕跡を 4 箇所から除去する。
# install.sh に uninstall 経路が無かったため、撤去はここで新規に実装する。
set -uo pipefail

# 検出用。旧実装が残しうる識別子を網羅する。
# herdr-codex-usage を落とすと、codex 側にそれしか無いファイルで detect が
# rc 10（痕跡なし）を返し purge が無言で素通りする
PAT='herdr-jump|herdr-usage-push|herdr-codex-usage'

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

# バックアップ名の一意性は mktemp に任せる。秒単位の名前だと、apply と revert を
# 同じ秒に走らせたときのように cp が先のバックアップを黙って上書きする（cp に -n は
# 無い）。ミリ秒（%3N）は GNU 拡張で BSD/macOS では展開されない。
# bin/_config.sh / lib/hooks.sh と同じ手（-p は macOS でも動作を確認済み）
_backup() {
  [ -f "$1" ] || return 0
  local bak; bak="$(mktemp "$1.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  cp -p "$1" "$bak"
}

# _stage_for <file> : 書き戻し用の空ステージを作りパスを stdout へ。
#
# 対象と同じディレクトリに作る。素の `mktemp`（$TMPDIR）だと 2 つ壊れる:
#   - mv がファイルシステムを跨ぐとアトミックでなくなる。途中で落ちれば
#     利用者の設定が壊れたまま残る
#   - TMPDIR が使えない環境で mktemp が空を返し、`> ""` が失敗して purge が
#     黙って素通りする（痕跡は消えないのに rc 0 で「済んだ」と報告する）
#
# 権限は cp -p で運ぶ。mktemp は 0600 で作るので、そのまま mv すると利用者の
# ファイルが 0600 に化ける —— ccstatus は実行される側なので実行ビットが落ちて
# ステータス行が黙って出なくなる。chmod --reference は使わない（GNU 拡張で
# macOS には無く、失敗しても静かなので umask 由来の権限が残る）
_stage_for() {
  local f="$1" stage
  stage="$(mktemp "$(dirname "$f")/.island-legacy.XXXXXX")" || return 1
  cp -p "$f" "$stage" || { rm -f "$stage"; return 1; }
  printf '%s' "$stage"
}

# hook JSON から自分のエントリだけを取り除く。他人の hook には触らない
_purge_hooks() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f" || return 1
  local tmp; tmp="$(_stage_for "$f")" || return 1
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
  ' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# config.toml は 2 箇所。マーカーブロックと [ui] 内の単独行
_purge_config() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f" || return 1
  local tmp; tmp="$(_stage_for "$f")" || return 1
  awk '
    /^# >>> herdr-jump \(managed\) >>>/ { skip = 1 }
    skip && /^# <<< herdr-jump \(managed\) <<</ { skip = 0; next }
    skip { next }
    # ブロック外で消すのは agent_panel_sort の 1 行だけ。
    # /herdr-jump/ のような素の部分一致にすると、利用者が書いた
    # 「herdr-jump を試したが乗り換えた」のような無関係な行まで巻き込む
    /^[[:space:]]*agent_panel_sort[[:space:]]*=.*#[[:space:]]*herdr-jump/ { next }
    { print }
  ' "$f" > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# ccstatus は利用者自身のスクリプト。該当行だけ落とす
_purge_ccstatus() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q 'herdr-usage-push' "$f" 2>/dev/null || return 0
  _backup "$f" || return 1
  local tmp; tmp="$(_stage_for "$f")" || return 1
  grep -v 'herdr-usage-push' "$f" > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
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
