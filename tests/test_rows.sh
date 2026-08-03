#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

R="$here/../lib/rows.py"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# roundtrip <名前> <元の内容> : add -> remove でバイト一致することを確かめる
roundtrip() {
  local name="$1" body="$2"
  local orig="$WORK/$name.toml"
  printf '%s' "$body" > "$orig"

  python3 "$R" add "$orig" > "$WORK/$name.added"
  assert_eq "0" "$?" "$name: add は 0 を返す"
  assert_contains "$(cat "$WORK/$name.added")" '$reason' "$name: add で \$reason が入る"

  python3 "$R" remove "$WORK/$name.added" > "$WORK/$name.back"
  assert_eq "0" "$(cmp -s "$orig" "$WORK/$name.back" && echo 0 || echo 1)" \
    "$name: add -> remove で元とバイト一致"
}

# --- ケース A: 複数行の rows ---
roundtrip multiline '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "workspace"],
  ["agent"],
]
'

# --- ケース B: 1 行の rows ---
roundtrip inline '[ui.sidebar.agents]
rows = [["state_icon", "workspace"], ["agent"]]
'

# --- ケース C: テーブルが無い ---
roundtrip absent '[ui]
sidebar_width = 30
'

# --- 冪等性 ---
printf '%s' '[ui.sidebar.agents]
rows = [["agent"]]
' > "$WORK/idem.toml"
python3 "$R" add "$WORK/idem.toml" > "$WORK/idem.1"
python3 "$R" add "$WORK/idem.1" > "$WORK/idem.2"
rc=$?
assert_eq "10" "$rc" "既に行があれば rc=10（変更不要）"
assert_eq "0" "$(cmp -s "$WORK/idem.1" "$WORK/idem.2" && echo 0 || echo 1)" \
  "2 回目の add で内容が変わらない"

# --- 他人の行を壊さない（usagebar 共存） ---
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
  assert_contains "$(cat "$WORK/co.added")" "$t" "usagebar の $t が保持される"
done

# --- 利用者が手で変えた行は削除しない ---
printf '%s' '[ui.sidebar.agents]
rows = [
  ["agent"],
  [{ token = "$reason", fg = "#ffffff" }],
]
' > "$WORK/mine.toml"
python3 "$R" remove "$WORK/mine.toml" > "$WORK/mine.out"
assert_eq "10" "$?" "完全一致しない \$reason 行は rc=10 で残す"
assert_contains "$(cat "$WORK/mine.out")" '#ffffff' "利用者の行はそのまま残る"

finish
