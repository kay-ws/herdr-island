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
  # 存在確認を外側に置く。`herdr plugin uninstall` は remove を実行しないため、
  # このエントリは利用者の settings.json に残り、GitHub インストール版では
  # 指す先（管理下のチェックアウト）だけが消える。素に `bash <path>` と書くと
  # そこで exit 127 になり、以後すべての PermissionRequest でエラーが出る。
  # 「必ず exit 0」の防御は消えたファイルの中にあるので効かない。
  printf "bash -c '[ -f \"\$0\" ] || exit 0; exec bash \"\$0\"' '%s/hooks/island-reason.sh'" "$root"
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

# _preflight_json <file> : file が存在しないか妥当な JSON なら 0、壊れていれば 1。
# 読み取り専用（作成も書き換えもしない）。_wire_both が両方の書き込みに
# 入る前にこれで両ファイルを検査し、片方が壊れているせいでもう片方だけ
# 書き換わってしまう事故（I4）を根元で潰す
_preflight_json() {
  local f="$1"
  [ -f "$f" ] || return 0
  jq empty "$f" >/dev/null 2>&1
}

# _wire_both <install|uninstall> : rc 0=変更した / 10=変更不要 / 1=失敗（何も書いていない）
# / 12=部分適用（一方は書けたがもう一方が失敗した。どちらがどちらかは
# stderr にファイル名で出す）
#
# 2 ファイルを順に処理する。まず両方を pre-flight で検査し、どちらかが
# 壊れていれば「候補を検証してから置く」の原則どおり、どちらにも触れず
# 中断する（rc 1）。pre-flight を通った後も権限やディスク容量など
# 予測できない理由で書き込みが失敗することはあり得るので、その場合は
# 「何も変更していない」と嘘をつかず、変更できたファイルと失敗した
# ファイルを名指しして rc 12 を返す。ロールバックはしない —
# バックアップからの復元自体が失敗し得る書き込みであり、バックアップは
# 利用者が自分で判断できるように残してあるものだから
_wire_both() {
  local op="$1" changed=1 rc
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
    [ "$rc" -eq 0 ] && { changed=0; wrote+=("$f"); }
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

# エージェントごとの配線状況を 1 行ずつ出す。
# count は両ファイルの和集合なので「Claude だけ配線済み」でも 2 を返し、
# doctor が最も知りたい部分配線を映せない。診断はこちらを使う
island_hooks_status() {
  # ラベルはファイルの中身/パスではなく「何番目に処理したか」で決める。
  # パスの部分一致（*codex*）で判定すると、ISLAND_CODEX_HOOKS が
  # "hooks.json" のような "codex" を含まない名前のとき（テスト fixture が
  # まさにこの形）両方 claude に化ける。呼び出し順は claude → codex で固定
  # なので、位置で決めれば環境変数の値に依存しない。
  local files=("$(claude_settings)" "$(codex_hooks)")
  local labels=(claude codex)
  local i f label c
  for i in 0 1; do
    f="${files[$i]}"
    label="${labels[$i]}"
    if [ ! -f "$f" ]; then
      printf '%s: file missing\n' "$label"
      continue
    fi
    c="$(jq -r '[ (.hooks // {}) | to_entries[] | .key as $event | .value[]? | select(.hooks[]?.command // "" | test("island-reason")) | $event + ":" + (.matcher // "") ] | unique | length' "$f" 2>/dev/null)"
    [ -n "$c" ] || c=0
    printf '%s: %s/2\n' "$label" "$c"
  done
}

case "${1:-}" in
  install)   island_hooks_install ;;
  uninstall) island_hooks_uninstall ;;
  count)     island_hooks_count ;;
  status)    island_hooks_status ;;
  *) echo "usage: hooks.sh {install|uninstall|count|status}" >&2; exit 1 ;;
esac
