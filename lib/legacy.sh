#!/bin/bash
# Remove traces of the old herdr-jump from four places.
# Its install.sh had no uninstall path, so the removal is implemented fresh here.
set -uo pipefail

# For detection: covers every identifier the old implementation could leave
# behind. Drop herdr-codex-usage from this list and, for a codex-side file that
# contains only that one, detect returns rc 10 (no traces) and purge silently
# does nothing.
PAT='herdr-jump|herdr-usage-push|herdr-codex-usage'

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }
herdr_config()    { printf '%s' "${ISLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"; }
ccstatus()        { printf '%s' "${ISLAND_CCSTATUS:-$HOME/.local/bin/ccstatus}"; }

legacy_detect() {
  local found=1 f
  for f in "$(claude_settings)" "$(codex_hooks)" "$(herdr_config)" "$(ccstatus)"; do
    [ -f "$f" ] || continue
    if grep -qE "$PAT" "$f" 2>/dev/null; then
      echo "$f"
      found=0
    fi
  done
  [ "$found" -eq 0 ] && return 0
  return 10
}

# Leave backup-name uniqueness to mktemp. With one-second resolution, running
# apply and revert within the same second makes cp silently overwrite the
# earlier backup (cp has no -n). Milliseconds (%3N) are a GNU extension and do
# not expand on BSD/macOS. Same approach as bin/_config.sh and lib/hooks.sh
# (-p is confirmed working on macOS too).
_backup() {
  [ -f "$1" ] || return 0
  local bak; bak="$(mktemp "$1.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  cp -p "$1" "$bak"
}

# _stage_for <file> : create an empty stage file for the write-back and print
# its path to stdout.
#
# It is created in the target's own directory. A plain `mktemp` ($TMPDIR) breaks
# two things:
#   - mv stops being atomic once it crosses filesystems. Die part-way through
#     and the user's settings are left corrupted.
#   - Where TMPDIR is unusable, mktemp returns empty, `> ""` fails, and purge
#     silently does nothing — reporting rc 0 ("done") while the traces remain.
#
# Permissions are carried over with cp -p. mktemp creates at 0600, so a straight
# mv would turn the user's file into 0600 — and since ccstatus is a file that
# gets executed, losing the execute bit makes the status line silently vanish.
# Do not use chmod --reference: it is a GNU extension macOS lacks, and it fails
# quietly, leaving whatever permissions the umask happened to produce.
_stage_for() {
  local f="$1" stage
  stage="$(mktemp "$(dirname "$f")/.island-legacy.XXXXXX")" || return 1
  cp -p "$f" "$stage" || { rm -f "$stage"; return 1; }
  printf '%s' "$stage"
}

# Strip only our own entries out of the hook JSON; never touch anyone else's
_purge_hooks() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f" || return 1
  local tmp; tmp="$(_stage_for "$f")" || return 1
  jq '
    def purge:
      (. // [])
      | map(.hooks |= ((. // []) | map(select(
          ((.command // "") | test("herdr-jump-reason|herdr-codex-usage")) | not))))
      | map(select((.hooks | length) > 0));
    if (.hooks | type) == "object"
    then .hooks |= with_entries(.value |= purge)
         | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# Two places in config.toml: the marker block, and a lone line inside [ui]
_purge_config() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f" || return 1
  local tmp; tmp="$(_stage_for "$f")" || return 1
  awk '
    /^# >>> herdr-jump \(managed\) >>>/ { skip = 1 }
    skip && /^# <<< herdr-jump \(managed\) <<</ { skip = 0; next }
    skip { next }
    # Outside the block, the only line removed is the agent_panel_sort one.
    # A bare substring match like /herdr-jump/ would also sweep up unrelated
    # lines the user wrote themselves, e.g. a comment saying they tried
    # herdr-jump and moved on.
    /^[[:space:]]*agent_panel_sort[[:space:]]*=.*#[[:space:]]*herdr-jump/ { next }
    { print }
  ' "$f" > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# ccstatus is the user's own script — drop only the offending lines
_purge_ccstatus() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q 'herdr-usage-push' "$f" 2>/dev/null || return 0
  _backup "$f" || return 1
  local tmp; tmp="$(_stage_for "$f")" || return 1
  grep -v 'herdr-usage-push' "$f" > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

legacy_purge() {
  _purge_hooks    "$(claude_settings)"
  _purge_hooks    "$(codex_hooks)"
  _purge_config   "$(herdr_config)"
  _purge_ccstatus "$(ccstatus)"
  return 0
}

case "${1:-}" in
  detect) legacy_detect ;;
  purge)  legacy_purge ;;
  *) echo "usage: legacy.sh {detect|purge}" >&2; exit 1 ;;
esac
