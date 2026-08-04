#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# A fake herdr standing in for config check. It records argv and HERDR_CONFIG_PATH.
#
# Recording HERDR_CONFIG_PATH is the important part. If the implementation
# regressed into validating the real config instead of the candidate, watching
# argv alone would let all 13 assertions pass — leaving "the gate looks alive
# but protects nothing" undetectable.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$1 $2" in
  "config check")
    printf '%s\n' "${HERDR_CONFIG_PATH:-UNSET}" >> "$FAKE_CHECKED_PATH_LOG"
    # Fail only when ISLAND_TEST_CHECK=fail
    if [ "${ISLAND_TEST_CHECK:-ok}" = "fail" ]; then
      echo "config: issues found"; exit 1
    fi
    echo "config: ok"; exit 0 ;;
  "server reload-config")
    # Fail only when ISLAND_TEST_RELOAD=fail — simulates herdr not running
    [ "${ISLAND_TEST_RELOAD:-ok}" = "fail" ] && exit 1
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"
export FAKE_CHECKED_PATH_LOG="$WORK/checked_path.log"

CFG="$WORK/config.toml"
export ISLAND_CONFIG="$CFG"

# Remove the backups too. $WORK is shared across every section, so leaving them
# makes the assertions that count backups pick up leftovers from earlier sections.
fresh() {
  printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CFG"
  : > "$FAKE_HERDR_LOG"
  rm -f "$CFG".bak.*
}

# --- happy path ---
fresh
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "0" "$?" "apply returns 0"
assert_contains "$(cat "$CFG")" '$reason' "\$reason lands in the config"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "config check" "config check runs before anything is installed"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "server reload-config" "reload-config is what makes it live"
assert_eq "no" "$(grep -q 'server restart' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "restart is never called"
assert_eq "1" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l | tr -d '[:space:]')" "exactly one backup is taken"

# What was validated must be the candidate file, not the real config.
# Were this pointing at the real config, the gate would always pass and protect nothing.
checked="$(tail -1 "$FAKE_CHECKED_PATH_LOG")"
assert_eq "no" "$([ "$checked" = "$CFG" ] && echo yes || echo no)" \
  "the validation target is not the real config"
assert_eq "no" "$([ "$checked" = "UNSET" ] && echo yes || echo no)" \
  "validation runs with HERDR_CONFIG_PATH set"

# --- idempotence ---
: > "$FAKE_HERDR_LOG"
before="$(cat "$CFG")"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "10" "$?" "a second apply returns 10"
assert_eq "$before" "$(cat "$CFG")" "a second apply changes nothing"

# --- a failed validation must not touch the real file ---
fresh
orig="$(cat "$CFG")"
ISLAND_TEST_CHECK=fail bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "1" "$?" "a failed validation returns 1"
assert_eq "$orig" "$(cat "$CFG")" "a failed validation leaves the real file alone"
assert_eq "no" "$(grep -q 'reload-config' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "a failed validation does not reload"

# --- revert restores the original ---
fresh
orig="$(cat "$CFG")"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "0" "$?" "revert returns 0"
assert_eq "$orig" "$(cat "$CFG")" "revert is byte-identical to the original"

# --- backup names must not collide within the same second ---
#
# This section goes last. It ends with the config already reverted, so slotting
# it in the middle would break the assumptions of later sections (idempotence,
# for instance, expects $reason to be present). Each section implicitly inherits
# the previous section's state, so appending at the end is the safe place to add.
fresh
bash "$here/../bin/apply.sh" >/dev/null 2>&1
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "2" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l | tr -d '[:space:]')" \
  "two edits within the same second leave two backups"

# --- the original config's permissions are preserved ---
# The staging file is made by mktemp, so it is 0600. Without carrying the
# permissions over, the user's config silently tightens to 0600. chmod
# --reference is not used because it is a GNU extension (it always fails on
# macOS, and the failure is swallowed so nobody notices).
mode_of() { ls -l "$1" | awk '{print substr($1,1,10)}'; }
fresh
chmod 640 "$CFG"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$CFG")" "apply preserves the config permissions"
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "-rw-r-----" "$(mode_of "$CFG")" "revert preserves them too"

# --- a failed reload still reports the edit itself as done ---
# The config is already written and the caller cannot undo it, so returning 1
# here would tell a different lie: that the edit was not applied. Staying silent
# would be a lie too, so a warning is emitted.
fresh
err="$(ISLAND_TEST_RELOAD=fail bash "$here/../bin/apply.sh" 2>&1 >/dev/null)"
rc=$?
assert_eq "0" "$rc" "apply still returns 0 when reload fails"
assert_contains "$err" "reload-config" "the reload failure surfaces as a warning"
assert_contains "$(cat "$CFG")" '$reason' "the config is written even when reload fails"

finish
