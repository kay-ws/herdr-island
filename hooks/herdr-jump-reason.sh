#!/bin/bash
# herdr Agents パネルに「何で止まっているか」を出す。
#
# 使い方: このスクリプトを Claude Code / Codex のフックから呼ぶ。
#   set   … PermissionRequest / PreToolUse(AskUserQuestion) / Elicitation
#   clear … PostToolBatch / Stop
#
# 何があっても exit 0 する。表示が出ないのは許容できるが、
# 非ゼロ終了でエージェントの動作に影響を与えるのは許容できない。

mode="${1:-}"
[ "$mode" = "set" ] || [ "$mode" = "clear" ] || exit 0

# ガード。herdr のペイン内で起動されたプロセスだけが通る。
# HERDR_PANE_ID はペイン内の全プロセスツリーに継承されるので、
# その存在自体がペイン所属の証明になる。
[ "${HERDR_ENV:-}" = "1" ]       || exit 0
[ -n "${HERDR_PANE_ID:-}" ]      || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq    >/dev/null 2>&1 || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
seq_ms="$(date +%s%3N)" || exit 0

if [ "$mode" = "clear" ]; then
  herdr pane report-metadata \
    --source herdr-jump \
    --clear-token reason \
    --seq "$seq_ms" \
    "$HERDR_PANE_ID" >/dev/null 2>&1
  exit 0
fi

# stdin の payload から 1 行を組み立てる。壊れた JSON なら空になる
reason="$(jq -r -f "$here/reason-filter.jq" 2>/dev/null)"
[ -n "$reason" ] || exit 0

herdr pane report-metadata \
  --source herdr-jump \
  --token "reason=$reason" \
  --seq "$seq_ms" \
  --ttl-ms 900000 \
  "$HERDR_PANE_ID" >/dev/null 2>&1

exit 0
