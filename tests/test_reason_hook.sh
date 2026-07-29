#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"
# shellcheck source=./fake_socket.sh
source "$here/fake_socket.sh"

HOOK="$here/../hooks/herdr-jump-reason.sh"

start_fake_socket || { echo "セットアップ失敗" >&2; exit 1; }
# 異常終了しても偽 socket の python3 を孤児にしない
trap stop_fake_socket EXIT

# run_hook <mode> <json> : ガードを揃えてフックを実行する
run_hook() {
  reset_capture
  printf '%s' "$2" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" "$1" >/dev/null 2>&1
}

# --- set: 送る内容 -----------------------------------------------------------

run_hook set '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_eq "pane.report_metadata" "$(sent '.method')"            "method は pane.report_metadata"
assert_eq "herdr-jump"           "$(sent '.params.source')"     "source は herdr-jump"
assert_eq "w0:p1"                "$(sent '.params.pane_id')"    "対象ペインは HERDR_PANE_ID"
assert_eq "Bash: ls -la"         "$(sent '.params.tokens.reason')" "reason トークンに本文が乗る"
assert_eq "900000"               "$(sent '.params.ttl_ms')"     "reason の TTL は 15 分"
assert_eq "number"               "$(sent '.params.seq | type')" "seq は数値で入る"

# 空白を含む値が JSON の 1 フィールドとして届くこと。CLI 引数ではなく JSON で
# 送るので word splitting の余地が構造的に無い
run_hook set '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"実装 方針 A|B"}]}}'
assert_eq "質問: 実装 方針 A|B" "$(sent '.params.tokens.reason')" \
  "空白と | を含む値もそのまま届く"

# --- clear -------------------------------------------------------------------

run_hook clear '{}'
assert_eq "pane.report_metadata" "$(sent '.method')" "clear も同じ method"

# `.tokens.reason // "null"` では「明示的な JSON null」と「キーそのものが無い」を
# 区別できない。RPC に clear_token 相当が無いので null を入れるのが唯一の
# クリア手段であり、それが消えても素通りするテストでは意味がない。
# キーの存在と値の型を別々に見る
assert_eq "true" "$(sent '.params.tokens | has("reason")')" "clear は reason キーを含める"
assert_eq "null" "$(sent '.params.tokens.reason | type')"   "その値は JSON の null"
assert_eq "null" "$(sent '.params.ttl_ms // "null"')"       "clear に TTL は付けない"

# --- ガード。いずれも何も送らずに黙って抜けること ----------------------------

reset_capture
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_ENV が 1 でなければ何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" set >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_PANE_ID が空なら何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 HERDR_SOCKET_PATH= bash "$HOOK" set >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_SOCKET_PATH が空なら何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "モード引数が無ければ何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" bogus >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "未知のモードでは何もしない"

run_hook set 'this is not json'
assert_eq "yes" "$(nothing_sent)" "壊れた JSON では何も送らない"

# 型不正な payload ではフィルタ側の jq が exit 5 で落ちる
# （"Cannot index string with string"）。フィルタは直さず、この層の
# 2>/dev/null + 空チェックで握り潰されることを固定する
run_hook set '{"tool_name":"Bash","tool_input":"oops"}'
assert_eq "yes" "$(nothing_sent)" "tool_input の型が不正でも何も送らない"

run_hook set '{"tool_name":"AskUserQuestion","tool_input":{"questions":{"a":1}}}'
assert_eq "yes" "$(nothing_sent)" "questions の型が不正でも何も送らない"

# --- 終了コード。フックは何があっても 0 で抜けること -------------------------

printf 'this is not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '{}' | HERDR_ENV=0 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "ガードで抜ける時も exit 0"

printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 HERDR_SOCKET_PATH=/nonexistent/sock \
    bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "socket が繋がらなくても exit 0"

# jq / python3 不在の経路。PATH を空にすると bash 自身も引けなくなるので
# インタプリタは絶対パスで呼ぶ
BASH_ABS="$(command -v bash)"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -u PATH HERDR_ENV=1 HERDR_PANE_ID=w0:p1 HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" \
    "$BASH_ABS" "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "jq / python3 が引けなくても exit 0"

stop_fake_socket
finish
