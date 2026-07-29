#!/usr/bin/env python3
"""stdin の JSON-RPC リクエスト 1 行を herdr の socket へ送る。

なぜ CLI を使わないか
--------------------
herdr 0.7.5 の `herdr pane report-metadata` は --source に値を渡せない。
help は `[OPTIONS] --source <ID> <PANE_ID>` と書いているが実装が対応しておらず、
`--source hj` は "unknown option: hj"、`--source=hj` は認識されず
"missing required --source" になる。位置引数の <PANE_ID> も常に拒否される。
(--token と --seq はスペース形式で通るので --source 固有の不具合)

herdr 公式のフック herdr-agent-state.sh も CLI を使わず socket を直接叩いて
いるので、こちらが herdr の想定する経路。

不変条件
--------
何があっても exit 0 する。表示が出ないのは許容できるが、非ゼロ終了で
エージェントの動作に影響を与えるのは許容できない。
"""

import os
import socket
import sys


def send() -> None:
    path = os.environ.get("HERDR_SOCKET_PATH", "")
    if not path:
        return

    payload = sys.stdin.buffer.read().strip()
    if not payload:
        return

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    try:
        sock.connect(path)
        sock.sendall(payload + b"\n")
        # 応答は読み捨てる。読まずに閉じると相手側が EPIPE を見るため一応受ける
        sock.recv(4096)
    finally:
        sock.close()


try:
    send()
except Exception:
    pass

sys.exit(0)
