#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

H="$here/../lib/hooks.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export HERDR_PLUGIN_ROOT="$here/.."

# 他人の hook が入った settings.json から始める
cat > "$ISLAND_CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}
]}}
EOF
echo '{}' > "$ISLAND_CODEX_HOOKS"

# --- install ---
bash "$H" install >/dev/null 2>&1
assert_eq "0" "$?" "install は 0 を返す"

# 設定した 2 経路が入っていること。set 専用なので clear は入らない
assert_eq "1" "$(jq '[.hooks.PermissionRequest[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PermissionRequest に 1 エントリ"
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PreToolUse に 1 エントリ"
# --- C2: 指す先が消えても無害な形で配線されていること ---
# herdr plugin uninstall は remove を実行しないのでこのエントリは残る。
# 素に `bash <path>` だと消えたパスで exit 127 になり、以後すべての
# PermissionRequest でエラーが出る（防御は消えたファイルの中にあるので効かない）
cmd="$(jq -r '[.hooks.PermissionRequest[]?.hooks[]? | select(.command | test("island-reason")) | .command] | first' "$ISLAND_CLAUDE_SETTINGS")"
assert_contains "$cmd" 'exit 0' "コマンドに存在確認と exit 0 が含まれる"
# 実際に消えたパスを指させて、非ゼロで落ちないことを確かめる
missing="$(printf '%s' "$cmd" | sed "s#'[^']*/hooks/island-reason.sh'#'/nonexistent/island-reason.sh'#")"
bash -c "$missing" >/dev/null 2>&1
assert_eq "0" "$?" "指す先が無くても exit 0（利用者のエージェントを壊さない）"

assert_eq "AskUserQuestion" "$(jq -r '.hooks.PreToolUse[]
  | select(.hooks[]?.command | test("island-reason")) | .matcher' "$ISLAND_CLAUDE_SETTINGS")" \
  "PreToolUse の matcher は AskUserQuestion"

# clear 系のイベントには配線しない（clear は herdr イベントが担当する）
assert_eq "0" "$(jq '[.hooks.PostToolBatch[]?.hooks[]?, .hooks.Stop[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PostToolBatch / Stop には配線しない"

# 他人の hook を壊していないこと
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command == "other-tool")] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "他人の hook は残る"

# 出力が妥当な JSON であること（壊れた JSON を書いたら次回以降すべて失敗する）
jq empty "$ISLAND_CLAUDE_SETTINGS" 2>/dev/null
assert_eq "0" "$?" "settings.json は妥当な JSON のまま"

# --- 冪等 ---
before="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$H" install >/dev/null 2>&1
assert_eq "10" "$?" "2 回目の install は 10"
assert_eq "$before" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "2 回目で内容が変わらない"

# --- count ---
assert_eq "2" "$(bash "$H" count)" "count は配線済みスロット数を返す"

# 出力が「裸の数値」であること。BSD/macOS の wc -l は先頭を空白で
# パディングするため、値が正しくても文字列比較する呼び出し側で落ちる。
# 実際 CI の macOS ジョブはこれで 5 アサーション落ちた
c="$(bash "$H" count)"
assert_eq "yes" "$(printf '%s' "$c" | grep -qE '^[0-9]+$' && echo yes || echo no)" \
  "count の出力に空白が混じらない（BSD の wc -l 対策）"

# --- status: 部分配線を区別できること ---
# count は両ファイルの和集合なので、片方だけ配線済みでも 2 を返す。
# doctor が最も知りたい「どちらが未配線か」を出せるのは status だけ
assert_contains "$(bash "$H" status)" "claude: 2/2" "status は claude の配線数を出す"
assert_contains "$(bash "$H" status)" "codex: 2/2"  "status は codex の配線数を出す"

cp "$ISLAND_CODEX_HOOKS" "$ISLAND_CODEX_HOOKS.keep"
echo '{}' > "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: 0/2"  "codex 未配線を 0/2 と出す"
assert_contains "$(bash "$H" status)" "claude: 2/2" "その時も claude は 2/2 のまま"
assert_eq "2" "$(bash "$H" count)" "count は片方だけでも 2 のまま（status が要る理由）"

rm -f "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: file missing" "ファイル自体が無い場合を区別する"
mv "$ISLAND_CODEX_HOOKS.keep" "$ISLAND_CODEX_HOOKS"

# --- uninstall ---
bash "$H" uninstall >/dev/null 2>&1
assert_eq "0" "$?" "uninstall は 0 を返す"
assert_eq "0" "$(grep -c 'island-reason' "$ISLAND_CLAUDE_SETTINGS")" \
  "island-reason の痕跡が消える"
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command == "other-tool")] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "uninstall 後も他人の hook は残る"

# --- 壊れた JSON を渡されたら本番に触れない ---
printf 'this is not json' > "$ISLAND_CLAUDE_SETTINGS"
orig="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$H" install >/dev/null 2>&1
assert_eq "1" "$?" "壊れた JSON では 1 を返す"
assert_eq "$orig" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "壊れた JSON のファイルは変更しない"

finish
