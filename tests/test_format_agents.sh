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

# --- 並べ替え: グループ優先、同グループ内は state_change_seq の降順 ---
# seq の並び (900,800,300,100) とグループの並びをわざと食い違わせてある。
# グループ分けが無ければ p9,p4,p3,p2 になり、seq が昇順なら p3,p4 になる。
# どちらが壊れても検出できる。
fixture_sort() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p9","tab_id":"w0:t9","agent":"claude","agent_status":"idle","state_change_seq":900,"terminal_title_stripped":"暇"},
 {"pane_id":"w0:p2","tab_id":"w0:t2","agent":"claude","agent_status":"working","state_change_seq":100,"terminal_title_stripped":"作業中"},
 {"pane_id":"w0:p3","tab_id":"w0:t3","agent":"codex","agent_status":"blocked","state_change_seq":300,"terminal_title_stripped":"確認待ち"},
 {"pane_id":"w0:p4","tab_id":"w0:t4","agent":"codex","agent_status":"done","state_change_seq":800,"terminal_title_stripped":"完了"}
]}}
JSON
}

order=$(fixture_sort | format_agents "" | sed 's/.*\t//' | tr '\n' ' ')
assert_eq "w0:p4 w0:p3 w0:p2 w0:p9 " "$order" "並び順: 要対応(seq降順) → working → idle"

# --- アイコンの対応 ---
# 最初の空白までを切る。cut -c1 は使わない: GNU cut の -c がマルチバイトを
# 文字として扱うかはロケール依存で、LC_ALL=C だとアイコンの 1 バイト目だけ
# 取れて壊れる。sed のこの形はバイト境界に依存しない。
icons=$(fixture_sort | format_agents "" | sed 's/ .*//' | tr '\n' ' ')
assert_eq "◍ ● ◐ ○ " "$icons" "アイコン: done / blocked / working / idle"

# --- タイトル空・キー欠落・未知の status ---
fixture_edge() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p1","tab_id":"w0:t1","agent":"claude","agent_status":"idle","state_change_seq":10,"terminal_title_stripped":""},
 {"pane_id":"w0:p2","tab_id":"w0:t2","agent":"claude","agent_status":"quantum","state_change_seq":20,"terminal_title_stripped":"未知状態"},
 {"pane_id":"w0:p3","tab_id":"w0:t3","agent":"codex","agent_status":"idle","state_change_seq":5}
]}}
JSON
}

edge=$(fixture_edge | format_agents "")
assert_contains "$edge" "(idle)"$'\t'"w0:p1" "タイトルが空なら (状態) を出す"
assert_contains "$edge" "(idle)"$'\t'"w0:p3" "キーごと無い場合も (状態) を出す"
assert_contains "$edge" "· claude"          "未知の status は · で出す（隠さない）"
assert_eq 3 "$(printf '%s\n' "$edge" | grep -c .)" "3 件すべて残る"

# --- 0 件 ---
empty=$(echo '{"result":{"agents":[]}}' | format_agents "")
assert_eq "" "$empty" "エージェント 0 件なら空出力"

# --- 自分しかいない ---
fixture_only_self() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p1","tab_id":"w0:t1","agent":"claude","agent_status":"idle","state_change_seq":1,"terminal_title_stripped":"x"}
]}}
JSON
}
only_self=$(fixture_only_self | format_agents "w0:p1")
assert_eq "" "$only_self" "自分だけなら空出力"

finish
