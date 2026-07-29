#!/bin/bash
# 偽の herdr socket を立て、受け取った JSON-RPC リクエストを記録する。
#
# 本番と同じ経路（UNIX socket への JSON 送信）を通すので、CLI の引数形式に
# 依存しない。JSON で送るため word splitting の心配も構造的に無い ——
# 値に空白や | が入っていても JSON の 1 フィールドとして届く。
#
#   $HERDR_SOCKET_PATH … 偽 socket のパス（フック側はこれを読む）
#   $CAPTURE           … 受信した JSON を 1 行 1 リクエストで追記
#
# socket のパスは -p /tmp で明示的に短く保つ。UNIX socket のパスは
# sun_path 108 バイトが上限で、TMPDIR が深いディレクトリを指していると
# bind に失敗する（しかもテストからは原因が見えにくい）。

start_fake_socket() {
  FAKE_DIR="$(mktemp -d -p /tmp)"
  HERDR_SOCKET_PATH="$FAKE_DIR/sock"
  CAPTURE="$FAKE_DIR/captured"
  : > "$CAPTURE"
  export HERDR_SOCKET_PATH CAPTURE

  python3 -c '
import socket, sys

sock_path, cap = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(8)
# bind が済んだことを呼び出し側に知らせる。socket ファイルの存在では
# listen 前に進んでしまう余地があるので別ファイルで合図する
open(sock_path + ".ready", "w").close()

while True:
    try:
        conn, _ = srv.accept()
    except Exception:
        break
    try:
        data = conn.recv(65536)
        if data:
            if not data.endswith(b"\n"):
                data += b"\n"
            with open(cap, "ab") as f:
                f.write(data)
        conn.sendall(b"{\"result\":{\"type\":\"ok\"}}\n")
    except Exception:
        pass
    finally:
        conn.close()
' "$HERDR_SOCKET_PATH" "$CAPTURE" &
  FAKE_PID=$!

  # listen 完了を待つ。2 秒で諦める
  local i
  for i in $(seq 100); do
    [ -e "$HERDR_SOCKET_PATH.ready" ] && return 0
    sleep 0.02
  done
  echo "fake socket が立ち上がりませんでした" >&2
  return 1
}

stop_fake_socket() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_PID:-}" ] && wait "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_DIR:-}" ] && rm -rf "$FAKE_DIR"
  return 0
}

reset_capture() { : > "$CAPTURE"; }

# sent <jq フィルタ> : 最後に受信したリクエストから値を取る。
# 何も届いていなければ空文字を返す
sent() {
  [ -s "$CAPTURE" ] || { printf ''; return 0; }
  tail -1 "$CAPTURE" | jq -r "$1" 2>/dev/null
}

# nothing_sent : 1 件も届いていないか
nothing_sent() { [ -s "$CAPTURE" ] && echo no || echo yes; }
