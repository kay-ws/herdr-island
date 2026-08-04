#!/bin/bash
# The config-editing procedure shared by apply / revert / setup / remove.
# "Validate, then install": build the candidate in a temp file, validate that,
# and only move it into place once it passes.

island_config_path() {
  printf '%s' "${ISLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
}

# island_edit_config <add|remove> : rc 0=applied / 10=no change needed / 1=failed
island_edit_config() {
  local op="$1"
  local cfg; cfg="$(island_config_path)"
  local root; root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  [ -f "$cfg" ] || { echo "config not found: $cfg" >&2; return 1; }

  local work; work="$(mktemp -d -p /tmp)" || return 1
  local cand="$work/config.toml"

  python3 "$root/lib/rows.py" "$op" "$cfg" > "$cand"
  local rc=$?
  if [ "$rc" -eq 10 ]; then rm -rf "$work"; return 10; fi
  if [ "$rc" -ne 0 ]; then rm -rf "$work"; return 1; fi

  # Let herdr itself validate the candidate before we touch the real config
  if ! HERDR_CONFIG_PATH="$cand" herdr config check >"$work/check.out" 2>&1; then
    echo "config validation failed. Configuration was not modified." >&2
    cat "$work/check.out" >&2
    rm -rf "$work"
    return 1
  fi

  # Backup names need sub-second uniqueness: at one-second resolution, running
  # apply and revert within the same second makes cp silently overwrite the
  # earlier backup (cp has no -n).
  # Milliseconds via %3N are a GNU extension — they do not expand on BSD/macOS,
  # so the same-second collision guard silently stops working there (measured in
  # the macOS CI job). What we actually want is "a unique filename even within
  # the same second", not milliseconds specifically, so hand the uniqueness
  # itself to mktemp (-p is confirmed working on macOS too).
  local bak; bak="$(mktemp "$cfg.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" \
    || { rm -rf "$work"; return 1; }
  cp -p "$cfg" "$bak" || { rm -rf "$work"; return 1; }

  # Replace atomically. `cat "$cand" > "$cfg"` truncates $cfg the moment the
  # redirect opens, so a failure part-way through leaves the user's real config
  # corrupted. mv is only atomic within a single filesystem, so stage the temp
  # file in the config's own directory rather than /tmp.
  local stage; stage="$(mktemp "$(dirname "$cfg")/.island.XXXXXX")" || { rm -rf "$work"; return 1; }
  # Carry the permissions over with cp -p. mktemp creates at 0600, so installing
  # that as-is would tighten the user's config to 0600. Do not use
  # chmod --reference — it is a GNU extension that macOS's chmod lacks, and
  # since the failure was swallowed by 2>/dev/null it gave us a path that
  # "always fails on macOS and quietly installs a 0600 file". cp -p gives both
  # userlands the same single path.
  cp -p "$cfg" "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  cat "$cand" > "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  mv -f "$stage" "$cfg" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  rm -rf "$work"

  # A failed reload does not change rc. The config is already written and the
  # caller cannot undo that — returning 1 here would tell a different lie, that
  # the edit was not applied. It also fails perfectly normally when herdr is not
  # running, so it is not a signal to take at face value. Staying silent would
  # be a lie too, so surface "not live yet" as a warning.
  if ! herdr server reload-config >/dev/null 2>&1; then
    echo "warning: config updated, but 'herdr server reload-config' failed." \
         "The change takes effect the next time herdr loads its config." >&2
  fi
  return 0
}
