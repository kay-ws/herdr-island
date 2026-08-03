#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
[ "$1 $2" = "config check" ] && { echo "config: ok"; exit 0; }
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

export ISLAND_CONFIG="$WORK/config.toml"
export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export ISLAND_CCSTATUS="$WORK/ccstatus"
export ISLAND_ASSUME_YES=1

# rows_by_agent を持つ config を置く（旧 herdr-jump 相当）
cat > "$ISLAND_CONFIG" <<'EOF'
[ui.sidebar.agents]
rows = [["agent"]]
[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
EOF
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"

out="$(bash "$here/../bin/setup.sh" 2>&1)"

# 最重要: rows_by_agent の complete override を警告すること
assert_contains "$out" "rows_by_agent" "rows_by_agent があれば警告する"
# シングルクォート必須。"$reason" だと bash が未定義変数として展開し
# set -u で落ちる（リテラルの $reason を探したいのであって変数ではない）
assert_contains "$out" '$reason' "追加するトークンを提示する"

# 適用されていること
assert_contains "$(cat "$ISLAND_CONFIG")" '$reason' "config に行が入る"

# doctor が現状を報告できること
d="$(bash "$here/../bin/doctor.sh" 2>&1)"
# 「reason」だけを見るアサーションは、あり/なしの判定が壊れていても通る。
# 適用済みの状態なので「あり」と出ることまで確かめる
assert_contains "$d" "reason 行: あり" "doctor は reason 行ありを報告する"

# remove で戻ること
bash "$here/../bin/remove.sh" >/dev/null 2>&1
assert_eq "no" "$(grep -q '\$reason' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "remove で行が消える"

finish
