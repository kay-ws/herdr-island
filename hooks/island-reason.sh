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

# --seq は付けない。
#
# 元は date +%s%3N のミリ秒を渡していたが、%N は GNU 拡張で BSD/macOS では
# 展開されず "17857471073N" のような非数値になる（CI の macOS ジョブで実測）。
#
# そもそも --seq が要るのは「古い報告が新しい報告を上書きしないこと」を
# 保証したい場合。この hook は質問や許可要求が発生した瞬間に 1 回送るだけで、
# 同一ペインへ並行して複数の理由が飛ぶ経路が無い。--seq を省いても
# report-metadata は rc 0 で受け付け、連続送信は後勝ちになることを実測済み。
# 単調増加値を作るためだけに python3 を呼ぶと hook の依存が 1 つ増え、
# python3 が無い環境で理由が出なくなる —— 得るものに対して代償が大きい。
#
# PANE_ID は必ずフラグより前に置く。後ろに置くと herdr が --source の値を
# フラグとして再解釈して "unknown option" で落ちる（0.7.5 実測）。
# --help の Usage 行は PANE_ID を最後に書いているので、素直に従うと踏む。
herdr pane report-metadata "$HERDR_PANE_ID" \
  --source island \
  --token "reason=$reason" \
  --ttl-ms 900000 >/dev/null 2>&1

exit 0
