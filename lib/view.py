#!/usr/bin/env python3
"""agent.view.set / agent.view.clear を socket へ送る。

agent.view.* には CLI ラッパが無いため socket 直叩き。view は揮発性
（サーバ終了・プラグインの無効化で消える）なので、送った params を
STATE_DIR に保存し [[startup]] から再適用する。
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
    path = os.environ.get("HERDR_SOCKET_PATH")
    if not path:
        return False
    req = json.dumps({"id": "island", "method": method, "params": params})
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(path)
        s.sendall(req.encode("utf-8") + b"\n")
        s.close()
        return True
    except OSError:
        return False


def main():
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    sf = state_file()

    if op == "set":
        send("agent.view.set", PARAMS)
        if sf:
            with open(sf, "w", encoding="utf-8") as f:
                json.dump(PARAMS, f)
        return 0

    if op == "clear":
        send("agent.view.clear", {"source": SOURCE})
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
