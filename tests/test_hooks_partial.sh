#!/bin/bash
# I4: _wire_both は2ファイルを順に処理するが、各ファイルの JSON 妥当性検証は
# _wire の内部で行われる。そのため Claude 側が正常・Codex 側が壊れている場合、
# Claude が先に書き込まれてから Codex で失敗し、_wire_both は 1 を返す ——
# 呼び出し元は「変更していない」と報告するが、実際には Claude 側は変更済み。
#
# 修正は二段構え:
#   1. 書き込みに入る前に両ファイルを pre-flight 検証する（これで JSON 破損
#      由来の部分適用はほぼ潰れる）
#   2. pre-flight では予測できない書き込み失敗（権限など）で部分適用が
#      それでも起きた場合は、rc 12 でどちらが変更されどちらが失敗したかを
#      名指しして報告する
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

H="$here/../lib/hooks.sh"
export HERDR_PLUGIN_ROOT="$here/.."

# --- 1. pre-flight: Codex が壊れていれば Claude 側にも一切触れないこと ---
WORK1="$(mktemp -d -p /tmp)"
export ISLAND_CLAUDE_SETTINGS="$WORK1/settings.json"
export ISLAND_CODEX_HOOKS="$WORK1/hooks.json"

echo '{"hooks":{}}' > "$ISLAND_CLAUDE_SETTINGS"
printf 'this is not json' > "$ISLAND_CODEX_HOOKS"

before_claude="$(cat "$ISLAND_CLAUDE_SETTINGS")"
before_codex="$(cat "$ISLAND_CODEX_HOOKS")"

out1="$(bash "$H" install 2>&1)"
rc1=$?
assert_eq "1" "$rc1" "Codex が壊れた JSON なら install は 1 を返す"
assert_eq "$before_claude" "$(cat "$ISLAND_CLAUDE_SETTINGS")" \
  "Claude 側は無事な JSON でも pre-flight 中断で無変更のまま"
assert_eq "$before_codex" "$(cat "$ISLAND_CODEX_HOOKS")" \
  "Codex 側（壊れたまま）も無変更"
assert_contains "$out1" "$ISLAND_CODEX_HOOKS" "中断の理由となったファイルを名指しする"

rm -rf "$WORK1"

# --- 2. pre-flight を通った後の書き込み失敗: 正直に部分適用を報告すること ---
WORK2="$(mktemp -d -p /tmp)"
mkdir -p "$WORK2/claude" "$WORK2/codex"
export ISLAND_CLAUDE_SETTINGS="$WORK2/claude/settings.json"
export ISLAND_CODEX_HOOKS="$WORK2/codex/hooks.json"
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
echo '{}' > "$ISLAND_CODEX_HOOKS"

before_claude2="$(cat "$ISLAND_CLAUDE_SETTINGS")"

# codex 側のディレクトリを書き込み不可にする。pre-flight は JSON の妥当性
# しか見ないので通過するが、_wire がバックアップ／ステージファイルを
# 作ろうとした時点で失敗する — 権限起因の失敗は pre-flight では予測できない
chmod 555 "$WORK2/codex"

out2="$(bash "$H" install 2>&1)"
rc2=$?

chmod 755 "$WORK2/codex"

assert_eq "12" "$rc2" "pre-flight 後の書き込み失敗は 1 ではなく専用の rc 12 を返す"
assert_contains "$out2" "$ISLAND_CLAUDE_SETTINGS" "メッセージが変更できたファイルを名指しする"
assert_contains "$out2" "$ISLAND_CODEX_HOOKS" "メッセージが失敗したファイルを名指しする"
assert_eq "no" "$([ "$before_claude2" = "$(cat "$ISLAND_CLAUDE_SETTINGS")" ] && echo yes || echo no)" \
  "Claude 側は実際に書き込まれている（『何も変更していません』ではない）"

rm -rf "$WORK2"

finish
