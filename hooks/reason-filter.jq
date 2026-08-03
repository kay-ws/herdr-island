# フック payload から Agents パネル用の 1 行を組み立てる。
# 入力: PermissionRequest / PreToolUse / Elicitation のいずれかの payload
# 出力: 40 文字以内の文字列 1 行（jq -r で使うこと）

def trunc($n):
  if (. | length) > $n then (.[0:$n-1] + "…") else . end;

def base: split("/") | last;

# MCP ツールか。tool_name は `mcp__<サーバ>__<ツール>` の形
def is_mcp: (.tool_name // "") | startswith("mcp__");

# MCP ツール名からサーバ部分を落とす。
# 先頭 2 区切り（"mcp" と サーバ名）を捨てて残りを繋ぎ直す。
# `split("__") | last` にすると、ツール名自体に __ を含むとき後半しか残らない。
# 区切りが足りない壊れた形では空文字になり、呼び出し側で見出しだけになる
def mcp_tool: (.tool_name // "") | split("__") | .[2:] | join("__");

# tool ごとの本文。取れなければ空文字
def body:
  .tool_name as $t
  | (.tool_input // {}) as $i
  | if is_mcp then
      # 素の tool_name は実測 48 文字あり、しかも先頭 39 文字がサーバ名まででほぼ
      # 埋まる。そのまま出すと trunc(40) と herdr 側の幅切り詰めで二重に削られ、
      # **表示が全部ボイラープレートになり何のツールで止まっているか一文字も
      # 出ない**（実機で確認）。情報があるのは末尾のツール名なのでそこだけ残す
      mcp_tool
    elif $t == "Bash" then
      ($i.description // $i.command // "")
    elif $t == "Edit" or $t == "Write" or $t == "Read" or $t == "NotebookEdit" then
      (($i.file_path // "") | if . == "" then "" else base end)
    elif $t == "AskUserQuestion" then
      ($i.questions[0].header // $i.questions[0].question // "")
    else
      ""
    end;

# 行頭に出す見出し。label は jq の予約語（label $out | break）なので使えない
def heading:
  # 他の tool は .tool_name をそのまま出す（Bash / Edit …）ので既定は英語。
  # AskUserQuestion だけ短縮する —— そのまま出すと 15 文字で、40 文字上限と
  # サイドバー幅の両方を圧迫し、肝心の本文が truncate される。
  # MCP も同様に潰す。Elicitation の分岐が既に "MCP: " を出しているので語彙が揃う
  if is_mcp then "MCP"
  elif .tool_name == "AskUserQuestion" then "Question"
  else (.tool_name // "?") end;

if .hook_event_name == "Elicitation" then
  # message も server 名も取れないときのフォールバック。これはプラグインが
  # 生成する文言であって利用者の payload ではないので英語で出す
  "MCP: " + (.message // .mcp_server_name // "input needed")
else
  (heading as $h | body as $b
   | if $b == "" then $h else ($h + ": " + $b) end)
end
| trunc(40)
