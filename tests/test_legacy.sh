#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

L="$here/../lib/legacy.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export ISLAND_CONFIG="$WORK/config.toml"
export ISLAND_CCSTATUS="$WORK/ccstatus"

# A copy of $PAT from legacy.sh. legacy.sh executes immediately via the case at
# its end, so it cannot be sourced and its internal variables are unreachable.
# Keep the broad side here (all three identifiers) so that any drift can only
# make the check stricter, never looser.
LEGACY_PAT='herdr-jump|herdr-usage-push|herdr-codex-usage'

seed() {
  cat > "$ISLAND_CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"bash '/x/hooks/herdr-jump-reason.sh' set"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}
]}}
EOF
  # The codex side is deliberately not a copy of settings.json. A copy would
  # never contain herdr-codex-usage, leaving "can it detect the codex-specific
  # identifier?" permanently untested.
  cat > "$ISLAND_CODEX_HOOKS" <<'EOF'
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash '/x/hooks/herdr-codex-usage.sh'","timeout":5}]},
  {"hooks":[{"type":"command","command":"keep-me"}]}
]}}
EOF
  cat > "$ISLAND_CONFIG" <<'EOF'
[ui]
sidebar_width = 30
agent_panel_sort = "priority"  # herdr-jump

# >>> herdr-jump (managed) >>>
[ui.sidebar.agents]
rows = [["agent"]]
[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
# <<< herdr-jump (managed) <<<
EOF
  printf 'input=$(cat)\necho "$input" | /x/herdr-usage-push &  # herdr-jump\necho done\n' \
    > "$ISLAND_CCSTATUS"
}

# --- detect ---
seed
out="$(bash "$L" detect)"
assert_eq "0" "$?" "detect returns 0 when traces exist"
for f in settings.json hooks.json config.toml ccstatus; do
  assert_contains "$out" "$f" "detect lists $f"
done

# --- purge ---
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$?" "purge returns 0"

# Confirm zero hits on the raw strings — do not trust marker-name matching alone
hits="$(cat "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS" \
        | grep -cE 'herdr-jump|herdr-usage-push' || true)"
assert_eq "0" "$hits" "traces are gone from all four places"

# agent_panel_sort outside the block is gone too (the easy-to-miss second spot)
assert_eq "no" "$(grep -q 'agent_panel_sort' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "agent_panel_sort inside [ui] is removed as well"

# No rows_by_agent left behind
assert_eq "no" "$(grep -q 'rows_by_agent' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "no rows_by_agent remains"

# --- do not break anyone else's settings ---
assert_contains "$(cat "$ISLAND_CLAUDE_SETTINGS")" "other-tool" "the other party's hook is kept"
assert_contains "$(cat "$ISLAND_CCSTATUS")" "echo done" "the other lines in ccstatus are kept"
assert_contains "$(cat "$ISLAND_CONFIG")" "sidebar_width" "the other keys in the config are kept"

# --- do not over-delete ---
# A line the user happened to write containing the word herdr-jump must survive
seed
printf '\n[notes]\nmemo = "used to try herdr-jump for this, switched away"\n' >> "$ISLAND_CONFIG"
bash "$L" purge >/dev/null 2>&1
assert_eq "1" "$(grep -c 'switched away' "$ISLAND_CONFIG")" \
  "an unrelated line survives even though it contains herdr-jump"
assert_eq "0" "$(grep -c 'agent_panel_sort' "$ISLAND_CONFIG")" \
  "the targeted agent_panel_sort line is still removed"

# --- a file holding only the codex-specific identifier is still detected/purged ---
# A hooks.json with no herdr-jump anywhere. If the gate pattern dropped
# herdr-codex-usage, detect would return rc 10 and sail right past.
cat > "$ISLAND_CODEX_HOOKS" <<'EOF'
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash '/x/hooks/herdr-codex-usage.sh'"}]},
  {"hooks":[{"type":"command","command":"keep-me"}]}
]}}
EOF
: > "$ISLAND_CONFIG"; : > "$ISLAND_CCSTATUS"; echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
bash "$L" detect >/dev/null 2>&1
assert_eq "0" "$?" "detect returns 0 for the codex-specific identifier alone"
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$(grep -c 'herdr-codex-usage' "$ISLAND_CODEX_HOOKS")" "the codex-side trace is gone"
assert_eq "1" "$(grep -c 'keep-me' "$ISLAND_CODEX_HOOKS")" "the other party's codex hook survives"

# --- a missing target file must not stop the rest ---
# An assertion on rc alone is worthless here: legacy_purge returns 0
# unconditionally, so anything passes. What matters is "did it carry on to the
# remaining files instead of aborting on the missing one".
seed
rm -f "$ISLAND_CODEX_HOOKS" "$ISLAND_CCSTATUS"
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$?" "purge returns 0 even with target files missing"
assert_eq "no" "$([ -f "$ISLAND_CODEX_HOOKS" ] && echo yes || echo no)" \
  "a missing file is not created"
assert_eq "no" "$([ -f "$ISLAND_CCSTATUS" ] && echo yes || echo no)" \
  "ccstatus is not created either"
assert_eq "0" "$(grep -c 'herdr-jump' "$ISLAND_CONFIG")" \
  "the remaining files are still processed when some are missing"

# --- broken JSON is left alone, not repaired ---
# The fixture must contain a PAT-matching string. Without one, the
# `grep -qE "$PAT" || return 0` gate short-circuits and the function returns
# before jq is ever called. The path under test is "do not write the file back
# when jq fails".
printf '{"hooks": broken herdr-jump-reason' > "$ISLAND_CLAUDE_SETTINGS"
orig="$(cat "$ISLAND_CLAUDE_SETTINGS")"
assert_eq "1" "$(grep -cE 'herdr-jump' "$ISLAND_CLAUDE_SETTINGS")" \
  "precondition: the fixture matches PAT (so the gate does not short-circuit)"
bash "$L" purge >/dev/null 2>&1
assert_eq "$orig" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "broken JSON is not rewritten"

# --- idempotence (all four places) ---
seed
bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  cp "$f" "$f.snap"
done
bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  assert_eq "0" "$(cmp -s "$f" "$f.snap" && echo 0 || echo 1)" \
    "a second purge leaves $(basename "$f") unchanged"
done

# --- with no traces, detect returns 10 ---
bash "$L" detect >/dev/null 2>&1
assert_eq "10" "$?" "detect returns 10 when there are no traces"

# --- properties of the write procedure ---
# The three sections below look at *how* purge writes back, not at what it
# removes. Each seeds its own state, so none depends on the sections above.

# Backup names must not collide within the same second.
# At one-second resolution cp silently overwrites the earlier backup (cp has no -n)
seed
rm -f "$ISLAND_CONFIG".bak.*
bash "$L" purge >/dev/null 2>&1
seed
bash "$L" purge >/dev/null 2>&1
assert_eq "2" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l | tr -d '[:space:]')" \
  "two purges within the same second leave two backups"

# The original file permissions must be preserved.
# ccstatus is a script the user executes, so dropping the execute bit makes the
# status line silently disappear. And a config tightened to 0600 can become
# unreadable to other tools.
mode_of() { ls -l "$1" | awk '{print substr($1,1,10)}'; }
seed
chmod 640 "$ISLAND_CONFIG"
chmod 750 "$ISLAND_CCSTATUS"
bash "$L" purge >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$ISLAND_CONFIG")"   "the config permissions are preserved"
assert_eq "-rwxr-x---" "$(mode_of "$ISLAND_CCSTATUS")" "the ccstatus execute bit is preserved"

# It must not depend on TMPDIR.
# Creating the temp file in $TMPDIR breaks two things: (a) mv crosses
# filesystems and stops being atomic, and (b) where TMPDIR is unusable mktemp
# returns empty and `> ""` silently does nothing. Staging into the target's own
# directory avoids both. A test that only checks permissions would also pass an
# incomplete fix ("keep /tmp, just add cp -p"), so this section exercises the
# location itself.
seed
TMPDIR="$WORK/no-such-dir" bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  assert_eq "0" "$(grep -cE "$LEGACY_PAT" "$f")" \
    "traces leave $(basename "$f") even with TMPDIR unusable"
done

# No staging leftovers may be abandoned
assert_eq "0" "$(find "$WORK" -name '.island-legacy.*' | wc -l | tr -d '[:space:]')" \
  "no staging files are left behind"

finish
