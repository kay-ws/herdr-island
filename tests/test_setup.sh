#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
[ "$1 $2" = "config check" ] && { echo "config: ok"; exit 0; }
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

export ISLAND_CONFIG="$WORK/config.toml"
export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export ISLAND_CCSTATUS="$WORK/ccstatus"
export ISLAND_ASSUME_YES=1

# Lay down a config that has rows_by_agent (as the old herdr-jump would)
cat > "$ISLAND_CONFIG" <<'EOF'
[ui.sidebar.agents]
rows = [["agent"]]
[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
EOF
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"

out="$(bash "$here/../bin/setup.sh" 2>&1)"

# Most important: it warns about the complete override that rows_by_agent is
assert_contains "$out" "rows_by_agent" "it warns when rows_by_agent is present"
# Single quotes are required here. With "$reason", bash would expand an unset
# variable and die under set -u — we want the literal $reason, not a variable.
assert_contains "$out" '$reason' "it shows the token it is about to add"

# It was actually applied
assert_contains "$(cat "$ISLAND_CONFIG")" '$reason' "the row lands in the config"

# doctor can report the current state
d="$(bash "$here/../bin/doctor.sh" 2>&1)"
# An assertion that only looks for "reason" would pass even with the
# present/absent decision broken. The row is applied here, so check that it
# actually reports "present".
assert_contains "$d" "reason line: present" "doctor reports the reason row as present"

# remove puts it back
bash "$here/../bin/remove.sh" >/dev/null 2>&1
assert_eq "no" "$(grep -q '\$reason' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "remove takes the row away"

finish
