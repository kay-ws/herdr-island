#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

HOOK="$here/../hooks/herdr-jump-reason.sh"

# shellcheck source=./fake_herdr.sh
source "$here/fake_herdr.sh"

# run_hook <mode> <json> : ガードを揃えてフックを実行し、捕まえた引数を返す
run_hook() {
  reset_capture
  printf '%s' "$2" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" "$1" >/dev/null 2>&1
  cat "$CAPTURE"
}

setup_fake_herdr

out="$(run_hook set '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
assert_contains "$out" "pane report-metadata" "set は report-metadata を呼ぶ"
assert_contains "$out" "--source herdr-jump"  "source は herdr-jump"
assert_contains "$out" "reason=Bash: ls -la"  "reason トークンに本文が乗る"
assert_contains "$out" "--ttl-ms 900000"      "reason の TTL は 15 分"
assert_contains "$out" "w0:p1"                "対象ペインは HERDR_PANE_ID"

# 1 引数 1 行の記録で word splitting を検出する。連結形の assert_contains では
# クォート漏れがあっても "$*" が同じ空白で再結合するため気づけない
assert_eq "yes" "$(has_arg "reason=Bash: ls -la")" \
  "空白を含む reason も 1 引数として渡る"

out="$(run_hook clear '{}')"
assert_contains "$out" "--clear-token reason" "clear は reason を消す"

# --- ガード。いずれも herdr を呼ばずに黙って抜けること ---

reset_capture
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_ENV が 1 でなければ何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" set >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_PANE_ID が空なら何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "モード引数が無ければ何もしない"

reset_capture
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" bogus >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "未知のモードでは何もしない"

# --- 終了コード。フックは何があっても 0 で抜けること ---

printf 'this is not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '{}' | HERDR_ENV=0 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "ガードで抜ける時も exit 0"

# herdr / jq 不在の経路。PATH を空にすると bash 自身も引けなくなるので
# インタプリタは絶対パスで呼ぶ
BASH_ABS="$(command -v bash)"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -u PATH HERDR_ENV=1 HERDR_PANE_ID=w0:p1 "$BASH_ABS" "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "herdr / jq が引けなくても exit 0"

# reason が空になる payload では herdr を呼ばない（壊れた JSON も同様）
assert_eq "" "$(run_hook set 'this is not json')" "壊れた JSON では何も送らない"

# 型不正な payload ではフィルタ側の jq が exit 5 で落ちる
# （"Cannot index string with string"）。フィルタは直さず、この層の
# 2>/dev/null + 空チェックで握り潰されることを固定する
assert_eq "" "$(run_hook set '{"tool_name":"Bash","tool_input":"oops"}')" \
  "tool_input の型が不正でも何も送らない"

printf '{"tool_name":"Bash","tool_input":"oops"}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "tool_input の型が不正でも exit 0"

assert_eq "" "$(run_hook set '{"tool_name":"AskUserQuestion","tool_input":{"questions":{"a":1}}}')" \
  "questions の型が不正でも何も送らない"

teardown_fake_herdr
finish
