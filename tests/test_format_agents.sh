#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../herdr-jump.sh"

fixture_basic() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p1","tab_id":"w0:t1","agent":"claude","agent_status":"working","state_change_seq":100,"terminal_title_stripped":"タスクA"},
 {"pane_id":"w1:p2","tab_id":"w1:t2","agent":"codex","agent_status":"blocked","state_change_seq":200,"terminal_title_stripped":"レビュー待ち"}
]}}
JSON
}

# --- 自ペインを除外する ---
result=$(fixture_basic | format_agents "w0:p1")
assert_eq 1 "$(printf '%s\n' "$result" | grep -c .)" "自ペインを除いて 1 行"
assert_contains "$result" "w1:p2" "残るのは相手ペイン"

# --- 出力フォーマットを 1 箇所で固定する ---
# 桁: アイコン + 空白 + agent(8桁詰め) + 空白 + tab_id(8桁詰め) + 空白 + タイトル + TAB + pane_id
assert_eq "● codex    w1:t2    レビュー待ち"$'\t'"w1:p2" "$result" "行フォーマット"

finish
