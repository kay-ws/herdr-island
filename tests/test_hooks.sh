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
assert_eq "2" "$(bash "$H" count)" "count は配線済みエントリ数を返す"

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
