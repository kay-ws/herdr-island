#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"
# shellcheck source=./fake_socket.sh
source "$here/fake_socket.sh"

PUSH="$here/../statusline/herdr-usage-push"

start_fake_socket || { echo "セットアップ失敗" >&2; exit 1; }

run_push() {
  reset_capture
  printf '%s' "$1" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
}

full='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":81000}},"rate_limits":{"five_hour":{"used_percentage":11.4},"seven_day":{"used_percentage":2.6}}}'

run_push "$full"
assert_eq "pane.report_metadata" "$(sent '.method')"                 "method は pane.report_metadata"
assert_eq "herdr-jump"           "$(sent '.params.source')"          "source は herdr-jump"
assert_eq "w0:p1"                "$(sent '.params.pane_id')"         "対象ペインは HERDR_PANE_ID"
assert_eq "42%"                  "$(sent '.params.tokens.ctx')"      "ctx トークンを送る"
assert_eq "3600000"              "$(sent '.params.ttl_ms')"          "usage の TTL は 1 時間"
assert_eq "number"               "$(sent '.params.seq | type')"      "seq は数値で入る"

# 空白と | を含む値が JSON の 1 フィールドとして届くこと
assert_eq "5h 11% | 7d 3%" "$(sent '.params.tokens.limits')" \
  "空白と | を含む limits もそのまま届く"

no_limits='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":50000}}}'
run_push "$no_limits"
assert_eq "25%"  "$(sent '.params.tokens.ctx')"                  "limits が無くても ctx は送る"
assert_eq "null" "$(sent '.params.tokens.limits // "null"')"     "limits が無い時は limits を含めない"
assert_eq "1"    "$(sent '.params.tokens | length')"             "tokens は ctx だけの 1 件"

# ctx すら取れないなら何も送らない
run_push '{}'
assert_eq "yes" "$(nothing_sent)" "空 payload では何も送らない"

run_push 'not json'
assert_eq "yes" "$(nothing_sent)" "壊れた JSON では何も送らない"

# ガード
reset_capture
printf '%s' "$full" | HERDR_ENV=1 HERDR_PANE_ID= bash "$PUSH" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_PANE_ID が空なら何もしない"

reset_capture
printf '%s' "$full" | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_ENV が 1 でなければ何もしない"

reset_capture
printf '%s' "$full" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 HERDR_SOCKET_PATH= bash "$PUSH" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_SOCKET_PATH が空なら何もしない"

# 終了コード
printf 'not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '%s' "$full" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 HERDR_SOCKET_PATH=/nonexistent/sock \
  bash "$PUSH" >/dev/null 2>&1
assert_eq "0" "$?" "socket が繋がらなくても exit 0"

BASH_ABS="$(command -v bash)"
printf '%s' "$full" | env -u PATH HERDR_ENV=1 HERDR_PANE_ID=w0:p1 \
  HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" "$BASH_ABS" "$PUSH" >/dev/null 2>&1
assert_eq "0" "$?" "jq / python3 が引けなくても exit 0"

stop_fake_socket
finish
