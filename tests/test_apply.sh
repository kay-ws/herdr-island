#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# config check を差し替えるための偽 herdr。argv を記録する
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$1 $2" in
  "config check")
    # ISLAND_TEST_CHECK=fail のときだけ失敗させる
    if [ "${ISLAND_TEST_CHECK:-ok}" = "fail" ]; then
      echo "config: issues found"; exit 1
    fi
    echo "config: ok"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

CFG="$WORK/config.toml"
export ISLAND_CONFIG="$CFG"

fresh() { printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CFG"; : > "$FAKE_HERDR_LOG"; }

# --- 正常系 ---
fresh
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "0" "$?" "apply は 0 を返す"
assert_contains "$(cat "$CFG")" '$reason' "config に \$reason が入る"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "config check" "本番へ置く前に config check を通す"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "server reload-config" "反映は reload-config"
assert_eq "no" "$(grep -q 'server restart' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "restart は呼ばない"
assert_eq "1" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l)" "バックアップを 1 つ取る"

# --- 冪等 ---
: > "$FAKE_HERDR_LOG"
before="$(cat "$CFG")"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "10" "$?" "2 回目の apply は 10"
assert_eq "$before" "$(cat "$CFG")" "2 回目で内容が変わらない"

# --- 検証が落ちたら本番に触れない ---
fresh
orig="$(cat "$CFG")"
ISLAND_TEST_CHECK=fail bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "1" "$?" "検証失敗で 1 を返す"
assert_eq "$orig" "$(cat "$CFG")" "検証失敗時は本番ファイルを変更しない"
assert_eq "no" "$(grep -q 'reload-config' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "検証失敗時は reload しない"

# --- revert は元に戻す ---
fresh
orig="$(cat "$CFG")"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "0" "$?" "revert は 0 を返す"
assert_eq "$orig" "$(cat "$CFG")" "revert で元とバイト一致"

finish
