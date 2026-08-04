#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

H="$here/../lib/hooks.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export HERDR_PLUGIN_ROOT="$here/.."

# Start from a settings.json that already holds somebody else's hook
cat > "$ISLAND_CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}
]}}
EOF
echo '{}' > "$ISLAND_CODEX_HOOKS"

# --- install ---
bash "$H" install >/dev/null 2>&1
assert_eq "0" "$?" "install returns 0"

# The two configured set paths are present. This is set-only, so no clear here.
assert_eq "1" "$(jq '[.hooks.PermissionRequest[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "one entry under PermissionRequest"
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "one entry under PreToolUse"
# --- C2: the wiring must stay harmless once its target disappears ---
# herdr plugin uninstall does not run remove, so this entry stays behind. A
# plain `bash <path>` would exit 127 on the vanished path and throw an error on
# every subsequent PermissionRequest (the defence is inside the file that is gone).
cmd="$(jq -r '[.hooks.PermissionRequest[]?.hooks[]? | select(.command | test("island-reason")) | .command] | first' "$ISLAND_CLAUDE_SETTINGS")"
assert_contains "$cmd" 'exit 0' "the command carries an existence check and exit 0"
# Point it at a genuinely missing path and confirm it does not exit non-zero
missing="$(printf '%s' "$cmd" | sed "s#'[^']*/hooks/island-reason.sh'#'/nonexistent/island-reason.sh'#")"
bash -c "$missing" >/dev/null 2>&1
assert_eq "0" "$?" "exit 0 even with the target gone (never break the user's agent)"

assert_eq "AskUserQuestion" "$(jq -r '.hooks.PreToolUse[]
  | select(.hooks[]?.command | test("island-reason")) | .matcher' "$ISLAND_CLAUDE_SETTINGS")" \
  "the PreToolUse matcher is AskUserQuestion"

# The clearing side is a single PostToolUse entry. Against the setting triggers
# (permission request / question), tool completion always happens, so it pairs
# reliably. The herdr event alone never clears on paths that do not actually
# stop, such as an auto-approval in auto mode.
assert_eq "1" "$(jq '[.hooks.PostToolUse[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "one clear entry under PostToolUse"
assert_contains "$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command] | first' "$ISLAND_CLAUDE_SETTINGS")" \
  'exec bash "$0" clear' "PostToolUse invokes it with the clear argument"

# The old implementation cleared through three paths — PostToolBatch / Stop /
# TTL — which made a reason sent by hand vanish before it could be seen.
# Only PostToolUse comes back.
assert_eq "0" "$(jq '[.hooks.PostToolBatch[]?.hooks[]?, .hooks.Stop[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PostToolBatch / Stop are not wired"

# Nobody else's hook was broken
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command == "other-tool")] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "the other party's hook survives"

# The output is valid JSON (writing broken JSON would fail everything afterwards)
jq empty "$ISLAND_CLAUDE_SETTINGS" 2>/dev/null
assert_eq "0" "$?" "settings.json remains valid JSON"

# --- idempotence ---
before="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$H" install >/dev/null 2>&1
assert_eq "10" "$?" "a second install returns 10"
assert_eq "$before" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "a second install changes nothing"

# --- status: partial wiring must be distinguishable ---
# What diagnosis actually needs is "which side is unwired". There used to be a
# count that summed both files, but being a union it returned 3 even with only
# one side wired, destroying exactly that distinction. Nothing in production
# called it, so it was removed.
assert_contains "$(bash "$H" status)" "claude: 3/3" "status reports the claude wiring count"
assert_contains "$(bash "$H" status)" "codex: 3/3"  "status reports the codex wiring count"

# The count must carry no whitespace. wc -l on BSD/macOS pads with leading
# spaces, so a correct value still fails on the string comparison side.
# The macOS CI job really did lose 5 assertions to this.
n="$(bash "$H" status | sed -n 's#^claude: \([0-9]*\)/3$#\1#p')"
assert_eq "3" "$n" "the count is a bare number with no padding (guards against BSD wc -l)"

cp "$ISLAND_CODEX_HOOKS" "$ISLAND_CODEX_HOOKS.keep"
echo '{}' > "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: 0/3"  "an unwired codex reports 0/3"
assert_contains "$(bash "$H" status)" "claude: 3/3" "claude stays 3/3 while the other side is unwired"

rm -f "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: file missing" "a missing file is reported distinctly"
mv "$ISLAND_CODEX_HOOKS.keep" "$ISLAND_CODEX_HOOKS"

# --- uninstall ---
bash "$H" uninstall >/dev/null 2>&1
assert_eq "0" "$?" "uninstall returns 0"
assert_eq "0" "$(grep -c 'island-reason' "$ISLAND_CLAUDE_SETTINGS")" \
  "every trace of island-reason is gone"
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command == "other-tool")] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "the other party's hook survives uninstall too"

# --- broken JSON must leave the real file alone ---
printf 'this is not json' > "$ISLAND_CLAUDE_SETTINGS"
orig="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$H" install >/dev/null 2>&1
assert_eq "1" "$?" "broken JSON returns 1"
assert_eq "$orig" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "a file with broken JSON is not modified"

# --- never create a config directory for an agent that is not installed ---
# This used to mkdir -p, which grew a ~/.codex/ containing {} in the home
# directory of anyone not using Codex, and made status report codex: 0/3.
# "Not installed" then becomes indistinguishable from "installed but unwired",
# and doctor can no longer diagnose anything.
NOPE="$WORK/no-such-agent"          # deliberately never created
mode_of() { ls -l "$1" | awk '{print substr($1,1,10)}'; }

echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
ISLAND_CODEX_HOOKS="$NOPE/hooks.json" bash "$H" install >/dev/null 2>&1
assert_eq "0" "$?" "install succeeds with one side not installed"
assert_eq "no" "$([ -d "$NOPE" ] && echo yes || echo no)" \
  "no config directory is created for an absent agent"
assert_eq "3" "$(jq '[.hooks[]?[]?.hooks[]? | select(.command | test("island-reason"))] | length' \
  "$ISLAND_CLAUDE_SETTINGS")" "the installed side gets all three wired"
assert_contains "$(ISLAND_CODEX_HOOKS="$NOPE/hooks.json" bash "$H" status)" \
  "codex: not installed" "status reports not-installed separately from unwired"

# With neither installed, say out loud that nothing was wired
err="$(ISLAND_CLAUDE_SETTINGS="$NOPE/settings.json" ISLAND_CODEX_HOOKS="$NOPE/hooks.json" \
  bash "$H" install 2>&1 >/dev/null)"
assert_contains "$err" "nothing to wire" "with neither installed it does not silently return 10"
assert_eq "no" "$([ -d "$NOPE" ] && echo yes || echo no)" \
  "no directory is created even with neither installed"

# --- the settings.json permissions are preserved ---
# The staging file is made by mktemp, so it is 0600. chmod --reference is a GNU
# extension macOS lacks, and because the failure was swallowed the file silently
# turned into 0600.
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
chmod 640 "$ISLAND_CLAUDE_SETTINGS"
bash "$H" install >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$ISLAND_CLAUDE_SETTINGS")" "install preserves the permissions"
bash "$H" uninstall >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$ISLAND_CLAUDE_SETTINGS")" "uninstall preserves them too"

finish
