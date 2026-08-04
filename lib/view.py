#!/usr/bin/env python3
"""Send agent.view.set / agent.view.clear to the socket.

agent.view.* has no CLI wrapper, so this talks to the socket directly. Views are
transient — they vanish when the server exits or the plugin is disabled — so the
params that were sent are saved in STATE_DIR and re-applied from [[startup]].
"""
import json
import os
import socket
import sys

SOURCE = "plugin:island"

PARAMS = {
    "source": SOURCE,
    "label": "waiting",
    "filter": {"op": "exists", "field": {"token": "reason"}},
    "sort": [
        {"field": "attention", "order": "desc"},
        {"field": "state_change_seq", "order": "desc"},
    ],
}


def state_file():
    d = os.environ.get("HERDR_PLUGIN_STATE_DIR")
    return os.path.join(d, "view.json") if d else None


def send(method, params):
    # Returning True without reading herdr's reply would count the cases where
    # herdr *rejected* the request — a misspelled parameter, a missing required
    # field, an incompatibility after a schema change — as "success". The
    # visible symptom is "I pressed the button and nothing happened", with the
    # error surfacing nowhere. So read the one-line reply, decide on the
    # presence of an error key, and print the message to stderr on rejection.
    # settimeout stays in place so a server that never replies cannot hang the
    # caller; timeout is a subclass of OSError, so it is caught as a failure here.
    path = os.environ.get("HERDR_SOCKET_PATH")
    if not path:
        sys.stderr.write("Could not send to herdr (no socket path)\n")
        return False
    req = json.dumps({"id": "island", "method": method, "params": params})
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(path)
        s.sendall(req.encode("utf-8") + b"\n")
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        s.close()
    except OSError:
        sys.stderr.write("Could not send to herdr\n")
        return False

    line = buf.split(b"\n", 1)[0]
    try:
        resp = json.loads(line.decode("utf-8"))
    except ValueError:
        sys.stderr.write("Could not send to herdr (malformed reply)\n")
        return False

    if isinstance(resp, dict) and "error" in resp:
        err = resp.get("error")
        msg = err.get("message") if isinstance(err, dict) else err
        sys.stderr.write(f"herdr rejected the request: {msg}\n")
        return False

    return True


def main():
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    sf = state_file()

    # The state file means "what was actually communicated to the server", not
    # "what the user wants". restore exists to bring back a view lost to a
    # server restart, so saving a view that was never applied would make restore
    # lie: someone who hits focus while herdr is down would meet an unexplained
    # filtered screen on the next start. Hence it is only updated on a
    # successful send.
    if op == "set":
        if not send("agent.view.set", PARAMS):
            return 1
        if sf:
            with open(sf, "w", encoding="utf-8") as f:
                json.dump(PARAMS, f)
        return 0

    if op == "clear":
        if not send("agent.view.clear", {"source": SOURCE}):
            return 1
        if sf and os.path.exists(sf):
            os.remove(sf)
        return 0

    if op == "restore":
        if not sf or not os.path.exists(sf):
            return 0
        try:
            with open(sf, encoding="utf-8") as f:
                send("agent.view.set", json.load(f))
        except (OSError, ValueError):
            pass
        return 0

    sys.stderr.write("usage: view.py {set|clear|restore}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
