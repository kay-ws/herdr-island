#!/bin/bash
# I4: _wire_both processes the two files in order, but each file's JSON validity
# was checked inside _wire. So with Claude fine and Codex broken, Claude gets
# written first, Codex then fails, and _wire_both returns 1 — the caller reports
# "nothing was changed" while Claude has in fact already been changed.
#
# The fix has two stages:
#   1. pre-flight both files before entering any write (which eliminates
#      essentially all partial application caused by broken JSON)
#   2. if a partial application still happens through a write failure pre-flight
#      cannot predict (permissions, say), report rc 12 and name which file was
#      changed and which one failed
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

H="$here/../lib/hooks.sh"
export HERDR_PLUGIN_ROOT="$here/.."

# --- 1. pre-flight: a broken Codex must leave Claude entirely untouched ---
WORK1="$(mktemp -d -p /tmp)"
export ISLAND_CLAUDE_SETTINGS="$WORK1/settings.json"
export ISLAND_CODEX_HOOKS="$WORK1/hooks.json"

echo '{"hooks":{}}' > "$ISLAND_CLAUDE_SETTINGS"
printf 'this is not json' > "$ISLAND_CODEX_HOOKS"

before_claude="$(cat "$ISLAND_CLAUDE_SETTINGS")"
before_codex="$(cat "$ISLAND_CODEX_HOOKS")"

out1="$(bash "$H" install 2>&1)"
rc1=$?
assert_eq "1" "$rc1" "install returns 1 when the Codex JSON is broken"
assert_eq "$before_claude" "$(cat "$ISLAND_CLAUDE_SETTINGS")" \
  "Claude stays unchanged despite valid JSON, because pre-flight aborted"
assert_eq "$before_codex" "$(cat "$ISLAND_CODEX_HOOKS")" \
  "Codex (still broken) is unchanged too"
assert_contains "$out1" "$ISLAND_CODEX_HOOKS" "the file that caused the abort is named"

rm -rf "$WORK1"

# --- 2. a write failure after a clean pre-flight: report the partial honestly ---
WORK2="$(mktemp -d -p /tmp)"
mkdir -p "$WORK2/claude" "$WORK2/codex"
export ISLAND_CLAUDE_SETTINGS="$WORK2/claude/settings.json"
export ISLAND_CODEX_HOOKS="$WORK2/codex/hooks.json"
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
echo '{}' > "$ISLAND_CODEX_HOOKS"

before_claude2="$(cat "$ISLAND_CLAUDE_SETTINGS")"

# Make the codex directory unwritable. pre-flight only looks at JSON validity so
# it passes, but _wire fails the moment it tries to create the backup or stage
# file — a permission failure is exactly what pre-flight cannot predict.
chmod 555 "$WORK2/codex"

out2="$(bash "$H" install 2>&1)"
rc2=$?

chmod 755 "$WORK2/codex"

assert_eq "12" "$rc2" "a write failure after pre-flight returns the dedicated rc 12, not 1"
assert_contains "$out2" "$ISLAND_CLAUDE_SETTINGS" "the message names the file that was changed"
assert_contains "$out2" "$ISLAND_CODEX_HOOKS" "the message names the file that failed"
assert_eq "no" "$([ "$before_claude2" = "$(cat "$ISLAND_CLAUDE_SETTINGS")" ] && echo yes || echo no)" \
  "Claude really was written (this is not a 'nothing was changed' case)"

rm -rf "$WORK2"

finish
