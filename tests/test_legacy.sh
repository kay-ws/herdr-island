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
  cp "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS"
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

# --- 冪等 ---
before="$(cat "$ISLAND_CONFIG")"
bash "$L" purge >/dev/null 2>&1
assert_eq "$before" "$(cat "$ISLAND_CONFIG")" "2 回目の purge で内容が変わらない"

# --- 痕跡が無ければ detect は 10 ---
bash "$L" detect >/dev/null 2>&1
assert_eq "10" "$?" "痕跡が無ければ detect は 10"

finish
