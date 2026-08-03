#!/bin/bash
# I7: send() が herdr の応答を読まないまま True を返すと、herdr がリクエストを
# 拒否した（パラメータ名の誤り・必須フィールド欠落など）場合でも focus は
# 「成功」と表示し、view.json を書き、[[startup]] が拒否されたリクエストを
# 再送し続ける。fake_socket.sh（変更禁止・常に成功応答）とは別の、常にエラー
# 応答を返す fake_socket_error.sh を使ってこれを検出する。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/fake_socket.sh"        # sent / nothing_sent / reset_capture を流用
source "$here/fake_socket_error.sh"  # start/stop_fake_error_socket

WORK="$(mktemp -d -p /tmp)"
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

start_fake_error_socket || { echo "セットアップ失敗" >&2; exit 1; }
trap 'stop_fake_error_socket; rm -rf "$WORK"' EXIT

V="$here/../lib/view.py"

# --- set: herdr がエラーを返したら失敗として扱うこと ---
reset_capture
err_out="$(python3 "$V" set 2>&1)"
rc=$?
assert_eq "1" "$rc" "herdr がエラー応答を返したら set は 1 を返す"
assert_contains "$err_out" "missing field" "エラーメッセージが stderr に出る（拒否が診断可能）"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "エラー応答では view.json を書かない（拒否されたリクエストを再送し続けない）"

# --- startup: state ファイルがあっても exit 0 を保つこと ---
# startup.sh はサーバ起動のたびに走るため、送信結果に関わらず exit 0 で
# なければならない。restore が実際に送信するよう、あらかじめ state を
# 用意しておく（無ければ restore は送信自体を試みず、この検証にならない）
cat > "$HERDR_PLUGIN_STATE_DIR/view.json" <<'EOF'
{"source":"plugin:island","label":"waiting"}
EOF
reset_capture
bash "$here/../bin/startup.sh" >/tmp/island-startup-err.$$ 2>&1
rc2=$?
assert_eq "0" "$rc2" "herdr がエラー応答を返しても startup.sh は exit 0 のまま"
assert_eq "yes" "$([ -s "$CAPTURE" ] && echo yes || echo no)" \
  "startup は実際に送信を試みている（state があるので restore が動く）"
rm -f /tmp/island-startup-err.$$

finish
