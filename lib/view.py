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
    # herdr の応答を読まずに True を返すと、herdr がリクエストを拒否した
    # ケース（パラメータ名の誤り・必須フィールド欠落・スキーマ変更後の互換切れ）
    # まで「成功」扱いになる。可視症状は「ボタンを押しても何も起きない」で、
    # エラーがどこにも出ない。1 行の応答を読んで error キーの有無で判定し、
    # 拒否ならメッセージを stderr に出す。settimeout は維持したまま —
    # 応答が返らないサーバに無応答のまま待たされて呼び出し元がハングしない
    # ようにする。timeout も OSError のサブクラスなのでここで失敗として拾われる
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

    # state ファイルの意味は「サーバに実際に伝えた内容」であって
    # 「ユーザーが望んでいる状態」ではない。restore の役目はサーバ再起動で
    # 消えた view の復元なので、一度も適用されていない view を保存すると
    # restore が嘘をつく（herdr 未起動時に focus を叩いた人が、次回起動時に
    # 理由の分からない絞り込み画面に出会う）。よって送信成功時のみ更新する。
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
