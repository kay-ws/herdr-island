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

# assert_toml_valid <ファイル> <メッセージ> : stdlib tomllib で read-only parse できることを確かめる
assert_toml_valid() {
  local file="$1" msg="$2"
  if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$file" 2>/dev/null; then
    printf 'ok   %s\n' "$msg"
  else
    printf 'FAIL %s\n  %q は有効な TOML でない\n' "$msg" "$file" >&2
    _fail=1
  fi
}

# --- ケース A1: 複数行の rows、末尾カンマ「あり」 ---
roundtrip multiline '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "workspace"],
  ["agent"],
]
'

# --- ケース A2 (I2): 複数行の rows、末尾カンマ「無し」 ---
# 末尾カンマの無い配列は珍しくないスタイルで、README のサンプル自体も
# たまたま末尾カンマ付きなだけ。ここに区切りカンマを補わないと
# ["agent"] の直後に次要素が続き、無効な TOML を吐いて apply が失敗する。
roundtrip multiline_no_comma '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "workspace"],
  ["agent"]
]
'
assert_toml_valid "$WORK/multiline_no_comma.added" \
  "multiline_no_comma: add 後が有効な TOML（I2 の直接検出）"

# --- ケース B: 1 行の rows ---
roundtrip inline '[ui.sidebar.agents]
rows = [["state_icon", "workspace"], ["agent"]]
'

# --- ケース D (I3): テーブルはあるが rows キーが無い ---
# bin/setup.sh が警告する「rows_by_agent だけを設定している」利用者と同じ
# 状態。BLOCK をそのまま追記すると [ui.sidebar.agents] を二重定義して
# config check に落ちる。
roundtrip table_no_rows '[ui.sidebar.agents]
row_gap = 0
'
assert_toml_valid "$WORK/table_no_rows.added" \
  "table_no_rows: add 後が有効な TOML"

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

# --- I1: 別テーブルの rows を掴まないこと ---
# ファイル内の最初の `rows =` を拾う実装だと、先に別テーブルがある config で
# そちらへ挿入してしまう。TOML として妥当なので config check は通り、
# doctor もファイル全体を grep するので「あり」と報告する = 全診断が正常と言う誤り
cat > "$WORK/other.toml" <<'EOF'
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"]]

[ui.sidebar.agents]
rows = [["agent"]]
EOF
python3 "$R" add "$WORK/other.toml" > "$WORK/other.added"
assert_eq "0" "$?" "別テーブルがあっても add は 0"
# spaces 側は無傷、agents 側にだけ入ること
spaces_line="$(grep -n 'ui.sidebar.spaces' -A1 "$WORK/other.added" | tail -1)"
assert_eq "no" "$(printf '%s' "$spaces_line" | grep -qF 'reason' && echo yes || echo no)" \
  "spaces テーブルの rows には入らない"
agents_line="$(grep -n 'ui.sidebar.agents' -A1 "$WORK/other.added" | tail -1)"
assert_eq "yes" "$(printf '%s' "$agents_line" | grep -qF 'reason' && echo yes || echo no)" \
  "agents テーブルの rows に入る"

# --- 子テーブルの rows を掴まないこと（かつ I3 の実例：rows キー不在） ---
cat > "$WORK/child.toml" <<'EOF'
[ui.sidebar.agents]
row_gap = 0

[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
EOF
python3 "$R" add "$WORK/child.toml" > "$WORK/child.added"
assert_eq "0" "$?" "child: rows_by_agent だけの config でも add は 0"
assert_eq "no" "$(grep -A2 'rows_by_agent' "$WORK/child.added" | grep -qF 'reason' && echo yes || echo no)" \
  "rows_by_agent の中には絶対に入れない"
assert_toml_valid "$WORK/child.added" "child: add 後が有効な TOML"
python3 "$R" remove "$WORK/child.added" > "$WORK/child.back"
assert_eq "0" "$(cmp -s "$WORK/child.toml" "$WORK/child.back" && echo 0 || echo 1)" \
  "child: add -> remove で元とバイト一致"


# --- 空配列（controller の独立検証で発覚。実装者のケース列挙に無かった形）---
# rows = [] に `, ROW` を足すと `rows = [, ROW]` と先頭カンマになり不正な TOML。
# I2（末尾カンマが無い）と同じ「カンマの要否を中身で決める」問題の裏返し。
# 空かつ複数行（rows = [\n]）は「最後の要素」が存在しないので、
# カンマ判定の手前で処理しないと複数行パスが誤認する
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

# --- ISLAND_REASON_FG: 色をまたいでも往復すること ---
# 色を指定して apply した config を、指定せずに revert する経路。照合を
# 完全一致でやっていた頃は ROW_TEXT が一致せず rc 10（変更不要）が返り、
# 行が config に取り残された —— 利用者から見ると「revert したのに消えない」で、
# 消すには当時の環境変数を思い出す必要がある。同一性の根拠は色ではなく
# token = "$reason" の方なので、fg の値は照合から外してある。
# 5 つの挿入形すべてで確かめる（形ごとに前後の文脈が違い、緩めた正規表現が
# 効くかは形ごとに独立に壊れ得る）
cross_color() {
  local name="$1" body="$2"
  local orig="$WORK/$name.cc.toml"
  printf '%s' "$body" > "$orig"

  ISLAND_REASON_FG='#00ff00' python3 "$R" add "$orig" > "$WORK/$name.cc.added"
  assert_contains "$(cat "$WORK/$name.cc.added")" '#00ff00' "$name: 指定した色で入る"

  # 色違いで既に入っているものを二重に足さない
  ISLAND_REASON_FG='#123456' python3 "$R" add "$WORK/$name.cc.added" >/dev/null 2>&1
  assert_eq "10" "$?" "$name: 色違いで入っていても add は 10"

  # 環境変数を指定せずに remove（= 既定色で照合される）
  python3 "$R" remove "$WORK/$name.cc.added" > "$WORK/$name.cc.back"
  assert_eq "0" "$?" "$name: 色違いでも remove は 0"
  assert_eq "0" "$(cmp -s "$orig" "$WORK/$name.cc.back" && echo 0 || echo 1)" \
    "$name: 色を指定して add -> 指定せず remove で元とバイト一致"
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
