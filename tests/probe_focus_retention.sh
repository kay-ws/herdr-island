#!/bin/bash
# popup が閉じた後もフォーカスが移動先に残るかを実機で確かめるプローブ。
# herdr のキーバインドから popup として起動されることを前提とする。

set -uo pipefail

OUT="${HOME}/.cache/herdr-jump-probe.txt"
mkdir -p "$(dirname "${OUT}")"
: > "${OUT}"

focused_now() {
  herdr pane list 2>/dev/null | jq -r '.result.panes[] | select(.focused) | .pane_id' | tr '\n' ' '
}

# herdr が実際に何を注入するかを記録する。
# spec の env 表は file-picker の記憶に基づく推測なので、ここで実測に置き換える。
{
  echo "--- herdr が注入した env ---"
  env | grep '^HERDR' | sort || echo "(HERDR_* は 1 つも無い)"
  echo "----------------------------"
} >> "${OUT}" 2>&1

target=$(herdr agent list 2>/dev/null \
  | jq -r --arg self "${HERDR_ACTIVE_PANE_ID:-}" \
      '.result.agents[] | select(.pane_id != $self) | .pane_id' \
  | head -1)

if [[ -z "${target}" ]]; then
  echo "ABORT: 他のエージェントがいません。2つ以上起動してから再実行してください" >> "${OUT}"
  exit 1
fi

# 観測者を「フォーカスを動かす前」に切り離す。
# agent focus で popup がフォーカスを失った瞬間に herdr がペインを畳むと、
# スクリプト末尾まで到達できずに観測者を起動しそこねるため。
setsid bash -c "
  for t in 1 2 3 4 5; do
    sleep 1
    echo \"focused at t=\${t}s : \$(herdr pane list 2>/dev/null | jq -r '.result.panes[] | select(.focused) | .pane_id' | tr '\n' ' ')\" >> '${OUT}'
  done
  {
    echo '--- 判定 ---'
    echo 'target(${target}) のまま   → 設計は成立'
    echo 'origin(${HERDR_ACTIVE_PANE_ID:-?}) に戻る → 引き戻されている（黒）'
  } >> '${OUT}'
" </dev/null >/dev/null 2>&1 &

{
  echo "origin(caller) = ${HERDR_ACTIVE_PANE_ID:-<unset>}"
  echo "target         = ${target}"
  echo "focused before = $(focused_now)"
  if herdr agent focus "${target}" >/dev/null 2>&1; then
    echo "agent focus    = ok"
  else
    echo "agent focus    = FAILED"
  fi
  echo "focused after (popup still open) = $(focused_now)"
} >> "${OUT}" 2>&1
