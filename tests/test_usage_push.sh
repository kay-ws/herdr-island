#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

PUSH="$here/../statusline/herdr-usage-push"

setup_fake_herdr() {
  FAKE_DIR="$(mktemp -d)"
  CAPTURE="$FAKE_DIR/captured"
  cat > "$FAKE_DIR/herdr" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CAPTURE"
exit 0
FAKE
  chmod +x "$FAKE_DIR/herdr"
  export CAPTURE
  export PATH="$FAKE_DIR:$PATH"
}

teardown_fake_herdr() { rm -rf "$FAKE_DIR"; }

run_push() {
  : > "$CAPTURE"
  printf '%s' "$1" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
  cat "$CAPTURE"
}

setup_fake_herdr

full='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":81000}},"rate_limits":{"five_hour":{"used_percentage":11.4},"seven_day":{"used_percentage":2.6}}}'

out="$(run_push "$full")"
assert_contains "$out" "--token ctx=42%"               "ctx トークンを送る"
assert_contains "$out" "--token limits=5h 11% | 7d 3%" "limits トークンを送る"
assert_contains "$out" "--ttl-ms 3600000"              "usage の TTL は 1 時間"
assert_contains "$out" "--source herdr-jump"           "source は herdr-jump"
assert_contains "$out" "w0:p1"                         "対象ペインは HERDR_PANE_ID"

no_limits='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":50000}}}'
out="$(run_push "$no_limits")"
assert_contains "$out" "--token ctx=25%" "limits が無くても ctx は送る"
assert_eq "" "$(printf '%s' "$out" | grep -o 'limits=' || true)" \
  "limits が無い時は limits トークンを送らない"

# ctx すら取れないなら herdr を呼ばない
assert_eq "" "$(run_push '{}')" "空 payload では何も送らない"

# ガード
: > "$CAPTURE"
printf '%s' "$full" | HERDR_ENV=1 HERDR_PANE_ID= bash "$PUSH" >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_PANE_ID が空なら何もしない"

: > "$CAPTURE"
printf '%s' "$full" | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_ENV が 1 でなければ何もしない"

printf 'not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

assert_eq "" "$(run_push 'not json')" "壊れた JSON では何も送らない"

teardown_fake_herdr
finish
