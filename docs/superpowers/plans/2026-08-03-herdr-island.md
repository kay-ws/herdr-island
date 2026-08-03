# herdr-island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** herdr-jump を「待たせているエージェントを見つける」プラグイン `herdr-island` として再構成し、公開できる状態にする。

**Architecture:** herdr プラグイン（`herdr-plugin.toml` + argv コマンド群）。停止理由は agent CLI 側の hook が `herdr pane report-metadata` で立て、herdr の `pane.agent_status_changed` イベントが消す。絞り込みは `agent.view.set` の宣言的 projection で行い `config.toml` を触らない。理由の本文表示のみ `ui.sidebar.agents.rows` に1行足す。

**Tech Stack:** bash / jq / `herdr` CLI。python3 は `agent.view.set`（CLI ラッパ無し）と rows 編集にのみ使用。外部ライブラリ依存なし。

**Spec:** [../specs/2026-08-03-herdr-island-design.md](../specs/2026-08-03-herdr-island-design.md)

## Global Constraints

すべてのタスクの要件に、暗黙にこの節が含まれる。

- プラグイン id は `island`。`min_herdr_version = "0.7.5"`。`platforms = ["linux", "macos"]`
- 所有するトークンは **`$reason` のみ**。`$ctx` / `$limits` / `$model` は削除する
- **`ui.sidebar.agents.rows_by_agent` に書き込まない**（complete override で他プラグインの行を無効化するため）
- `herdr pane report-metadata` は **位置引数 PANE_ID をフラグより前に置く**。後ろに置くと `unknown option` で壊れる
- agent CLI 側の hook は**何があっても `exit 0`**。表示が出ないことは許容するが、エージェントの動作に影響を与えることは許容しない
- 外部 Python ライブラリを追加しない（`tomlkit` 等は使わない）。標準ライブラリのみ
- `herdr server restart` を呼ばない（herdr ペイン内から叩くと自分ごと落ちる）。反映は `herdr server reload-config`
- `$reason` 行の既定色は `#f38ba8`
- 反映確認は `herdr api snapshot` の `.result.snapshot.agents[].tokens`。`panes[].tokens` で判断しない
- テストは `bash tests/run.sh` で全件走る。各テストは `tests/assert.sh` の `assert_eq` / `assert_contains` と `finish` を使う

## File Structure

**新規作成**

| パス | 責務 |
|---|---|
| `herdr-plugin.toml` | マニフェスト。エントリポイント宣言 |
| `lib/rows.py` | `config.toml` の `rows` へ1行を挿入 / 除去する文字列操作 |
| `lib/view.py` | `agent.view.set` / `agent.view.clear` の socket 送信 |
| `lib/legacy.sh` | 旧 herdr-jump の痕跡を4箇所から除去 |
| `lib/hooks.sh` | agent CLI 側 hook の配線・撤去・本数確認 |
| `bin/apply.sh` | action: 検証してから `config.toml` に行を足す（非対話） |
| `bin/revert.sh` | action: 足した行を除去する（非対話） |
| `bin/focus.sh` | action: 待っているエージェントだけに絞る |
| `bin/unfocus.sh` | action: 絞りを解除 |
| `bin/setup.sh` | pane(popup): 対話確認つき導入 |
| `bin/remove.sh` | pane(popup): 対話確認つき撤去 |
| `bin/doctor.sh` | action: 診断 |
| `bin/on-status-changed.sh` | event: 理由のクリア |
| `bin/startup.sh` | startup: 保存済み view の再適用 |
| `hooks/island-reason.sh` | agent CLI hook。理由を**立てる**のみ |

**流用**

- `hooks/reason-filter.jq` — 変更なし
- `tests/assert.sh` / `tests/fake_socket.sh` / `tests/run.sh` — 変更なし

**削除**

- `install.sh`、`lib/herdr-send.py`、`hooks/herdr-jump-reason.sh`、`hooks/herdr-codex-usage.sh`、`statusline/`、`config/agents-rows.toml`
- `tests/test_usage_filter.sh`、`tests/test_usage_push.sh`、`tests/test_codex_usage_hook.sh`、`tests/test_install_idempotent.sh`、`tests/test_reason_hook.sh`

---

### Task 1: プラグイン骨格と改名

**Files:**
- Create: `herdr-plugin.toml`
- Create: `tests/test_manifest.sh`
- Delete: `docs/superpowers/plans/2026-07-29-herdr-jump.md` は残す（履歴）

**Interfaces:**
- Consumes: なし
- Produces: プラグイン id `island`。以降のタスクは `HERDR_PLUGIN_ROOT` / `HERDR_PLUGIN_STATE_DIR` / `HERDR_PLUGIN_CONFIG_DIR` を前提にしてよい

- [ ] **Step 1: ディレクトリを改名する**

```bash
cd ~/project
mv herdr-jump herdr-island
cd herdr-island
```

- [ ] **Step 2: マニフェストの失敗テストを書く**

`tests/test_manifest.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

M="$here/../herdr-plugin.toml"

assert_eq "yes" "$([ -f "$M" ] && echo yes || echo no)" "マニフェストが存在する"

# herdr 自身に検証させる。link できることが唯一の正解判定
out="$(herdr plugin link "$here/.." 2>&1)"
assert_contains "$out" '"plugin_id":"island"' "id は island"
herdr plugin unlink island >/dev/null 2>&1

# rows_by_agent への「書き込み」がリポジトリに無いこと（Global Constraints）。
# 検出して警告することは Task 8 の要件そのものなので、文字列としての言及
# （grep での検出・警告文）まで禁じると要件と矛盾する。禁じるのはあくまで
# TOML への代入形（`rows_by_agent = ...`）
hits="$(grep -rlE 'rows_by_agent[[:space:]]*=' "$here/../bin" "$here/../lib" 2>/dev/null | wc -l)"
assert_eq "0" "$hits" "bin/ lib/ は rows_by_agent へ書き込まない（代入形が無い）"

finish
```

- [ ] **Step 3: 失敗を確認する**

Run: `bash tests/test_manifest.sh`
Expected: FAIL（`マニフェストが存在する` が no）

- [ ] **Step 4: マニフェストを書く**

`herdr-plugin.toml`:

```toml
id = "island"
name = "Island"
version = "1.0.0"
min_herdr_version = "0.7.5"
description = "Find the agents that are waiting on you. Shows why each agent stopped, and filters the Agents panel down to just those."
platforms = ["linux", "macos"]

[[panes]]
id = "setup"
title = "Set up Island"
placement = "popup"
width = "80%"
height = 20
command = ["bash", "bin/setup.sh"]

[[panes]]
id = "remove"
title = "Remove Island"
placement = "popup"
width = "80%"
height = 20
command = ["bash", "bin/remove.sh"]

[[actions]]
id = "focus"
title = "Show only agents waiting on you"
contexts = ["workspace", "pane"]
command = ["bash", "bin/focus.sh"]

[[actions]]
id = "unfocus"
title = "Show all agents"
contexts = ["workspace", "pane"]
command = ["bash", "bin/unfocus.sh"]

[[actions]]
id = "apply"
title = "Add the reason row to config (no prompt)"
contexts = ["workspace"]
command = ["bash", "bin/apply.sh"]

[[actions]]
id = "revert"
title = "Remove the reason row from config (no prompt)"
contexts = ["workspace"]
command = ["bash", "bin/revert.sh"]

[[actions]]
id = "doctor"
title = "Diagnose Island"
contexts = ["workspace"]
command = ["bash", "bin/doctor.sh"]

[[events]]
on = "pane.agent_status_changed"
command = ["bash", "bin/on-status-changed.sh"]

[[startup]]
command = ["bash", "bin/startup.sh"]
```

- [ ] **Step 5: 空のエントリポイントを置く**

各コマンドが存在しないと `plugin link` 後の呼び出しが落ちる。中身は後続タスクで埋める。

```bash
mkdir -p bin
for f in setup remove focus unfocus apply revert doctor on-status-changed startup; do
  printf '#!/bin/bash\nexit 0\n' > "bin/$f.sh"
done
chmod +x bin/*.sh
```

- [ ] **Step 6: テストが通ることを確認する**

Run: `bash tests/test_manifest.sh`
Expected: PASS（`ALL PASS`）

- [ ] **Step 7: コミット**

```bash
git add herdr-plugin.toml bin tests/test_manifest.sh
git commit -m "機能: herdr プラグインの骨格を追加

- herdr-plugin.toml でエントリポイントを宣言
- plugin link が通ることをテストで固定"
```

---

### Task 2: rows の挿入と除去

**Files:**
- Create: `lib/rows.py`
- Create: `tests/test_rows.sh`

**Interfaces:**
- Consumes: なし
- Produces: `python3 lib/rows.py add <config.toml>` / `python3 lib/rows.py remove <config.toml>` — stdin を取らず引数のファイルを読み、**結果を stdout に出す**（ファイルは書き換えない）。終了コード `0`=変更あり / `10`=変更不要（冪等） / `1`=エラー。`ROW_TEXT` は挿入する要素の文字列

**設計判断:** TOML として parse して書き戻すとコメントと整形が失われる。標準ライブラリの `tomllib` は読み取り専用で、`tomlkit` は外部依存。よって **TOML として編集せず、完全一致する文字列の挿入と削除**として扱う。逆操作が定義上バイト一致になる。

扱うケースは3つ:

- **A**: `rows = [` が複数行にわたる → 閉じ `]` の直前の行に要素行を挿入
- **B**: `rows = [...]` が1行 → 最後の `]` の直前にインラインで挿入
- **C**: `[ui.sidebar.agents]` または `rows` が無い → 末尾にマーカー付きブロックを追記

C だけマーカーを使う。ブロック全体を自分で作るため他人の内容を巻き込まない。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_rows.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

R="$here/../lib/rows.py"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# roundtrip <名前> <元の内容> : add -> remove でバイト一致することを確かめる
roundtrip() {
  local name="$1" body="$2"
  local orig="$WORK/$name.toml"
  printf '%s' "$body" > "$orig"

  python3 "$R" add "$orig" > "$WORK/$name.added"
  assert_eq "0" "$?" "$name: add は 0 を返す"
  assert_contains "$(cat "$WORK/$name.added")" '$reason' "$name: add で \$reason が入る"

  python3 "$R" remove "$WORK/$name.added" > "$WORK/$name.back"
  assert_eq "0" "$(cmp -s "$orig" "$WORK/$name.back" && echo 0 || echo 1)" \
    "$name: add -> remove で元とバイト一致"
}

# --- ケース A: 複数行の rows ---
roundtrip multiline '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "workspace"],
  ["agent"],
]
'

# --- ケース B: 1 行の rows ---
roundtrip inline '[ui.sidebar.agents]
rows = [["state_icon", "workspace"], ["agent"]]
'

# --- ケース C: テーブルが無い ---
roundtrip absent '[ui]
sidebar_width = 30
'

# --- 冪等性 ---
printf '%s' '[ui.sidebar.agents]
rows = [["agent"]]
' > "$WORK/idem.toml"
python3 "$R" add "$WORK/idem.toml" > "$WORK/idem.1"
python3 "$R" add "$WORK/idem.1" > "$WORK/idem.2"
rc=$?
assert_eq "10" "$rc" "既に行があれば rc=10（変更不要）"
assert_eq "0" "$(cmp -s "$WORK/idem.1" "$WORK/idem.2" && echo 0 || echo 1)" \
  "2 回目の add で内容が変わらない"

# --- 他人の行を壊さない（usagebar 共存） ---
printf '%s' '[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "$title"],
  ["$provider", "$limit"],
  ["$context"],
]
' > "$WORK/co.toml"
python3 "$R" add "$WORK/co.toml" > "$WORK/co.added"
for t in '$title' '$provider' '$limit' '$context'; do
  assert_contains "$(cat "$WORK/co.added")" "$t" "usagebar の $t が保持される"
done

# --- 利用者が手で変えた行は削除しない ---
printf '%s' '[ui.sidebar.agents]
rows = [
  ["agent"],
  [{ token = "$reason", fg = "#ffffff" }],
]
' > "$WORK/mine.toml"
python3 "$R" remove "$WORK/mine.toml" > "$WORK/mine.out"
assert_eq "10" "$?" "完全一致しない \$reason 行は rc=10 で残す"
assert_contains "$(cat "$WORK/mine.out")" '#ffffff' "利用者の行はそのまま残る"

finish
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_rows.sh`
Expected: FAIL（`lib/rows.py` が無く `add は 0 を返す` が失敗）

- [ ] **Step 3: 実装する**

`lib/rows.py`:

```python
#!/usr/bin/env python3
"""config.toml の ui.sidebar.agents.rows へ $reason の行を足す / 外す。

TOML として parse せず、完全一致する文字列の挿入と削除として扱う。
コメントと整形を壊さず、add -> remove がバイト一致で往復する。
"""
import os
import re
import sys

ROW_TEXT = '[{ token = "$reason", fg = "%s", bold = true }]' % os.environ.get(
    "ISLAND_REASON_FG", "#f38ba8"
)

BLOCK = """
# >>> island >>>
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"], %s]
# <<< island <<<
""" % ROW_TEXT

MULTILINE_INSERT = "  %s,\n" % ROW_TEXT
INLINE_INSERT = ", %s" % ROW_TEXT

# rows = [ から対応する ] までを掴む。行頭の rows のみを対象にする
ROWS_RE = re.compile(r"(?m)^([ \t]*)rows[ \t]*=[ \t]*\[")


def find_rows_span(text):
    """rows 配列の [ と対応する ] の位置を返す。無ければ None"""
    m = ROWS_RE.search(text)
    if not m:
        return None
    open_at = text.index("[", m.end() - 1)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return (open_at, i)
    return None


def add(text):
    if ROW_TEXT in text:
        return None  # 冪等
    span = find_rows_span(text)
    if span is None:
        return text + BLOCK
    open_at, close_at = span
    body = text[open_at : close_at + 1]
    if "\n" in body:
        # ケース A: 閉じ ] を含む行の直前に 1 行足す
        line_start = text.rfind("\n", 0, close_at) + 1
        return text[:line_start] + MULTILINE_INSERT + text[line_start:]
    # ケース B: 閉じ ] の直前にインラインで足す
    return text[:close_at] + INLINE_INSERT + text[close_at:]


def remove(text):
    # 順序が重要。INLINE_INSERT は BLOCK の rows 行にそのまま含まれるため、
    # INLINE を先に見るとケース C で BLOCK 全体ではなく断片だけが消えて
    # 往復のバイト一致が壊れる。BLOCK を先に判定すること。
    for chunk in (MULTILINE_INSERT, BLOCK, INLINE_INSERT):
        if chunk in text:
            return text.replace(chunk, "", 1)
    return None  # 自分が入れた形と完全一致するものが無い


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("add", "remove"):
        sys.stderr.write("usage: rows.py {add|remove} <config.toml>\n")
        return 1
    try:
        with open(sys.argv[2], encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (sys.argv[2], e))
        return 1

    out = add(text) if sys.argv[1] == "add" else remove(text)
    if out is None:
        sys.stdout.write(text)
        return 10
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_rows.sh`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/rows.py tests/test_rows.sh
git commit -m "機能: rows への行挿入と除去を追加

- TOML を parse せず完全一致の文字列操作で往復のバイト一致を保証
- 1 行 / 複数行 / テーブル不在の 3 ケースを扱う
- 利用者が手で変えた \$reason 行は削除しない"
```

---

### Task 3: 検証ゲートつきの apply / revert

**Files:**
- Create: `bin/apply.sh`（Task 1 の空ファイルを置換）
- Create: `bin/revert.sh`（同上）
- Create: `tests/test_apply.sh`

**Interfaces:**
- Consumes: `lib/rows.py`（`add` / `remove`、rc 0/10/1）
- Produces: `bin/apply.sh` / `bin/revert.sh` — `ISLAND_CONFIG` が指す config を編集する（未設定なら `${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml`）。rc `0`=適用 / `10`=変更不要 / `1`=検証失敗で未変更

- [ ] **Step 1: 失敗テストを書く**

`tests/test_apply.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# config check を差し替えるための偽 herdr。argv と HERDR_CONFIG_PATH を記録する。
#
# HERDR_CONFIG_PATH を記録するのが重要。実装が候補ファイルではなく実 config を
# 検証するよう退行しても、argv だけ見ていると 13 個のアサーション全部が通る
# ——「ゲートが動いているように見えて何も守っていない」状態を検出できない。
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$1 $2" in
  "config check")
    printf '%s\n' "${HERDR_CONFIG_PATH:-UNSET}" >> "$FAKE_CHECKED_PATH_LOG"
    # ISLAND_TEST_CHECK=fail のときだけ失敗させる
    if [ "${ISLAND_TEST_CHECK:-ok}" = "fail" ]; then
      echo "config: issues found"; exit 1
    fi
    echo "config: ok"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"
export FAKE_CHECKED_PATH_LOG="$WORK/checked_path.log"

CFG="$WORK/config.toml"
export ISLAND_CONFIG="$CFG"

# バックアップも消すこと。$WORK は全区間で共有されるので、消さないと
# バックアップ数を数えるアサーションが前の区間の残骸を拾う
fresh() {
  printf '[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CFG"
  : > "$FAKE_HERDR_LOG"
  rm -f "$CFG".bak.*
}

# --- 正常系 ---
fresh
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "0" "$?" "apply は 0 を返す"
assert_contains "$(cat "$CFG")" '$reason' "config に \$reason が入る"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "config check" "本番へ置く前に config check を通す"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "server reload-config" "反映は reload-config"
assert_eq "no" "$(grep -q 'server restart' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "restart は呼ばない"
assert_eq "1" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l)" "バックアップを 1 つ取る"

# 検証したのは候補ファイルであって実 config ではないこと。
# これが実 config を指していたら、ゲートは常に通り何も守っていない
checked="$(tail -1 "$FAKE_CHECKED_PATH_LOG")"
assert_eq "no" "$([ "$checked" = "$CFG" ] && echo yes || echo no)" \
  "検証対象は実 config ではない"
assert_eq "no" "$([ "$checked" = "UNSET" ] && echo yes || echo no)" \
  "HERDR_CONFIG_PATH を設定して検証している"

# --- 冪等 ---
: > "$FAKE_HERDR_LOG"
before="$(cat "$CFG")"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "10" "$?" "2 回目の apply は 10"
assert_eq "$before" "$(cat "$CFG")" "2 回目で内容が変わらない"

# --- 検証が落ちたら本番に触れない ---
fresh
orig="$(cat "$CFG")"
ISLAND_TEST_CHECK=fail bash "$here/../bin/apply.sh" >/dev/null 2>&1
assert_eq "1" "$?" "検証失敗で 1 を返す"
assert_eq "$orig" "$(cat "$CFG")" "検証失敗時は本番ファイルを変更しない"
assert_eq "no" "$(grep -q 'reload-config' "$FAKE_HERDR_LOG" && echo yes || echo no)" \
  "検証失敗時は reload しない"

# --- revert は元に戻す ---
fresh
orig="$(cat "$CFG")"
bash "$here/../bin/apply.sh" >/dev/null 2>&1
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "0" "$?" "revert は 0 を返す"
assert_eq "$orig" "$(cat "$CFG")" "revert で元とバイト一致"

# --- バックアップ名が同一秒でも衝突しないこと ---
#
# この区間は最後に置く。config を revert 済みの状態で終えるため、途中に
# 挟むと後続区間（$reason がある前提の「冪等」など）の前提を壊す。
# 各区間が暗黙に前の区間の状態を引き継ぐテストなので、追加は末尾が安全。
fresh
bash "$here/../bin/apply.sh" >/dev/null 2>&1
bash "$here/../bin/revert.sh" >/dev/null 2>&1
assert_eq "2" "$(find "$WORK" -name 'config.toml.bak.*' | wc -l)" \
  "同一秒内の 2 回の編集でバックアップが 2 つ残る"

finish
```

- [ ] **Step 1b: 本物の herdr を使う検証テストを書く**

偽 `herdr` は「実装が正しい対象を検証しているか」しか見られない。ゲートが**実際に
効くか**（本物の `herdr config check` が壊れた config を拒否するか）は本物でしか確かめ
られない。ただし公開プラグインのテストが herdr の存在を必須にはしないよう、
無い環境では skip する。

`tests/test_apply_real.sh`:

```bash
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
```

**注意:** 終了コードは必ずリダイレクト後に直接読む。`herdr config check | head` の
`$?` は `head` の終了コードであり、不正な config でも 0 に見える。

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_apply.sh`
Expected: FAIL（`bin/apply.sh` が `exit 0` のみで `\$reason` が入らない）

- [ ] **Step 3: 共通処理を実装する**

`bin/_config.sh`:

```bash
#!/bin/bash
# apply / revert / setup / remove が共有する config 編集手順。
# 「検証してから置く」——候補を一時ファイルで検証し、通ったものだけ本番へ。

island_config_path() {
  printf '%s' "${ISLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
}

# island_edit_config <add|remove> : rc 0=適用 / 10=変更不要 / 1=失敗
island_edit_config() {
  local op="$1"
  local cfg; cfg="$(island_config_path)"
  local root; root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  [ -f "$cfg" ] || { echo "config が見つかりません: $cfg" >&2; return 1; }

  local work; work="$(mktemp -d -p /tmp)" || return 1
  local cand="$work/config.toml"

  python3 "$root/lib/rows.py" "$op" "$cfg" > "$cand"
  local rc=$?
  if [ "$rc" -eq 10 ]; then rm -rf "$work"; return 10; fi
  if [ "$rc" -ne 0 ]; then rm -rf "$work"; return 1; fi

  # 本番に触れる前に herdr 自身に検証させる
  if ! HERDR_CONFIG_PATH="$cand" herdr config check >"$work/check.out" 2>&1; then
    echo "config の検証に失敗しました。設定は変更していません。" >&2
    cat "$work/check.out" >&2
    rm -rf "$work"
    return 1
  fi

  # バックアップ名はミリ秒まで含める。秒単位だと apply と revert を同じ秒に
  # 実行したとき cp が先のバックアップを黙って上書きする（cp に -n は無い）
  cp -p "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S-%3N)" || { rm -rf "$work"; return 1; }

  # 置き換えはアトミックに。`cat "$cand" > "$cfg"` はリダイレクトの時点で
  # $cfg を切り詰めるため、途中で失敗すると実 config が壊れたまま残る。
  # mv がアトミックなのは同一ファイルシステム内だけなので、一時ファイルは
  # /tmp ではなく config と同じディレクトリに作る
  local stage; stage="$(mktemp "$(dirname "$cfg")/.island.XXXXXX")" || { rm -rf "$work"; return 1; }
  cat "$cand" > "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  chmod --reference="$cfg" "$stage" 2>/dev/null
  mv -f "$stage" "$cfg" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  rm -rf "$work"

  herdr server reload-config >/dev/null 2>&1
  return 0
}
```

- [ ] **Step 4: apply / revert を実装する**

`bin/apply.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/_config.sh"

island_edit_config add
rc=$?
case $rc in
  0)  echo "reason の行を追加しました。" ;;
  10) echo "既に追加済みです。変更はありません。" ;;
esac
exit $rc
```

`bin/revert.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/_config.sh"

island_edit_config remove
rc=$?
case $rc in
  0)  echo "reason の行を除去しました。" ;;
  10) echo "除去対象がありません（手で編集された行は残します）。" ;;
esac
exit $rc
```

- [ ] **Step 5: テストが通ることを確認する**

Run: `bash tests/test_apply.sh`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add bin/_config.sh bin/apply.sh bin/revert.sh tests/test_apply.sh
git commit -m "機能: 検証ゲートつきの apply / revert を追加

- HERDR_CONFIG_PATH で候補を検証し、通ったものだけ本番へ置く
- 検証失敗時は本番ファイルに一切触れない
- restart ではなく reload-config で反映する"
```

---

### Task 4: 理由 hook を CLI 経由へ移行

**Files:**
- Create: `hooks/island-reason.sh`
- Create: `tests/test_reason_hook.sh`（既存を置換）
- Delete: `hooks/herdr-jump-reason.sh`、`lib/herdr-send.py`、`hooks/herdr-codex-usage.sh`

**Interfaces:**
- Consumes: `hooks/reason-filter.jq`（変更なし）
- Produces: `bash hooks/island-reason.sh` — stdin から hook payload を読み、`herdr pane report-metadata <PANE_ID> --source island --token reason=<本文> --seq <ms> --ttl-ms 900000` を実行する。モード引数は取らない（set 専用）

**設計判断:** clear は Task 5 の herdr イベントへ移すため、この hook は **set のみ**。`lib/herdr-send.py` は不要になる（`report-metadata` CLI は引数順序さえ守れば動く）。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_reason_hook.sh`（既存を上書き）:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

HOOK="$here/../hooks/island-reason.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

# 偽 herdr。argv を 1 行にして記録する
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

run_hook() {
  : > "$FAKE_HERDR_LOG"
  printf '%s' "$1" | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
}
logged() { cat "$FAKE_HERDR_LOG"; }
nothing_sent() { [ -s "$FAKE_HERDR_LOG" ] && echo no || echo yes; }

# --- 送る内容 ---
run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_contains "$(logged)" "pane report-metadata" "report-metadata を呼ぶ"
assert_contains "$(logged)" "--source island"      "source は island"
assert_contains "$(logged)" "reason=Bash: ls -la"  "reason に本文が乗る"
assert_contains "$(logged)" "--ttl-ms 900000"      "TTL は 15 分"

# --- 引数順序の回帰。PANE_ID はフラグより前に置くこと ---
# 後ろに置くと herdr が "unknown option" で落ちる（0.7.5 実測）
first_arg="$(logged | awk '{print $3}')"
assert_eq "w0:p1" "$first_arg" "PANE_ID は report-metadata の直後（フラグより前）"

# --- ガード。いずれも何も呼ばずに抜けること ---
: > "$FAKE_HERDR_LOG"
printf '{}' | HERDR_ENV=0 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_ENV が 1 でなければ何もしない"

: > "$FAKE_HERDR_LOG"
printf '{}' | HERDR_ENV=1 HERDR_PANE_ID= bash "$HOOK" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "HERDR_PANE_ID が空なら何もしない"

run_hook 'this is not json'
assert_eq "yes" "$(nothing_sent)" "壊れた JSON では何もしない"

run_hook '{"tool_name":"Bash","tool_input":"oops"}'
assert_eq "yes" "$(nothing_sent)" "tool_input の型が不正でも何もしない"

# --- python3 に依存しないこと ---
assert_eq "no" "$(grep -q 'python3' "$HOOK" && echo yes || echo no)" \
  "hook のホットパスは python3 を使わない"

# --- 終了コード ---
printf 'not json' | HERDR_ENV=1 HERDR_PANE_ID=w0:p1 bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

printf '{}' | HERDR_ENV=0 bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "ガードで抜ける時も exit 0"

BASH_ABS="$(command -v bash)"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -u PATH HERDR_ENV=1 HERDR_PANE_ID=w0:p1 "$BASH_ABS" "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "jq / herdr が引けなくても exit 0"

finish
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_reason_hook.sh`
Expected: FAIL（`hooks/island-reason.sh` が無い）

- [ ] **Step 3: 実装する**

`hooks/island-reason.sh`:

```bash
#!/bin/bash
# herdr Agents パネルに「何で止まっているか」を出す。理由を立てるのみ。
#
# 消すのはプラグイン側の pane.agent_status_changed イベントが担当する。
# ここで clear しないので、agent CLI の設定に入るのはこの 1 本だけで済む。
#
# 何があっても exit 0 する。表示が出ないのは許容できるが、
# 非ゼロ終了でエージェントの動作に影響を与えるのは許容できない。

# ガード。herdr のペイン内で起動されたプロセスだけが通る
[ "${HERDR_ENV:-}" = "1" ]      || exit 0
[ -n "${HERDR_PANE_ID:-}" ]     || exit 0
command -v jq    >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
FILTER="$here/reason-filter.jq"
[ -f "$FILTER" ] || exit 0

reason="$(jq -r -f "$FILTER" 2>/dev/null)"
[ -n "$reason" ] || exit 0

seq_ms="$(date +%s%3N)" || exit 0

# PANE_ID は必ずフラグより前に置く。後ろに置くと herdr が --source の値を
# フラグとして再解釈して "unknown option" で落ちる（0.7.5 実測）。
# --help の Usage 行は PANE_ID を最後に書いているので、素直に従うと踏む。
herdr pane report-metadata "$HERDR_PANE_ID" \
  --source island \
  --token "reason=$reason" \
  --seq "$seq_ms" \
  --ttl-ms 900000 >/dev/null 2>&1

exit 0
```

- [ ] **Step 4: 旧ファイルを削除する**

```bash
git rm hooks/herdr-jump-reason.sh lib/herdr-send.py hooks/herdr-codex-usage.sh
git rm statusline/herdr-usage-push statusline/usage-filter.jq
git rm config/agents-rows.toml
git rm tests/test_usage_filter.sh tests/test_usage_push.sh tests/test_codex_usage_hook.sh
git rm tests/test_install_idempotent.sh
git rm install.sh
```

- [ ] **Step 5: テストが通ることを確認する**

Run: `bash tests/test_reason_hook.sh && bash tests/run.sh`
Expected: 両方 PASS

- [ ] **Step 6: コミット**

```bash
git add hooks/island-reason.sh tests/test_reason_hook.sh
git commit -m "機能: 理由 hook を herdr CLI 経由へ移行

- report-metadata CLI は PANE_ID をフラグより前に置けば動く
- ホットパスから python3 を除去
- clear は herdr イベント側へ移すため set 専用にする
- 使用率・モデル名の一式を削除"
```

---

### Task 5: clear を herdr イベントへ移す

**Files:**
- Create: `bin/on-status-changed.sh`（Task 1 の空ファイルを置換）
- Create: `tests/test_status_event.sh`

**Interfaces:**
- Consumes: なし
- Produces: `bash bin/on-status-changed.sh` — `HERDR_PLUGIN_EVENT_JSON` を読み、状態が `blocked` 以外へ遷移していたら `herdr pane report-metadata <PANE_ID> --source island --clear-token reason` を実行する

**設計判断:** `--clear-token` は 0.7.5 に存在する（`tokens:{name:null}` を送る必要は無い）。clear を1経路に集約することで、手で送った理由が即座に消える問題（過去に3回、故障と誤診）が解消する。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_status_event.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

E="$here/../bin/on-status-changed.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

fire() {
  : > "$FAKE_HERDR_LOG"
  HERDR_PLUGIN_EVENT_JSON="$1" bash "$E" >/dev/null 2>&1
}
logged() { cat "$FAKE_HERDR_LOG"; }
nothing_sent() { [ -s "$FAKE_HERDR_LOG" ] && echo no || echo yes; }

# --- blocked を抜けたら消す ---
fire '{"pane_id":"w0:p1","workspace_id":"w0","agent_status":"working"}'
assert_contains "$(logged)" "--clear-token reason" "blocked 以外へ遷移したら reason を消す"
assert_contains "$(logged)" "--source island"      "source は island"
assert_eq "w0:p1" "$(logged | awk '{print $3}')"   "PANE_ID はフラグより前"

# --- blocked のままなら消さない ---
fire '{"pane_id":"w0:p1","workspace_id":"w0","agent_status":"blocked"}'
assert_eq "yes" "$(nothing_sent)" "blocked のときは消さない"

# --- 不正な payload ---
fire 'not json'
assert_eq "yes" "$(nothing_sent)" "壊れた JSON では何もしない"

fire '{"workspace_id":"w0","agent_status":"working"}'
assert_eq "yes" "$(nothing_sent)" "pane_id が無ければ何もしない"

# --- 空文字 / キー欠落の agent_status では消さない ---
# これを消しすぎると、ユーザーがまだ見ていない理由が消える。
# ガードを外すと落ちることを確認済み（レビューの mutation test）
fire '{"pane_id":"w0:p1","workspace_id":"w0","agent_status":""}'
assert_eq "yes" "$(nothing_sent)" "agent_status が空文字なら消さない"

fire '{"pane_id":"w0:p1","workspace_id":"w0"}'
assert_eq "yes" "$(nothing_sent)" "agent_status キーが無ければ消さない"

# --- HERDR_PLUGIN_EVENT_JSON が未設定でも落ちない ---
: > "$FAKE_HERDR_LOG"
env -u HERDR_PLUGIN_EVENT_JSON bash "$E" >/dev/null 2>&1
assert_eq "0" "$?" "環境変数が未設定でも exit 0"
assert_eq "yes" "$(nothing_sent)" "環境変数が未設定なら何もしない"

# --- 終了コード ---
HERDR_PLUGIN_EVENT_JSON='not json' bash "$E" >/dev/null 2>&1
assert_eq "0" "$?" "壊れた JSON でも exit 0"

finish
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_status_event.sh`
Expected: FAIL（`bin/on-status-changed.sh` が `exit 0` のみ）

- [ ] **Step 3: 実装する**

`bin/on-status-changed.sh`:

```bash
#!/bin/bash
# pane.agent_status_changed を受けて、blocked を抜けたペインの reason を消す。
#
# clear をここに集約する理由: agent CLI 側の hook に clear を持たせると
# 経路が増え、手で送った理由が即座に消えて目視確認ができなくなる。
# blocked を抜けたことは herdr が知っているので、herdr 側で消すのが素直。

command -v jq    >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

payload="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$payload" ] || exit 0

pane="$(printf '%s' "$payload" | jq -r '.pane_id // ""' 2>/dev/null)"
# フィールド名は agent_status。status ではない（herdr 0.7.5 の
# subscription_event スキーマ PaneAgentStatusChangedEvent で確認。
# required は pane_id / workspace_id / agent_status で、status は存在しない）。
# 間違えると常に空になりガードで抜け、clear が一度も走らない
status="$(printf '%s' "$payload" | jq -r '.agent_status // ""' 2>/dev/null)"
[ -n "$pane" ] || exit 0
[ "$status" = "blocked" ] && exit 0
[ -n "$status" ] || exit 0

# PANE_ID はフラグより前（Task 4 と同じ制約）
herdr pane report-metadata "$pane" \
  --source island \
  --clear-token reason >/dev/null 2>&1

exit 0
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_status_event.sh`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add bin/on-status-changed.sh tests/test_status_event.sh
git commit -m "機能: reason のクリアを herdr イベントへ移す

- pane.agent_status_changed で blocked を抜けたら --clear-token
- agent CLI 側に入れる hook が set の 1 本だけになる"
```

---

### Task 6: 絞り込み（focus / unfocus）

**Files:**
- Create: `lib/view.py`
- Create: `bin/focus.sh`、`bin/unfocus.sh`、`bin/startup.sh`（Task 1 の空ファイルを置換）
- Create: `tests/test_view.sh`

**Interfaces:**
- Consumes: なし
- Produces: `python3 lib/view.py set` / `python3 lib/view.py clear` — `HERDR_SOCKET_PATH` へ JSON-RPC を1行送る。`set` は `HERDR_PLUGIN_STATE_DIR/view.json` に送った params を保存し、`clear` は削除する

**設計判断:** `agent.view.set` に CLI ラッパが無いため socket 直叩き。view は揮発性（サーバ終了・プラグイン無効化で消える）なので `[[startup]]` で再適用する。

- [ ] **Step 1: 失敗テストを書く**

`tests/test_view.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/fake_socket.sh"

WORK="$(mktemp -d -p /tmp)"
export HERDR_PLUGIN_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

start_fake_socket || { echo "セットアップ失敗" >&2; exit 1; }
trap 'stop_fake_socket; rm -rf "$WORK"' EXIT

V="$here/../lib/view.py"

# --- set ---
reset_capture
python3 "$V" set
assert_eq "0" "$?" "set は 0 を返す"
assert_eq "agent.view.set"  "$(sent '.method')"        "method は agent.view.set"
assert_eq "plugin:island"   "$(sent '.params.source')" "source は plugin:island"
assert_eq "exists"          "$(sent '.params.filter.op')"           "filter は exists"
assert_eq "reason"          "$(sent '.params.filter.field.token')"  "reason トークンの有無で絞る"
assert_eq "attention"       "$(sent '.params.sort[0].field')"       "attention 優先で並べる"
assert_eq "desc"            "$(sent '.params.sort[0].order')"       "attention は降順"
assert_eq "state_change_seq" "$(sent '.params.sort[1].field')"      "次に直近の状態遷移で並べる"
assert_eq "desc"            "$(sent '.params.sort[1].order')"       "state_change_seq も降順"
assert_eq "yes" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "state に保存する"

# --- startup で再適用 ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "agent.view.set" "$(sent '.method')" "startup は保存済み view を再適用する"
# method だけ見ると、params を落とした restore でも通ってしまう
assert_eq "plugin:island" "$(sent '.params.source')"       "restore も source を forward する"
assert_eq "exists"        "$(sent '.params.filter.op')"    "restore も filter を forward する"
assert_eq "reason"        "$(sent '.params.filter.field.token')" "restore も filter の token を forward する"
assert_eq "2"             "$(sent '.params.sort | length')" "restore も sort を 2 件 forward する"

# --- clear ---
reset_capture
python3 "$V" clear
assert_eq "0" "$?" "clear は 0 を返す"
assert_eq "agent.view.clear" "$(sent '.method')"        "method は agent.view.clear"
assert_eq "plugin:island"    "$(sent '.params.source')" "source 指定で他者の view を奪わない"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "clear で state を消す"

# --- state が無ければ startup は何もしない ---
reset_capture
bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "yes" "$(nothing_sent)" "保存が無ければ startup は何も送らない"

# --- socket が到達不能なら state を書かない ---
# exit code だけ見るテストは、この不整合に対して無力だった。
# 送信していないのに state を書くと startup が「一度も適用されていない
# view」を毎回復元しにいく
rm -f "$HERDR_PLUGIN_STATE_DIR/view.json"
reset_capture
HERDR_SOCKET_PATH=/nonexistent/sock python3 "$V" set >/dev/null 2>&1
assert_eq "1" "$?" "socket が繋がらなければ 1 を返す"
assert_eq "yes" "$(nothing_sent)" "到達不能なら何も送られていない"
assert_eq "no" "$([ -f "$HERDR_PLUGIN_STATE_DIR/view.json" ] && echo yes || echo no)" \
  "送信できなかったときは state を書かない"

# --- startup は socket が無くても exit 0（サーバ起動のたびに走るため） ---
HERDR_SOCKET_PATH=/nonexistent/sock bash "$here/../bin/startup.sh" >/dev/null 2>&1
assert_eq "0" "$?" "startup は socket が無くても exit 0"

finish
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_view.sh`
Expected: FAIL（`lib/view.py` が無い）

- [ ] **Step 3: 実装する**

`lib/view.py`:

```python
#!/usr/bin/env python3
"""agent.view.set / agent.view.clear を socket へ送る。

agent.view.* には CLI ラッパが無いため socket 直叩き。view は揮発性
（サーバ終了・プラグインの無効化で消える）なので、送った params を
STATE_DIR に保存し [[startup]] から再適用する。
"""
import json
import os
import socket
import sys

SOURCE = "plugin:island"

PARAMS = {
    "source": SOURCE,
    "label": "waiting",
    "filter": {"op": "exists", "field": {"token": "reason"}},
    "sort": [
        {"field": "attention", "order": "desc"},
        {"field": "state_change_seq", "order": "desc"},
    ],
}


def state_file():
    d = os.environ.get("HERDR_PLUGIN_STATE_DIR")
    return os.path.join(d, "view.json") if d else None


def send(method, params):
    path = os.environ.get("HERDR_SOCKET_PATH")
    if not path:
        return False
    req = json.dumps({"id": "island", "method": method, "params": params})
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(path)
        s.sendall(req.encode("utf-8") + b"\n")
        s.close()
        return True
    except OSError:
        return False


def main():
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    sf = state_file()

    # state ファイルの意味は「サーバに実際に伝えた内容」であって
    # 「ユーザーが望んでいる状態」ではない。restore の役目はサーバ再起動で
    # 消えた view の復元なので、一度も適用されていない view を保存すると
    # restore が嘘をつく（herdr 未起動時に focus を叩いた人が、次回起動時に
    # 理由の分からない絞り込み画面に出会う）。よって送信成功時のみ更新する。
    if op == "set":
        if not send("agent.view.set", PARAMS):
            sys.stderr.write("herdr へ送信できませんでした\n")
            return 1
        if sf:
            with open(sf, "w", encoding="utf-8") as f:
                json.dump(PARAMS, f)
        return 0

    if op == "clear":
        if not send("agent.view.clear", {"source": SOURCE}):
            sys.stderr.write("herdr へ送信できませんでした\n")
            return 1
        if sf and os.path.exists(sf):
            os.remove(sf)
        return 0

    if op == "restore":
        if not sf or not os.path.exists(sf):
            return 0
        try:
            with open(sf, encoding="utf-8") as f:
                send("agent.view.set", json.load(f))
        except (OSError, ValueError):
            pass
        return 0

    sys.stderr.write("usage: view.py {set|clear|restore}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

`bin/focus.sh`:

```bash
#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if python3 "$root/lib/view.py" set; then
  echo "待っているエージェントだけを表示します。"
else
  echo "絞り込みを適用できませんでした（herdr に接続できません）。" >&2
  exit 1
fi
```

`bin/unfocus.sh`:

```bash
#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if python3 "$root/lib/view.py" clear; then
  echo "すべてのエージェントを表示します。"
else
  echo "絞り込みを解除できませんでした（herdr に接続できません）。" >&2
  exit 1
fi
```

`bin/startup.sh`:

```bash
#!/bin/bash
# view は揮発性なので、保存してあれば起動時に再適用する
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 "$root/lib/view.py" restore
exit 0
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_view.sh`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/view.py bin/focus.sh bin/unfocus.sh bin/startup.sh tests/test_view.sh
git commit -m "機能: reason トークンによる絞り込みを追加

- agent.view.set の filter に {token: reason} の exists を使う
- config.toml を触らずに絞り込みと並べ替えを行う
- 揮発性の view を startup で再適用する"
```

---

### Task 7: 旧 herdr-jump の撤去

**Files:**
- Create: `lib/legacy.sh`
- Create: `tests/test_legacy.sh`

**Interfaces:**
- Consumes: なし
- Produces: `bash lib/legacy.sh detect` — 痕跡があれば 0、無ければ 10。検出内容を stdout に1行ずつ出す。`bash lib/legacy.sh purge` — 4箇所から痕跡を除去する

**対象（spec §8.1）:**

| ファイル | 除去対象 |
|---|---|
| `~/.claude/settings.json` | `herdr-jump-reason` / `herdr-codex-usage` を含む hook エントリ |
| `~/.codex/hooks.json` | 同上 |
| `~/.config/herdr/config.toml` | マーカーブロックと、`[ui]` 内の `agent_panel_sort = ... # herdr-jump` の**2箇所** |
| `~/.local/bin/ccstatus` | `herdr-usage-push` を含む行 |

- [ ] **Step 1: 失敗テストを書く**

`tests/test_legacy.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

L="$here/../lib/legacy.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export ISLAND_CONFIG="$WORK/config.toml"
export ISLAND_CCSTATUS="$WORK/ccstatus"

seed() {
  cat > "$ISLAND_CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"bash '/x/hooks/herdr-jump-reason.sh' set"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}
]}}
EOF
  # codex 側は settings.json の複製にしない。複製すると herdr-codex-usage を
  # 一度も含まないため、codex 固有の識別子を検出できるかが永久に未検証になる
  cat > "$ISLAND_CODEX_HOOKS" <<'EOF'
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash '/x/hooks/herdr-codex-usage.sh'","timeout":5}]},
  {"hooks":[{"type":"command","command":"keep-me"}]}
]}}
EOF
  cat > "$ISLAND_CONFIG" <<'EOF'
[ui]
sidebar_width = 30
agent_panel_sort = "priority"  # herdr-jump

# >>> herdr-jump (managed) >>>
[ui.sidebar.agents]
rows = [["agent"]]
[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
# <<< herdr-jump (managed) <<<
EOF
  printf 'input=$(cat)\necho "$input" | /x/herdr-usage-push &  # herdr-jump\necho done\n' \
    > "$ISLAND_CCSTATUS"
}

# --- detect ---
seed
out="$(bash "$L" detect)"
assert_eq "0" "$?" "痕跡があれば detect は 0"
for f in settings.json hooks.json config.toml ccstatus; do
  assert_contains "$out" "$f" "detect は $f を挙げる"
done

# --- purge ---
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$?" "purge は 0 を返す"

# 生の文字列でゼロヒットを確認する（マーカー名の照合だけを信じない）
hits="$(cat "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS" \
        | grep -cE 'herdr-jump|herdr-usage-push' || true)"
assert_eq "0" "$hits" "4 箇所すべてから痕跡が消える"

# ブロック外の agent_panel_sort も消えていること（見落としやすい 2 箇所目）
assert_eq "no" "$(grep -q 'agent_panel_sort' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "[ui] 内の agent_panel_sort も除去される"

# rows_by_agent が残っていないこと
assert_eq "no" "$(grep -q 'rows_by_agent' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "rows_by_agent が残らない"

# --- 他人の設定を壊さない ---
assert_contains "$(cat "$ISLAND_CLAUDE_SETTINGS")" "other-tool" "他人の hook は残す"
assert_contains "$(cat "$ISLAND_CCSTATUS")" "echo done" "ccstatus の他の行は残す"
assert_contains "$(cat "$ISLAND_CONFIG")" "sidebar_width" "config の他のキーは残す"

# --- 過剰削除をしない ---
# 利用者が偶然 herdr-jump という語を含む行を書いていても巻き込まない
seed
printf '\n[notes]\nmemo = "used to try herdr-jump for this, switched away"\n' >> "$ISLAND_CONFIG"
bash "$L" purge >/dev/null 2>&1
assert_eq "1" "$(grep -c 'switched away' "$ISLAND_CONFIG")" \
  "無関係な行に herdr-jump が含まれていても残る"
assert_eq "0" "$(grep -c 'agent_panel_sort' "$ISLAND_CONFIG")" \
  "対象の agent_panel_sort 行は消える"

# --- codex 固有の識別子だけのファイルでも検出・除去できる ---
# herdr-jump を一切含まない hooks.json。ゲートのパターンが
# herdr-codex-usage を落としていると detect が rc 10 を返して素通りする
cat > "$ISLAND_CODEX_HOOKS" <<'EOF'
{"hooks":{"Stop":[
  {"hooks":[{"type":"command","command":"bash '/x/hooks/herdr-codex-usage.sh'"}]},
  {"hooks":[{"type":"command","command":"keep-me"}]}
]}}
EOF
: > "$ISLAND_CONFIG"; : > "$ISLAND_CCSTATUS"; echo '{}' > "$ISLAND_CLAUDE_SETTINGS"
bash "$L" detect >/dev/null 2>&1
assert_eq "0" "$?" "codex 固有の識別子だけでも detect は 0"
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$(grep -c 'herdr-codex-usage' "$ISLAND_CODEX_HOOKS")" "codex 側の痕跡が消える"
assert_eq "1" "$(grep -c 'keep-me' "$ISLAND_CODEX_HOOKS")" "codex 側の他人の hook は残る"

# --- 対象ファイルが無くても残りは処理される ---
# rc だけ見るアサーションは無意味。legacy_purge は無条件に 0 を返すので
# 何をしても通ってしまう。「欠けたファイルで中断せず残りを処理したか」を見る
seed
rm -f "$ISLAND_CODEX_HOOKS" "$ISLAND_CCSTATUS"
bash "$L" purge >/dev/null 2>&1
assert_eq "0" "$?" "対象ファイルが無くても purge は 0"
assert_eq "no" "$([ -f "$ISLAND_CODEX_HOOKS" ] && echo yes || echo no)" \
  "無いファイルを勝手に作らない"
assert_eq "0" "$(grep -c 'herdr-jump' "$ISLAND_CONFIG")" \
  "一部が欠けていても残りのファイルは処理される"

# --- 壊れた JSON は修復せず放置する ---
# fixture に PAT 一致文字列を含めること。含めないと
# `grep -qE "$PAT" || return 0` の門で短絡し、jq が呼ばれる前に関数が返る。
# 検証したいのは「jq が失敗したとき元ファイルを書き戻さない」経路
printf '{"hooks": broken herdr-jump-reason' > "$ISLAND_CLAUDE_SETTINGS"
orig="$(cat "$ISLAND_CLAUDE_SETTINGS")"
assert_eq "1" "$(grep -cE 'herdr-jump' "$ISLAND_CLAUDE_SETTINGS")" \
  "前提: fixture は PAT に一致する（門で短絡しない）"
bash "$L" purge >/dev/null 2>&1
assert_eq "$orig" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "壊れた JSON は書き換えない"

# --- 冪等（4 箇所すべて） ---
seed
bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  cp "$f" "$f.snap"
done
bash "$L" purge >/dev/null 2>&1
for f in "$ISLAND_CLAUDE_SETTINGS" "$ISLAND_CODEX_HOOKS" "$ISLAND_CONFIG" "$ISLAND_CCSTATUS"; do
  assert_eq "0" "$(cmp -s "$f" "$f.snap" && echo 0 || echo 1)" \
    "2 回目の purge で $(basename "$f") が変わらない"
done

# --- 痕跡が無ければ detect は 10 ---
bash "$L" detect >/dev/null 2>&1
assert_eq "10" "$?" "痕跡が無ければ detect は 10"

finish
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_legacy.sh`
Expected: FAIL（`lib/legacy.sh` が無い）

- [ ] **Step 3: 実装する**

`lib/legacy.sh`:

```bash
#!/bin/bash
# 旧 herdr-jump の痕跡を 4 箇所から除去する。
# install.sh に uninstall 経路が無かったため、撤去はここで新規に実装する。
set -uo pipefail

# 検出用。旧実装が残しうる識別子を網羅する。
# herdr-codex-usage を落とすと、codex 側にそれしか無いファイルで detect が
# rc 10（痕跡なし）を返し purge が無言で素通りする
PAT='herdr-jump|herdr-usage-push|herdr-codex-usage'

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }
herdr_config()    { printf '%s' "${ISLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"; }
ccstatus()        { printf '%s' "${ISLAND_CCSTATUS:-$HOME/.local/bin/ccstatus}"; }

legacy_detect() {
  local found=1 f
  for f in "$(claude_settings)" "$(codex_hooks)" "$(herdr_config)" "$(ccstatus)"; do
    [ -f "$f" ] || continue
    if grep -qE "$PAT" "$f" 2>/dev/null; then
      echo "$f"
      found=0
    fi
  done
  [ "$found" -eq 0 ] && return 0
  return 10
}

_backup() { [ -f "$1" ] && cp -p "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; return 0; }

# hook JSON から自分のエントリだけを取り除く。他人の hook には触らない
_purge_hooks() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f"
  local tmp; tmp="$(mktemp)"
  jq '
    def purge:
      (. // [])
      | map(.hooks |= ((. // []) | map(select(
          ((.command // "") | test("herdr-jump-reason|herdr-codex-usage")) | not))))
      | map(select((.hooks | length) > 0));
    if (.hooks | type) == "object"
    then .hooks |= with_entries(.value |= purge)
         | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
}

# config.toml は 2 箇所。マーカーブロックと [ui] 内の単独行
_purge_config() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE "$PAT" "$f" 2>/dev/null || return 0
  _backup "$f"
  local tmp; tmp="$(mktemp)"
  awk '
    /^# >>> herdr-jump \(managed\) >>>/ { skip = 1 }
    skip && /^# <<< herdr-jump \(managed\) <<</ { skip = 0; next }
    skip { next }
    # ブロック外で消すのは agent_panel_sort の 1 行だけ。
    # /herdr-jump/ のような素の部分一致にすると、利用者が書いた
    # 「herdr-jump を試したが乗り換えた」のような無関係な行まで巻き込む
    /^[[:space:]]*agent_panel_sort[[:space:]]*=.*#[[:space:]]*herdr-jump/ { next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

# ccstatus は利用者自身のスクリプト。該当行だけ落とす
_purge_ccstatus() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q 'herdr-usage-push' "$f" 2>/dev/null || return 0
  _backup "$f"
  local tmp; tmp="$(mktemp)"
  grep -v 'herdr-usage-push' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

legacy_purge() {
  _purge_hooks    "$(claude_settings)"
  _purge_hooks    "$(codex_hooks)"
  _purge_config   "$(herdr_config)"
  _purge_ccstatus "$(ccstatus)"
  return 0
}

case "${1:-}" in
  detect) legacy_detect ;;
  purge)  legacy_purge ;;
  *) echo "usage: legacy.sh {detect|purge}" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_legacy.sh`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/legacy.sh tests/test_legacy.sh
git commit -m "機能: 旧 herdr-jump の撤去を追加

- 4 箇所（claude settings / codex hooks / herdr config / ccstatus）を対象
- config.toml はマーカーブロックと [ui] 内の単独行の 2 箇所を処理
- 他人の hook・他のキー・ccstatus の他の行は残す"
```

---

### Task 8: setup / remove の対話 popup

**Files:**
- Create: `lib/hooks.sh`
- Create: `bin/setup.sh`、`bin/remove.sh`（Task 1 の空ファイルを置換）
- Create: `bin/doctor.sh`（同上）
- Create: `tests/test_setup.sh`
- Create: `tests/test_hooks.sh`

**Interfaces:**
- Consumes: `lib/legacy.sh`（detect / purge）、`bin/_config.sh`（`island_edit_config`）、`lib/rows.py`
- Produces: `lib/hooks.sh` の3関数 — `island_hooks_install`（rc 0=配線した / 10=既に配線済み / 1=失敗）、`island_hooks_uninstall`（同）、`island_hooks_count`（配線済みエントリ数を stdout へ）

**なぜ hook の配線がこのタスクに入るか:** Task 4 で削除した `install.sh` が
`~/.claude/settings.json` と `~/.codex/hooks.json` への配線を担っていた。spec §5.3 が
「`settings.json` への hook 追加も同じ手順（候補作成 → JSON パース確認 → バックアップ →
置換）」を要求しているのに、当初の計画はこの受け皿を欠いていた（Task 4 のレビューが
「install.sh 亡き後に配線する仕組みが計画のどこにも無い」と指摘して発覚）。導入・撤去の
導線はすべてこのタスクが持つのが素直なので、ここに置く。

**設計判断:** action には TTY が無い（fd0/1/2 すべて notty、`TERM` は継承されるため `TERM` での判定は誤る）。対話確認は popup pane でのみ可能。`ISLAND_ASSUME_YES=1` で確認を飛ばせるようにし、テストは非対話経路を通す。

- [ ] **Step 0: hook 配線の失敗テストを書く**

`tests/test_hooks.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

H="$here/../lib/hooks.sh"
WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export HERDR_PLUGIN_ROOT="$here/.."

# 他人の hook が入った settings.json から始める
cat > "$ISLAND_CLAUDE_SETTINGS" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}
]}}
EOF
echo '{}' > "$ISLAND_CODEX_HOOKS"

# --- install ---
bash "$H" install >/dev/null 2>&1
assert_eq "0" "$?" "install は 0 を返す"

# 設定した 2 経路が入っていること。set 専用なので clear は入らない
assert_eq "1" "$(jq '[.hooks.PermissionRequest[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PermissionRequest に 1 エントリ"
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PreToolUse に 1 エントリ"
assert_eq "AskUserQuestion" "$(jq -r '.hooks.PreToolUse[]
  | select(.hooks[]?.command | test("island-reason")) | .matcher' "$ISLAND_CLAUDE_SETTINGS")" \
  "PreToolUse の matcher は AskUserQuestion"

# clear 系のイベントには配線しない（clear は herdr イベントが担当する）
assert_eq "0" "$(jq '[.hooks.PostToolBatch[]?.hooks[]?, .hooks.Stop[]?.hooks[]?
  | select(.command | test("island-reason"))] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "PostToolBatch / Stop には配線しない"

# 他人の hook を壊していないこと
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command == "other-tool")] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "他人の hook は残る"

# 出力が妥当な JSON であること（壊れた JSON を書いたら次回以降すべて失敗する）
jq empty "$ISLAND_CLAUDE_SETTINGS" 2>/dev/null
assert_eq "0" "$?" "settings.json は妥当な JSON のまま"

# --- 冪等 ---
before="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$H" install >/dev/null 2>&1
assert_eq "10" "$?" "2 回目の install は 10"
assert_eq "$before" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "2 回目で内容が変わらない"

# --- count ---
assert_eq "2" "$(bash "$H" count)" "count は配線済みスロット数を返す"

# --- status: 部分配線を区別できること ---
# count は両ファイルの和集合なので、片方だけ配線済みでも 2 を返す。
# doctor が最も知りたい「どちらが未配線か」を出せるのは status だけ
assert_contains "$(bash "$H" status)" "claude: 2/2" "status は claude の配線数を出す"
assert_contains "$(bash "$H" status)" "codex: 2/2"  "status は codex の配線数を出す"

cp "$ISLAND_CODEX_HOOKS" "$ISLAND_CODEX_HOOKS.keep"
echo '{}' > "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: 0/2"  "codex 未配線を 0/2 と出す"
assert_contains "$(bash "$H" status)" "claude: 2/2" "その時も claude は 2/2 のまま"
assert_eq "2" "$(bash "$H" count)" "count は片方だけでも 2 のまま（status が要る理由）"

rm -f "$ISLAND_CODEX_HOOKS"
assert_contains "$(bash "$H" status)" "codex: ファイル無し" "ファイル自体が無い場合を区別する"
mv "$ISLAND_CODEX_HOOKS.keep" "$ISLAND_CODEX_HOOKS"

# --- uninstall ---
bash "$H" uninstall >/dev/null 2>&1
assert_eq "0" "$?" "uninstall は 0 を返す"
assert_eq "0" "$(grep -c 'island-reason' "$ISLAND_CLAUDE_SETTINGS")" \
  "island-reason の痕跡が消える"
assert_eq "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?
  | select(.command == "other-tool")] | length' "$ISLAND_CLAUDE_SETTINGS")" \
  "uninstall 後も他人の hook は残る"

# --- 壊れた JSON を渡されたら本番に触れない ---
printf 'this is not json' > "$ISLAND_CLAUDE_SETTINGS"
orig="$(cat "$ISLAND_CLAUDE_SETTINGS")"
bash "$H" install >/dev/null 2>&1
assert_eq "1" "$?" "壊れた JSON では 1 を返す"
assert_eq "$orig" "$(cat "$ISLAND_CLAUDE_SETTINGS")" "壊れた JSON のファイルは変更しない"

finish
```

- [ ] **Step 0b: hook 配線を実装する**

`lib/hooks.sh`:

```bash
#!/bin/bash
# agent CLI 側の hook を配線する。理由を「立てる」1 本だけを入れる。
#
# clear はこちらに入れない。herdr の pane.agent_status_changed が担当する
# （bin/on-status-changed.sh）。そのぶん他人の settings.json への侵襲が減る。
set -uo pipefail

claude_settings() { printf '%s' "${ISLAND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
codex_hooks()     { printf '%s' "${ISLAND_CODEX_HOOKS:-$HOME/.codex/hooks.json}"; }

island_hook_cmd() {
  local root; root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  printf "bash '%s/hooks/island-reason.sh'" "$root"
}

# _wire <file> <install|uninstall> : rc 0=変更した / 10=変更不要 / 1=失敗
_wire() {
  local f="$1" op="$2"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  [ -f "$f" ] || echo '{}' > "$f" || return 1

  # 壊れた JSON には触らない。jq が失敗した結果を書き戻すと被害が広がる
  jq empty "$f" >/dev/null 2>&1 || return 1

  local cmd; cmd="$(island_hook_cmd)"
  local work; work="$(mktemp -d -p /tmp)" || return 1
  local cand="$work/out.json"

  jq --arg cmd "$cmd" --arg op "$op" '
    # 自分のエントリだけを取り除く。他人の hook には触らない。
    # .hooks が無い / null のグループがあっても落ちないよう (. // []) で守る
    def purge:
      (. // [])
      | map(.hooks |= ((. // []) | map(select(
          ((.command // "") | test("island-reason")) | not))))
      | map(select((.hooks | length) > 0));

    def entry($matcher; $c):
      (if $matcher == "" then {} else {matcher: $matcher} end)
      + {hooks: [{type: "command", command: $c, timeout: 5}]};

      .hooks = (.hooks // {})
    | .hooks.PermissionRequest = ((.hooks.PermissionRequest | purge)
        + (if $op == "install" then [entry("*"; $cmd)] else [] end))
    | .hooks.PreToolUse        = ((.hooks.PreToolUse | purge)
        + (if $op == "install" then [entry("AskUserQuestion"; $cmd)] else [] end))
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$f" > "$cand" 2>/dev/null || { rm -rf "$work"; return 1; }

  jq empty "$cand" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }

  if cmp -s "$f" "$cand"; then rm -rf "$work"; return 10; fi

  cp -p "$f" "$f.bak.$(date +%Y%m%d-%H%M%S-%3N)" || { rm -rf "$work"; return 1; }
  local stage; stage="$(mktemp "$(dirname "$f")/.island.XXXXXX")" || { rm -rf "$work"; return 1; }
  cat "$cand" > "$stage" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  chmod --reference="$f" "$stage" 2>/dev/null
  mv -f "$stage" "$f" || { rm -f "$stage"; rm -rf "$work"; return 1; }
  rm -rf "$work"
  return 0
}

# 2 ファイルを順に処理する。どちらかが変更されれば 0、両方不要なら 10
_wire_both() {
  local op="$1" changed=1 rc
  local f
  for f in "$(claude_settings)" "$(codex_hooks)"; do
    _wire "$f" "$op"; rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -eq 0 ] && changed=0
  done
  [ "$changed" -eq 0 ] && return 0
  return 10
}

island_hooks_install()   { _wire_both install; }
island_hooks_uninstall() { _wire_both uninstall; }

island_hooks_count() {
  # 「立てる」側は PermissionRequest(*) と PreToolUse(AskUserQuestion) の
  # 2 スロットしか無い。settings.json と hooks.json の両方に同じ 2 スロットを
  # 配線するので、ファイルごとの生エントリを単純合算すると常に 4 になり
  # 「配線済みなら 2」という doctor の前提と食い違う。event:matcher で
  # 重複排除し、実際に存在するスロット数を返す
  local f
  {
    for f in "$(claude_settings)" "$(codex_hooks)"; do
      [ -f "$f" ] || continue
      jq -r '
        (.hooks // {}) | to_entries[]
        | .key as $event
        | .value[]?
        | select(.hooks[]?.command // "" | test("island-reason"))
        | $event + ":" + (.matcher // "")
      ' "$f" 2>/dev/null
    done
  } | sort -u | wc -l
}

# エージェントごとの配線状況を 1 行ずつ出す。
# count は両ファイルの和集合なので「Claude だけ配線済み」でも 2 を返し、
# doctor が最も知りたい部分配線を映せない。診断はこちらを使う
island_hooks_status() {
  local f label c
  for f in "$(claude_settings)" "$(codex_hooks)"; do
    case "$f" in
      *codex*) label=codex ;;
      *)       label=claude ;;
    esac
    if [ ! -f "$f" ]; then
      printf '%s: ファイル無し\n' "$label"
      continue
    fi
    c="$(jq -r '[ (.hooks // {}) | to_entries[] | .key as $event | .value[]? | select(.hooks[]?.command // "" | test("island-reason")) | $event + ":" + (.matcher // "") ] | unique | length' "$f" 2>/dev/null)"
    [ -n "$c" ] || c=0
    printf '%s: %s/2\n' "$label" "$c"
  done
}

case "${1:-}" in
  install)   island_hooks_install ;;
  uninstall) island_hooks_uninstall ;;
  count)     island_hooks_count ;;
  status)    island_hooks_status ;;
  *) echo "usage: hooks.sh {install|uninstall|count|status}" >&2; exit 1 ;;
esac
```

- [ ] **Step 1: 失敗テストを書く**

`tests/test_setup.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"

WORK="$(mktemp -d -p /tmp)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
[ "$1 $2" = "config check" ] && { echo "config: ok"; exit 0; }
exit 0
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_HERDR_LOG="$WORK/herdr.log"

export ISLAND_CONFIG="$WORK/config.toml"
export ISLAND_CLAUDE_SETTINGS="$WORK/settings.json"
export ISLAND_CODEX_HOOKS="$WORK/hooks.json"
export ISLAND_CCSTATUS="$WORK/ccstatus"
export ISLAND_ASSUME_YES=1

# rows_by_agent を持つ config を置く（旧 herdr-jump 相当）
cat > "$ISLAND_CONFIG" <<'EOF'
[ui.sidebar.agents]
rows = [["agent"]]
[ui.sidebar.agents.rows_by_agent]
claude = [["agent"]]
EOF
echo '{}' > "$ISLAND_CLAUDE_SETTINGS"

out="$(bash "$here/../bin/setup.sh" 2>&1)"

# 最重要: rows_by_agent の complete override を警告すること
assert_contains "$out" "rows_by_agent" "rows_by_agent があれば警告する"
# シングルクォート必須。"$reason" だと bash が未定義変数として展開し
# set -u で落ちる（リテラルの $reason を探したいのであって変数ではない）
assert_contains "$out" '$reason' "追加するトークンを提示する"

# 適用されていること
assert_contains "$(cat "$ISLAND_CONFIG")" '$reason' "config に行が入る"

# doctor が現状を報告できること
d="$(bash "$here/../bin/doctor.sh" 2>&1)"
# 「reason」だけを見るアサーションは、あり/なしの判定が壊れていても通る。
# 適用済みの状態なので「あり」と出ることまで確かめる
assert_contains "$d" "reason 行: あり" "doctor は reason 行ありを報告する"

# remove で戻ること
bash "$here/../bin/remove.sh" >/dev/null 2>&1
assert_eq "no" "$(grep -q '\$reason' "$ISLAND_CONFIG" && echo yes || echo no)" \
  "remove で行が消える"

finish
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash tests/test_setup.sh`
Expected: FAIL（`bin/setup.sh` が `exit 0` のみ）

- [ ] **Step 3: 実装する**

`bin/setup.sh`:

```bash
#!/bin/bash
# 対話つきの導入。popup pane から呼ばれる前提（action には TTY が無い）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

cfg="$(island_config_path)"

# confirm <質問> : ISLAND_ASSUME_YES=1 なら常に yes。
# TTY が無い場合も yes に倒さず no を返す（勝手に書き換えない）
confirm() {
  [ "${ISLAND_ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || return 1
  local ans
  printf '%s [y/N] ' "$1"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

echo "Island — 待っているエージェントを見つける"
echo

# 1. 旧 herdr-jump の痕跡
if bash "$root/lib/legacy.sh" detect > /tmp/island-legacy.$$ 2>/dev/null; then
  echo "旧 herdr-jump の痕跡が見つかりました:"
  sed 's/^/  /' /tmp/island-legacy.$$
  echo
  if confirm "撤去しますか？"; then
    bash "$root/lib/legacy.sh" purge && echo "撤去しました。"
  fi
  echo
fi
rm -f /tmp/island-legacy.$$

# 2. rows_by_agent の影。complete override で新しい行が効かなくなる
if [ -f "$cfg" ] && grep -q 'rows_by_agent' "$cfg" 2>/dev/null; then
  echo "警告: config.toml に rows_by_agent があります。"
  echo "  rows_by_agent は complete override です。該当エージェントには"
  echo "  ui.sidebar.agents.rows が一切参照されず、追加した行が"
  echo "  エラーも警告も無しに表示されません。"
  echo "  手で確認して除去することを勧めます。"
  echo
fi

# 3. reason 行の追加
echo "追加する行:"
echo '  [{ token = "$reason", fg = "#f38ba8", bold = true }]'
echo
if confirm "config.toml に追加しますか？"; then
  island_edit_config add
  case $? in
    0)  echo "追加しました。" ;;
    10) echo "既に追加済みです。" ;;
    *)  echo "追加できませんでした。設定は変更していません。" ;;
  esac
else
  echo "config は変更しませんでした。絞り込み機能だけなら設定不要で使えます。"
fi

# 4. agent CLI 側の hook 配線
echo
echo "停止理由を取得するには、Claude Code / Codex 側に hook を 1 本入れる必要があります。"
echo "  対象: PermissionRequest（全ツール）と PreToolUse（AskUserQuestion のみ）"
echo "  消す側の配線は入れません（herdr のイベントが担当します）"
echo
if confirm "hook を配線しますか？"; then
  bash "$root/lib/hooks.sh" install
  case $? in
    0)  echo "配線しました。" ;;
    10) echo "既に配線済みです。" ;;
    *)  echo "配線できませんでした。設定は変更していません。" ;;
  esac
fi

echo
echo "使い方: plugin action 'focus' で待っているエージェントだけに絞れます。"
```

`bin/remove.sh`:

```bash
#!/bin/bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

confirm() {
  [ "${ISLAND_ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || return 1
  local ans
  printf '%s [y/N] ' "$1"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

echo "Island を取り外します。"
echo

python3 "$root/lib/view.py" clear >/dev/null 2>&1
echo "絞り込みを解除しました。"

if confirm "agent CLI 側の hook を外しますか？"; then
  bash "$root/lib/hooks.sh" uninstall
  case $? in
    0)  echo "外しました。" ;;
    10) echo "配線がありません。" ;;
    *)  echo "外せませんでした。" ;;
  esac
fi

if confirm "config.toml から reason の行を除去しますか？"; then
  island_edit_config remove
  case $? in
    0)  echo "除去しました。" ;;
    10) echo "除去対象がありません（手で編集された行は残します）。" ;;
    *)  echo "除去できませんでした。" ;;
  esac
fi
```

`bin/doctor.sh`:

```bash
#!/bin/bash
# 現状を1画面で報告する。action なので TTY は無い（出力は plugin log へ）
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

cfg="$(island_config_path)"

echo "config: $cfg"
if [ -f "$cfg" ]; then
  grep -q '\$reason' "$cfg" && echo "  reason 行: あり" || echo "  reason 行: なし"
  grep -q 'rows_by_agent' "$cfg" \
    && echo "  rows_by_agent: あり（追加した行が無効化されます）" \
    || echo "  rows_by_agent: なし"
else
  echo "  ファイルがありません"
fi

echo "依存:"
for c in herdr jq python3; do
  command -v "$c" >/dev/null 2>&1 && echo "  $c: あり" || echo "  $c: なし"
done

echo "hook の配線:"
# エージェントごとに出す。合算値だと「片方だけ配線済み」が見えない
bash "$root/lib/hooks.sh" status | while IFS= read -r line; do echo "  $line"; done

echo "絞り込み:"
[ -f "${HERDR_PLUGIN_STATE_DIR:-/nonexistent}/view.json" ] \
  && echo "  適用中" || echo "  未適用"

echo "旧 herdr-jump:"
if bash "$root/lib/legacy.sh" detect 2>/dev/null | sed 's/^/  /'; then
  echo "  ↑ 痕跡があります。setup から撤去できます"
else
  echo "  痕跡なし"
fi
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/test_setup.sh && bash tests/run.sh`
Expected: 両方 PASS

- [ ] **Step 5: コミット**

```bash
git add lib/hooks.sh bin/setup.sh bin/remove.sh bin/doctor.sh tests/test_setup.sh tests/test_hooks.sh
git commit -m "機能: 対話つきの setup / remove と doctor を追加

- 確認は popup 前提。TTY が無ければ no に倒し勝手に書き換えない
- rows_by_agent の complete override を警告する
- 旧 herdr-jump の痕跡を検出して撤去を促す"
```

---

### Task 9: 実機での通し確認

**Files:**
- Modify: なし（確認のみ）

**Interfaces:**
- Consumes: 全タスク
- Produces: なし

- [ ] **Step 1: 全テストを走らせる**

Run: `bash tests/run.sh`
Expected: `=== ALL TESTS PASSED ===`

- [ ] **Step 2: 旧 herdr-jump を実環境から撤去する**

```bash
bash lib/legacy.sh detect
bash lib/legacy.sh purge
```

- [ ] **Step 3: 生の文字列でゼロヒットを確認する**

マーカー名の照合を信じず、話題名そのもので裏を取る。

```bash
grep -cE 'herdr-jump|herdr-usage-push' \
  ~/.claude/settings.json ~/.codex/hooks.json \
  ~/.config/herdr/config.toml ~/.local/bin/ccstatus 2>/dev/null
```

Expected: すべて `0`

- [ ] **Step 4: config が壊れていないことを確認する**

Run: `herdr config check`
Expected: `config: ok`（exit 0）

- [ ] **Step 5: プラグインを link して動作を見る**

```bash
herdr plugin link ~/project/herdr-island
herdr plugin list
herdr plugin action invoke island.doctor
herdr plugin log list --plugin island
```

Expected: `doctor` の出力が log に入り、`reason 行: なし` / `rows_by_agent: なし` が出る

- [ ] **Step 6: agent CLI 側の hook を配線して理由が出ることを確認する**

`~/.claude/settings.json` に `PreToolUse`(matcher `AskUserQuestion`) と `PermissionRequest`(matcher `*`) の2エントリを足し、`bash <ROOT>/hooks/island-reason.sh` を呼ぶ。その後 Claude に質問させ、届いたことを確認する。

```bash
herdr api snapshot | jq '.result.snapshot.agents[] | {agent, reason: .tokens.reason}'
```

Expected: 該当エージェントの `reason` に本文が入る。**`panes[]` ではなく `agents[]` で確認すること**

- [ ] **Step 7: 絞り込みを確認する**

```bash
herdr plugin action invoke island.focus
```

Expected: Agents パネルが理由の立っているエージェントだけになる。`island.unfocus` で戻る

- [ ] **Step 8: 状態を記録してコミット**

```bash
git commit --allow-empty -m "確認: 実機での通し確認を完了

- 旧 herdr-jump の撤去を 4 箇所で確認（生文字列でゼロヒット）
- reason の到達を agents[] で確認
- focus / unfocus の動作を確認"
```

---

### Task 10: 公開準備

**Files:**
- Create: `README.md`（既存を全面書き換え）
- Create: `LICENSE`
- Modify: `docs/` 配下から個人環境固有の記述を除去

**Interfaces:**
- Consumes: 全タスク
- Produces: 公開可能なリポジトリ

- [ ] **Step 1: 個人環境固有の記述を洗い出す**

```bash
grep -rniE '/home/kay|kay@|10\.10\.10\.|w0:p1|cachy-note|archlinux' \
  README.md docs/ bin/ lib/ hooks/ tests/ 2>/dev/null
```

テスト内の `w0:p1` は固定値として問題ないが、ホスト名・実パス・IP は除去する。

- [ ] **Step 2: README を書く**

`README.md`（英語）。含める内容:

- 一行説明: "Find the agents that are waiting on you."
- スクリーンショット位置のプレースホルダは置かない（無いなら節ごと省く）
- インストール: `herdr plugin install kay-ws/herdr-island`
- セットアップ: `herdr plugin pane open --plugin island --entrypoint setup`
- agent CLI 側 hook の配線手順（Claude Code / Codex）
- **`senna-lang/herdr-agent-usage` との共存**を明記する節。
  「Island は `$reason` のみを所有し `rows_by_agent` に書き込まない。
  `usagebar` の行はそのまま残る」
- 依存: `herdr` 0.7.5+, `jq`, `python3`
- 出典: "The name is a nod to [Vibe Island](https://vibeisland.app/), which framed the problem space that led to this plugin."

- [ ] **Step 3: LICENSE を置く**

MIT。著作権表示は `kay-ws`。

- [ ] **Step 4: リポジトリを作って push する**

```bash
gh repo create kay-ws/herdr-island --public --source=. --remote=origin
git push -u origin main
```

**注意:** GitHub への push は事前確認が要る。kay の承認を得てから実行すること。

- [ ] **Step 5: topic を付ける**

```bash
gh repo edit kay-ws/herdr-island --add-topic herdr-plugin
```

marketplace は次回の index 更新で自動的に拾う。申請・審査は無い。

- [ ] **Step 6: クリーンな状態からのインストールを確認する**

```bash
herdr plugin unlink island
herdr plugin install kay-ws/herdr-island --yes
herdr plugin list
```

Expected: `island` が GitHub 由来で登録される

- [ ] **Step 7: コミット**

```bash
git add README.md LICENSE
git commit -m "文書: 公開用の README と LICENSE を追加

- usagebar との共存を明記
- Vibe Island への出典を記載"
```

---

## Self-Review

**1. Spec coverage**

| spec の節 | 対応タスク |
|---|---|
| §2.1 名前 | Task 1（id `island`）、Task 10（repo 名・出典） |
| §3.1 トークン非衝突 | Task 4（`$reason` のみ送る）、Task 2（共存テスト） |
| §3.2 `rows_by_agent` 問題 | Task 8（警告）、Task 1（リポジトリに書き込みが無いことをテスト） |
| §3.3 原則1/2/3 | Task 2（行単位マージ）、Task 6（config を触らない絞り込み） |
| §4.1 マニフェスト | Task 1 |
| §4.2 popup / action | Task 8 |
| §4.3 set/clear 分離 | Task 4（set）、Task 5（clear） |
| §4.4 依存 | Task 4（ホットパスから python3 除去をテストで固定） |
| §4.5 状態 | Task 6（STATE_DIR + startup 再適用） |
| §4.6 絞り込みクエリ | Task 6 |
| §5.1 検証ゲート | Task 3 |
| §5.2 移行検出 | Task 7（detect）、Task 8（警告） |
| §5.3 その他 | Task 4（socket 不在で exit 0）、Task 9 Step 6（`agents[]` で確認） |
| §6 テスト | 各タスクに分散。引数順序=Task 4、往復=Task 2、実検証=Task 3、影検出=Task 7/8、冪等=Task 2/3、共存=Task 2 |
| §7 訂正 | Task 4（CLI 使用）、Task 5（`--clear-token`） |
| §8 撤去 | Task 7、Task 9 |
| §9 公開 | Task 10 |

**2. Placeholder scan** — 各ステップに実コードを記載済み。TBD・「適切に処理する」の類は無し。README（Task 10 Step 2）のみ内容を箇条書きで指定しているが、これは散文であり、書くべき項目は列挙済み。

**3. Type consistency**

- `lib/rows.py`: `add` / `remove` を CLI 引数として受け、rc 0/10/1。Task 3 の `island_edit_config` が同じ規約で呼ぶ ✓
- `lib/view.py`: `set` / `clear` / `restore`。Task 6 の `focus.sh` / `unfocus.sh` / `startup.sh` が対応 ✓
- `lib/legacy.sh`: `detect`（0/10） / `purge`。Task 8 の `setup.sh` と Task 9 が同じ規約で呼ぶ ✓
- `bin/_config.sh`: `island_config_path` / `island_edit_config`。Task 3 で定義し Task 8 で再利用 ✓
- 環境変数: `ISLAND_CONFIG` / `ISLAND_CLAUDE_SETTINGS` / `ISLAND_CODEX_HOOKS` / `ISLAND_CCSTATUS` / `ISLAND_ASSUME_YES` / `ISLAND_REASON_FG` — Task 2/3/7/8 で一貫 ✓
- source 名: 送信側 `island`（Task 4/5）、view 側 `plugin:island`（Task 6）。前者は metadata の source、後者は view の owner で別物。spec §4.6 の `plugin:<HERDR_PLUGIN_ID>` 規約どおり ✓
