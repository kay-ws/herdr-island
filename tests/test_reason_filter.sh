#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

FILTER="$here/../hooks/reason-filter.jq"

# reason <json> -> the assembled result
reason() { printf '%s' "$1" | jq -r -f "$FILTER"; }

assert_eq "Bash: Remove node_modules" \
  "$(reason '{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules"}}')" \
  "Bash prefers description"

assert_eq "Bash: ls -la" \
  "$(reason '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')" \
  "command is used when there is no description"

assert_eq "Edit: c.sh" \
  "$(reason '{"tool_name":"Edit","tool_input":{"file_path":"/a/b/c.sh"}}')" \
  "Edit uses the basename"

assert_eq "Write: memo.md" \
  "$(reason '{"tool_name":"Write","tool_input":{"file_path":"/x/memo.md"}}')" \
  "Write uses the basename too"

assert_eq "Question: Design approach" \
  "$(reason '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Design approach"}]}}')" \
  "AskUserQuestion uses the header"

assert_eq "WebFetch" \
  "$(reason '{"tool_name":"WebFetch","tool_input":{}}')" \
  "an unknown tool shows only its name"

# --- MCP tools ---
# A raw tool_name is `mcp__<server>__<tool>` and measured 48 characters. Emitted
# as-is it is cut to 40, and then herdr's width clamp cuts it again to 31, so
# **the display becomes pure boilerplate without a single character telling you
# which tool is blocking** (confirmed on a real machine). Drop the server name
# and produce `MCP: <tool>`. The Elicitation branch already uses "MCP: ", so the
# vocabulary lines up.
assert_eq "MCP: ctx_stats" \
  "$(reason '{"tool_name":"mcp__plugin_context-mode_context-mode__ctx_stats","tool_input":{}}')" \
  "an MCP tool drops the server name and becomes MCP: <tool>"

assert_eq "MCP: list_events" \
  "$(reason '{"tool_name":"mcp__claude_ai_Google_Calendar__list_events","tool_input":{}}')" \
  "it still extracts correctly when the server name contains _"

# Do not drop everything but the last segment when the *tool* name contains __.
# split("__")|last would leave just "b".
assert_eq "MCP: a__b" \
  "$(reason '{"tool_name":"mcp__srv__a__b","tool_input":{}}')" \
  "a tool name containing __ is kept whole"

# A malformed name (too few separators) does not blow up; only the heading remains
assert_eq "MCP" \
  "$(reason '{"tool_name":"mcp__onlyserver","tool_input":{}}')" \
  "an MCP name with too few separators does not blow up"

# Names that do not start with mcp__ must not be swept up
assert_eq "mcpfoo" \
  "$(reason '{"tool_name":"mcpfoo","tool_input":{}}')" \
  "a name not starting with mcp__ passes through untouched"

assert_eq "Edit" \
  "$(reason '{"tool_name":"Edit","tool_input":{"file_path":"/a/b/"}}')" \
  "a file_path ending in / does not blow up; only the heading remains"

assert_eq "Bash" \
  "$(reason '{"tool_name":"Bash","tool_input":{}}')" \
  "an empty tool_input does not blow up"

assert_eq "Bash" \
  "$(reason '{"tool_name":"Bash"}')" \
  "a missing tool_input does not blow up"

# Exactly 40 characters is not cut. "Bash: " is 6 characters, so the body is 34.
body34="0123456789012345678901234567890123"
assert_eq "Bash: $body34" \
  "$(reason "$(jq -nc --arg c "$body34" '{tool_name:"Bash",tool_input:{command:$c}}')")" \
  "exactly 40 characters is not cut"

# 41 characters is cut to 39 + … ("Bash: " 6 + body 33 + …)
body35="01234567890123456789012345678901234"
assert_eq "Bash: 012345678901234567890123456789012…" \
  "$(reason "$(jq -nc --arg c "$body35" '{tool_name:"Bash",tool_input:{command:$c}}')")" \
  "41 characters is cut to 39 + …"

# 41 Japanese characters — the cut must land on a character boundary, not a byte
# one. The data stays Japanese on purpose: multibyte input is the whole point of
# this test. Count with jq; wc -m is locale-dependent and returns bytes under
# LC_ALL=C.
jbody='あいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあいうえおかきくけこあ'
jout="$(reason "$(jq -nc --arg h "$jbody" '{tool_name:"AskUserQuestion",tool_input:{questions:[{header:$h}]}}')")"
assert_eq "40"   "$(printf '%s' "$jout" | jq -Rr 'length')"                  "multibyte text still fits in 40 characters"
assert_eq "true" "$(printf '%s' "$jout" | jq -Rr 'endswith("…")')"           "multibyte text still gets the … suffix"
assert_eq "true" "$(printf '%s' "$jout" | jq -Rr 'startswith("Question: あいうえお")')" "the leading characters survive"

finish
