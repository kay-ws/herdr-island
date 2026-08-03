#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

FILTER="$here/../hooks/reason-filter.jq"

# reason <json> -> 組み立て結果
reason() { printf '%s' "$1" | jq -r -f "$FILTER"; }

assert_eq "Bash: Remove node_modules" \
  "$(reason '{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules"}}')" \
  "Bash は description を優先"

assert_eq "Bash: ls -la" \
  "$(reason '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')" \
  "description が無ければ command"

assert_eq "Edit: c.sh" \
  "$(reason '{"tool_name":"Edit","tool_input":{"file_path":"/a/b/c.sh"}}')" \
  "Edit は basename"

assert_eq "Write: memo.md" \
  "$(reason '{"tool_name":"Write","tool_input":{"file_path":"/x/memo.md"}}')" \
  "Write も basename"

assert_eq "Question: 実装方針" \
  "$(reason '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"実装方針"}]}}')" \
  "AskUserQuestion は header"

assert_eq "WebFetch" \
  "$(reason '{"tool_name":"WebFetch","tool_input":{}}')" \
  "未知 tool は名前だけ"

# --- MCP ツール ---
# 素の tool_name は `mcp__<サーバ>__<ツール>` で、実測 48 文字。そのまま出すと
# 40 文字に切られた上に herdr が幅で更に 31 文字へ切るので、**表示が全部
# ボイラープレートになり何のツールで止まっているか一文字も出ない**（実機で確認）。
# サーバ名は落として `MCP: <ツール>` にする。Elicitation の分岐が既に
# "MCP: " を使っているので語彙も揃う
assert_eq "MCP: ctx_stats" \
  "$(reason '{"tool_name":"mcp__plugin_context-mode_context-mode__ctx_stats","tool_input":{}}')" \
  "MCP ツールはサーバ名を落として MCP: <ツール>"

assert_eq "MCP: list_events" \
  "$(reason '{"tool_name":"mcp__claude_ai_Google_Calendar__list_events","tool_input":{}}')" \
  "サーバ名に _ が含まれても切り出せる"

# ツール名側に __ が入っても最後の 1 区切りだけを落とさない。
# split("__")|last だと "b" になってしまう
assert_eq "MCP: a__b" \
  "$(reason '{"tool_name":"mcp__srv__a__b","tool_input":{}}')" \
  "ツール名に __ が含まれても全部残す"

# 壊れた形（区切りが足りない）でも落ちず、見出しだけになる
assert_eq "MCP" \
  "$(reason '{"tool_name":"mcp__onlyserver","tool_input":{}}')" \
  "区切りが足りない MCP 名でも落ちない"

# mcp__ で始まらないものを巻き込まない
assert_eq "mcpfoo" \
  "$(reason '{"tool_name":"mcpfoo","tool_input":{}}')" \
  "mcp__ で始まらない名前は素通し"

assert_eq "Edit" \
  "$(reason '{"tool_name":"Edit","tool_input":{"file_path":"/a/b/"}}')" \
  "file_path が / 終わりでも落ちず見出しのみになる"

assert_eq "Bash" \
  "$(reason '{"tool_name":"Bash","tool_input":{}}')" \
  "tool_input が空でも落ちない"

assert_eq "Bash" \
  "$(reason '{"tool_name":"Bash"}')" \
  "tool_input 自体が無くても落ちない"

# 40 文字ちょうどは切らない。"Bash: " が 6 文字なので本文 34 文字
body34="0123456789012345678901234567890123"
assert_eq "Bash: $body34" \
  "$(reason "$(jq -nc --arg c "$body34" '{tool_name:"Bash",tool_input:{command:$c}}')")" \
  "40 文字ちょうどは切らない"

# 41 文字は 39 文字 + … に切られる（"Bash: " 6 文字 + 本文 33 文字 + …）
body35="01234567890123456789012345678901234"
assert_eq "Bash: 012345678901234567890123456789012…" \
  "$(reason "$(jq -nc --arg c "$body35" '{tool_name:"Bash",tool_input:{command:$c}}')")" \
  "41 文字は 39 文字 + … に切られる"

# 日本語 41 文字。バイト境界ではなく文字境界で切れること。
# 文字数は jq で数える。wc -m はロケール依存で、LC_ALL=C だとバイト数になる
jbody='あいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあ'
jout="$(reason "$(jq -nc --arg h "$jbody" '{tool_name:"AskUserQuestion",tool_input:{questions:[{header:$h}]}}')")"
assert_eq "40"   "$(printf '%s' "$jout" | jq -Rr 'length')"                  "日本語でも 40 文字に収まる"
assert_eq "true" "$(printf '%s' "$jout" | jq -Rr 'endswith("…")')"           "日本語でも … が付く"
assert_eq "true" "$(printf '%s' "$jout" | jq -Rr 'startswith("Question: あいうえお")')" "先頭は保たれる"

finish
