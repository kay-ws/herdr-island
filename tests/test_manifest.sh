#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

M="$here/../herdr-plugin.toml"

assert_eq "yes" "$([ -f "$M" ] && echo yes || echo no)" "マニフェストが存在する"

# 途中で失敗・早期終了しても plugin link 状態を残さないための安全網
cleanup() { herdr plugin unlink island >/dev/null 2>&1; }
trap cleanup EXIT

# herdr 自身に検証させる。link できることが唯一の正解判定
out="$(herdr plugin link "$here/.." 2>&1)"
assert_contains "$out" '"plugin_id":"island"' "id は island"
herdr plugin unlink island >/dev/null 2>&1

# rows_by_agent への言及がリポジトリに残っていないこと（Global Constraints）
hits="$(grep -rl 'rows_by_agent' "$here/../bin" "$here/../lib" 2>/dev/null | wc -l)"
assert_eq "0" "$hits" "bin/ lib/ は rows_by_agent を書かない"

finish
