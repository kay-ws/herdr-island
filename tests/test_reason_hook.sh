#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

HOOK="$here/../hooks/herdr-jump-reason.sh"

# 偽 herdr を仕込んだ一時 PATH を作る。引数を $CAPTURE に 1 行で吐く
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

# run_hook <mode> <json> : ガードを揃えてフックを実行し、捕まえた引数を返す
run_hook() {
  : > "$CAPTURE"
  printf '%s' "$2" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" "$1" >/dev/null 2>&1
  cat "$CAPTURE"
}

setup_fake_herdr

out="$(run_hook set '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
assert_contains "$out" "pane report-metadata" "set は report-metadata を呼ぶ"
assert_contains "$out" "--source herdr-jump"  "source は herdr-jump"
assert_contains "$out" "reason=Bash: ls -la"  "reason トークンに本文が乗る"
assert_contains "$out" "--ttl-ms 900000"      "reason の TTL は 15 分"
assert_contains "$out" "w0:p1"                "対象ペインは HERDR_PANE_ID"

out="$(run_hook clear '{}')"
assert_contains "$out" "--clear-token reason" "clear は reason を消す"

# --- ガード。いずれも herdr を呼ばずに黙って抜けること ---

: > "$CAPTURE"
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_ENV が 1 でなければ何もしない"

: > "$CAPTURE"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" set >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_PANE_ID が空なら何もしない"

: > "$CAPTURE"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "モード引数が無ければ何もしない"

: > "$CAPTURE"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" bogus >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "未知のモードでは何もしない"

# --- 終了コード。フックは何があっても 0 で抜けること ---

printf 'this is not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '{}' | HERDR_ENV=0 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "ガードで抜ける時も exit 0"

# reason が空になる payload では herdr を呼ばない（壊れた JSON も同様）
assert_eq "" "$(run_hook set 'this is not json')" "壊れた JSON では何も送らない"

teardown_fake_herdr
finish
