#!/bin/bash
# I6: remove.sh は view.py clear の終了コードを捨てて常に「クリアした」と
# 表示していた（bin/unfocus.sh は同じ状況で正しく分岐している）。socket が
# 届かないとき、remove.sh が失敗を報告し、view.json（＝実際にサーバへ
# 伝わった内容の記録）が残っていることを、削除されたと嘘をつかずに
# 伝えることを確かめる。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export HERDR_PLUGIN_ROOT="$here/.."
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"
echo '{"source":"plugin:island","label":"waiting"}' > "$HERDR_PLUGIN_STATE_DIR/view.json"

# socket 到達不能をシミュレート
export HERDR_SOCKET_PATH="/nonexistent/sock"
# 非対話。ISLAND_ASSUME_YES を立てないので confirm は常に no
# （hook/config の削除ステップには入らない。フィルタクリアの検証に絞る）
export ISLAND_ASSUME_YES=0

out="$(bash "$here/../bin/remove.sh" </dev/null 2>&1)"

assert_contains "$out" "Could not clear the filter" "socket 不達なら remove.sh は失敗を報告する"
assert_contains "$out" "still present" "保存済みフィルタが残っていることを伝える"
assert_eq "0" "$(printf '%s' "$out" | grep -cF 'Filtering has been cleared')" \
  "「クリアした」とは言わない（unfocus.sh 同様に分岐すること）"
assert_eq "yes" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "送信できなかったので view.json は実際に残っている（by design）"

finish
