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

# 対象テーブルの見出しと、次のテーブル見出し（=テーブルの終端）
TABLE_RE = re.compile(r"(?m)^[ \t]*\[ui\.sidebar\.agents\][ \t]*$")
NEXT_TABLE_RE = re.compile(r"(?m)^[ \t]*\[")


def agents_table_span(text):
    """[ui.sidebar.agents] テーブルの本文範囲を返す。無ければ None。

    範囲は見出しの次から、次のテーブル見出しの直前まで。
    [ui.sidebar.agents.rows_by_agent] のような子テーブルも「次の見出し」
    として扱う（そこにある rows は我々の対象ではない）。
    """
    m = TABLE_RE.search(text)
    if not m:
        return None
    start = m.end()
    nxt = NEXT_TABLE_RE.search(text, start)
    return (start, nxt.start() if nxt else len(text))


def find_rows_span(text):
    """rows 配列の [ と対応する ] の位置を返す。無ければ None。

    探索は [ui.sidebar.agents] テーブルの中に限定する。ファイル全体から
    最初の `rows =` を拾うと、先に [ui.sidebar.workspaces] などがある config で
    そちらへ挿入してしまう。TOML としては妥当なので herdr config check は通り、
    doctor もファイル全体を grep するため「あり」と報告する ——
    全ての診断が正常と答える誤りになるため、範囲の限定が要る。
    """
    table = agents_table_span(text)
    if table is None:
        return None
    lo, hi = table
    m = ROWS_RE.search(text, lo, hi)
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
