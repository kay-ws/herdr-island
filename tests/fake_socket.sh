#!/bin/bash
# Stand up a fake herdr socket and record the JSON-RPC requests it receives.
#
# It goes through the same path production does (JSON over a UNIX socket), so it
# does not depend on the CLI's argument format. Sending JSON also removes any
# structural worry about word splitting — a value containing spaces or | still
# arrives as one JSON field.
#
#   $HERDR_SOCKET_PATH … path to the fake socket (what the hook side reads)
#   $CAPTURE           … received JSON, appended one request per line
#
# Keep the socket path explicitly short with -p /tmp. A UNIX socket path is
# capped at 108 bytes of sun_path, so a TMPDIR pointing at a deep directory
# makes bind fail — and the cause is hard to see from inside the test.

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
# Signal to the caller that bind is done. The socket file existing would leave
# room to proceed before listen, so signal with a separate file.
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

  # Wait for listen to complete; give up after 2 seconds
  local i
  for i in $(seq 100); do
    [ -e "$HERDR_SOCKET_PATH.ready" ] && return 0
    sleep 0.02
  done
  echo "the fake socket never came up" >&2
  return 1
}

stop_fake_socket() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_PID:-}" ] && wait "$FAKE_PID" 2>/dev/null
  [ -n "${FAKE_DIR:-}" ] && rm -rf "$FAKE_DIR"
  return 0
}

reset_capture() { : > "$CAPTURE"; }

# sent <jq filter> : pull a value out of the most recently received request.
# Returns the empty string when nothing has arrived.
sent() {
  [ -s "$CAPTURE" ] || { printf ''; return 0; }
  tail -1 "$CAPTURE" | jq -r "$1" 2>/dev/null
}

# nothing_sent : has nothing at all arrived?
nothing_sent() { [ -s "$CAPTURE" ] && echo no || echo yes; }
