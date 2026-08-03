#!/bin/bash
# agent CLI 側の hook を配線する。3 本:
#   PermissionRequest(*)              … 理由を立てる
#   PreToolUse(AskUserQuestion)       … 理由を立てる
#   PostToolUse(matcher 無し)         … 理由を消す
#
# clear は herdr の pane.agent_status_changed（bin/on-status-changed.sh）でも
# 行うが、あちらは状態が遷移したときしか発火しない。auto mode で自動承認された
# 許可要求はエージェントを blocked にしないため遷移が起きず、セットだけが起きて
# クリアが起きなかった（実測で TTL 15 分まで残留）。ツールの完了は必ず起きるので
# PostToolUse なら確実に対になる。戻したのはこの 1 本だけで、旧実装の
# PostToolBatch / Stop には配線しない。
set -uo pipefail

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }

# island_hook_cmd [clear] : 配線するコマンド文字列。引数を付けると clear 用
island_hook_cmd() {
  local root; root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local arg="${1:-}"
  # 存在確認を外側に置く。`herdr plugin uninstall` は remove を実行しないため、
  # このエントリは利用者の settings.json に残り、GitHub インストール版では
  # 指す先（管理下のチェックアウト）だけが消える。素に `bash <path>` と書くと
  # そこで exit 127 になり、以後すべての PermissionRequest でエラーが出る。
  # 「必ず exit 0」の防御は消えたファイルの中にあるので効かない。
  if [ -n "$arg" ]; then
    printf "bash -c '[ -f \"\$0\" ] || exit 0; exec bash \"\$0\" %s' '%s/hooks/island-reason.sh'" \
      "$arg" "$root"
  else
    printf "bash -c '[ -f \"\$0\" ] || exit 0; exec bash \"\$0\"' '%s/hooks/island-reason.sh'" "$root"
  fi
}

# _wire <file> <install|uninstall> : rc 0=変更した / 10=変更不要 / 11=対象なし / 1=失敗
_wire() {
  local f="$1" op="$2"
  # 設定ディレクトリの有無を「そのエージェントが入っているか」の判定に使う。
  # ここで mkdir -p すると Codex を使っていない利用者のホームに ~/.codex/ と
  # {} が生え、以後 status が codex: 0/3 と出る —— 「入れていない」と
  # 「入れたが未配線」が区別できなくなり、doctor が何も診断できない。
  # 無いものは配線対象から外す（失敗ではない）
  [ -d "$(dirname "$f")" ] || return 11
  [ -f "$f" ] || echo '{}' > "$f" || return 1

  # 壊れた JSON には触らない。jq が失敗した結果を書き戻すと被害が広がる
  jq empty "$f" >/dev/null 2>&1 || return 1

  local cmd; cmd="$(island_hook_cmd)"
  local clear_cmd; clear_cmd="$(island_hook_cmd clear)"
  local work; work="$(mktemp -d -p /tmp)" || return 1
  local cand="$work/out.json"

  jq --arg cmd "$cmd" --arg clear_cmd "$clear_cmd" --arg op "$op" '
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
    # 消す側。セットの契機（許可要求 / 質問）に対して、ツール完了は必ず起きるので
    # 確実に対になる。herdr の pane.agent_status_changed は状態が遷移したときしか
    # 発火せず、auto mode で自動承認された許可要求のように「止まらない」経路では
    # クリアが起きない（実測で TTL 15 分まで残留）。
    # 戻すのは PostToolUse だけ —— 旧実装の PostToolBatch / Stop には配線しない。
    | .hooks.PostToolUse       = ((.hooks.PostToolUse | purge)
        + (if $op == "install" then [entry(""; $clear_cmd)] else [] end))
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$f" > "$cand" 2>/dev/null || { rm -rf "$work"; return 1; }

  jq empty "$cand" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }

  if cmp -s "$f" "$cand"; then rm -rf "$work"; return 10; fi

  # %3N は GNU 拡張。一意名の生成は mktemp に任せる（bin/_config.sh と同じ理由）
  local bak; bak="$(mktemp "$f.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" \
    || { rm -rf "$work"; return 1; }
  cp -p "$f" "$bak" || { rm -rf "$work"; return 1; }
  local stage; stage="$(mktemp "$(dirname "$f")/.island.XXXXXX")" || { rm -rf "$work"; return 1; }
  # 権限は cp -p で運ぶ（bin/_config.sh と同じ理由）。chmod --reference は
  # GNU 拡張で macOS には無く、握り潰していたため settings.json が
  # 0600 に化けていた
  cp -p "$f" "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  cat "$cand" > "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
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
  # 全部が「そのエージェントは入っていない」で飛ばされた場合。rc 10 のまま
  # 返すと「もう配線済み」と区別がつかないので、何も配線しなかったことを言う
  if [ "$skipped" -eq "${#files[@]}" ]; then
    echo "no agent config directory found — nothing to wire." \
      "Looked for $(dirname "${files[0]}") and $(dirname "${files[1]}")." >&2
  fi
  [ "$changed" -eq 0 ] && return 0
  return 10
}

island_hooks_install()   { _wire_both install; }
island_hooks_uninstall() { _wire_both uninstall; }

island_hooks_count() {
  # スロットは PermissionRequest(*) / PreToolUse(AskUserQuestion) /
  # PostToolUse の 3 つしか無い。settings.json と hooks.json の両方に同じ 3 スロットを
  # 配線するので、ファイルごとの生エントリを単純合算すると常に 4 になり
  # 「配線済みなら 3」という doctor の前提と食い違う。event:matcher で
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
  # wc -l は BSD/macOS では先頭を空白でパディングする（"       2"）。
  # 値は正しくても文字列比較に使う側で落ちるので、ここで数値へ正規化する
  } | sort -u | wc -l | tr -d '[:space:]'
}

# エージェントごとの配線状況を 1 行ずつ出す。
# count は両ファイルの和集合なので「Claude だけ配線済み」でも 3 を返し、
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
    # ディレクトリの有無で「未導入」と「導入済みだが未配線」を分ける。
    # island は ~/.codex/ を作らないので、無いことがそのまま
    # 「Codex を使っていない」の意味になる（診断すべきことが無い）
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
  count)     island_hooks_count ;;
  status)    island_hooks_status ;;
  *) echo "usage: hooks.sh {install|uninstall|count|status}" >&2; exit 1 ;;
esac
