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

# 消す側は PostToolUse に 1 本だけ。セットの契機（許可要求 / 質問）に対して
# ツール完了は必ず起きるので確実に対になる。herdr イベントだけでは
# auto mode の自動承認のように「止まらない」経路でクリアが起きない
assert_eq "1" "$(jq '[.hooks.PostToolUse[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PostToolUse に clear が 1 本"
assert_contains "$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command] | first' "$ISLAND_CLAUDE_SETTINGS")" \
  'exec bash "$0" clear' "PostToolUse は clear 引数つきで呼ぶ"

# 旧実装は PostToolBatch / Stop / TTL の 3 経路で消しており、手で送った理由が
# 即座に消えて目視確認ができなかった。戻すのは PostToolUse だけ
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

# --- status: 部分配線を区別できること ---
# 診断で本当に要るのは「どちらが未配線か」。両ファイルを合算する count も
# あったが、和集合なので片方だけ配線済みでも 3 を返し、その区別を潰していた。
# 本番からは呼ばれていなかったので削除済み
assert_contains "$(bash "$H" status)" "claude: 3/3" "status は claude の配線数を出す"
assert_contains "$(bash "$H" status)" "codex: 3/3"  "status は codex の配線数を出す"

# 数え上げの出力に空白が混じらないこと。BSD/macOS の wc -l は先頭を空白で
# パディングするため、値が正しくても文字列比較する側で落ちる。
# 実際 CI の macOS ジョブはこれで 5 アサーション落ちた
n="$(bash "$H" status | sed -n 's#^claude: \([0-9]*\)/3$#\1#p')"
assert_eq "3" "$n" "配線数は空白の混じらない裸の数値（BSD の wc -l 対策）"

cp "$ISLAND_CODEX_HOOKS" "$ISLAND_CODEX_HOOKS.keep"
echo '{}' > "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: 0/3"  "codex 未配線を 0/3 と出す"
assert_contains "$(bash "$H" status)" "claude: 3/3" "片方が未配線でも claude は 3/3 のまま"

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

# --- 入れていないエージェントの設定ディレクトリを作らない ---
# 以前は mkdir -p していたため、Codex を使っていない利用者のホームに
# ~/.codex/ と {} が生え、status が codex: 0/3 と出た。「入れていない」と
# 「入れたが未配線」が区別できず、doctor が何も診断できなくなる
NOPE="$WORK/no-such-agent"          # 作らない
mode_of() { ls -l "$1" | awk '{print substr($1,1,10)}'; }

echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
ISLAND_CODEX_HOOKS="$NOPE/hooks.json" bash "$H" install >/dev/null 2>&1
assert_eq "0" "$?" "片方が未導入でも install は成功する"
assert_eq "no" "$([ -d "$NOPE" ] && echo yes || echo no)" \
  "未導入エージェントの設定ディレクトリを作らない"
assert_eq "3" "$(jq '[.hooks[]?[]?.hooks[]? | select(.command | test("island-reason"))] | length' \
  "$ISLAND_CLAUDE_SETTINGS")" "導入済みの側は 3 本とも配線される"
assert_contains "$(ISLAND_CODEX_HOOKS="$NOPE/hooks.json" bash "$H" status)" \
  "codex: not installed" "status は未導入を未配線と別に出す"

# 両方とも未導入なら、何も配線しなかったことを言う
err="$(ISLAND_CLAUDE_SETTINGS="$NOPE/settings.json" ISLAND_CODEX_HOOKS="$NOPE/hooks.json" \
  bash "$H" install 2>&1 >/dev/null)"
assert_contains "$err" "nothing to wire" "両方未導入なら黙って 10 を返さない"
assert_eq "no" "$([ -d "$NOPE" ] && echo yes || echo no)" \
  "両方未導入でもディレクトリを作らない"

# --- settings.json の権限を保つ ---
# staging は mktemp で作るので 0600。chmod --reference は GNU 拡張で
# macOS には無く、握り潰していたので静かに 0600 へ化けていた
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
chmod 640 "$ISLAND_CLAUDE_SETTINGS"
bash "$H" install >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$ISLAND_CLAUDE_SETTINGS")" "install は権限を保つ"
bash "$H" uninstall >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$ISLAND_CLAUDE_SETTINGS")" "uninstall も権限を保つ"

finish
