# フック payload から Agents パネル用の 1 行を組み立てる。
# 入力: PermissionRequest / PreToolUse / Elicitation のいずれかの payload
# 出力: 40 文字以内の文字列 1 行（jq -r で使うこと）

def trunc($n):
  if (. | length) > $n then (.[0:$n-1] + "…") else . end;

def base: split("/") | last;

# tool ごとの本文。取れなければ空文字
def body:
  .tool_name as $t
  | (.tool_input // {}) as $i
  | if $t == "Bash" then
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
  # サイドバー幅の両方を圧迫し、肝心の本文が truncate される
  if .tool_name == "AskUserQuestion" then "Question" else (.tool_name // "?") end;

if .hook_event_name == "Elicitation" then
  # message も server 名も取れないときのフォールバック。これはプラグインが
  # 生成する文言であって利用者の payload ではないので英語で出す
  "MCP: " + (.message // .mcp_server_name // "input needed")
else
  (heading as $h | body as $b
   | if $b == "" then $h else ($h + ": " + $b) end)
end
| trunc(40)
