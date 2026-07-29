#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

INSTALL="$here/../install.sh"

# --- 検証ヘルパ ---------------------------------------------------------------

# [ui] セクション内に agent_panel_sort = "priority" があるか。
# TOML パーサを持ち込まずに awk でセクション境界を見る
sort_in_ui() {
  awk '
    /^\[ui\][[:space:]]*$/ { f = 1; next }
    /^\[/                  { f = 0 }
    f && /agent_panel_sort[[:space:]]*=[[:space:]]*"priority"/ { found = 1 }
    END { print (found ? "yes" : "no") }
  ' "$1"
}

# --- ケース 1: 既存環境（[ui] あり、superset フックあり） --------------------

root="$(mktemp -d)"
mkdir -p "$root/.claude" "$root/.config/herdr" "$root/.codex" "$root/.local/bin"

cat > "$root/.claude/settings.json" <<'JSON'
{
  "statusLine": { "type": "command", "command": "ccstatus", "padding": 0 },
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*",
        "hooks": [ { "type": "command", "command": "bash /home/kay/.superset/hooks/notify.sh" } ] }
    ]
  }
}
JSON

cat > "$root/.config/herdr/config.toml" <<'TOML'
[ui.toast]
delivery = "terminal"
[ui]
show_agent_labels_on_pane_borders = true
[theme]
name = "catppuccin"

[[keys.command]]
key = "x"
TOML

cat > "$root/.local/bin/ccstatus" <<'SH'
#!/bin/bash
input=$(cat)
echo "$input" | crmux rpc status-update &
echo "done"
SH
chmod +x "$root/.local/bin/ccstatus"

cat > "$root/.codex/hooks.json" <<'JSON'
{ "hooks": { "SessionStart": [ { "hooks": [ { "command": "bash '/x/herdr-agent-state.sh' session", "timeout": 10, "type": "command" } ] } ] } }
JSON

run_install() { HERDR_JUMP_PREFIX="$root" bash "$INSTALL" >/dev/null 2>&1; }

snapshot() {
  cat "$root/.claude/settings.json" "$root/.config/herdr/config.toml" \
      "$root/.local/bin/ccstatus" "$root/.codex/hooks.json"
}

run_install
s1="$(snapshot)"
run_install
s2="$(snapshot)"
assert_eq "$s1" "$s2" "2 回実行しても内容が変わらない"

assert_contains "$(cat "$root/.claude/settings.json")" "superset" \
  "既存の superset フックを残す"

evs="$(jq -r '.hooks | keys[]' "$root/.claude/settings.json" | sort | tr '\n' ' ')"
assert_eq "PermissionRequest PostToolBatch PreToolUse Stop " "$evs" \
  "4 イベントが配線される"

n="$(jq '[.hooks.PermissionRequest[].hooks[]] | length' "$root/.claude/settings.json")"
assert_eq "2" "$n" "PermissionRequest は superset と herdr-jump の 2 エントリ"

m="$(jq -r '.hooks.PreToolUse[0].matcher' "$root/.claude/settings.json")"
assert_eq "AskUserQuestion" "$m" "PreToolUse は AskUserQuestion に絞る"

run_install
n="$(jq '[.hooks.PermissionRequest[].hooks[]] | length' "$root/.claude/settings.json")"
assert_eq "2" "$n" "3 回目でもエントリが増えない"

c="$(grep -c '>>> herdr-jump (managed) >>>' "$root/.config/herdr/config.toml")"
assert_eq "1" "$c" "config のマーカーブロックは 1 組"

assert_eq "yes" "$(sort_in_ui "$root/.config/herdr/config.toml")" \
  "agent_panel_sort が既存 [ui] セクション内に入る"

# 行頭のキーだけ数える。agents-rows.toml のコメントも agent_panel_sort に
# 言及しているので、素の grep だとそれらを拾ってしまう
c="$(grep -cE '^[[:space:]]*agent_panel_sort[[:space:]]*=' "$root/.config/herdr/config.toml")"
assert_eq "1" "$c" "agent_panel_sort のキーは 1 行だけ"

c="$(grep -c '^\[ui\]' "$root/.config/herdr/config.toml")"
assert_eq "1" "$c" "[ui] を二重定義しない"

assert_contains "$(cat "$root/.config/herdr/config.toml")" "show_agent_labels_on_pane_borders" \
  "既存 [ui] のキーを残す"

c="$(grep -c 'herdr-usage-push' "$root/.local/bin/ccstatus")"
assert_eq "1" "$c" "ccstatus の push 行は 1 本"

assert_contains "$(cat "$root/.local/bin/ccstatus")" "crmux rpc status-update" \
  "ccstatus の既存 crmux 行を残す"

assert_contains "$(cat "$root/.codex/hooks.json")" "herdr-agent-state.sh" \
  "codex の既存 SessionStart を残す"

evs="$(jq -r '.hooks | keys[]' "$root/.codex/hooks.json" | sort | tr '\n' ' ')"
assert_eq "PermissionRequest PostToolBatch PreToolUse SessionStart Stop " "$evs" \
  "codex も 4 イベント + SessionStart"

b="$(find "$root" -name '*.bak.*' | wc -l)"
assert_eq "yes" "$( [ "$b" -ge 4 ] && echo yes || echo "no($b)" )" \
  "4 ファイル分のバックアップを取る"

rm -rf "$root"

# --- ケース 2: [ui] を持たない config ---------------------------------------

root2="$(mktemp -d)"
mkdir -p "$root2/.claude" "$root2/.config/herdr" "$root2/.codex" "$root2/.local/bin"
printf '[theme]\nname = "x"\n' > "$root2/.config/herdr/config.toml"

HERDR_JUMP_PREFIX="$root2" bash "$INSTALL" >/dev/null 2>&1
assert_eq "yes" "$(sort_in_ui "$root2/.config/herdr/config.toml")" \
  "[ui] が無い config でも agent_panel_sort が入る"

r2run1="$(cat "$root2/.config/herdr/config.toml")"

HERDR_JUMP_PREFIX="$root2" bash "$INSTALL" >/dev/null 2>&1
r2run2="$(cat "$root2/.config/herdr/config.toml")"

c="$(grep -cE '^[[:space:]]*agent_panel_sort[[:space:]]*=' "$root2/.config/herdr/config.toml")"
assert_eq "1" "$c" "[ui] 無し経路でも 2 回目に重複しない"

c="$(grep -c '^\[ui\]' "$root2/.config/herdr/config.toml")"
assert_eq "1" "$c" "[ui] 無し経路でも [ui] は 1 つだけ"

# run1 と run2 でレイアウトが変わる（run1 は [ui] がマーカーブロックの後ろ、
# run2 は前）。run2 以降が不動点であることを完全比較で確かめる
HERDR_JUMP_PREFIX="$root2" bash "$INSTALL" >/dev/null 2>&1
r2run3="$(cat "$root2/.config/herdr/config.toml")"
assert_eq "$r2run2" "$r2run3" "[ui] 無し経路は run2 以降が不動点"

# run1 → run2 で変わること自体は仕様。変わらないなら上の比較が無意味になるので
# ここで固定しておく
assert_eq "no" "$( [ "$r2run1" = "$r2run2" ] && echo yes || echo no )" \
  "[ui] 無し経路は run1 と run2 でレイアウトが変わる（仕様）"

rm -rf "$root2"

# --- ケース 3: 何も無い環境（settings.json / hooks.json が不在） -------------

root3="$(mktemp -d)"
mkdir -p "$root3/.claude" "$root3/.config/herdr" "$root3/.codex" "$root3/.local/bin"

HERDR_JUMP_PREFIX="$root3" bash "$INSTALL" >/dev/null 2>&1
assert_eq "0" "$?" "空の環境でも install.sh は成功する"

evs="$(jq -r '.hooks | keys[]' "$root3/.claude/settings.json" 2>/dev/null | sort | tr '\n' ' ')"
assert_eq "PermissionRequest PostToolBatch PreToolUse Stop " "$evs" \
  "settings.json を新規作成して配線する"

rm -rf "$root3"
finish
