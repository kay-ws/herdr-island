#!/bin/bash
# pane.agent_status_changed を受けて、blocked を抜けたペインの reason を消す。
#
# clear をここに集約する理由: agent CLI 側の hook に clear を持たせると
# 経路が増え、手で送った理由が即座に消えて目視確認ができなくなる。
# blocked を抜けたことは herdr が知っているので、herdr 側で消すのが素直。

command -v jq    >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

payload="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$payload" ] || exit 0

pane="$(printf '%s' "$payload" | jq -r '.pane_id // ""' 2>/dev/null)"
status="$(printf '%s' "$payload" | jq -r '.status // ""' 2>/dev/null)"
[ -n "$pane" ] || exit 0
[ "$status" = "blocked" ] && exit 0
[ -n "$status" ] || exit 0

# PANE_ID はフラグより前（Task 4 と同じ制約）
herdr pane report-metadata "$pane" \
  --source island \
  --clear-token reason >/dev/null 2>&1

exit 0
