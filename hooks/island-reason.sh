#!/bin/bash
# Show "what is this agent stuck on" in herdr's Agents panel.
#
#   no argument … set the reason (PermissionRequest / PreToolUse(AskUserQuestion))
#   clear       … clear the reason (PostToolUse)
#
# clear lives here so that the set and clear triggers form a pair. The plugin
# also clears on pane.agent_status_changed, but that only fires on a state
# *transition*. A permission request auto-approved in auto mode never puts the
# agent into blocked, so no transition happens: the set fires and the clear does
# not, and the reason lingers for the full 15-minute TTL. Tool completion always
# happens, so PostToolUse is a reliable counterpart.
#
# Only that one PostToolUse path comes back, though. The old implementation
# cleared through three paths — PostToolBatch / Stop / TTL — which made a reason
# sent by hand disappear instantly, so you could never eyeball it.
#
# Always exit 0, no matter what. Losing the display is acceptable; affecting the
# agent's own behaviour with a non-zero exit is not.

mode="${1:-set}"
[ "$mode" = "set" ] || [ "$mode" = "clear" ] || exit 0

# Guards — only a process launched inside a herdr pane gets past these
[ "${HERDR_ENV:-}" = "1" ]      || exit 0
[ -n "${HERDR_PANE_ID:-}" ]     || exit 0
command -v jq    >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

if [ "$mode" = "clear" ]; then
  # PANE_ID before the flags (same reason as the set path below)
  herdr pane report-metadata "$HERDR_PANE_ID" \
    --source island \
    --clear-token reason >/dev/null 2>&1
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
FILTER="$here/reason-filter.jq"
[ -f "$FILTER" ] || exit 0

reason="$(jq -r -f "$FILTER" 2>/dev/null)"
[ -n "$reason" ] || exit 0

# No --seq here.
#
# It used to pass milliseconds from date +%s%3N, but %N is a GNU extension: on
# BSD/macOS it does not expand and you get a non-numeric string like
# "17857471073N" (measured in the macOS CI job).
#
# --seq exists to guarantee that an older report never overwrites a newer one.
# This hook sends exactly once, at the moment a question or permission request
# appears, and there is no path that sends several reasons to the same pane
# concurrently. Measured: without --seq, report-metadata still accepts with
# rc 0, and back-to-back sends are last-write-wins. Calling python3 purely to
# mint a monotonic counter would add a dependency to the hook and lose the
# reason entirely on machines without python3 — too high a price for what it buys.
#
# Always put PANE_ID before the flags. Put it after and herdr re-reads the value
# of --source as a flag and dies with "unknown option" (measured on 0.7.5).
# The Usage line in --help puts PANE_ID last, so following it naively is the trap.
herdr pane report-metadata "$HERDR_PANE_ID" \
  --source island \
  --token "reason=$reason" \
  --ttl-ms 900000 >/dev/null 2>&1

exit 0
