#!/bin/bash
# fake_socket.sh の変種。herdr が実際に返すエラー応答
# （{"id":"","error":{"code":"invalid_request","message":"..."}}）を
# 常に返す偽 socket。I7（応答未読チェック）を検出させるためのもので、
# 成功応答を返す tests/fake_socket.sh（変更禁止）とは別ファイルにしてある。
#
# 使い方は fake_socket.sh と同じ: start_fake_error_socket / stop_fake_error_socket。
# HERDR_SOCKET_PATH / CAPTURE を同じ変数名でエクスポートするので、
# fake_socket.sh の sent() / nothing_sent() / reset_capture() をそのまま流用できる。

start_fake_error_socket() {
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
open(sock_path + ".ready", "w").close()

reply = b"{\"id\":\"\",\"error\":{\"code\":\"invalid_request\",\"message\":\"invalid request: missing field \x60subscriptions\x60 at line 1 column 96\"}}\n"

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
        conn.sendall(reply)
    except Exception:
        pass
    finally:
        conn.close()
' "$HERDR_SOCKET_PATH" "$CAPTURE" &
  FAKE_PID=$!

  local i
  for i in $(seq 100); do
    [ -e "$HERDR_SOCKET_PATH.ready" ] && return 0
    sleep 0.02
  done
  echo "fake error socket が立ち上がりませんでした" >&2
  return 1
}

stop_fake_error_socket() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_PID:-}" ] && wait "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_DIR:-}" ] && rm -rf "$FAKE_DIR"
  return 0
}
