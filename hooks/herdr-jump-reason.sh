#!/bin/bash
# herdr Agents パネルに「何で止まっているか」を出す。
#
# 使い方: このスクリプトを Claude Code / Codex のフックから呼ぶ。
#   set   … PermissionRequest / PreToolUse(AskUserQuestion)
#   clear … PostToolBatch / Stop
#   model … Codex SessionStart
#
# reason-filter.jq は Elicitation（MCP の入力待ち）も扱えるが、payload を
# 実物で確認していないため install.sh では配線していない。確認できたら
# install.sh に 1 エントリ足すだけで有効になる。
#
# herdr CLI ではなく socket API を叩く（理由は lib/herdr-send.py の冒頭参照）。
#
# 何があっても exit 0 する。表示が出ないのは許容できるが、
# 非ゼロ終了でエージェントの動作に影響を与えるのは許容できない。

mode="${1:-}"
[ "$mode" = "set" ] || [ "$mode" = "clear" ] || [ "$mode" = "model" ] || exit 0

# ガード。herdr のペイン内で起動されたプロセスだけが通る。
# HERDR_PANE_ID / HERDR_SOCKET_PATH はペイン内の全プロセスツリーに継承される
# ので、その存在自体がペイン所属の証明になる。
[ "${HERDR_ENV:-}" = "1" ]        || exit 0
[ -n "${HERDR_PANE_ID:-}" ]       || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ]   || exit 0
command -v jq      >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
SEND="$here/../lib/herdr-send.py"
[ -f "$SEND" ] || exit 0

seq_ms="$(date +%s%3N)" || exit 0

# Codex の全コマンドフックに入る model slug を、セッション開始時に送る。
# Claude の表示名は statusLine 側が送るため、このモードは Codex の
# SessionStart だけに配線する。
if [ "$mode" = "model" ]; then
  model="$(jq -r 'if (.model | type) == "string" then .model else "" end' 2>/dev/null)"
  [ -n "$model" ] || exit 0

  jq -nc --arg p "$HERDR_PANE_ID" --arg m "$model" --argjson seq "$seq_ms" \
    '{id: "herdr-jump",
      method: "pane.report_metadata",
      params: { pane_id: $p, source: "herdr-jump",
                tokens: { model: $m }, seq: $seq }}' \
    2>/dev/null | python3 "$SEND"
  exit 0
fi

# クリアは tokens に null を入れる。RPC に clear_token 相当のパラメータは無い
# （title / display_agent / state_labels には専用フラグがあるが token には無い）
if [ "$mode" = "clear" ]; then
  jq -nc --arg p "$HERDR_PANE_ID" --argjson seq "$seq_ms" \
    '{id: "herdr-jump",
      method: "pane.report_metadata",
      params: { pane_id: $p, source: "herdr-jump",
                tokens: { reason: null }, seq: $seq }}' \
    2>/dev/null | python3 "$SEND"
  exit 0
fi

# stdin の payload から 1 行を組み立てる。壊れた JSON なら空になる
reason="$(jq -r -f "$here/reason-filter.jq" 2>/dev/null)"
[ -n "$reason" ] || exit 0

jq -nc --arg p "$HERDR_PANE_ID" --arg r "$reason" --argjson seq "$seq_ms" \
  '{id: "herdr-jump",
    method: "pane.report_metadata",
    params: { pane_id: $p, source: "herdr-jump",
              tokens: { reason: $r }, seq: $seq, ttl_ms: 900000 }}' \
  2>/dev/null | python3 "$SEND"

exit 0
