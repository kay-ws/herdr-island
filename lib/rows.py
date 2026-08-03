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

# rows を新規に書き起こす場合の内容。herdr の既定行（state_icon/workspace/tab
# と agent 名）+ Island 自身の行。rows は herdr では all-or-nothing なので、
# 既定行を含めないと state アイコンや agent 名まで消える。BLOCK と
# TABLE_INSERT の両方がこれを使うので、変えるときは両方に効く形にしておく。
DEFAULT_ROWS_LINE = (
    'rows = [["state_icon", "workspace", "tab"], ["agent"], %s]' % ROW_TEXT
)

# ケース C: [ui.sidebar.agents] テーブルごと無い場合に丸ごと追記する
BLOCK = """
# >>> island >>>
[ui.sidebar.agents]
%s
# <<< island <<<
""" % DEFAULT_ROWS_LINE

# ケース D: テーブルはあるが rows キーが無い場合、その本文に 1 行差し込む。
# BLOCK のように新しいテーブル見出しを足すと TOML は同じテーブルの二重定義を
# 禁じているため config check に落ちる（I3）。見出しは足さず、既存テーブルの
# 中に rows 行だけを挿む。
TABLE_INSERT = "%s\n" % DEFAULT_ROWS_LINE

# ケース A1: 複数行の rows で、既存の最後の要素に末尾カンマが「ある」場合。
# 閉じ ] の行の直前に 1 行足すだけで区切りが揃う。
MULTILINE_INSERT = "  %s,\n" % ROW_TEXT

# ケース A2: 複数行の rows で、既存の最後の要素に末尾カンマが「無い」場合
# （I2）。MULTILINE_INSERT をそのまま前置すると
#   ["agent"]
#     [{ token = "$reason", ... }],
#   ]
# のように区切りカンマが無いまま 2 要素が並び、無効な TOML になる。
# 末尾要素の直後（カンマが無い箇所）にカンマを補いながら自分の行を足す。
# 自分の行自体には末尾カンマを付けない — 「このスタイルの配列は要素間だけを
# カンマで区切り、最後の要素にはカンマを置かない」という元の書式に合わせる
# ためであり、これは remove() の巻き込み事故を避けるためでもある。もし末尾に
# もカンマを付けると、MULTILINE_INSERT が挿す "  ROW,\n" と文字面が完全一致
# してしまい、A1 系のファイルと A2 系のファイルを remove() が区別できなくなる。
MULTILINE_INSERT_NO_COMMA = ",\n  %s" % ROW_TEXT

# ケース B: 1 行の rows
INLINE_INSERT = ", %s" % ROW_TEXT

# 照合は fg の値を問わない。
#
# ROW_TEXT は ISLAND_REASON_FG で色が変わる。完全一致だけで照合すると、
# 色を指定して apply した config を、指定せずに revert したときに一致せず
# rc 10（変更不要）が返り、行が config に取り残される —— 利用者から見ると
# 「revert したのに消えない」で、しかも消すには当時の環境変数を思い出す
# 必要がある。同じ理由で add も二重に足してしまう。
#
# 同一性の根拠は色ではなく token = "$reason" の方なので、fg の値だけを
# 任意に許す。5 つの挿入形すべてが ROW_TEXT をちょうど 1 回含むので、
# 形ごとにテンプレートを二重管理せず、そこだけを差し替えれば足りる
ROW_LAX_SRC = (
    re.escape('[{ token = "$reason", fg = "')
    + r'[^"]*'
    + re.escape('", bold = true }]')
)


def _lax(chunk):
    """chunk 中の ROW_TEXT を「fg の値は何でもよい」形に緩めた正規表現。"""
    head, _, tail = chunk.partition(ROW_TEXT)
    return re.compile(re.escape(head) + ROW_LAX_SRC + re.escape(tail))


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


def find_rows_span(text, table=None):
    """rows 配列の [ と対応する ] の位置を返す。無ければ None。

    探索は [ui.sidebar.agents] テーブルの中に限定する。ファイル全体から
    最初の `rows =` を拾うと、先に [ui.sidebar.workspaces] などがある config で
    そちらへ挿入してしまう。TOML としては妥当なので herdr config check は通り、
    doctor もファイル全体を grep するため「あり」と報告する ——
    全ての診断が正常と答える誤りになるため、範囲の限定が要る。

    table を渡すと agents_table_span() の再計算を省く。
    """
    if table is None:
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


def _last_nonspace_before(text, hi):
    """hi の手前にある、空白類（スペース/タブ/改行）を除いた最後の文字の位置を返す。"""
    i = hi - 1
    while i >= 0 and text[i] in " \t\r\n":
        i -= 1
    return i


def _insert_after_line(text, pos):
    """pos を含む行の直後（次の行の先頭）の位置を返す。改行が無ければ末尾。"""
    nl = text.find("\n", pos)
    return nl + 1 if nl != -1 else len(text)


def add(text):
    if _lax(ROW_TEXT).search(text):
        return None  # 冪等。色違いで入っていても「もうある」と見る
    table = agents_table_span(text)
    if table is None:
        # ケース C: テーブルごと無い
        return text + BLOCK
    span = find_rows_span(text, table)
    if span is None:
        # ケース D: テーブルはあるが rows キーが無い（I3）。BLOCK をそのまま
        # 追記すると [ui.sidebar.agents] を二重定義してしまい TOML が壊れる。
        # 見出し行の直後に rows 行だけを差し込む。
        insert_at = _insert_after_line(text, table[0])
        return text[:insert_at] + TABLE_INSERT + text[insert_at:]
    open_at, close_at = span
    body = text[open_at : close_at + 1]
    # 空配列は「最後の要素」が存在しないので、カンマの要否を中身から
    # 決める A1/A2/B の判定に先立って処理する。ここを分岐の後ろに置くと、
    # rows = [\n] のように空かつ複数行の配列で「最後の要素」を誤認する
    if text[open_at + 1 : close_at].strip() == "":
        if "\n" in body:
            # 閉じ ] を含む行の直前に足す。結果は A1 と同一形になるので
            # remove 側に新しい形を増やさずに済む
            line_start = text.rfind("\n", 0, close_at) + 1
            return text[:line_start] + MULTILINE_INSERT + text[line_start:]
        # 単一行の空配列。区切りを付けると `rows = [, ROW]` になり不正な TOML
        return text[:close_at] + ROW_TEXT + text[close_at:]
    if "\n" in body:
        last = _last_nonspace_before(text, close_at)
        if text[last] == ",":
            # ケース A1: 既に末尾カンマがある。閉じ ] を含む行の直前に 1 行足す
            line_start = text.rfind("\n", 0, close_at) + 1
            return text[:line_start] + MULTILINE_INSERT + text[line_start:]
        # ケース A2: 末尾カンマが無い（I2）。最後の要素の直後にカンマを
        # 補いながら自分の行を足す
        insert_at = last + 1
        return text[:insert_at] + MULTILINE_INSERT_NO_COMMA + text[insert_at:]
    # ケース B: 閉じ ] の直前にインラインで足す（空配列は上で処理済み）
    return text[:close_at] + INLINE_INSERT + text[close_at:]


def remove(text):
    # 5 つの挿入形の間にある包含関係を踏まえた順序。短い方を先に調べると、
    # 長い方が実際に入っているファイルでも短い方の部分だけを誤って剥がして
    # しまうため、常に「長い/より具体的な形」を先に調べる。
    #
    # 1) BLOCK ⊃ TABLE_INSERT ⊃ INLINE_INSERT
    #    BLOCK は DEFAULT_ROWS_LINE（= TABLE_INSERT の中身）をそのまま含み、
    #    DEFAULT_ROWS_LINE 自体が ", " + ROW_TEXT（= INLINE_INSERT）を含む。
    #    よって BLOCK -> TABLE_INSERT -> INLINE_INSERT の順で調べる。
    #
    # 2) MULTILINE_INSERT_NO_COMMA (以下 NC) と MULTILINE_INSERT (以下 M)
    #    は一見無関係だが、M を選ぶ前提（挿入直前が「カンマ+改行」で終わる
    #    こと）のせいで、M を挿入したファイルには NC の内容
    #    (",\n  " + ROW_TEXT) が境界をまたいで偶然そのまま現れる
    #    ——「元々あった末尾カンマ+改行」の直後に「M が足した行の
    #    ROW_TEXT 部分」が続くため。だが NC をそこで剥がしても、
    #    M 自身の末尾カンマ+改行がそのまま元の末尾カンマ+改行として
    #    残るので、結果は byte 一致で元に戻る（両ケースとも実際に
    #    確認済み）。
    #    逆に M (2 スペース + ROW_TEXT + ",\n") が NC を挿入した
    #    ファイルに紛れ込むことは無い——NC は自分の行にカンマを
    #    付けないので、"ROW_TEXT,\n" という並びがそもそも生まれない。
    #    この非対称性から、衝突しても安全な NC を先に調べる。
    # 3) 素の ROW_TEXT（空配列 rows = [] に区切り無しで入れた形）は
    #    上記 5 形すべての部分文字列なので、必ず最後に調べる。先に調べると
    #    どの形で入っていても ROW_TEXT 部分だけが剥がれ、区切りのカンマが
    #    孤立して不正な TOML になる
    for chunk in (
        BLOCK,
        TABLE_INSERT,
        MULTILINE_INSERT_NO_COMMA,
        MULTILINE_INSERT,
        INLINE_INSERT,
        ROW_TEXT,
    ):
        m = _lax(chunk).search(text)
        if m:
            return text[: m.start()] + text[m.end() :]
    return None  # 自分が入れた形と一致するものが無い


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
