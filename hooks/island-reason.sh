#!/bin/bash
# herdr Agents パネルに「何で止まっているか」を出す。理由を立てるのみ。
#
# 消すのはプラグイン側の pane.agent_status_changed イベントが担当する。
# ここで clear しないので、agent CLI の設定に入るのはこの 1 本だけで済む。
#
# 何があっても exit 0 する。表示が出ないのは許容できるが、
# 非ゼロ終了でエージェントの動作に影響を与えるのは許容できない。

# ガード。herdr のペイン内で起動されたプロセスだけが通る
[ "${HERDR_ENV:-}" = "1" ]      || exit 0
[ -n "${HERDR_PANE_ID:-}" ]     || exit 0
command -v jq    >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
FILTER="$here/reason-filter.jq"
[ -f "$FILTER" ] || exit 0

reason="$(jq -r -f "$FILTER" 2>/dev/null)"
[ -n "$reason" ] || exit 0

seq_ms="$(date +%s%3N)" || exit 0

# PANE_ID は必ずフラグより前に置く。後ろに置くと herdr が --source の値を
# フラグとして再解釈して "unknown option" で落ちる（0.7.5 実測）。
# --help の Usage 行は PANE_ID を最後に書いているので、素直に従うと踏む。
herdr pane report-metadata "$HERDR_PANE_ID" \
  --source island \
  --token "reason=$reason" \
  --seq "$seq_ms" \
  --ttl-ms 900000 >/dev/null 2>&1

exit 0
