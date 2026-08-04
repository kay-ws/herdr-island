#!/bin/bash
# A variant of fake_socket.sh: a fake socket that always returns the error reply
# herdr genuinely sends
# ({"id":"","error":{"code":"invalid_request","message":"..."}}).
# It exists to expose I7 (the unread-reply check), and is kept as a separate
# file from tests/fake_socket.sh (which must not change) so that one keeps
# returning success replies.
#
# Usage mirrors fake_socket.sh: start_fake_error_socket / stop_fake_error_socket.
# It exports HERDR_SOCKET_PATH / CAPTURE under the same variable names, so
# sent() / nothing_sent() / reset_capture() from fake_socket.sh work unchanged.

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
  echo "the fake error socket never came up" >&2
  return 1
}

stop_fake_error_socket() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_PID:-}" ] && wait "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_DIR:-}" ] && rm -rf "$FAKE_DIR"
  return 0
}
