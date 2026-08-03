#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

HOOK="$here/../hooks/island-reason.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# 偽 herdr。argv を 1 行にして記録する
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

run_hook() {
  : > "$FAKE_HERDR_LOG"
  printf '%s' "$1" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
}
logged() { cat "$FAKE_HERDR_LOG"; }
nothing_sent() { [ -s "$FAKE_HERDR_LOG" ] && echo no || echo yes; }

# --- 送る内容 ---
run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_contains "$(logged)" "pane report-metadata" "report-metadata を呼ぶ"
assert_contains "$(logged)" "--source island"      "source は island"
assert_contains "$(logged)" "reason=Bash: ls -la"  "reason に本文が乗る"
assert_contains "$(logged)" "--ttl-ms 900000"      "TTL は 15 分"

# --- 引数順序の回帰。PANE_ID はフラグより前に置くこと ---
# 後ろに置くと herdr が "unknown option" で落ちる（0.7.5 実測）
first_arg="$(logged | awk '{print $3}')"
assert_eq "w0:p1" "$first_arg" "PANE_ID は report-metadata の直後（フラグより前）"

# --- ガード。いずれも何も呼ばずに抜けること ---
: > "$FAKE_HERDR_LOG"
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_ENV が 1 でなければ何もしない"

: > "$FAKE_HERDR_LOG"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_PANE_ID が空なら何もしない"

run_hook 'this is not json'
assert_eq "yes" "$(nothing_sent)" "壊れた JSON では何もしない"

run_hook '{"tool_name":"Bash","tool_input":"oops"}'
assert_eq "yes" "$(nothing_sent)" "tool_input の型が不正でも何もしない"

# --- clear モード ---
# セットとクリアの契機を対にするため PostToolUse から呼ばれる経路
: > "$FAKE_HERDR_LOG"
HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" clear >/dev/null 2>&1
assert_contains "$(logged)" "--clear-token reason" "clear 引数で reason を消す"
assert_contains "$(logged)" "--source island"      "clear も source は island"
assert_eq "w0:p1" "$(logged | awk '{print $3}')"   "clear でも PANE_ID はフラグより前"
assert_eq "no" "$(grep -q 'ttl-ms' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "clear に TTL は付けない"

# clear は stdin を読まない（PostToolUse の payload は理由の材料ではない）
: > "$FAKE_HERDR_LOG"
printf 'this is not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" clear >/dev/null 2>&1
assert_contains "$(logged)" "--clear-token reason" "壊れた stdin でも clear は成立する"

# 未知のモードでは何もしない
: > "$FAKE_HERDR_LOG"
HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" bogus >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "未知のモードでは何もしない"

HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" clear >/dev/null 2>&1
assert_eq "0" "$?" "clear も exit 0"

# --- python3 に依存しないこと ---
# 禁じたいのは「python3 を起動すること」であって「python3 という語が
# 出てくること」ではない。素の grep だと、なぜ python3 を呼ばないかを
# 説明したコメントで落ちる（実際に落ちた）。コメント行を除いて判定する
assert_eq "no" \
  "$(grep -v '^[[:space:]]*#' "$HOOK" | grep -q 'python3' && echo yes || echo no)" \
  "hook は python3 を起動しない（コメントでの言及は可）"

# --- 終了コード ---
printf 'not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '{}' | HERDR_ENV=0 bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "ガードで抜ける時も exit 0"

BASH_ABS="$(command -v bash)"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -u PATH HERDR_ENV=1 HERDR_PANE_ID=w0:p1 "$BASH_ABS" "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "jq / herdr が引けなくても exit 0"

finish
