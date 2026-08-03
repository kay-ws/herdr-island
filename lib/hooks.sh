#!/bin/bash
# agent CLI 側の hook を配線する。理由を「立てる」1 本だけを入れる。
#
# clear はこちらに入れない。herdr の pane.agent_status_changed が担当する
# （bin/on-status-changed.sh）。そのぶん他人の settings.json への侵襲が減る。
set -uo pipefail

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }

island_hook_cmd() {
  local root; root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  printf "bash '%s/hooks/island-reason.sh'" "$root"
}

# _wire <file> <install|uninstall> : rc 0=変更した / 10=変更不要 / 1=失敗
_wire() {
  local f="$1" op="$2"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  [ -f "$f" ] || echo '{}' > "$f" || return 1

  # 壊れた JSON には触らない。jq が失敗した結果を書き戻すと被害が広がる
  jq empty "$f" >/dev/null 2>&1 || return 1

  local cmd; cmd="$(island_hook_cmd)"
  local work; work="$(mktemp -d -p /tmp)" || return 1
  local cand="$work/out.json"

  jq --arg cmd "$cmd" --arg op "$op" '
    # 自分のエントリだけを取り除く。他人の hook には触らない。
    # .hooks が無い / null のグループがあっても落ちないよう (. // []) で守る
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
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$f" > "$cand" 2>/dev/null || { rm -rf "$work"; return 1; }

  jq empty "$cand" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }

  if cmp -s "$f" "$cand"; then rm -rf "$work"; return 10; fi

  cp -p "$f" "$f.bak.$(date +%Y%m%d-%H%M%S-%3N)" || { rm -rf "$work"; return 1; }
  local stage; stage="$(mktemp "$(dirname "$f")/.island.XXXXXX")" || { rm -rf "$work"; return 1; }
  cat "$cand" > "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  chmod --reference="$f" "$stage" 2>/dev/null
  mv -f "$stage" "$f" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  rm -rf "$work"
  return 0
}

# 2 ファイルを順に処理する。どちらかが変更されれば 0、両方不要なら 10
_wire_both() {
  local op="$1" changed=1 rc
  local f
  for f in "$(claude_settings)" "$(codex_hooks)"; do
    _wire "$f" "$op"; rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -eq 0 ] && changed=0
  done
  [ "$changed" -eq 0 ] && return 0
  return 10
}

island_hooks_install()   { _wire_both install; }
island_hooks_uninstall() { _wire_both uninstall; }

island_hooks_count() {
  # 「立てる」側は PermissionRequest(*) と PreToolUse(AskUserQuestion) の
  # 2 スロットしか無い。settings.json と hooks.json の両方に同じ 2 スロットを
  # 配線するので、ファイルごとの生エントリを単純合算すると常に 4 になり
  # 「配線済みなら 2」という doctor の前提と食い違う。event:matcher で
  # 重複排除し、実際に存在するスロット数を返す。
  local f
  {
    for f in "$(claude_settings)" "$(codex_hooks)"; do
      [ -f "$f" ] || continue
      jq -r '
        (.hooks // {}) | to_entries[]
        | .key as $event
        | .value[]?
        | select(.hooks[]?.command // "" | test("island-reason"))
        | $event + ":" + (.matcher // "")
      ' "$f" 2>/dev/null
    done
  } | sort -u | wc -l
}

case "${1:-}" in
  install)   island_hooks_install ;;
  uninstall) island_hooks_uninstall ;;
  count)     island_hooks_count ;;
  *) echo "usage: hooks.sh {install|uninstall|count}" >&2; exit 1 ;;
esac
