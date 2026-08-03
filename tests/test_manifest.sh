#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

M="$here/../herdr-plugin.toml"

assert_eq "yes" "$([ -f "$M" ] && echo yes || echo no)" "マニフェストが存在する"

# 途中で失敗・早期終了しても plugin link 状態を残さないための安全網
cleanup() { herdr plugin unlink island >/dev/null 2>&1; }
trap cleanup EXIT

# herdr 自身に検証させる。link できることが唯一の正解判定。
# herdr が無いときは assert_contains の失敗（期待した文字列が無い）として
# 出るだけで原因が読めないので、先に切り分けて名指しする
if ! command -v herdr >/dev/null 2>&1; then
  printf 'FAIL herdr が PATH に無いためマニフェストを検証できない\n' >&2
  _fail=1
else
  out="$(herdr plugin link "$here/.." 2>&1)"
  assert_contains "$out" '"plugin_id":"island"' "id は island"
fi
# unlink は trap の cleanup に任せる（早期終了しても確実に走る）

# rows_by_agent への「書き込み」がリポジトリに無いこと（Global Constraints）。
# 検出して警告することは Task 8 の要件そのものなので、文字列としての言及
# （grep での検出・警告文）まで禁じると要件と矛盾する。禁じるのはあくまで
# TOML への代入形（`rows_by_agent = ...`）で、これが無ければ書き込んでいない
# wc -l は BSD/macOS で空白パディングされるため数値へ正規化する
hits="$(grep -rlE 'rows_by_agent[[:space:]]*=' "$here/../bin" "$here/../lib" 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "0" "$hits" "bin/ lib/ は rows_by_agent へ書き込まない（代入形が無い）"

finish
