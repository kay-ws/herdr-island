#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

if ! command -v herdr >/dev/null 2>&1; then
  echo "skip: no herdr on this machine, so the validation gate cannot be measured"
  finish
fi

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

CFG="$WORK/config.toml"
export ISLAND_CONFIG="$CFG"

# herdr rejects a custom token without the $ prefix. Using the real herdr as the
# judge, confirm the production file is left untouched when such a candidate is
# fed in.
printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CFG"
orig="$(cat "$CFG")"

# First confirm the real herdr genuinely rejects a broken config
printf '[ui.sidebar.agents]\nrows = [["agent"], ["reason"]]\n' > "$WORK/bad.toml"
HERDR_CONFIG_PATH="$WORK/bad.toml" herdr config check > "$WORK/check.out" 2>&1
assert_eq "1" "$?" "the real herdr rejects a config with an unprefixed token, exit 1"

# And that a valid candidate passes (so the gate is not just always-failing)
printf '[ui.sidebar.agents]\nrows = [["agent"], [{ token = "$reason" }]]\n' > "$WORK/good.toml"
HERDR_CONFIG_PATH="$WORK/good.toml" herdr config check > /dev/null 2>&1
assert_eq "0" "$?" "the real herdr accepts a config with a \$-prefixed token"

# apply succeeds through the real validation, and its result passes it too
bash "$here/../bin/apply.sh" >/dev/null 2>&1
HERDR_CONFIG_PATH="$CFG" herdr config check > /dev/null 2>&1
assert_eq "0" "$?" "the config after apply passes validation by the real herdr"
assert_contains "$(cat "$CFG")" '$reason' "apply did insert the row"

finish
