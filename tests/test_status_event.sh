#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

E="$here/../bin/on-status-changed.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

fire() {
  : > "$FAKE_HERDR_LOG"
  HERDR_PLUGIN_EVENT_JSON="$1" bash "$E" >/dev/null 2>&1
}
logged() { cat "$FAKE_HERDR_LOG"; }
nothing_sent() { [ -s "$FAKE_HERDR_LOG" ] && echo no || echo yes; }

# --- blocked を抜けたら消す ---
fire '{"pane_id":"w0:p1","status":"working"}'
assert_contains "$(logged)" "--clear-token reason" "blocked 以外へ遷移したら reason を消す"
assert_contains "$(logged)" "--source island"      "source は island"
assert_eq "w0:p1" "$(logged | awk '{print $3}')"   "PANE_ID はフラグより前"

# --- blocked のままなら消さない ---
fire '{"pane_id":"w0:p1","status":"blocked"}'
assert_eq "yes" "$(nothing_sent)" "blocked のときは消さない"

# --- 不正な payload ---
fire 'not json'
assert_eq "yes" "$(nothing_sent)" "壊れた JSON では何もしない"

fire '{"status":"working"}'
assert_eq "yes" "$(nothing_sent)" "pane_id が無ければ何もしない"

# --- 終了コード ---
HERDR_PLUGIN_EVENT_JSON='not json' bash "$E" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

finish
