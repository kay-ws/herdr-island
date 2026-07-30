#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"
# shellcheck source=./fake_socket.sh
source "$here/fake_socket.sh"

HOOK="$here/../hooks/herdr-codex-usage.sh"
test_root="$(mktemp -d)"
thread_id="019fb042-3a8f-7f83-ae09-7aa03cd68909"
session_dir="$test_root/.codex/sessions/2026/07/30"
mkdir -p "$session_dir"

start_fake_socket || { echo "セットアップ失敗" >&2; exit 1; }
trap 'stop_fake_socket; rm -rf "$test_root"' EXIT

run_hook() {
  reset_capture
  HOME="$test_root" HERDR_ENV=1 HERDR_PANE_ID=w0:p1 \
    CODEX_THREAD_ID="$thread_id" bash "$HOOK" >/dev/null 2>&1
}

session="$session_dir/rollout-2026-07-30T08-42-38-$thread_id.jsonl"
cat > "$session" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10000},"model_context_window":200000}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":25999},"model_context_window":200000}}}
JSONL

run_hook
assert_eq "12%" "$(sent '.params.tokens.ctx')" "最新 token_count から使用率を切り捨て計算する"
assert_eq "3600000" "$(sent '.params.ttl_ms')" "context 使用率の TTL は 1 時間"
assert_eq "false" "$(sent '.params.tokens | has("reason")')" \
  "context 更新時に reason を上書きしない"

# 末尾が書き込み途中でも、それ以前の完全な token_count を利用する
printf '%s' '{"type":"event_msg","payload":' >> "$session"
run_hook
assert_eq "12%" "$(sent '.params.tokens.ctx')" "書き込み途中の最終行を無視する"

# 累計 total_token_usage ではなく last_token_usage を使う
cat > "$session" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999999},"last_token_usage":{"total_tokens":50000},"model_context_window":200000}}}
JSONL
run_hook
assert_eq "25%" "$(sent '.params.tokens.ctx')" "セッション累計ではなく現在の context を使う"

reset_capture
HOME="$test_root" HERDR_ENV=1 HERDR_PANE_ID=w0:p1 \
  CODEX_THREAD_ID="not-found" bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "対応するセッションが無ければ何も送らない"

reset_capture
HOME="$test_root" HERDR_ENV=1 HERDR_PANE_ID=w0:p1 \
  CODEX_THREAD_ID="../bad" bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "不正な thread ID を拒否する"

stop_fake_socket
rm -rf "$test_root"
trap - EXIT
finish
