#!/bin/bash
# herdr-jump: キー一発で「用のあるエージェント」のペインへ飛ぶ。
# herdr のキーバインドから popup ペインとして起動されることを前提とする。

set -euo pipefail

# format_agents <self_pane_id>
#   stdin : herdr agent list の JSON
#   stdout: "表示文字列 \t pane_id" を 1 行ずつ。該当なしなら 0 行
#
# 絞り込みは一切しない。agent_status は信用できないので、blocked で
# フィルタすると本当に用のある子を隠す危険がある。並べ替えるだけにする。
format_agents() {
  local self="${1:-}"
  jq -r --arg self "${self}" '
    # jq には桁詰めの組込みが無いので空白リテラルを切って使う。
    # ("" * 0) が版によって null になる問題を避けるためこの形にしている。
    def pad($n):
      . as $s
      | ($n - ($s | length)) as $k
      | if $k > 0 then $s + ("        " | .[0:$k]) else $s end;

    def icon:
      if   . == "blocked" then "●"
      elif . == "done"    then "◍"
      elif . == "working" then "◐"
      elif . == "idle"    then "○"
      else "·" end;

    def grp:
      if   . == "blocked" or . == "done" then 1
      elif . == "working" then 2
      else 3 end;

    [ .result.agents[] | select(.pane_id != $self) ]
    | sort_by((.agent_status | grp), -(.state_change_seq))
    | .[]
    | (.terminal_title_stripped // "") as $t
    | [ ( (.agent_status | icon) + " "
          + (.agent   | pad(8)) + " "
          + (.tab_id  | pad(8)) + " "
          + (if $t == "" then "(" + .agent_status + ")" else $t end) ),
        .pane_id ]
    | @tsv
  '
}

# notify <message>
#   popup は終了と同時に消えるので stderr は目に映らない。
#   想定外の失敗はここから外へ出す。通知の失敗自体は握りつぶす。
notify() {
  herdr notification show "herdr-jump: ${1}" >/dev/null 2>&1 || true
}

main() {
  # Herdr 外からの誤実行。ここだけは popup ではないので stderr が読める
  if [[ "${HERDR_ENV:-}" != "1" ]]; then
    echo "Error: このスクリプトは herdr セッション内で実行してください。" >&2
    exit 1
  fi

  local self_pane="${HERDR_ACTIVE_PANE_ID:-}"
  if [[ -z "${self_pane}" ]]; then
    echo "Error: HERDR_ACTIVE_PANE_ID が設定されていません。キーバインドから起動してください。" >&2
    exit 1
  fi

  # 自己クローズは書かない。type = "pane" の popup は、起動したコマンドが
  # 終了した時点で herdr が自前で畳む（実測）。閉じる主体を二重にしない。

  local json
  if ! json=$(herdr agent list 2>/dev/null); then
    notify "エージェント一覧を取得できませんでした"
    exit 1
  fi

  local rows
  if ! rows=$(printf '%s' "${json}" | format_agents "${self_pane}"); then
    notify "一覧の整形に失敗しました"
    exit 1
  fi

  if [[ -z "${rows}" ]]; then
    notify "他にエージェントはいません"
    exit 0
  fi

  # --with-nth=1 で pane_id 列を隠す。選択結果には含まれたまま返ってくる
  local selected
  selected=$(printf '%s\n' "${rows}" | fzf \
    --reverse \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='jump> ' \
    --header='Enter: 移動  /  Esc: 取消') || true

  # Esc で抜けた場合。何も起きないのが正しい
  [[ -n "${selected}" ]] || exit 0

  local target="${selected##*$'\t'}"

  if ! herdr agent focus "${target}" >/dev/null 2>&1; then
    notify "フォーカスできませんでした: ${target}"
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
