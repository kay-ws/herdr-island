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
assert_eq "yes" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "state に保存する"

# --- startup で再適用 ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "agent.view.set" "$(sent '.method')" "startup は保存済み view を再適用する"

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

# --- socket が無くても落ちない ---
HERDR_SOCKET_PATH=/nonexistent/sock python3 "$V" set >/dev/null 2>&1
assert_eq "0" "$?" "socket が繋がらなくても 0 で抜ける"

finish
