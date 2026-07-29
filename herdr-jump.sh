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

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
