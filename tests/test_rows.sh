#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

R="$here/../lib/rows.py"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# roundtrip <name> <original content> : check that add -> remove is byte-identical
roundtrip() {
  local name="$1" body="$2"
  local orig="$WORK/$name.toml"
  printf '%s' "$body" > "$orig"

  python3 "$R" add "$orig" > "$WORK/$name.added"
  assert_eq "0" "$?" "$name: add returns 0"
  assert_contains "$(cat "$WORK/$name.added")" '$reason' "$name: add inserts \$reason"

  python3 "$R" remove "$WORK/$name.added" > "$WORK/$name.back"
  assert_eq "0" "$(cmp -s "$orig" "$WORK/$name.back" && echo 0 || echo 1)" \
    "$name: add -> remove is byte-identical to the original"
}

# assert_toml_valid <file> <message> : check it read-only parses with stdlib tomllib
assert_toml_valid() {
  local file="$1" msg="$2"
  if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$file" 2>/dev/null; then
    printf 'ok   %s\n' "$msg"
  else
    printf 'FAIL %s\n  %q is not valid TOML\n' "$msg" "$file" >&2
    _fail=1
  fi
}

# --- Case A1: multi-line rows, trailing comma present ---
roundtrip multiline '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "workspace"],
  ["agent"],
]
'

# --- Case A2 (I2): multi-line rows, no trailing comma ---
# Arrays without a trailing comma are a perfectly common style; the README
# sample merely happens to have one. Without supplying the separating comma
# here, the next element follows straight after ["agent"], producing invalid
# TOML and making apply fail.
roundtrip multiline_no_comma '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "workspace"],
  ["agent"]
]
'
assert_toml_valid "$WORK/multiline_no_comma.added" \
  "multiline_no_comma: valid TOML after add (direct detection of I2)"

# --- Case B: single-line rows ---
roundtrip inline '[ui.sidebar.agents]
rows = [["state_icon", "workspace"], ["agent"]]
'

# --- Case D (I3): the table exists but has no rows key ---
# The same state as the "only rows_by_agent is configured" user that
# bin/setup.sh warns about. Appending BLOCK as-is would define
# [ui.sidebar.agents] twice and fail config check.
roundtrip table_no_rows '[ui.sidebar.agents]
row_gap = 0
'
assert_toml_valid "$WORK/table_no_rows.added" \
  "table_no_rows: valid TOML after add"

# --- Case C: no table at all ---
roundtrip absent '[ui]
sidebar_width = 30
'

# --- idempotence ---
printf '%s' '[ui.sidebar.agents]
rows = [["agent"]]
' > "$WORK/idem.toml"
python3 "$R" add "$WORK/idem.toml" > "$WORK/idem.1"
python3 "$R" add "$WORK/idem.1" > "$WORK/idem.2"
rc=$?
assert_eq "10" "$rc" "an existing row gives rc=10 (no change needed)"
assert_eq "0" "$(cmp -s "$WORK/idem.1" "$WORK/idem.2" && echo 0 || echo 1)" \
  "a second add changes nothing"

# --- do not break anyone else's rows (coexisting with usagebar) ---
printf '%s' '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "$title"],
  ["$provider", "$limit"],
  ["$context"],
]
' > "$WORK/co.toml"
python3 "$R" add "$WORK/co.toml" > "$WORK/co.added"
for t in '$title' '$provider' '$limit' '$context'; do
  assert_contains "$(cat "$WORK/co.added")" "$t" "the usagebar $t is preserved"
done

# --- never delete a row the user edited by hand ---
printf '%s' '[ui.sidebar.agents]
rows = [
  ["agent"],
  [{ token = "$reason", fg = "#ffffff" }],
]
' > "$WORK/mine.toml"
python3 "$R" remove "$WORK/mine.toml" > "$WORK/mine.out"
assert_eq "10" "$?" "a \$reason row that does not match exactly is kept, rc=10"
assert_contains "$(cat "$WORK/mine.out")" '#ffffff' "the user's row survives untouched"

# --- I1: never grab the rows of a different table ---
# An implementation that takes the first `rows =` in the file would insert into
# the wrong place in any config where another table comes first. That is valid
# TOML so config check passes, and doctor greps the whole file so it reports
# "present" = every diagnostic says fine while the edit is wrong.
cat > "$WORK/other.toml" <<'EOF'
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"]]

[ui.sidebar.agents]
rows = [["agent"]]
EOF
python3 "$R" add "$WORK/other.toml" > "$WORK/other.added"
assert_eq "0" "$?" "add returns 0 even with another table present"
# The spaces side stays untouched; only the agents side gets the row
spaces_line="$(grep -n 'ui.sidebar.spaces' -A1 "$WORK/other.added" | tail -1)"
assert_eq "no" "$(printf '%s' "$spaces_line" | grep -qF 'reason' && echo yes || echo no)" \
  "nothing goes into the rows of the spaces table"
agents_line="$(grep -n 'ui.sidebar.agents' -A1 "$WORK/other.added" | tail -1)"
assert_eq "yes" "$(printf '%s' "$agents_line" | grep -qF 'reason' && echo yes || echo no)" \
  "it goes into the rows of the agents table"

# --- never grab a child table's rows (also a live example of I3: no rows key) ---
cat > "$WORK/child.toml" <<'EOF'
[ui.sidebar.agents]
row_gap = 0

[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
EOF
python3 "$R" add "$WORK/child.toml" > "$WORK/child.added"
assert_eq "0" "$?" "child: add returns 0 even for a rows_by_agent-only config"
assert_eq "no" "$(grep -A2 'rows_by_agent' "$WORK/child.added" | grep -qF 'reason' && echo yes || echo no)" \
  "nothing is ever written inside rows_by_agent"
assert_toml_valid "$WORK/child.added" "child: valid TOML after add"
python3 "$R" remove "$WORK/child.added" > "$WORK/child.back"
assert_eq "0" "$(cmp -s "$WORK/child.toml" "$WORK/child.back" && echo 0 || echo 1)" \
  "child: add -> remove is byte-identical to the original"


# --- empty arrays (surfaced by independent review; absent from the original case list) ---
# Adding `, ROW` to rows = [] yields `rows = [, ROW]` — a leading comma, invalid
# TOML. It is the mirror image of I2 (no trailing comma): the same "decide comma
# placement from the contents" problem. An empty *and* multi-line array
# (rows = [\n]) has no "last element", so unless it is handled before the comma
# decision, the multi-line path misidentifies one.
roundtrip empty_inline '[ui.sidebar.agents]
rows = []
'
roundtrip empty_spaced '[ui.sidebar.agents]
rows = [   ]
'
roundtrip empty_multiline '[ui.sidebar.agents]
rows = [
]
'

# --- ISLAND_REASON_FG: the round trip must survive a colour change ---
# The path where a config applied with a colour is reverted without one. Back
# when matching was exact, ROW_TEXT failed to match, rc 10 (no change needed)
# came back, and the row was left stranded in the config — from the user's side
# "I reverted and it did not go away", removable only by remembering which env
# var was set at the time. Identity rests on token = "$reason", not the colour,
# so the fg value is excluded from matching.
# Check all five insertion shapes: each has different surrounding context, and
# whether the relaxed regex works can break independently per shape.
cross_color() {
  local name="$1" body="$2"
  local orig="$WORK/$name.cc.toml"
  printf '%s' "$body" > "$orig"

  ISLAND_REASON_FG='#00ff00' python3 "$R" add "$orig" > "$WORK/$name.cc.added"
  assert_contains "$(cat "$WORK/$name.cc.added")" '#00ff00' "$name: it goes in with the given colour"

  # Do not add a second copy when one is already there in a different colour
  ISLAND_REASON_FG='#123456' python3 "$R" add "$WORK/$name.cc.added" >/dev/null 2>&1
  assert_eq "10" "$?" "$name: add returns 10 even when the existing row differs in colour"

  # remove without the env var (= matched against the default colour)
  python3 "$R" remove "$WORK/$name.cc.added" > "$WORK/$name.cc.back"
  assert_eq "0" "$?" "$name: remove returns 0 across a colour difference"
  assert_eq "0" "$(cmp -s "$orig" "$WORK/$name.cc.back" && echo 0 || echo 1)" \
    "$name: add with a colour -> remove without one is byte-identical to the original"
}

cross_color cc_multiline '[ui.sidebar.agents]
rows = [
  ["state_icon", "workspace"],
  ["agent"],
]
'
cross_color cc_multiline_no_comma '[ui.sidebar.agents]
rows = [
  ["state_icon", "workspace"],
  ["agent"]
]
'
cross_color cc_inline '[ui.sidebar.agents]
rows = [["state_icon", "workspace"], ["agent"]]
'
cross_color cc_empty '[ui.sidebar.agents]
rows = []
'
cross_color cc_table_no_rows '[ui.sidebar.agents]
row_gap = 0
'
cross_color cc_absent '[ui]
sidebar_width = 30
'

finish
