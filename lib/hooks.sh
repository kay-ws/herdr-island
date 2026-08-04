#!/bin/bash
# Wire the hooks on the agent CLI side. Three of them:
#   PermissionRequest(*)          … set the reason
#   PreToolUse(AskUserQuestion)   … set the reason
#   PostToolUse(no matcher)       … clear the reason
#
# herdr's pane.agent_status_changed (bin/on-status-changed.sh) also clears, but
# that only fires on a state transition. A permission request auto-approved in
# auto mode never puts the agent into blocked, so no transition happens: the set
# fired and the clear did not (measured: the reason lingered for the full
# 15-minute TTL). Tool completion always happens, so PostToolUse is a reliable
# counterpart. That is the only path brought back — the old implementation's
# PostToolBatch / Stop are deliberately not wired.
set -uo pipefail

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }

# island_hook_cmd [clear] : the command string to wire. Pass an argument for the
# clear variant.
island_hook_cmd() {
  local root; root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local arg="${1:-}"
  # The existence check lives on the outside. `herdr plugin uninstall` does not
  # run remove, so this entry stays behind in the user's settings.json while,
  # for a GitHub-installed copy, only its target (the managed checkout)
  # disappears. A plain `bash <path>` would then exit 127 and throw an error on
  # every subsequent PermissionRequest. The "always exit 0" defence cannot help
  # here — it lives inside the file that is gone.
  if [ -n "$arg" ]; then
    printf "bash -c '[ -f \"\$0\" ] || exit 0; exec bash \"\$0\" %s' '%s/hooks/island-reason.sh'" \
      "$arg" "$root"
  else
    printf "bash -c '[ -f \"\$0\" ] || exit 0; exec bash \"\$0\"' '%s/hooks/island-reason.sh'" "$root"
  fi
}

# _wire <file> <install|uninstall> :
#   rc 0=changed / 10=no change needed / 11=not applicable / 1=failed
_wire() {
  local f="$1" op="$2"
  # Use the presence of the config directory to decide whether that agent is
  # installed at all. An mkdir -p here would grow a ~/.codex/ containing {} in
  # the home directory of someone who does not use Codex, and status would
  # report codex: 0/3 from then on — "not installed" and "installed but not
  # wired" become indistinguishable and doctor can no longer diagnose anything.
  # What is not there is simply out of scope (not a failure).
  [ -d "$(dirname "$f")" ] || return 11
  [ -f "$f" ] || echo '{}' > "$f" || return 1

  # Never touch broken JSON. Writing back the result of a failed jq spreads the damage.
  jq empty "$f" >/dev/null 2>&1 || return 1

  local cmd; cmd="$(island_hook_cmd)"
  local clear_cmd; clear_cmd="$(island_hook_cmd clear)"
  local work; work="$(mktemp -d -p /tmp)" || return 1
  local cand="$work/out.json"

  jq --arg cmd "$cmd" --arg clear_cmd "$clear_cmd" --arg op "$op" '
    # Remove only our own entries; never touch hooks belonging to anyone else.
    # (. // []) guards against groups with a missing or null .hooks.
    def purge:
      (. // [])
      | map(.hooks |= ((. // []) | map(select(
          ((.command // "") | test("island-reason")) | not))))
      | map(select((.hooks | length) > 0));

    def entry($matcher; $c):
      (if $matcher == "" then {} else {matcher: $matcher} end)
      + {hooks: [{type: "command", command: $c, timeout: 5}]};

      .hooks = (.hooks // {})
    | .hooks.PermissionRequest = ((.hooks.PermissionRequest | purge)
        + (if $op == "install" then [entry("*"; $cmd)] else [] end))
    | .hooks.PreToolUse        = ((.hooks.PreToolUse | purge)
        + (if $op == "install" then [entry("AskUserQuestion"; $cmd)] else [] end))
    # The clearing side. Against the setting triggers (permission request /
    # question), tool completion always happens, so it is a reliable
    # counterpart. The pane.agent_status_changed event in herdr only fires on a
    # state transition, so on paths that never actually stop — such as a
    # permission request auto-approved in auto mode — the clear never runs
    # (measured: the reason lingered for the full 15-minute TTL).
    # Only PostToolUse comes back — the old PostToolBatch / Stop stay unwired.
    | .hooks.PostToolUse       = ((.hooks.PostToolUse | purge)
        + (if $op == "install" then [entry(""; $clear_cmd)] else [] end))
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$f" > "$cand" 2>/dev/null || { rm -rf "$work"; return 1; }

  jq empty "$cand" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }

  if cmp -s "$f" "$cand"; then rm -rf "$work"; return 10; fi

  # %3N is a GNU extension; leave uniqueness to mktemp (same reason as bin/_config.sh)
  local bak; bak="$(mktemp "$f.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" \
    || { rm -rf "$work"; return 1; }
  cp -p "$f" "$bak" || { rm -rf "$work"; return 1; }
  local stage; stage="$(mktemp "$(dirname "$f")/.island.XXXXXX")" || { rm -rf "$work"; return 1; }
  # Carry permissions over with cp -p (same reason as bin/_config.sh).
  # chmod --reference is a GNU extension that macOS lacks, and because the
  # failure was swallowed, settings.json silently ended up at 0600.
  cp -p "$f" "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  cat "$cand" > "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  mv -f "$stage" "$f" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  rm -rf "$work"
  return 0
}

# _preflight_json <file> : 0 if the file is absent or valid JSON, 1 if broken.
# Read-only — it neither creates nor modifies. _wire_both runs this over both
# files before entering either write, which eliminates at the root the accident
# (I4) where one file gets rewritten only because the other one was broken.
_preflight_json() {
  local f="$1"
  [ -f "$f" ] || return 0
  jq empty "$f" >/dev/null 2>&1
}

# _wire_both <install|uninstall> :
#   rc 0=changed / 10=no change needed / 1=failed (nothing was written)
#   / 12=partially applied (one file was written, the other failed; which is
#        which is named on stderr)
#
# The two files are processed in order. Both are pre-flighted first, and if
# either is broken we abort without touching either one (rc 1), per the same
# "validate the candidate before installing it" principle used elsewhere.
# Even after a clean pre-flight a write can still fail for unpredictable
# reasons — permissions, disk space — so rather than lying that nothing was
# changed, rc 12 comes back naming the file that was changed and the one that
# was not. There is no rollback: restoring from the backup is itself a write
# that can fail, and the backup is there precisely so the user can decide.
_wire_both() {
  local op="$1" changed=1 rc skipped=0
  local files=("$(claude_settings)" "$(codex_hooks)")
  local f wrote=()

  for f in "${files[@]}"; do
    _preflight_json "$f" || {
      echo "invalid JSON — aborting before any write: $f" >&2
      return 1
    }
  done

  for f in "${files[@]}"; do
    _wire "$f" "$op"; rc=$?
    if [ "$rc" -eq 1 ]; then
      if [ "${#wrote[@]}" -gt 0 ]; then
        echo "Partially applied: wrote ${wrote[*]}; failed to write $f." \
          "${wrote[*]} was changed, $f was not." >&2
        return 12
      fi
      return 1
    fi
    [ "$rc" -eq 11 ] && skipped=$((skipped + 1))
    [ "$rc" -eq 0 ] && { changed=0; wrote+=("$f"); }
  done
  # Everything was skipped as "that agent is not installed". Returning a bare
  # rc 10 would be indistinguishable from "already wired", so say out loud that
  # nothing was wired.
  if [ "$skipped" -eq "${#files[@]}" ]; then
    echo "no agent config directory found — nothing to wire." \
      "Looked for $(dirname "${files[0]}") and $(dirname "${files[1]}")." >&2
  fi
  [ "$changed" -eq 0 ] && return 0
  return 10
}

island_hooks_install()   { _wire_both install; }
island_hooks_uninstall() { _wire_both uninstall; }

# Print the wiring status one line per agent.
#
# There used to be an island_hooks_count that summed both files, but because it
# was a union it returned 3 even when only Claude was wired — exactly hiding the
# partial wiring doctor most wants to see. Nothing in production ever called it,
# only the tests did, so it was removed.
# The three slots are PermissionRequest(*) / PreToolUse(AskUserQuestion) /
# PostToolUse.
island_hooks_status() {
  # Labels come from processing order, not from the file's contents or path.
  # Deciding by substring match on the path (*codex*) turns both into claude
  # whenever ISLAND_CODEX_HOOKS is a name that does not contain "codex" — such
  # as plain "hooks.json", which is exactly the shape the test fixture uses.
  # The call order is fixed at claude → codex, so deciding by position makes
  # this independent of the env var's value.
  local files=("$(claude_settings)" "$(codex_hooks)")
  local labels=(claude codex)
  local i f label c
  for i in 0 1; do
    f="${files[$i]}"
    label="${labels[$i]}"
    # The directory's presence separates "not installed" from "installed but
    # not wired". Island never creates ~/.codex/, so its absence directly means
    # "this person does not use Codex" — there is nothing to diagnose.
    if [ ! -d "$(dirname "$f")" ]; then
      printf '%s: not installed\n' "$label"
      continue
    fi
    if [ ! -f "$f" ]; then
      printf '%s: file missing\n' "$label"
      continue
    fi
    c="$(jq -r '[ (.hooks // {}) | to_entries[] | .key as $event | .value[]? | select(.hooks[]?.command // "" | test("island-reason")) | $event + ":" + (.matcher // "") ] | unique | length' "$f" 2>/dev/null)"
    [ -n "$c" ] || c=0
    printf '%s: %s/3\n' "$label" "$c"
  done
}

case "${1:-}" in
  install)   island_hooks_install ;;
  uninstall) island_hooks_uninstall ;;
  status)    island_hooks_status ;;
  *) echo "usage: hooks.sh {install|uninstall|status}" >&2; exit 1 ;;
esac
