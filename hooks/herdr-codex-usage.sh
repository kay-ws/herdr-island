#!/bin/bash
# Codex のセッション JSONL から現在の context 使用率を読み、
# herdr Agents パネルへ push する。Codex の Stop フックから呼ばれる。
#
# total_token_usage はセッション全体の累計なので使わない。各応答時点の
# context に対応する last_token_usage.total_tokens を window で割る。
#
# 何があっても exit 0 する。表示補助の失敗で Codex を止めない。

[ "${HERDR_ENV:-}" = "1" ]        || exit 0
[ -n "${HERDR_PANE_ID:-}" ]       || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ]   || exit 0
[ -n "${CODEX_THREAD_ID:-}" ]     || exit 0
command -v jq      >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# ID を glob の一部に使うため、想定外の文字やパス区切りを拒否する。
[[ "$CODEX_THREAD_ID" =~ ^[A-Za-z0-9-]+$ ]] || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
SEND="$here/../lib/herdr-send.py"
[ -f "$SEND" ] || exit 0

codex_root="${CODEX_HOME:-$HOME/.codex}"
shopt -s nullglob
session_files=("$codex_root"/sessions/*/*/*/*-"$CODEX_THREAD_ID".jsonl)
[ "${#session_files[@]}" -eq 1 ] || exit 0

# token_count は各 API 応答の直後に書かれるので末尾だけを見る。-R + fromjson?
# により、書き込み途中の最終行や JSON 以外の行があっても全体を捨てない。
ctx="$(
  tail -n 200 "${session_files[0]}" 2>/dev/null |
    jq -Rrs '
      split("\n")
      | map(fromjson?
            | select(.type == "event_msg"
                     and .payload.type == "token_count"
                     and (.payload.info.last_token_usage.total_tokens | type) == "number"
                     and (.payload.info.model_context_window | type) == "number"
                     and .payload.info.model_context_window > 0))
      | last
      | if . == null then ""
        else
          ((.payload.info.last_token_usage.total_tokens * 100
            / .payload.info.model_context_window) | floor | if . > 100 then 100 else . end)
          | "\(.)%"
        end
    ' 2>/dev/null
)" || exit 0
[ -n "$ctx" ] || exit 0

jq -nc --arg p "$HERDR_PANE_ID" --arg c "$ctx" \
       --argjson seq "$(date +%s%3N)" \
  '{id: "herdr-jump",
    method: "pane.report_metadata",
    params: { pane_id: $p, source: "herdr-jump",
              tokens: { ctx: $c }, seq: $seq, ttl_ms: 3600000 }}' \
  2>/dev/null | python3 "$SEND"

exit 0
