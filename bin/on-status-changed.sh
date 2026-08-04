#!/bin/bash
# On pane.agent_status_changed, clear the reason for any pane that left the
# blocked state.
#
# Why clearing is concentrated here: giving the agent-side CLI hooks more clear
# paths means a reason you sent by hand vanishes immediately, and you can never
# see it. herdr is the one that knows a pane left blocked, so let herdr clear it.

command -v jq    >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

payload="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$payload" ] || exit 0

pane="$(printf '%s' "$payload" | jq -r '.pane_id // ""' 2>/dev/null)"
# The field is agent_status, NOT status. (Confirmed against herdr 0.7.5's
# subscription_event schema, PaneAgentStatusChangedEvent: required is
# pane_id / workspace_id / agent_status — there is no `status` at all.)
# Get this wrong and the value is always empty, the guard below bails, and
# clear never runs even once.
status="$(printf '%s' "$payload" | jq -r '.agent_status // ""' 2>/dev/null)"
[ -n "$pane" ] || exit 0
[ "$status" = "blocked" ] && exit 0
[ -n "$status" ] || exit 0

# PANE_ID goes before the flags (same constraint as hooks/island-reason.sh)
herdr pane report-metadata "$pane" \
  --source island \
  --clear-token reason >/dev/null 2>&1

exit 0
