#!/usr/bin/env python3
"""Add / remove the $reason row in config.toml's ui.sidebar.agents.rows.

This does not parse the file as TOML; it treats the edit as the insertion and
deletion of an exactly-matching string. That preserves comments and formatting,
and makes add -> remove round-trip byte for byte.
"""
import os
import re
import sys

ROW_TEXT = '[{ token = "$reason", fg = "%s", bold = true }]' % os.environ.get(
    "ISLAND_REASON_FG", "#f38ba8"
)

# What to write when rows has to be created from scratch: herdr's default rows
# (state_icon/workspace/tab and the agent name) plus Island's own row. rows is
# all-or-nothing in herdr, so leaving the defaults out would wipe the state icon
# and the agent name too. Both BLOCK and TABLE_INSERT build on this, so any
# change here has to work for both.
DEFAULT_ROWS_LINE = (
    'rows = [["state_icon", "workspace", "tab"], ["agent"], %s]' % ROW_TEXT
)

# Case C: append the whole thing when there is no [ui.sidebar.agents] table
BLOCK = """
# >>> island >>>
[ui.sidebar.agents]
%s
# <<< island <<<
""" % DEFAULT_ROWS_LINE

# Case D: the table exists but has no rows key — insert a single line into its
# body. Adding a fresh table header the way BLOCK does would fail config check,
# because TOML forbids defining the same table twice (I3). So no header: just
# slip the rows line inside the existing table.
TABLE_INSERT = "%s\n" % DEFAULT_ROWS_LINE

# Case A1: a multi-line rows whose last existing element *does* have a trailing
# comma. Adding one line just before the closing ] keeps the separators correct.
MULTILINE_INSERT = "  %s,\n" % ROW_TEXT

# Case A2: a multi-line rows whose last existing element does *not* have a
# trailing comma (I2). Prefixing MULTILINE_INSERT as-is would produce
#   ["agent"]
#     [{ token = "$reason", ... }],
#   ]
# — two elements sitting next to each other with no separating comma, which is
# invalid TOML. So supply the missing comma right after the last element while
# adding our own line.
# Our own line deliberately gets no trailing comma. That matches the original
# style ("arrays written this way separate elements with commas and leave none
# after the last one"), and it also keeps remove() from mangling the file: with
# a trailing comma our text would be character-for-character identical to the
# "  ROW,\n" that MULTILINE_INSERT inserts, and remove() could no longer tell an
# A1-shaped file from an A2-shaped one.
MULTILINE_INSERT_NO_COMMA = ",\n  %s" % ROW_TEXT

# Case B: a single-line rows
INLINE_INSERT = ", %s" % ROW_TEXT

# Matching ignores the value of fg.
#
# ROW_TEXT's colour changes with ISLAND_REASON_FG. If matching were exact, a
# config applied with a custom colour would not match a revert run without one:
# rc 10 (no change needed) comes back and the row is left stranded in the config.
# From the user's side that reads as "I reverted and it did not go away", and
# removing it would require remembering which env var was set at the time. add
# has the same failure in reverse and would insert a second copy.
#
# Identity rests on token = "$reason", not on the colour, so allow any fg value.
# All five insertion shapes contain ROW_TEXT exactly once, so substituting that
# one part is enough — no need to maintain a second template per shape.
ROW_LAX_SRC = (
    re.escape('[{ token = "$reason", fg = "')
    + r'[^"]*'
    + re.escape('", bold = true }]')
)


def _lax(chunk):
    """Regex for chunk with its ROW_TEXT relaxed to accept any fg value."""
    head, _, tail = chunk.partition(ROW_TEXT)
    return re.compile(re.escape(head) + ROW_LAX_SRC + re.escape(tail))


# Grab from `rows = [` to its matching ]. Only a rows at the start of a line counts.
ROWS_RE = re.compile(r"(?m)^([ \t]*)rows[ \t]*=[ \t]*\[")

# The target table's header, and the next table header (= where it ends)
TABLE_RE = re.compile(r"(?m)^[ \t]*\[ui\.sidebar\.agents\][ \t]*$")
NEXT_TABLE_RE = re.compile(r"(?m)^[ \t]*\[")


def agents_table_span(text):
    """Return the body span of the [ui.sidebar.agents] table, or None.

    The span runs from just after the header to just before the next table
    header. A child table such as [ui.sidebar.agents.rows_by_agent] counts as
    "the next header" too — any rows in there is not ours to touch.
    """
    m = TABLE_RE.search(text)
    if not m:
        return None
    start = m.end()
    nxt = NEXT_TABLE_RE.search(text, start)
    return (start, nxt.start() if nxt else len(text))


def find_rows_span(text, table=None):
    """Return the positions of the rows array's [ and its matching ], or None.

    The search is confined to the [ui.sidebar.agents] table. Taking the first
    `rows =` in the whole file would insert into the wrong place in any config
    where, say, [ui.sidebar.workspaces] comes first. That result is still valid
    TOML, so herdr config check passes, and doctor greps the whole file so it
    reports "present" as well — every diagnostic answers "fine" while the edit
    is wrong. Hence the need to bound the range.

    Passing table skips recomputing agents_table_span().
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
    """Position of the last non-whitespace (space/tab/newline) char before hi."""
    i = hi - 1
    while i >= 0 and text[i] in " \t\r\n":
        i -= 1
    return i


def _insert_after_line(text, pos):
    """Position just after the line containing pos (start of the next line).

    Falls back to the end of the text when there is no newline.
    """
    nl = text.find("\n", pos)
    return nl + 1 if nl != -1 else len(text)


def add(text):
    if _lax(ROW_TEXT).search(text):
        return None  # Idempotent. A row in a different colour still counts as present.
    table = agents_table_span(text)
    if table is None:
        # Case C: no table at all
        return text + BLOCK
    span = find_rows_span(text, table)
    if span is None:
        # Case D: the table exists but has no rows key (I3). Appending BLOCK
        # as-is would define [ui.sidebar.agents] twice and break the TOML.
        # Slip in just the rows line right after the header.
        insert_at = _insert_after_line(text, table[0])
        return text[:insert_at] + TABLE_INSERT + text[insert_at:]
    open_at, close_at = span
    body = text[open_at : close_at + 1]
    # An empty array has no "last element", so handle it before the A1/A2/B
    # branches that decide comma placement from the existing contents. Put this
    # after those branches instead and an empty multi-line array like
    # rows = [\n] would have its "last element" misidentified.
    if text[open_at + 1 : close_at].strip() == "":
        if "\n" in body:
            # Add just before the line holding the closing ]. The result is
            # shaped exactly like A1, so remove() needs no extra shape.
            line_start = text.rfind("\n", 0, close_at) + 1
            return text[:line_start] + MULTILINE_INSERT + text[line_start:]
        # Single-line empty array. A separator here gives `rows = [, ROW]`, invalid TOML.
        return text[:close_at] + ROW_TEXT + text[close_at:]
    if "\n" in body:
        last = _last_nonspace_before(text, close_at)
        if text[last] == ",":
            # Case A1: a trailing comma is already there. Add one line just
            # before the line holding the closing ].
            line_start = text.rfind("\n", 0, close_at) + 1
            return text[:line_start] + MULTILINE_INSERT + text[line_start:]
        # Case A2: no trailing comma (I2). Supply the comma right after the
        # last element while adding our own line.
        insert_at = last + 1
        return text[:insert_at] + MULTILINE_INSERT_NO_COMMA + text[insert_at:]
    # Case B: add inline just before the closing ] (empty arrays handled above)
    return text[:close_at] + INLINE_INSERT + text[close_at:]


def remove(text):
    # The order here follows the containment relationships between the five
    # insertion shapes. Checking a shorter shape first would strip only that
    # fragment out of a file that actually holds a longer one, so always check
    # the longer / more specific shape first.
    #
    # 1) BLOCK ⊃ TABLE_INSERT ⊃ INLINE_INSERT
    #    BLOCK contains DEFAULT_ROWS_LINE (= TABLE_INSERT's content) verbatim,
    #    and DEFAULT_ROWS_LINE itself contains ", " + ROW_TEXT (= INLINE_INSERT).
    #    Hence the order BLOCK -> TABLE_INSERT -> INLINE_INSERT.
    #
    # 2) MULTILINE_INSERT_NO_COMMA (NC below) and MULTILINE_INSERT (M below)
    #    look unrelated, but the precondition for choosing M — that the text
    #    just before the insertion point ends in "comma + newline" — means a
    #    file that M edited happens to contain NC's exact content
    #    (",\n  " + ROW_TEXT) straddling the boundary: the pre-existing trailing
    #    comma+newline is immediately followed by the ROW_TEXT part of the line
    #    M added. Stripping NC there is still safe, though: M's own trailing
    #    comma+newline stays behind and plays the role of the original trailing
    #    comma+newline, so the result is byte-identical to the original (both
    #    cases verified for real).
    #    The reverse never happens — M (two spaces + ROW_TEXT + ",\n") cannot
    #    turn up in a file NC edited, because NC puts no comma on its own line,
    #    so the sequence "ROW_TEXT,\n" is never created in the first place.
    #    Given that asymmetry, check NC first: it is the one that is safe to hit.
    # 3) Bare ROW_TEXT (the shape inserted into an empty rows = [] with no
    #    separator) is a substring of all five shapes above, so it must be
    #    checked last. Check it earlier and whichever shape is actually present
    #    loses only its ROW_TEXT part, leaving a separating comma stranded and
    #    the TOML invalid.
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
    return None  # Nothing here matches a shape we inserted


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
