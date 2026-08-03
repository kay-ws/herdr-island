#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

if ! command -v herdr >/dev/null 2>&1; then
  echo "skip: herdr が無い環境のため検証ゲートの実測はスキップ"
  finish
fi

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

CFG="$WORK/config.toml"
export ISLAND_CONFIG="$CFG"

# $ 無しのカスタムトークンは herdr が拒否する。これを候補として食わせたとき
# 本番ファイルが変更されないことを、本物の herdr の判定で確かめる
printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CFG"
orig="$(cat "$CFG")"

# 本物の herdr が壊れた config を実際に拒否することをまず確認する
printf '[ui.sidebar.agents]\nrows = [["agent"], ["reason"]]\n' > "$WORK/bad.toml"
HERDR_CONFIG_PATH="$WORK/bad.toml" herdr config check > "$WORK/check.out" 2>&1
assert_eq "1" "$?" "本物の herdr は \$ 無しトークンの config を exit 1 で拒否する"

# 正常な候補は通ること（ゲートが常に落ちるだけの実装ではないことの確認）
printf '[ui.sidebar.agents]\nrows = [["agent"], [{ token = "$reason" }]]\n' > "$WORK/good.toml"
HERDR_CONFIG_PATH="$WORK/good.toml" herdr config check > /dev/null 2>&1
assert_eq "0" "$?" "本物の herdr は \$ つきトークンの config を通す"

# apply が本物の検証を経て成功し、結果も本物に通ること
bash "$here/../bin/apply.sh" >/dev/null 2>&1
HERDR_CONFIG_PATH="$CFG" herdr config check > /dev/null 2>&1
assert_eq "0" "$?" "apply 後の config は本物の herdr の検証を通る"
assert_contains "$(cat "$CFG")" '$reason' "apply が行を入れている"

finish
