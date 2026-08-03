#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# config check を差し替えるための偽 herdr。argv と HERDR_CONFIG_PATH を記録する。
#
# HERDR_CONFIG_PATH を記録するのが重要。実装が候補ファイルではなく実 config を
# 検証するよう退行しても、argv だけ見ていると 13 個のアサーション全部が通る
# ——「ゲートが動いているように見えて何も守っていない」状態を検出できない。
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$1 $2" in
  "config check")
    printf '%s\n' "${HERDR_CONFIG_PATH:-UNSET}" >> "$FAKE_CHECKED_PATH_LOG"
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
export FAKE_CHECKED_PATH_LOG="$WORK/checked_path.log"

CFG="$WORK/config.toml"
export ISLAND_CONFIG="$CFG"

# バックアップも消すこと。$WORK は全区間で共有されるので、消さないと
# バックアップ数を数えるアサーションが前の区間の残骸を拾う
fresh() {
  printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CFG"
  : > "$FAKE_HERDR_LOG"
  rm -f "$CFG".bak.*
}

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

# 検証したのは候補ファイルであって実 config ではないこと。
# これが実 config を指していたら、ゲートは常に通り何も守っていない
checked="$(tail -1 "$FAKE_CHECKED_PATH_LOG")"
assert_eq "no" "$([ "$checked" = "$CFG" ] && echo yes || echo no)" \
  "検証対象は実 config ではない"
assert_eq "no" "$([ "$checked" = "UNSET" ] && echo yes || echo no)" \
  "HERDR_CONFIG_PATH を設定して検証している"

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

# --- バックアップ名が同一秒でも衝突しないこと ---
#
# この区間は最後に置く。config を revert 済みの状態で終えるため、途中に
# 挟むと後続区間（$reason がある前提の「冪等」など）の前提を壊す。
# 各区間が暗黙に前の区間の状態を引き継ぐテストなので、追加は末尾が安全。
fresh
bash "$here/../bin/apply.sh" >/dev/null 2>&1
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "2" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l)" \
  "同一秒内の 2 回の編集でバックアップが 2 つ残る"

finish
