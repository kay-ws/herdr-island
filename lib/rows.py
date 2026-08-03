#!/usr/bin/env python3
"""config.toml の ui.sidebar.agents.rows へ $reason の行を足す / 外す。

TOML として parse せず、完全一致する文字列の挿入と削除として扱う。
コメントと整形を壊さず、add -> remove がバイト一致で往復する。
"""
import os
import re
import sys

ROW_TEXT = '[{ token = "$reason", fg = "%s", bold = true }]' % os.environ.get(
    "ISLAND_REASON_FG", "#f38ba8"
)

BLOCK = """
# >>> island >>>
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"], %s]
# <<< island <<<
""" % ROW_TEXT

MULTILINE_INSERT = "  %s,\n" % ROW_TEXT
INLINE_INSERT = ", %s" % ROW_TEXT

# rows = [ から対応する ] までを掴む。行頭の rows のみを対象にする
ROWS_RE = re.compile(r"(?m)^([ \t]*)rows[ \t]*=[ \t]*\[")


def find_rows_span(text):
    """rows 配列の [ と対応する ] の位置を返す。無ければ None"""
    m = ROWS_RE.search(text)
    if not m:
        return None
    open_at = text.index("[", m.end() - 1)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return (open_at, i)
    return None


def add(text):
    if ROW_TEXT in text:
        return None  # 冪等
    span = find_rows_span(text)
    if span is None:
        return text + BLOCK
    open_at, close_at = span
    body = text[open_at : close_at + 1]
    if "\n" in body:
        # ケース A: 閉じ ] を含む行の直前に 1 行足す
        line_start = text.rfind("\n", 0, close_at) + 1
        return text[:line_start] + MULTILINE_INSERT + text[line_start:]
    # ケース B: 閉じ ] の直前にインラインで足す
    return text[:close_at] + INLINE_INSERT + text[close_at:]


def remove(text):
    # BLOCK は自身の rows 行に INLINE_INSERT と同じ文字列
    # (", " + ROW_TEXT) を含むため、BLOCK を先に調べないと
    # ケース C (テーブル不在) で BLOCK 全体ではなく INLINE_INSERT
    # 部分だけを誤って剥がしてしまう。
    for chunk in (MULTILINE_INSERT, BLOCK, INLINE_INSERT):
        if chunk in text:
            return text.replace(chunk, "", 1)
    return None  # 自分が入れた形と完全一致するものが無い


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("add", "remove"):
        sys.stderr.write("usage: rows.py {add|remove} <config.toml>\n")
        return 1
    try:
        with open(sys.argv[2], encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (sys.argv[2], e))
        return 1

    out = add(text) if sys.argv[1] == "add" else remove(text)
    if out is None:
        sys.stdout.write(text)
        return 10
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
