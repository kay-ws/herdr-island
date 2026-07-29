# herdr Agents パネル情報拡充 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** herdr の Agents パネルに「何で止まっているか」と context 使用率を表示し、パネルを見ただけで用のあるエージェントが分かる状態を作る。

**Architecture:** 独立した2本の配管。(1) Claude/Codex のフックが `PermissionRequest` などを捕まえて `herdr pane report-metadata --token reason=...` を打つ。(2) `ccstatus`（statusLine）が stdin JSON から使用率を読んで同じく打つ。表示は herdr の `[ui.sidebar.agents.rows_by_agent]` が担う。文字列の組み立ては jq フィルタに切り出し、シェルから独立してテストする。

**Tech Stack:** bash / jq / herdr CLI 0.7.5

**Spec:** [docs/superpowers/specs/2026-07-30-herdr-agent-status-design.md](../specs/2026-07-30-herdr-agent-status-design.md)

## Global Constraints

- 依存は `jq` と `herdr` CLI のみ。`python3` / `fzf` は使わない
- **全経路で失敗を握り潰す。** フックは必ず `exit 0` する。表示が出ないのは許容、エージェントが止まるのは許容しない
- ガードは4つ全て: `HERDR_ENV=1` / `HERDR_PANE_ID` 非空 / `herdr` 存在 / `jq` 存在
- `report-metadata` の `--source` は常に `herdr-jump`
- `--seq` は常に `$(date +%s%3N)`（ミリ秒 epoch）
- TTL: reason = `900000`（15分）、usage = `3600000`（1時間）
- reason の切り捨ては **40 文字**、jq の文字列スライスで行う（UTF-8 コードポイント単位）
- 既存ファイルを書き換える前に必ず `.bak.$(date +%Y%m%d-%H%M%S)` を取る
- コミットメッセージは日本語。1行目に `種別: 概要`、空行、箇条書き

---

### Task 1: v1 の撤去

v1 のペイン切り替え UI を消す。これを先にやらないと `tests/run.sh` が古い
`test_format_agents.sh` を拾い続け、新しいテストと混ざる。

**Files:**
- Delete: `herdr-jump.sh`
- Delete: `tests/test_format_agents.sh`
- Delete: `tests/probe_focus_retention.sh`
- Keep: `tests/assert.sh`, `tests/run.sh`（テストの骨格として再利用）

- [ ] **Step 1: 削除**

```bash
cd /home/kay/project/herdr-jump
git rm herdr-jump.sh tests/test_format_agents.sh tests/probe_focus_retention.sh
```

- [ ] **Step 2: テストランナーが空でも通ることを確認**

Run: `bash tests/run.sh`
Expected: `=== ALL TESTS PASSED ===`（対象が0件でも for ループは回らず fail=0 のまま抜ける）

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
削除: v1 のペイン切り替え UI を撤去

herdr 0.7.5 の Agents パネルがクリックで同じことをするため重複。
テストの骨格 (assert.sh / run.sh) は新機能で再利用するので残す。
EOF
)"
```

---

### Task 2: reason 文字列フィルタ

フック payload から Agents パネルに出す1行を組み立てる jq フィルタ。
本機能で唯一ロジックらしいロジックなので、シェルや herdr から独立させて TDD する。

**Files:**
- Create: `hooks/reason-filter.jq`
- Create: `tests/test_reason_filter.sh`

**Interfaces:**
- Consumes: なし
- Produces: `hooks/reason-filter.jq` — stdin にフック payload の JSON、stdout に1行の文字列。
  `jq -r -f hooks/reason-filter.jq` で使う。Task 3 が呼ぶ。

- [ ] **Step 1: 失敗するテストを書く**

Create `tests/test_reason_filter.sh`:

```bash
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

assert_eq "質問: 実装方針" \
  "$(reason '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"実装方針"}]}}')" \
  "AskUserQuestion は header"

assert_eq "WebFetch" \
  "$(reason '{"tool_name":"WebFetch","tool_input":{}}')" \
  "未知 tool は名前だけ"

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
assert_eq "true" "$(printf '%s' "$jout" | jq -Rr 'startswith("質問: あいうえお")')" "先頭は保たれる"

finish
```

- [ ] **Step 2: 失敗を確認**

Run: `bash tests/test_reason_filter.sh`
Expected: FAIL。`jq: error: Could not open ... hooks/reason-filter.jq` で全ケースが落ちる

- [ ] **Step 3: フィルタを実装**

Create `hooks/reason-filter.jq`:

```jq
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

def label:
  if .tool_name == "AskUserQuestion" then "質問" else (.tool_name // "?") end;

if .hook_event_name == "Elicitation" then
  "MCP: " + (.message // .mcp_server_name // "入力待ち")
else
  (label as $l | body as $b
   | if $b == "" then $l else ($l + ": " + $b) end)
end
| trunc(40)
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bash tests/test_reason_filter.sh`
Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add hooks/reason-filter.jq tests/test_reason_filter.sh
git commit -m "$(cat <<'EOF'
機能: reason 文字列の組み立てフィルタを追加

- Bash は description 優先、無ければ command
- Edit/Write/Read は file_path の basename
- AskUserQuestion は questions[0].header
- 40 文字で切り捨て。jq のスライスは UTF-8 コードポイント単位なので
  日本語混じりでもバイト境界を割らない
EOF
)"
```

---

### Task 3: reason フック本体

ガードを通し、フィルタを呼び、`herdr pane report-metadata` を打つ。
set と clear の両方をこの1本で受ける（第1引数で分岐）。Claude と Codex で共用する。

**Files:**
- Create: `hooks/herdr-jump-reason.sh`
- Create: `tests/test_reason_hook.sh`

**Interfaces:**
- Consumes: `hooks/reason-filter.jq`（Task 2）
- Produces: `hooks/herdr-jump-reason.sh` — 引数は `set` または `clear`。
  stdin にフック payload。Task 7 の install.sh がこのパスを settings.json と
  hooks.json に書き込む。

- [ ] **Step 1: 失敗するテストを書く**

herdr CLI は実機にしか無いので、PATH の先頭に偽 `herdr` を置いて呼び出し引数を記録する。

Create `tests/test_reason_hook.sh`:

```bash
#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

HOOK="$here/../hooks/herdr-jump-reason.sh"

# 偽 herdr を仕込んだ一時 PATH を作る。引数を $CAPTURE に 1 行で吐く
setup_fake_herdr() {
  FAKE_DIR="$(mktemp -d)"
  CAPTURE="$FAKE_DIR/captured"
  cat > "$FAKE_DIR/herdr" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CAPTURE"
exit 0
FAKE
  chmod +x "$FAKE_DIR/herdr"
  export CAPTURE
  export PATH="$FAKE_DIR:$PATH"
}

teardown_fake_herdr() { rm -rf "$FAKE_DIR"; }

# run_hook <mode> <json> : ガードを揃えてフックを実行し、捕まえた引数を返す
run_hook() {
  : > "$CAPTURE"
  printf '%s' "$2" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" "$1" >/dev/null 2>&1
  cat "$CAPTURE"
}

setup_fake_herdr

out="$(run_hook set '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')"
assert_contains "$out" "pane report-metadata" "set は report-metadata を呼ぶ"
assert_contains "$out" "--source herdr-jump"  "source は herdr-jump"
assert_contains "$out" "reason=Bash: ls -la"  "reason トークンに本文が乗る"
assert_contains "$out" "--ttl-ms 900000"      "reason の TTL は 15 分"
assert_contains "$out" "w0:p1"                "対象ペインは HERDR_PANE_ID"

out="$(run_hook clear '{}')"
assert_contains "$out" "--clear-token reason" "clear は reason を消す"

# --- ガード。いずれも herdr を呼ばずに黙って抜けること ---

: > "$CAPTURE"
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_ENV が 1 でなければ何もしない"

: > "$CAPTURE"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" set >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_PANE_ID が空なら何もしない"

: > "$CAPTURE"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "モード引数が無ければ何もしない"

# --- 終了コード。フックは何があっても 0 で抜けること ---

printf 'this is not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '{}' | HERDR_ENV=0 bash "$HOOK" set >/dev/null 2>&1
assert_eq "0" "$?" "ガードで抜ける時も exit 0"

teardown_fake_herdr
finish
```

- [ ] **Step 2: 失敗を確認**

Run: `bash tests/test_reason_hook.sh`
Expected: FAIL。`herdr-jump-reason.sh` が無いので全 assert が落ちる

- [ ] **Step 3: フックを実装**

Create `hooks/herdr-jump-reason.sh`:

```bash
#!/bin/bash
# herdr Agents パネルに「何で止まっているか」を出す。
#
# 使い方: このスクリプトを Claude Code / Codex のフックから呼ぶ。
#   set   … PermissionRequest / PreToolUse(AskUserQuestion) / Elicitation
#   clear … PostToolBatch / Stop
#
# 何があっても exit 0 する。表示が出ないのは許容できるが、
# 非ゼロ終了でエージェントの動作に影響を与えるのは許容できない。

mode="${1:-}"
[ "$mode" = "set" ] || [ "$mode" = "clear" ] || exit 0

# ガード。herdr のペイン内で起動されたプロセスだけが通る。
# HERDR_PANE_ID はペイン内の全プロセスツリーに継承されるので、
# その存在自体がペイン所属の証明になる。
[ "${HERDR_ENV:-}" = "1" ]     || exit 0
[ -n "${HERDR_PANE_ID:-}" ]    || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq    >/dev/null 2>&1 || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
seq_ms="$(date +%s%3N)" || exit 0

if [ "$mode" = "clear" ]; then
  herdr pane report-metadata \
    --source herdr-jump \
    --clear-token reason \
    --seq "$seq_ms" \
    "$HERDR_PANE_ID" >/dev/null 2>&1
  exit 0
fi

# stdin の payload から 1 行を組み立てる。壊れた JSON なら空になる
reason="$(jq -r -f "$here/reason-filter.jq" 2>/dev/null)"
[ -n "$reason" ] || exit 0

herdr pane report-metadata \
  --source herdr-jump \
  --token "reason=$reason" \
  --seq "$seq_ms" \
  --ttl-ms 900000 \
  "$HERDR_PANE_ID" >/dev/null 2>&1

exit 0
```

- [ ] **Step 4: 実行権を付けてテスト**

```bash
chmod +x hooks/herdr-jump-reason.sh
bash tests/test_reason_hook.sh
```

Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add hooks/herdr-jump-reason.sh tests/test_reason_hook.sh
git commit -m "$(cat <<'EOF'
機能: reason を push/clear するフック本体を追加

- set/clear を第 1 引数で分岐。Claude と Codex で共用する
- ガード 4 連（HERDR_ENV / HERDR_PANE_ID / herdr / jq）
- 壊れた JSON でも必ず exit 0。エージェントを止めない
EOF
)"
```

---

### Task 4: usage 文字列フィルタ

statusLine の stdin JSON から context 使用率と rate limits を組み立てる。

**Files:**
- Create: `statusline/usage-filter.jq`
- Create: `tests/test_usage_filter.sh`

**Interfaces:**
- Consumes: なし
- Produces: `statusline/usage-filter.jq` — stdin に statusLine payload、
  stdout に `<ctx>\t<limits>` の TSV 1行。値が取れない側は空文字。Task 5 が呼ぶ。

- [ ] **Step 1: 失敗するテストを書く**

Create `tests/test_usage_filter.sh`:

```bash
#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

FILTER="$here/../statusline/usage-filter.jq"

# ctx <json> / lim <json> : TSV の 1 列目 / 2 列目
ctx() { printf '%s' "$1" | jq -r -f "$FILTER" | cut -f1; }
lim() { printf '%s' "$1" | jq -r -f "$FILTER" | cut -f2; }

full='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":81000}},"rate_limits":{"five_hour":{"used_percentage":11.4},"seven_day":{"used_percentage":2.6}}}'

assert_eq "42%" "$(ctx "$full")" "84000/200000 は 42%"
assert_eq "5h 11% | 7d 3%" "$(lim "$full")" "rate limits は丸めて連結"

no_limits='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":50000}}}'
assert_eq "25%" "$(ctx "$no_limits")" "rate_limits が無くても ctx は出る"
assert_eq "" "$(lim "$no_limits")" "rate_limits が無ければ limits は空"

only_5h='{"context_window":{"context_window_size":100,"current_usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"rate_limits":{"five_hour":{"used_percentage":80}}}'
assert_eq "5h 80%" "$(lim "$only_5h")" "片方だけでも出る"

no_usage='{"context_window":{"context_window_size":200000,"current_usage":null}}'
assert_eq "" "$(ctx "$no_usage")" "current_usage が null なら空"

partial='{"context_window":{"context_window_size":1000,"current_usage":{"input_tokens":100}}}'
assert_eq "10%" "$(ctx "$partial")" "cache 系フィールドが無くても落ちない"

zero='{"context_window":{"context_window_size":0,"current_usage":{"input_tokens":5}}}'
assert_eq "" "$(ctx "$zero")" "0 除算を踏まない"

assert_eq "" "$(ctx '{}')" "空 payload でも落ちない"

finish
```

- [ ] **Step 2: 失敗を確認**

Run: `bash tests/test_usage_filter.sh`
Expected: FAIL。フィルタファイルが無い

- [ ] **Step 3: フィルタを実装**

Create `statusline/usage-filter.jq`:

```jq
# statusLine の stdin payload から Agents パネル用の値を取り出す。
# 出力: "<ctx>\t<limits>" の TSV 1 行。取れない側は空文字。

def pct:
  (.context_window.current_usage) as $u
  | (.context_window.context_window_size) as $size
  | if ($u == null) or ($size == null) or ($size == 0) then null
    else
      ( (($u.input_tokens // 0)
         + ($u.cache_creation_input_tokens // 0)
         + ($u.cache_read_input_tokens // 0)) * 100 / $size | floor )
    end;

# rate_limits はセッション最初の API 応答後にしか出現しない。
# 無ければ null を返し、呼び出し側は送信を見送る（クリアはしない）。
def limits:
  [ (.rate_limits.five_hour.used_percentage  | if . == null then empty else "5h \(round)%" end),
    (.rate_limits.seven_day.used_percentage  | if . == null then empty else "7d \(round)%" end) ]
  | if length == 0 then null else join(" | ") end;

[ (pct    | if . == null then "" else "\(.)%" end),
  (limits | if . == null then "" else . end) ]
| @tsv
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bash tests/test_usage_filter.sh`
Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add statusline/usage-filter.jq tests/test_usage_filter.sh
git commit -m "$(cat <<'EOF'
機能: usage 文字列の組み立てフィルタを追加

- context 使用率は input + cache_creation + cache_read を分子に floor
- rate_limits は 5h / 7d を丸めて連結。無ければ空
- 0 除算・欠損フィールド・空 payload のいずれでも落ちない
EOF
)"
```

---

### Task 5: usage push 本体

`ccstatus` から `&` で呼ばれ、stdin の JSON を読んで `report-metadata` を打つ。

**Files:**
- Create: `statusline/herdr-usage-push`
- Create: `tests/test_usage_push.sh`

**Interfaces:**
- Consumes: `statusline/usage-filter.jq`（Task 4）
- Produces: `statusline/herdr-usage-push` — 引数なし。stdin に statusLine payload。
  Task 7 の install.sh がこのパスを `ccstatus` に書き込む。

- [ ] **Step 1: 失敗するテストを書く**

Create `tests/test_usage_push.sh`:

```bash
#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

PUSH="$here/../statusline/herdr-usage-push"

setup_fake_herdr() {
  FAKE_DIR="$(mktemp -d)"
  CAPTURE="$FAKE_DIR/captured"
  cat > "$FAKE_DIR/herdr" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CAPTURE"
exit 0
FAKE
  chmod +x "$FAKE_DIR/herdr"
  export CAPTURE
  export PATH="$FAKE_DIR:$PATH"
}

teardown_fake_herdr() { rm -rf "$FAKE_DIR"; }

run_push() {
  : > "$CAPTURE"
  printf '%s' "$1" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
  cat "$CAPTURE"
}

setup_fake_herdr

full='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":81000}},"rate_limits":{"five_hour":{"used_percentage":11.4},"seven_day":{"used_percentage":2.6}}}'

out="$(run_push "$full")"
assert_contains "$out" "--token ctx=42%"           "ctx トークンを送る"
assert_contains "$out" "--token limits=5h 11% | 7d 3%" "limits トークンを送る"
assert_contains "$out" "--ttl-ms 3600000"          "usage の TTL は 1 時間"
assert_contains "$out" "--source herdr-jump"       "source は herdr-jump"

no_limits='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":50000}}}'
out="$(run_push "$no_limits")"
assert_contains "$out" "--token ctx=25%" "limits が無くても ctx は送る"
assert_eq "" "$(printf '%s' "$out" | grep -o 'limits=' || true)" \
  "limits が無い時は limits トークンを送らない"

# ctx すら取れないなら herdr を呼ばない
assert_eq "" "$(run_push '{}')" "空 payload では何も送らない"

# ガード
: > "$CAPTURE"
printf '%s' "$full" | HERDR_ENV=1 HERDR_PANE_ID= bash "$PUSH" >/dev/null 2>&1
assert_eq "" "$(cat "$CAPTURE")" "HERDR_PANE_ID が空なら何もしない"

printf 'not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$PUSH" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

teardown_fake_herdr
finish
```

- [ ] **Step 2: 失敗を確認**

Run: `bash tests/test_usage_push.sh`
Expected: FAIL。`herdr-usage-push` が無い

- [ ] **Step 3: 実装**

Create `statusline/herdr-usage-push`:

```bash
#!/bin/bash
# statusLine の stdin JSON から context 使用率を読み、
# herdr Agents パネルへ push する。ccstatus から & で呼ばれる。
#
# 毎ターン起動される。前回値と比較してスキップする最適化は入れない
# （状態ファイルを持つ複雑さが 1 プロセス分のコストに見合わない）。

[ "${HERDR_ENV:-}" = "1" ]     || exit 0
[ -n "${HERDR_PANE_ID:-}" ]    || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq    >/dev/null 2>&1 || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0

line="$(jq -r -f "$here/usage-filter.jq" 2>/dev/null)" || exit 0
ctx="${line%%$'\t'*}"
limits="${line#*$'\t'}"

# ctx が取れないうちは何も送らない。まだ API 応答が返っていない状態
[ -n "$ctx" ] || exit 0

args=( --source herdr-jump --token "ctx=$ctx" )
# limits はセッション最初の API 応答後にしか出ない。無い間は送らないだけで、
# クリアはしない（前の値が TTL まで残るが実害が無い）
[ -n "$limits" ] && args+=( --token "limits=$limits" )

herdr pane report-metadata \
  "${args[@]}" \
  --seq "$(date +%s%3N)" \
  --ttl-ms 3600000 \
  "$HERDR_PANE_ID" >/dev/null 2>&1

exit 0
```

- [ ] **Step 4: 実行権を付けてテスト**

```bash
chmod +x statusline/herdr-usage-push
bash tests/test_usage_push.sh
```

Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add statusline/herdr-usage-push tests/test_usage_push.sh
git commit -m "$(cat <<'EOF'
機能: usage を push する statusLine 片を追加

- ctx が取れない間は何も送らない（API 応答前の状態）
- limits が無い間は送らないだけでクリアはしない
- TTL は 1 時間。usage は事象ではなく状態なので reason より長く持たせる
EOF
)"
```

---

### Task 6: 表示層の config ブロック

トークンを送っても、herdr 側の行テンプレートに置き場が無ければ何も表示されない。
その置き場を定義するブロックを原本として持つ。install.sh がこれを読んで挿入する。

**Files:**
- Create: `config/agents-rows.toml`

**Interfaces:**
- Consumes: なし
- Produces: `config/agents-rows.toml` — マーカー行
  `# >>> herdr-jump (managed) >>>` と `# <<< herdr-jump (managed) <<<` で
  囲まれた TOML ブロック。Task 7 の install.sh がこの2行を境界として
  `~/.config/herdr/config.toml` に差し込む。

- [ ] **Step 1: ブロックを作る**

Create `config/agents-rows.toml`:

```toml
# >>> herdr-jump (managed) >>>
# このブロックは install.sh が管理する。手で編集すると次回の実行で失われる。

# 止まっているペインを上に持ち上げる。herdr 内蔵の attention queue 順
agent_panel_sort = "priority"

[ui.sidebar.agents]
row_gap = 0
rows = [["state_icon", "workspace", "tab"], ["agent"]]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", "workspace", "tab"],
  [{ token = "reason", fg = "#f38ba8", bold = true }],
  [{ token = "ctx", fg = "#89b4fa" }, { token = "limits", dim = true }],
]
codex = [
  ["state_icon", "workspace", "tab"],
  [{ token = "reason", fg = "#f9e2af", bold = true }],
]
# <<< herdr-jump (managed) <<<
```

- [ ] **Step 2: herdr が受け付けることを確認**

現行 config の複製に追記して、herdr の設定パーサを通す。

```bash
tmp="$(mktemp -d)"
cat ~/.config/herdr/config.toml config/agents-rows.toml > "$tmp/config.toml"
herdr --config "$tmp/config.toml" --default-config >/dev/null && echo "PARSE OK"
```

Expected: `PARSE OK`

`--config` が受け付けられない版の場合は `herdr config validate` / `herdr config check`
を `herdr --help` で探す。どれも無ければ Task 8 の実機検証に判断を委ね、
ここでは TOML 構文の妥当性だけ確認する:

```bash
jq --version >/dev/null && python3 -c "import tomllib,sys; tomllib.load(open('$tmp/config.toml','rb'))" && echo "TOML OK"
```

（この python3 使用は検証時の一度きりで、実行時依存には含まれない）

- [ ] **Step 3: Commit**

```bash
git add config/agents-rows.toml
git commit -m "$(cat <<'EOF'
機能: Agents パネルの行テンプレートを追加

トークンを送っても行テンプレートに置き場が無ければ描画されない。
claude は reason + ctx/limits の 3 行、codex は reason のみの 2 行。
agent_panel_sort = "priority" で止まっているペインを上に出す。
EOF
)"
```

---

### Task 7: install.sh

4ファイルを冪等に書き換える。何度実行しても同じ結果になること。

**Files:**
- Create: `install.sh`
- Create: `tests/test_install_idempotent.sh`

**Interfaces:**
- Consumes: `hooks/herdr-jump-reason.sh`（Task 3）、`statusline/herdr-usage-push`（Task 5）、
  `config/agents-rows.toml`（Task 6）
- Produces: `install.sh` — 環境変数 `HERDR_JUMP_PREFIX` でインストール先の
  ルートを差し替えられる（既定は `$HOME`）。テストはこれを使って一時ディレクトリへ
  インストールする。

- [ ] **Step 1: 冪等性のテストを書く**

Create `tests/test_install_idempotent.sh`:

```bash
#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

INSTALL="$here/../install.sh"

root="$(mktemp -d)"
mkdir -p "$root/.claude" "$root/.config/herdr" "$root/.codex" "$root/.local/bin"

# 既存環境を模す。superset のフックが PermissionRequest に居る状態から始める
cat > "$root/.claude/settings.json" <<'JSON'
{
  "statusLine": { "type": "command", "command": "ccstatus", "padding": 0 },
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*",
        "hooks": [ { "type": "command", "command": "bash /home/kay/.superset/hooks/notify.sh" } ] }
    ]
  }
}
JSON

cat > "$root/.config/herdr/config.toml" <<'TOML'
[theme]
name = "catppuccin"

[[keys.command]]
key = "x"
TOML

cat > "$root/.local/bin/ccstatus" <<'SH'
#!/bin/bash
input=$(cat)
echo "$input" | crmux rpc status-update &
echo "done"
SH
chmod +x "$root/.local/bin/ccstatus"

cat > "$root/.codex/hooks.json" <<'JSON'
{ "hooks": { "SessionStart": [ { "hooks": [ { "command": "bash '/x/herdr-agent-state.sh' session", "timeout": 10, "type": "command" } ] } ] } }
JSON

run_install() { HERDR_JUMP_PREFIX="$root" bash "$INSTALL" >/dev/null 2>&1; }

run_install
snapshot1="$(cat "$root/.claude/settings.json" "$root/.config/herdr/config.toml" \
                 "$root/.local/bin/ccstatus" "$root/.codex/hooks.json")"

run_install
snapshot2="$(cat "$root/.claude/settings.json" "$root/.config/herdr/config.toml" \
                 "$root/.local/bin/ccstatus" "$root/.codex/hooks.json")"

assert_eq "$snapshot1" "$snapshot2" "2 回実行しても内容が変わらない"

# superset のフックを潰していないこと
assert_contains "$(cat "$root/.claude/settings.json")" "superset" \
  "既存の superset フックを残す"

# 4 イベントが配線されていること
s="$(jq -r '.hooks | keys[]' "$root/.claude/settings.json" | sort | tr '\n' ' ')"
assert_eq "PermissionRequest PostToolBatch PreToolUse Stop " "$s" \
  "4 イベントが配線される"

# PermissionRequest には superset と herdr-jump の 2 エントリが並ぶ
n="$(jq '[.hooks.PermissionRequest[].hooks[]] | length' "$root/.claude/settings.json")"
assert_eq "2" "$n" "PermissionRequest は 2 エントリ"

# 3 回目でも増えない
run_install
n="$(jq '[.hooks.PermissionRequest[].hooks[]] | length' "$root/.claude/settings.json")"
assert_eq "2" "$n" "3 回目でもエントリが増えない"

# config.toml のマーカーブロックが 1 組だけ
c="$(grep -c '>>> herdr-jump (managed) >>>' "$root/.config/herdr/config.toml")"
assert_eq "1" "$c" "config のマーカーブロックは 1 組"

# ccstatus の push 行が 1 本だけ
c="$(grep -c 'herdr-usage-push' "$root/.local/bin/ccstatus")"
assert_eq "1" "$c" "ccstatus の push 行は 1 本"

# codex の SessionStart が保たれている
assert_contains "$(cat "$root/.codex/hooks.json")" "herdr-agent-state.sh" \
  "codex の既存 SessionStart を残す"

# バックアップが取られている（4 ファイル分 × 実行回数）
b="$(find "$root" -name '*.bak.*' | wc -l)"
assert_eq "yes" "$( [ "$b" -ge 4 ] && echo yes || echo "no($b)" )" \
  "4 ファイル分のバックアップを取る"

rm -rf "$root"
finish
```

- [ ] **Step 2: 失敗を確認**

Run: `bash tests/test_install_idempotent.sh`
Expected: FAIL。`install.sh` が無い

- [ ] **Step 3: install.sh を実装**

Create `install.sh`:

```bash
#!/bin/bash
# herdr Agents パネル拡充の配線。何度実行しても同じ結果になる。
#
# 触るファイル:
#   ~/.claude/settings.json      … reason フックの 4 イベント
#   ~/.config/herdr/config.toml  … 行テンプレート
#   ~/.local/bin/ccstatus        … usage push の 1 行
#   ~/.codex/hooks.json          … reason フックの 4 イベント（Codex 側）
#
# ~/.codex/config.toml は触らない。trusted_hash の入力正規化を特定できないため、
# 推測した値を書くと Codex がフックを黙って無効化する。承認は次回起動時に 1 回。

set -uo pipefail

PREFIX="${HERDR_JUMP_PREFIX:-$HOME}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

HOOK="$HERE/hooks/herdr-jump-reason.sh"
PUSH="$HERE/statusline/herdr-usage-push"
ROWS="$HERE/config/agents-rows.toml"

SETTINGS="$PREFIX/.claude/settings.json"
HERDRCFG="$PREFIX/.config/herdr/config.toml"
CCSTATUS="$PREFIX/.local/bin/ccstatus"
CODEXHOOKS="$PREFIX/.codex/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "jq が必要です" >&2; exit 1; }

backup() { [ -f "$1" ] && cp -p "$1" "$1.bak.$STAMP"; }

# --- 1. ~/.claude/settings.json --------------------------------------------

wire_claude_settings() {
  local f="$1"
  [ -f "$f" ] || echo '{}' > "$f"
  backup "$f"

  local tmp; tmp="$(mktemp)"
  jq \
    --arg set   "bash '$HOOK' set" \
    --arg clear "bash '$HOOK' clear" '
    # 既存の herdr-jump エントリを取り除く。「消してから足す」ので冪等
    def purge:
      (. // [])
      | map(.hooks |= map(select(((.command // "") | contains("herdr-jump-reason")) | not)))
      | map(select((.hooks | length) > 0));

    def entry($matcher; $cmd):
      (if $matcher == "" then {} else {matcher: $matcher} end)
      + {hooks: [{type: "command", command: $cmd, timeout: 5}]};

    .hooks                  = (.hooks // {})
    | .hooks.PermissionRequest = ((.hooks.PermissionRequest | purge) + [entry("*"; $set)])
    | .hooks.PreToolUse        = ((.hooks.PreToolUse        | purge) + [entry("AskUserQuestion"; $set)])
    | .hooks.PostToolBatch     = ((.hooks.PostToolBatch     | purge) + [entry(""; $clear)])
    | .hooks.Stop              = ((.hooks.Stop              | purge) + [entry(""; $clear)])
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- 2. ~/.config/herdr/config.toml ----------------------------------------

wire_herdr_config() {
  local f="$1"
  [ -f "$f" ] || : > "$f"
  backup "$f"

  local tmp; tmp="$(mktemp)"
  # 既存のマーカーブロックを落としてから、原本を末尾に付け直す
  awk '
    /^# >>> herdr-jump \(managed\) >>>/ { skip = 1 }
    skip != 1 { print }
    /^# <<< herdr-jump \(managed\) <<</ { skip = 0 }
  ' "$f" > "$tmp"

  # 末尾に空行が無ければ足す。直前のテーブルへ吸い込まれるのを防ぐ
  [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ] && printf '\n' >> "$tmp"
  printf '\n' >> "$tmp"
  cat "$ROWS" >> "$tmp"
  mv "$tmp" "$f"
}

# --- 3. ~/.local/bin/ccstatus ----------------------------------------------

wire_ccstatus() {
  local f="$1"
  [ -f "$f" ] || { echo "  skip: $f が見つかりません" >&2; return 0; }
  grep -q 'herdr-usage-push' "$f" && return 0
  backup "$f"

  local tmp; tmp="$(mktemp)"
  # crmux 行の直後に差し込む。無ければ 'input=$(cat)' の直後
  awk -v push="$PUSH" '
    { print }
    !done && /crmux rpc status-update/ {
      printf "echo \"$input\" | %s &  # herdr-jump\n", push
      done = 1
    }
    !done && /^input=\$\(cat\)/ {
      printf "echo \"$input\" | %s &  # herdr-jump\n", push
      done = 1
    }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
  chmod +x "$f"
}

# --- 4. ~/.codex/hooks.json ------------------------------------------------

wire_codex_hooks() {
  local f="$1"
  [ -f "$f" ] || echo '{"hooks":{}}' > "$f"
  backup "$f"

  local tmp; tmp="$(mktemp)"
  jq \
    --arg set   "bash '$HOOK' set" \
    --arg clear "bash '$HOOK' clear" '
    def purge:
      (. // [])
      | map(.hooks |= map(select(((.command // "") | contains("herdr-jump-reason")) | not)))
      | map(select((.hooks | length) > 0));

    def entry($matcher; $cmd):
      (if $matcher == "" then {} else {matcher: $matcher} end)
      + {hooks: [{type: "command", command: $cmd, timeout: 5}]};

    .hooks                  = (.hooks // {})
    | .hooks.PermissionRequest = ((.hooks.PermissionRequest | purge) + [entry("*"; $set)])
    | .hooks.PreToolUse        = ((.hooks.PreToolUse        | purge) + [entry("AskUserQuestion"; $set)])
    | .hooks.PostToolBatch     = ((.hooks.PostToolBatch     | purge) + [entry(""; $clear)])
    | .hooks.Stop              = ((.hooks.Stop              | purge) + [entry(""; $clear)])
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- 実行 -------------------------------------------------------------------

chmod +x "$HOOK" "$PUSH" 2>/dev/null

echo "herdr-jump をインストールします (prefix: $PREFIX)"
wire_claude_settings "$SETTINGS" && echo "  ok: $SETTINGS"
wire_herdr_config    "$HERDRCFG" && echo "  ok: $HERDRCFG"
wire_ccstatus        "$CCSTATUS" && echo "  ok: $CCSTATUS"
wire_codex_hooks     "$CODEXHOOKS" && echo "  ok: $CODEXHOOKS"

cat <<'NOTE'

完了しました。

  * Claude Code は次のセッションから有効になります
  * herdr は設定の再読み込みが要ります (herdr config reload / 再起動)
  * Codex は次回起動時にフックの承認プロンプトが 1 回出ます。
    trusted_hash は自動登録できないため、そこで許可してください

バックアップは各ファイルの隣に .bak.<timestamp> で置いてあります。
NOTE
```

- [ ] **Step 4: テストが通ることを確認**

```bash
chmod +x install.sh
bash tests/test_install_idempotent.sh
```

Expected: `ALL PASS`

`PostToolBatch` の matcher についてテストが落ちる場合（Claude Code が
matcher 必須を要求する場合）は `entry(""; ...)` を `entry("*"; ...)` に変える。
判断材料は Task 8 の実機検証で得る。

- [ ] **Step 5: 全テストを通す**

Run: `bash tests/run.sh`
Expected: `=== ALL TESTS PASSED ===`（reason フィルタ / reason フック / usage フィルタ / usage push / install の5本）

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/test_install_idempotent.sh
git commit -m "$(cat <<'EOF'
機能: 冪等な配線スクリプトを追加

- settings.json / hooks.json は「消してから足す」ので何度でも実行できる
- 既存の superset フックを潰さず PermissionRequest 配列へ追記する
- config.toml はマーカーブロックごと差し替え
- codex の config.toml は触らない。trusted_hash の入力正規化を特定できず、
  推測値を書くとフックが黙って無効化されるため。承認は次回起動時に 1 回
EOF
)"
```

---

### Task 8: README と実機検証

ここまでは全て偽 `herdr` に対するテスト。本物に当てて動くことを確認する。

**Files:**
- Modify: `README.md`（全面書き換え）

- [ ] **Step 1: README を書き換える**

Replace `README.md`:

````markdown
# herdr-jump

herdr の Agents パネルに「何で止まっているか」と context 使用率を表示する。

パネルを見れば用のあるエージェントが分かり、クリックすればそのペインへ飛べる。
飛ぶ機能自体は herdr 0.7.5 が内蔵しているので、こちらは**飛ぶ判断に必要な情報を
パネルへ流し込むこと**に徹する。

## 何が出るか

```
● ws0  tab1
  Bash: Remove node_modules        ← 何で止まっているか
  42%  5h 11% | 7d 3%              ← context 使用率と rate limits
```

| 行 | 出所 |
|---|---|
| reason | `PermissionRequest` / `PreToolUse(AskUserQuestion)` / `Elicitation` フック |
| ctx / limits | `ccstatus`（statusLine）の stdin JSON |

Codex では reason のみ（statusLine 相当の仕組みが無いため）。

## インストール

```bash
./install.sh
```

以下を冪等に書き換える。何度実行しても結果は同じで、既存のフックは潰さない。
書き換え前に `.bak.<timestamp>` を取る。

- `~/.claude/settings.json`
- `~/.config/herdr/config.toml`
- `~/.local/bin/ccstatus`
- `~/.codex/hooks.json`

インストール後、**Codex は次回起動時にフックの承認プロンプトが1回出る**。
Codex の `trusted_hash` は入力の正規化方法を特定できなかったため自動登録していない。

## 依存

`jq` と `herdr` CLI のみ。

## テスト

```bash
bash tests/run.sh
```

偽の `herdr` を PATH に置いて呼び出し引数を検証するので、herdr 本体は要らない。

## 設計

[docs/superpowers/specs/2026-07-30-herdr-agent-status-design.md](docs/superpowers/specs/2026-07-30-herdr-agent-status-design.md)
````

- [ ] **Step 2: 本番へインストール**

```bash
./install.sh
```

Expected: 4行の `ok:` と完了メッセージ

- [ ] **Step 3: herdr に設定を読ませる**

```bash
herdr config reload 2>/dev/null || echo "reload が無い。herdr を再起動する"
```

- [ ] **Step 4: 手で reason を打って表示を確認**

Claude ペインの中から:

```bash
herdr pane report-metadata --source herdr-jump \
  --token "reason=手動テスト" --seq "$(date +%s%3N)" --ttl-ms 60000 "$HERDR_PANE_ID"
```

Expected: Agents パネルの該当行に `手動テスト` が出る。
**出ない場合は表示層（Task 6 の config）の問題**で、フック側ではない。切り分けはここ。

- [ ] **Step 5: 実際に止めて確認**

新しい Claude セッションで許可を要する操作を叩き、別ペインから Agents パネルを見る。

Expected: `Bash: <description>` が出る

- [ ] **Step 6: 拒否したときに消えることを確認（最重要）**

Step 5 の許可プロンプトを **拒否** する。

Expected: reason が消える

消えない場合、`PostToolBatch` が拒否時に発火していない上に `Stop` も通っていない。
`~/.claude/settings.json` の `Stop` エントリが正しく入っているか確認し、
入っているなら `bash '$HOOK' clear` を手で叩いて clear 自体が効くか切り分ける。

- [ ] **Step 7: usage を確認**

Claude ペインで何かターンを回す。

Expected: `42%` のような値が出て、ターンごとに更新される

- [ ] **Step 8: Codex を確認**

Codex を起動し、承認プロンプトを通す。許可を要する操作を叩く。

Expected: 承認後、Codex ペインにも reason が出る

- [ ] **Step 9: 結果を README に反映**

Step 4-8 で判明した差異（`PostToolBatch` の挙動、40文字の妥当性、
`Elicitation` の可否）を README と spec の第11節へ反映する。

- [ ] **Step 10: Commit**

```bash
git add README.md docs/
git commit -m "$(cat <<'EOF'
文書: README を全面書き換えし実機検証の結果を反映

- v1 のペイン切り替えの説明を削除
- 実機で確認した挙動を spec 第 11 節へ反映
EOF
)"
```

---

## 未解決（実装中に判断する）

- **`PostToolBatch` の matcher** — 必須かどうか未確認。Task 7 Step 4 で落ちたら `"*"` に変える
- **`Elicitation` は意図的に未配線** — `reason-filter.jq` は Elicitation を扱えるが、
  `install.sh` は配線しない。payload のフィールド名（`message` / `mcp_server_name`）を
  実物で確認していないため、配線して壊れるより後回しにする。Task 8 で MCP elicitation を
  実際に発生させて payload を確認できたら、`install.sh` に 1 エントリ足すだけで有効になる。
  許可待ち・質問待ちはこれと独立に動くので、未配線でも機能は完結している
- **40文字の妥当性** — 実際のパネル幅次第。Task 8 Step 5 で見て `reason-filter.jq` の
  `trunc(40)` を調整する
- **herdr 側の自動 truncate** — herdr がはみ出しをどう扱うか未確認。自動で切ってくれるなら
  こちらの切り捨てを緩められる
