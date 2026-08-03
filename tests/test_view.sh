#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/fake_socket.sh"

WORK="$(mktemp -d -p /tmp)"
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

start_fake_socket || { echo "セットアップ失敗" >&2; exit 1; }
trap 'stop_fake_socket; rm -rf "$WORK"' EXIT

V="$here/../lib/view.py"

# --- set ---
reset_capture
python3 "$V" set
assert_eq "0" "$?" "set は 0 を返す"
assert_eq "agent.view.set"  "$(sent '.method')"        "method は agent.view.set"
assert_eq "plugin:island"   "$(sent '.params.source')" "source は plugin:island"
assert_eq "exists"          "$(sent '.params.filter.op')"           "filter は exists"
assert_eq "reason"          "$(sent '.params.filter.field.token')"  "reason トークンの有無で絞る"
assert_eq "attention"       "$(sent '.params.sort[0].field')"       "attention 優先で並べる"
assert_eq "desc"            "$(sent '.params.sort[0].order')"       "attention は降順"
assert_eq "state_change_seq" "$(sent '.params.sort[1].field')"      "次に直近の状態遷移で並べる"
assert_eq "desc"            "$(sent '.params.sort[1].order')"       "state_change_seq も降順"
assert_eq "yes" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "state に保存する"

# --- startup で再適用 ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "agent.view.set" "$(sent '.method')" "startup は保存済み view を再適用する"
# method だけ見ると、params を落とした restore でも通ってしまう
assert_eq "plugin:island" "$(sent '.params.source')"       "restore も source を forward する"
assert_eq "exists"        "$(sent '.params.filter.op')"    "restore も filter を forward する"
assert_eq "reason"        "$(sent '.params.filter.field.token')" "restore も filter の token を forward する"
assert_eq "2"             "$(sent '.params.sort | length')" "restore も sort を 2 件 forward する"

# --- clear ---
reset_capture
python3 "$V" clear
assert_eq "0" "$?" "clear は 0 を返す"
assert_eq "agent.view.clear" "$(sent '.method')"        "method は agent.view.clear"
assert_eq "plugin:island"    "$(sent '.params.source')" "source 指定で他者の view を奪わない"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "clear で state を消す"

# --- state が無ければ startup は何もしない ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "保存が無ければ startup は何も送らない"

# --- socket が到達不能なら state を書かない ---
# exit code だけ見るテストは、この不整合に対して無力だった。
# 送信していないのに state を書くと startup が「一度も適用されていない
# view」を毎回復元しにいく
rm -f "$HERDR_PLUGIN_STATE_DIR/view.json"
reset_capture
HERDR_SOCKET_PATH=/nonexistent/sock python3 "$V" set >/dev/null 2>&1
assert_eq "1" "$?" "socket が繋がらなければ 1 を返す"
assert_eq "yes" "$(nothing_sent)" "到達不能なら何も送られていない"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "送信できなかったときは state を書かない"

# --- startup は socket が無くても exit 0（サーバ起動のたびに走るため） ---
HERDR_SOCKET_PATH=/nonexistent/sock bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "0" "$?" "startup は socket が無くても exit 0"

finish
