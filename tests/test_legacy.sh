#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

L="$here/../lib/legacy.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export ISLAND_CONFIG="$WORK/config.toml"
export ISLAND_CCSTATUS="$WORK/ccstatus"

seed() {
  cat > "$ISLAND_CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"bash '/x/hooks/herdr-jump-reason.sh' set"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}
]}}
EOF
  # codex 側は settings.json の複製にしない。複製すると herdr-codex-usage を
  # 一度も含まないため、codex 固有の識別子を検出できるかが永久に未検証になる
  cat > "$ISLAND_CODEX_HOOKS" <<'EOF'
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash '/x/hooks/herdr-codex-usage.sh'","timeout":5}]},
  {"hooks":[{"type":"command","command":"keep-me"}]}
]}}
EOF
  cat > "$ISLAND_CONFIG" <<'EOF'
[ui]
sidebar_width = 30
agent_panel_sort = "priority"  # herdr-jump

# >>> herdr-jump (managed) >>>
[ui.sidebar.agents]
rows = [["agent"]]
[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
# <<< herdr-jump (managed) <<<
EOF
  printf 'input=$(cat)\necho "$input" | /x/herdr-usage-push &  # herdr-jump\necho done\n' \
    > "$ISLAND_CCSTATUS"
}

# --- detect ---
seed
out="$(bash "$L" detect)"
assert_eq "0" "$?" "痕跡があれば detect は 0"
for f in settings.json hooks.json config.toml ccstatus; do
  assert_contains "$out" "$f" "detect は $f を挙げる"
done

# --- purge ---
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$?" "purge は 0 を返す"

# 生の文字列でゼロヒットを確認する（マーカー名の照合だけを信じない）
hits="$(cat "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS" \
        | grep -cE 'herdr-jump|herdr-usage-push' || true)"
assert_eq "0" "$hits" "4 箇所すべてから痕跡が消える"

# ブロック外の agent_panel_sort も消えていること（見落としやすい 2 箇所目）
assert_eq "no" "$(grep -q 'agent_panel_sort' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "[ui] 内の agent_panel_sort も除去される"

# rows_by_agent が残っていないこと
assert_eq "no" "$(grep -q 'rows_by_agent' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "rows_by_agent が残らない"

# --- 他人の設定を壊さない ---
assert_contains "$(cat "$ISLAND_CLAUDE_SETTINGS")" "other-tool" "他人の hook は残す"
assert_contains "$(cat "$ISLAND_CCSTATUS")" "echo done" "ccstatus の他の行は残す"
assert_contains "$(cat "$ISLAND_CONFIG")" "sidebar_width" "config の他のキーは残す"

# --- 過剰削除をしない ---
# 利用者が偶然 herdr-jump という語を含む行を書いていても巻き込まない
seed
printf '\n[notes]\nmemo = "used to try herdr-jump for this, switched away"\n' >> "$ISLAND_CONFIG"
bash "$L" purge >/dev/null 2>&1
assert_eq "1" "$(grep -c 'switched away' "$ISLAND_CONFIG")" \
  "無関係な行に herdr-jump が含まれていても残る"
assert_eq "0" "$(grep -c 'agent_panel_sort' "$ISLAND_CONFIG")" \
  "対象の agent_panel_sort 行は消える"

# --- codex 固有の識別子だけのファイルでも検出・除去できる ---
# herdr-jump を一切含まない hooks.json。ゲートのパターンが
# herdr-codex-usage を落としていると detect が rc 10 を返して素通りする
cat > "$ISLAND_CODEX_HOOKS" <<'EOF'
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash '/x/hooks/herdr-codex-usage.sh'"}]},
  {"hooks":[{"type":"command","command":"keep-me"}]}
]}}
EOF
: > "$ISLAND_CONFIG"; : > "$ISLAND_CCSTATUS"; echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
bash "$L" detect >/dev/null 2>&1
assert_eq "0" "$?" "codex 固有の識別子だけでも detect は 0"
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$(grep -c 'herdr-codex-usage' "$ISLAND_CODEX_HOOKS")" "codex 側の痕跡が消える"
assert_eq "1" "$(grep -c 'keep-me' "$ISLAND_CODEX_HOOKS")" "codex 側の他人の hook は残る"

# --- 対象ファイルが無くても異常終了しない ---
rm -f "$ISLAND_CODEX_HOOKS" "$ISLAND_CCSTATUS"
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$?" "対象ファイルが無くても purge は 0"

# --- 壊れた JSON は修復せず放置する ---
printf 'this is not json' > "$ISLAND_CLAUDE_SETTINGS"
orig="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$L" purge >/dev/null 2>&1
assert_eq "$orig" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "壊れた JSON は書き換えない"

# --- 冪等（4 箇所すべて） ---
seed
bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  cp "$f" "$f.snap"
done
bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  assert_eq "0" "$(cmp -s "$f" "$f.snap" && echo 0 || echo 1)" \
    "2 回目の purge で $(basename "$f") が変わらない"
done

# --- 痕跡が無ければ detect は 10 ---
bash "$L" detect >/dev/null 2>&1
assert_eq "10" "$?" "痕跡が無ければ detect は 10"

finish
