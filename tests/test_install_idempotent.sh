#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

INSTALL="$here/../install.sh"

# --- 検証ヘルパ ---------------------------------------------------------------

# [ui] セクション内に agent_panel_sort = "priority" があるか（テキスト近似）
sort_in_ui() {
  awk '
    /^\[ui\][[:space:]]*$/ { f = 1; next }
    /^\[/                  { f = 0 }
    f && /^[[:space:]]*agent_panel_sort[[:space:]]*=[[:space:]]*"priority"/ { found = 1 }
    END { print (found ? "yes" : "no") }
  ' "$1"
}

# TOML として実際にパースして意味を検証する。テキスト近似では
# ui.agent_panel_sort = "..." が ui.ui.agent_panel_sort に化ける失敗モード
# （パースは通るので気づけない）を捕まえられない。python3 は既に必須依存
toml_ok() {
  python3 - "$1" <<'PY' 2>&1
import sys, tomllib
try:
    d = tomllib.load(open(sys.argv[1], "rb"))
except Exception as e:
    print(f"parse-error: {e}")
    sys.exit(0)
ui = d.get("ui", {})
if not isinstance(ui, dict):
    print("ui-not-table"); sys.exit(0)
if ui.get("agent_panel_sort") != "priority":
    print(f"sort={ui.get('agent_panel_sort')!r}"); sys.exit(0)
if "ui" in ui:
    print("ui.ui が出来ている（dotted key の誤り）"); sys.exit(0)
agents = ui.get("sidebar", {}).get("agents", {})
if agents.get("row_gap") != 0:
    print(f"row_gap={agents.get('row_gap')!r}"); sys.exit(0)
rows = agents.get("rows_by_agent", {}).get("claude")
if not rows:
    print("rows_by_agent.claude が無い"); sys.exit(0)
flat = [t for row in rows for t in row]
toks = [t["token"] for t in flat if isinstance(t, dict) and "token" in t]
if "$reason" not in toks:
    print(f"$reason が無い: {toks}"); sys.exit(0)
print("ok")
PY
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

assert_eq "ok" "$(toml_ok "$root/.config/herdr/config.toml")" \
  'TOML としてパースでき agent_panel_sort と $reason が正しい位置に入る'

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

n="$(jq '[.hooks.SessionStart[].hooks[]
  | select(.command | contains("herdr-jump-reason.sh") and endswith(" model"))] | length' \
  "$root/.codex/hooks.json")"
assert_eq "1" "$n" "codex の SessionStart に model 送信を 1 本だけ配線する"

n="$(jq '[.hooks.Stop[].hooks[]
  | select(.command | contains("herdr-codex-usage.sh"))] | length' \
  "$root/.codex/hooks.json")"
assert_eq "1" "$n" "codex の Stop に context 使用率送信を 1 本だけ配線する"

n="$(jq '[.hooks.SessionStart[].hooks[]
  | select(.command | contains("herdr-agent-state.sh"))] | length' \
  "$root/.codex/hooks.json")"
assert_eq "1" "$n" "codex の既存 SessionStart と共存する"

assert_eq "false" "$(jq '[.hooks.SessionStart[]?.hooks[]?
  | select(.command | contains("herdr-jump-reason.sh") and endswith(" model"))] | length > 0' \
  "$root/.claude/settings.json")" \
  "Claude には model の SessionStart を追加しない"

assert_eq "false" "$(jq '[.hooks.Stop[]?.hooks[]?
  | select(.command | contains("herdr-codex-usage.sh"))] | length > 0' \
  "$root/.claude/settings.json")" \
  "Claude には Codex usage フックを追加しない"

# Codex の Stop には reason の clear と usage の両方が要る。
# jq を 2 段に分けていた頃、2 段目の purge が 1 段目の clear を巻き込んで消し、
# 拒否・中断時に reason が TTL まで残る状態になっていた
stop_cmds="$(jq -r '[.hooks.Stop[].hooks[].command] | join(" ")' "$root/.codex/hooks.json")"
assert_eq "yes" "$(printf '%s' "$stop_cmds" | grep -q "herdr-jump-reason.*clear" && echo yes || echo no)" \
  "codex の Stop に reason の clear が残る"
assert_eq "yes" "$(printf '%s' "$stop_cmds" | grep -q 'herdr-codex-usage' && echo yes || echo no)" \
  "codex の Stop に usage 収集がある"
assert_eq "2" "$(jq '[.hooks.Stop[].hooks[]] | length' "$root/.codex/hooks.json")" \
  "codex の Stop は clear と usage の 2 エントリ"

# Claude 側は usage 収集を配線しない（statusLine があるので不要）
assert_eq "1" "$(jq '[.hooks.Stop[].hooks[]] | length' "$root/.claude/settings.json")" \
  "claude の Stop は clear の 1 エントリだけ"
assert_eq "no" "$(jq -r '[.hooks.Stop[].hooks[].command] | join(" ")' "$root/.claude/settings.json" \
  | grep -q 'herdr-codex-usage' && echo yes || echo no)" \
  "claude 側に codex 用の usage フックを入れない"

# 再実行しても Stop が増えない（purge が両方を消してから足すこと）
HERDR_JUMP_PREFIX="$root" bash "$INSTALL" >/dev/null 2>&1
assert_eq "2" "$(jq '[.hooks.Stop[].hooks[]] | length' "$root/.codex/hooks.json")" \
  "再実行しても codex の Stop は 2 エントリのまま"

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

assert_eq "ok" "$(toml_ok "$root2/.config/herdr/config.toml")" \
  "[ui] 無し経路でも TOML として正しい"

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

# ディレクトリも作らない。install.sh が mkdir -p する経路を通す
root3="$(mktemp -d)"

HERDR_JUMP_PREFIX="$root3" bash "$INSTALL" >/dev/null 2>&1
assert_eq "0" "$?" "ディレクトリごと無い環境でも install.sh は成功する"

assert_eq "yes" "$( [ -f "$root3/.claude/settings.json" ] && echo yes || echo no )" \
  "settings.json の親ディレクトリごと作る"
assert_eq "yes" "$( [ -f "$root3/.codex/hooks.json" ] && echo yes || echo no )" \
  "codex hooks.json の親ディレクトリごと作る"
assert_eq "ok" "$(toml_ok "$root3/.config/herdr/config.toml")" \
  "config.toml も親ディレクトリごと作られ TOML として正しい"

evs="$(jq -r '.hooks | keys[]' "$root3/.claude/settings.json" 2>/dev/null | sort | tr '\n' ' ')"
assert_eq "PermissionRequest PostToolBatch PreToolUse Stop " "$evs" \
  "settings.json を新規作成して配線する"

rm -rf "$root3"
finish
