# herdr-jump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Herdr でキーを 1 つ押すと、動いているエージェントの一覧が popup で出て、選んだペインへフォーカスが飛ぶ。

**Architecture:** Herdr のプラグイン機構は使わない。`[[keys.command]]` の `type = "pane"` で popup を開き、その中で bash スクリプトを 1 本走らせる。スクリプトは `herdr agent list` の JSON を jq で表示行に整形し、fzf で選ばせ、`herdr agent focus <pane_id>` を呼んで自分を閉じる。整形部分だけを純関数として切り出し、そこにテストを当てる。

**Tech Stack:** bash / jq 1.8.2 / fzf 0.74.1 / herdr 0.7.5

**Spec:** `docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md`

## Global Constraints

- 依存は `herdr` 0.7.5+ / `jq` / `fzf` のみ。新しい依存を足さない
- スクリプト冒頭は `#!/bin/bash` と `set -euo pipefail`
- スクリプト末尾に `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` を置く。テストが `source` しても `main` が走らないようにするため
- コメントと通知文言は日本語
- `terminal_title` ではなく `terminal_title_stripped` を使う（生のほうはスピナー字が毎フレーム変わる）
- `tab_id` は `"w0:t1"` の形で workspace prefix を既に含む。`workspace_id` と連結しない
- **絞り込まない。並べ替えるだけ。** `agent_status` は信用できないので `blocked` でフィルタすると本当に用のある子を隠す
- `herdr` はエラー時に終了コード 1 を返す。エラー判定に JSON の `.error` を見る必要はない
- popup は終了と同時に消えるので **stderr は目に映らない**。想定外の失敗は `herdr notification show` へ逃がす
- git commit メッセージは日本語。`機能: ` / `修正: ` / `文書: ` などの接頭辞を付ける
- リポジトリ `~/project/herdr-jump` に remote は無い。push しない

## File Structure

| ファイル | 責務 |
|---|---|
| `herdr-jump.sh` | 本体。`format_agents`（純関数）＋ `notify` ＋ `main` |
| `tests/assert.sh` | アサーション関数。file-picker からコピー |
| `tests/run.sh` | `test_*.sh` を順に走らせるランナー。file-picker からコピー |
| `tests/test_format_agents.sh` | `format_agents` の自動テスト |
| `tests/probe_focus_retention.sh` | Task 1 専用の実機プローブ。本体完成後も回帰確認に残す |
| `README.md` | 使い方・設定手順・既知の制約 |

`herdr-jump.sh` は 1 ファイルに収める。file-picker（9.5KB, 6 関数）より小さくなる見込みで、分割する理由がない。

---

### Task 1: popup 終了がフォーカスを引き戻さないか実機で確かめる

spec の「未検証のリスク」。`agent focus` の直後に popup の trap がフォーカスを呼び出し元へ戻すなら、この設計は成立しない。**他の何より先に確かめる。**

**Files:**
- Create: `tests/probe_focus_retention.sh`
- Modify: `~/.config/herdr/config.toml`（一時的なキーバインドを追加。Task 6 で正式なものに置き換える）

**Interfaces:**
- Consumes: なし
- Produces: 判定結果のみ。コードは何も produce しない

**前提条件（人間が用意する）:** エージェントを **2 つ以上** 起動しておくこと。1 つだと飛び先が自分しかなく、「動いた」のか「何も起きなかった」のか区別できない。過去に同じ罠を踏んでいる。

- [ ] **Step 1: プローブスクリプトを書く**

`tests/probe_focus_retention.sh`:

```bash
#!/bin/bash
# popup が閉じた後もフォーカスが移動先に残るかを実機で確かめるプローブ。
# herdr のキーバインドから popup として起動されることを前提とする。

set -uo pipefail

OUT="${HOME}/.cache/herdr-jump-probe.txt"
mkdir -p "$(dirname "$OUT")"

focused_now() {
  herdr pane list 2>/dev/null | jq -r '.result.panes[] | select(.focused) | .pane_id' | tr '\n' ' '
}

{
  echo "self(popup)   = ${HERDR_SELF_PANE:-<unset>}"
  echo "origin(caller)= ${HERDR_ACTIVE_PANE_ID:-<unset>}"

  target=$(herdr agent list 2>/dev/null \
    | jq -r --arg self "${HERDR_ACTIVE_PANE_ID:-}" \
        '.result.agents[] | select(.pane_id != $self) | .pane_id' \
    | head -1)
  echo "target        = ${target:-<none>}"

  if [[ -z "$target" ]]; then
    echo "ABORT: 他のエージェントがいません。2つ以上起動してから再実行してください"
    exit 1
  fi

  echo "focused before = $(focused_now)"
  if herdr agent focus "$target" >/dev/null 2>&1; then
    echo "agent focus    = ok"
  else
    echo "agent focus    = FAILED"
  fi
  echo "focused after (popup still open) = $(focused_now)"
} > "$OUT" 2>&1

# popup が消えた後を観測する。setsid で session を切り離し、
# popup ペインの teardown で道連れにされないようにする。
setsid bash -c "
  sleep 2
  {
    echo 'focused 2s after popup close = '\$(herdr pane list 2>/dev/null | jq -r '.result.panes[] | select(.focused) | .pane_id' | tr '\n' ' ')
    echo '--- 判定 ---'
    echo 'target と一致 → 設計は成立。origin と一致 → 引き戻されている（黒）'
  } >> '$OUT'
" </dev/null >/dev/null 2>&1 &

[[ -n "${HERDR_SELF_PANE:-}" ]] && herdr pane close "${HERDR_SELF_PANE}" 2>/dev/null || true
```

- [ ] **Step 2: 実行可能にして一時キーバインドを追加**

```bash
chmod +x ~/project/herdr-jump/tests/probe_focus_retention.sh
```

`~/.config/herdr/config.toml` の末尾に追記:

```toml
[[keys.command]]
key = "alt+p"
type = "pane"
command = "/home/kay/project/herdr-jump/tests/probe_focus_retention.sh"
description = "focus retention probe (temporary)"
```

Herdr の設定を再読み込みする（`herdr` を再起動するか、設定リロードのキーを押す）。

- [ ] **Step 3: エージェントを 2 つ用意して alt+p を押す**

飛び先になるエージェントを別ペイン／別タブで起動しておく。片方のペインで `alt+p` を押す。

- [ ] **Step 4: 結果を読む**

```bash
sleep 3 && cat ~/.cache/herdr-jump-probe.txt
```

判定:

| `focused 2s after popup close` の値 | 意味 | 次の行動 |
|---|---|---|
| `target` と一致 | **白。** 設計はそのまま成立 | Task 2 へ進む |
| `origin` と一致 | **黒。** teardown が引き戻している | 下の回避策へ |
| `target` も `origin` も無い / 空 | 観測失敗 | `setsid` の子が死んでいる。`sleep` を 4 に伸ばして再実行 |

黒だった場合の回避策（上から順に試す）:

1. `agent focus` を `setsid` の子へ逃がし、popup が閉じた **後** に実行させる
2. `type` を `"pane"` 以外に変えて popup を使わない形にする
3. `~/project/herdr/` の Herdr 本体ソースを読み、フォーカス復帰の条件を確定させる

- [ ] **Step 5: 結果を spec に追記してコミット**

`docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md` の「未検証のリスクと実装の一手目」に、実測した値と判定を追記する。「未検証」という見出しも実測済みに書き換える。

```bash
cd ~/project/herdr-jump
git add tests/probe_focus_retention.sh docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md
git commit -m "検証: popup 終了時のフォーカス保持を実機確認

- tests/probe_focus_retention.sh を追加
- spec の未検証リスク欄に実測結果を反映"
```

---

### Task 2: テスト土台と `format_agents` の最小形

**Files:**
- Create: `tests/assert.sh`, `tests/run.sh`, `tests/test_format_agents.sh`, `herdr-jump.sh`

**Interfaces:**
- Consumes: なし
- Produces: `format_agents <self_pane_id>` — stdin から `herdr agent list` の JSON を読み、`表示文字列 \t pane_id` を 1 行ずつ stdout へ。該当なしなら 0 行。jq が失敗したら非ゼロ終了

- [ ] **Step 1: テスト土台を file-picker からコピー**

```bash
cd ~/project/herdr-jump
cp ~/project/herdr-file-picker/tests/assert.sh tests/assert.sh
cp ~/project/herdr-file-picker/tests/run.sh    tests/run.sh
chmod +x tests/run.sh
```

`assert.sh` が提供するのは `assert_eq` / `assert_contains` / `assert_exit_nonzero` / `finish`。`run.sh` は `tests/test_*.sh` を順に走らせ、1 つでも落ちたら非ゼロで終わる。

- [ ] **Step 2: 失敗するテストを書く**

`tests/test_format_agents.sh`:

```bash
#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../herdr-jump.sh"

fixture_basic() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p1","tab_id":"w0:t1","agent":"claude","agent_status":"working","state_change_seq":100,"terminal_title_stripped":"タスクA"},
 {"pane_id":"w1:p2","tab_id":"w1:t2","agent":"codex","agent_status":"blocked","state_change_seq":200,"terminal_title_stripped":"レビュー待ち"}
]}}
JSON
}

# --- 自ペインを除外する ---
result=$(fixture_basic | format_agents "w0:p1")
assert_eq 1 "$(printf '%s\n' "$result" | grep -c .)" "自ペインを除いて 1 行"
assert_contains "$result" "w1:p2" "残るのは相手ペイン"

# --- 出力フォーマットを 1 箇所で固定する ---
# 桁: アイコン + 空白 + agent(8桁詰め) + 空白 + tab_id(8桁詰め) + 空白 + タイトル + TAB + pane_id
assert_eq "● codex    w1:t2    レビュー待ち"$'\t'"w1:p2" "$result" "行フォーマット"

finish
```

区切りは `$'\t'` で外に出して書く。リテラルのタブ文字を文字列に埋めると、
エディタや git の設定で空白に化けたときに気付けない。

**日本語タイトルで桁がずれない理由:** jq の `length` は表示幅ではなく文字数を返すので、
日本語を桁詰めすると崩れる。ただし `pad()` を当てているのは `agent` と `tab_id` の
2 列だけで、どちらも ASCII しか入らない。日本語が入りうるタイトルは最終列なので
そもそも詰める必要がない。**表示幅の計算はこの設計には存在しない。**
ここに幅計算を足そうとしたら、それは要らない複雑さ。

- [ ] **Step 3: テストを走らせて失敗を確認**

```bash
cd ~/project/herdr-jump && bash tests/run.sh
```

期待: `herdr-jump.sh` が存在しないので `source` が失敗して非ゼロ終了。

- [ ] **Step 4: 本体を書く**

`herdr-jump.sh`:

```bash
#!/bin/bash
# herdr-jump: キー一発で「用のあるエージェント」のペインへ飛ぶ。
# herdr のキーバインドから popup ペインとして起動されることを前提とする。

set -euo pipefail

# format_agents <self_pane_id>
#   stdin : herdr agent list の JSON
#   stdout: "表示文字列 \t pane_id" を 1 行ずつ。該当なしなら 0 行
#
# 絞り込みは一切しない。agent_status は信用できないので、blocked で
# フィルタすると本当に用のある子を隠す危険がある。並べ替えるだけにする。
format_agents() {
  local self="${1:-}"
  jq -r --arg self "${self}" '
    # jq には桁詰めの組込みが無いので空白リテラルを切って使う。
    # ("" * 0) が版によって null になる問題を避けるためこの形にしている。
    def pad($n):
      . as $s
      | ($n - ($s | length)) as $k
      | if $k > 0 then $s + ("        " | .[0:$k]) else $s end;

    def icon:
      if   . == "blocked" then "●"
      elif . == "done"    then "◍"
      elif . == "working" then "◐"
      elif . == "idle"    then "○"
      else "·" end;

    def grp:
      if   . == "blocked" or . == "done" then 1
      elif . == "working" then 2
      else 3 end;

    [ .result.agents[] | select(.pane_id != $self) ]
    | sort_by((.agent_status | grp), -(.state_change_seq))
    | .[]
    | (.terminal_title_stripped // "") as $t
    | [ ( (.agent_status | icon) + " "
          + (.agent   | pad(8)) + " "
          + (.tab_id  | pad(8)) + " "
          + (if $t == "" then "(" + .agent_status + ")" else $t end) ),
        .pane_id ]
    | @tsv
  '
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 5: テストを走らせて成功を確認**

```bash
cd ~/project/herdr-jump && bash tests/run.sh
```

期待: `ok` 3 件、`ALL PASS`、`=== ALL TESTS PASSED ===`。

- [ ] **Step 6: コミット**

```bash
cd ~/project/herdr-jump
chmod +x herdr-jump.sh
git add herdr-jump.sh tests/
git commit -m "機能: format_agents の最小形とテスト土台を追加

- agent list の JSON を表示行へ整形する純関数
- 自ペイン除外と行フォーマットをテストで固定
- assert.sh / run.sh は herdr-file-picker から流用"
```

---

### Task 3: 並べ替えとアイコンをテストで固定する

Task 2 で並べ替えのコードは既に書いてあるが、テストで縛られていない。**縛られていない挙動は将来壊れる。**

**Files:**
- Modify: `tests/test_format_agents.sh`

**Interfaces:**
- Consumes: `format_agents <self_pane_id>`（Task 2 で定義）
- Produces: なし

- [ ] **Step 1: 失敗しうるテストを追加**

`tests/test_format_agents.sh` の `finish` の **直前** に挿入:

```bash
# --- 並べ替え: グループ優先、同グループ内は state_change_seq の降順 ---
# seq の並び (900,800,300,100) とグループの並びをわざと食い違わせてある。
# グループ分けが無ければ p9,p4,p3,p2 になり、seq が昇順なら p3,p4 になる。
# どちらが壊れても検出できる。
fixture_sort() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p9","tab_id":"w0:t9","agent":"claude","agent_status":"idle","state_change_seq":900,"terminal_title_stripped":"暇"},
 {"pane_id":"w0:p2","tab_id":"w0:t2","agent":"claude","agent_status":"working","state_change_seq":100,"terminal_title_stripped":"作業中"},
 {"pane_id":"w0:p3","tab_id":"w0:t3","agent":"codex","agent_status":"blocked","state_change_seq":300,"terminal_title_stripped":"確認待ち"},
 {"pane_id":"w0:p4","tab_id":"w0:t4","agent":"codex","agent_status":"done","state_change_seq":800,"terminal_title_stripped":"完了"}
]}}
JSON
}

order=$(fixture_sort | format_agents "" | sed 's/.*\t//' | tr '\n' ' ')
assert_eq "w0:p4 w0:p3 w0:p2 w0:p9 " "$order" "並び順: 要対応(seq降順) → working → idle"

# --- アイコンの対応 ---
# 最初の空白までを切る。cut -c1 は使わない: GNU cut の -c がマルチバイトを
# 文字として扱うかはロケール依存で、LC_ALL=C だとアイコンの 1 バイト目だけ
# 取れて壊れる。sed のこの形はバイト境界に依存しない。
icons=$(fixture_sort | format_agents "" | sed 's/ .*//' | tr '\n' ' ')
assert_eq "◍ ● ◐ ○ " "$icons" "アイコン: done / blocked / working / idle"
```

- [ ] **Step 2: テストを走らせる**

```bash
cd ~/project/herdr-jump && bash tests/run.sh
```

期待: **PASS**。Task 2 の実装が既に正しいため。もし FAIL したら Task 2 の jq を疑うこと（このステップは実装ではなく既存挙動の固定が目的）。

- [ ] **Step 3: テストが本当に効いているか確かめる**

一時的に `herdr-jump.sh` の `sort_by(...)` を `sort_by(-(.state_change_seq))` に書き換えて（グループ分けを外して）テストを走らせる。

期待: `並び順` の assert が FAIL する。確認したら **元に戻す**。

通ることの確認だけでは、テストが何も見ていない可能性を排除できない。

- [ ] **Step 4: コミット**

```bash
cd ~/project/herdr-jump
git add tests/test_format_agents.sh
git commit -m "テスト: 並べ替えとアイコン対応を固定

- グループ順と seq 降順が独立に検出できるフィクスチャ
- グループ分けを外すと落ちることを確認済み"
```

---

### Task 4: エッジケース

**Files:**
- Modify: `tests/test_format_agents.sh`

**Interfaces:**
- Consumes: `format_agents <self_pane_id>`
- Produces: なし

- [ ] **Step 1: エッジケースのテストを追加**

`finish` の直前に挿入:

```bash
# --- タイトル空・キー欠落・未知の status ---
fixture_edge() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p1","tab_id":"w0:t1","agent":"claude","agent_status":"idle","state_change_seq":10,"terminal_title_stripped":""},
 {"pane_id":"w0:p2","tab_id":"w0:t2","agent":"claude","agent_status":"quantum","state_change_seq":20,"terminal_title_stripped":"未知状態"},
 {"pane_id":"w0:p3","tab_id":"w0:t3","agent":"codex","agent_status":"idle","state_change_seq":5}
]}}
JSON
}

edge=$(fixture_edge | format_agents "")
assert_contains "$edge" "(idle)"$'\t'"w0:p1" "タイトルが空なら (状態) を出す"
assert_contains "$edge" "(idle)"$'\t'"w0:p3" "キーごと無い場合も (状態) を出す"
assert_contains "$edge" "· claude"          "未知の status は · で出す（隠さない）"
assert_eq 3 "$(printf '%s\n' "$edge" | grep -c .)" "3 件すべて残る"

# --- 0 件 ---
empty=$(echo '{"result":{"agents":[]}}' | format_agents "")
assert_eq "" "$empty" "エージェント 0 件なら空出力"

# --- 自分しかいない ---
fixture_only_self() {
  cat <<'JSON'
{"result":{"agents":[
 {"pane_id":"w0:p1","tab_id":"w0:t1","agent":"claude","agent_status":"idle","state_change_seq":1,"terminal_title_stripped":"x"}
]}}
JSON
}
only_self=$(fixture_only_self | format_agents "w0:p1")
assert_eq "" "$only_self" "自分だけなら空出力"
```

未知 status を `·` で **出す**（除外しない）ことを固定しているのが要点。spec の「絞り込まない」判断をテストで守る。

- [ ] **Step 2: テストを走らせる**

```bash
cd ~/project/herdr-jump && bash tests/run.sh
```

期待: 全 PASS。

- [ ] **Step 3: コミット**

```bash
cd ~/project/herdr-jump
git add tests/test_format_agents.sh
git commit -m "テスト: 空タイトル・未知 status・0件のエッジケースを追加

- 未知 status を除外せず · で出すことを固定"
```

---

### Task 5: `main` を実装する

**Files:**
- Modify: `herdr-jump.sh`

**Interfaces:**
- Consumes: `format_agents <self_pane_id>`
- Produces: `notify <message>` — `herdr notification show` へ 1 行流す。失敗しても握りつぶす

`main` は herdr 実プロセスと fzf の対話を要するため自動テストの対象外。Task 6 の手動検証で確かめる。

- [ ] **Step 1: `notify` と `main` を書く**

`herdr-jump.sh` の `main() { : }` を以下で置き換える:

```bash
# notify <message>
#   popup は終了と同時に消えるので stderr は目に映らない。
#   想定外の失敗はここから外へ出す。通知の失敗自体は握りつぶす。
notify() {
  herdr notification show "herdr-jump: ${1}" >/dev/null 2>&1 || true
}

main() {
  # Herdr 外からの誤実行。ここだけは popup ではないので stderr が読める
  if [[ "${HERDR_ENV:-}" != "1" ]]; then
    echo "Error: このスクリプトは herdr セッション内で実行してください。" >&2
    exit 1
  fi

  local self_pane="${HERDR_ACTIVE_PANE_ID:-}"
  if [[ -z "${self_pane}" ]]; then
    echo "Error: HERDR_ACTIVE_PANE_ID が設定されていません。キーバインドから起動してください。" >&2
    exit 1
  fi

  # 以降どの経路で抜けても popup を畳む
  if [[ -n "${HERDR_SELF_PANE:-}" ]]; then
    trap 'herdr pane close "${HERDR_SELF_PANE}" 2>/dev/null || true' EXIT
  fi

  local json
  if ! json=$(herdr agent list 2>/dev/null); then
    notify "エージェント一覧を取得できませんでした"
    exit 1
  fi

  local rows
  if ! rows=$(printf '%s' "${json}" | format_agents "${self_pane}"); then
    notify "一覧の整形に失敗しました"
    exit 1
  fi

  if [[ -z "${rows}" ]]; then
    notify "他にエージェントはいません"
    exit 0
  fi

  # --with-nth=1 で pane_id 列を隠す。選択結果には含まれたまま返ってくる
  local selected
  selected=$(printf '%s\n' "${rows}" | fzf \
    --reverse \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='jump> ' \
    --header='Enter: 移動  /  Esc: 取消') || true

  # Esc で抜けた場合。何も起きないのが正しい
  [[ -n "${selected}" ]] || exit 0

  local target="${selected##*$'\t'}"

  if ! herdr agent focus "${target}" >/dev/null 2>&1; then
    notify "フォーカスできませんでした: ${target}"
    exit 1
  fi
}
```

- [ ] **Step 2: 既存テストが壊れていないことを確認**

```bash
cd ~/project/herdr-jump && bash tests/run.sh
```

期待: 全 PASS。`source` しても `main` は走らないので影響しないはず。ここで落ちたら `BASH_SOURCE` ガードを疑う。

- [ ] **Step 3: 構文チェック**

```bash
bash -n ~/project/herdr-jump/herdr-jump.sh && echo "構文 OK"
shellcheck ~/project/herdr-jump/herdr-jump.sh || true
```

このコードで shellcheck が出す指摘は **SC2310 の 1 件だけ**（確認済み）。

```
SC2310 (info): This function is invoked in an 'if' condition so set -e will be disabled.
  → if ! rows=$(printf '%s' "${json}" | format_agents "${self_pane}"); then
```

**これは意図した形なので直さない。** `format_agents` が落ちたときに `set -e` で即死されると
popup が畳まれずに残るうえ、通知も出せない。自分で受けて `notify` に流すためにわざと
`if !` で包んでいる。

これ以外の指摘が出たら、それは書き写しのミス。

`shellcheck` が無ければ `bash -n` だけでよい。

- [ ] **Step 4: Herdr 外で起動して env ガードが効くことを確認**

```bash
env -u HERDR_ENV bash ~/project/herdr-jump/herdr-jump.sh; echo "exit=$?"
```

期待: `Error: このスクリプトは herdr セッション内で実行してください。` と `exit=1`。

- [ ] **Step 5: コミット**

```bash
cd ~/project/herdr-jump
git add herdr-jump.sh
git commit -m "機能: main と notify を実装

- env ガード / trap 自己クローズ / fzf 選択 / agent focus
- popup は stderr を飲むので想定外の失敗は notification へ逃がす"
```

---

### Task 6: 配線して実機で検証する

**Files:**
- Create: `~/.local/bin/herdr-jump.sh`（シンボリックリンク）
- Modify: `~/.config/herdr/config.toml`

**Interfaces:**
- Consumes: `herdr-jump.sh`
- Produces: なし

- [ ] **Step 1: シンボリックリンクを張る**

```bash
ln -sf ~/project/herdr-jump/herdr-jump.sh ~/.local/bin/herdr-jump.sh
ls -l ~/.local/bin/herdr-jump.sh
command -v herdr-jump.sh
```

file-picker と同じ配置。`~/.local/bin` は PATH 上にあるので `command` に絶対パスを書かなくてよい。

- [ ] **Step 2: キー衝突を確認**

```bash
grep -n 'key *=' ~/.config/herdr/config.toml
herdr --default-config 2>/dev/null | grep -n 'alt+j' || echo "組込みに alt+j なし"
```

既存は `ctrl+f`（file picker）と `alt+g`（lazygit）。`alt+j` が組込みと衝突していたら別のキーに変える。決めたキーは README と spec に反映する。

- [ ] **Step 3: Task 1 の一時キーバインドを本番のものに置き換える**

`~/.config/herdr/config.toml` の `alt+p`（probe）のブロックを削除し、以下を追加:

```toml
[[keys.command]]
key = "alt+j"
type = "pane"
command = "herdr-jump.sh"
description = "jump to agent"
```

Herdr の設定を再読み込みする。

- [ ] **Step 4: 手動検証**

判定材料には **フォーカスが動いた時にしか真にならないもの** を使う。目視だけだと「popup が閉じてスッキリしただけ」と区別がつかない。

エージェントを 2 つ起動した状態で:

| # | 操作 | 判定方法 | 期待 |
|---|---|---|---|
| 1 | `alt+j` → 相手を選ぶ | 移動先で `herdr pane list \| jq -r '.result.panes[]\|select(.focused)\|.pane_id'` | 選んだ pane_id |
| 2 | 同上（Task 1 の結論の再確認） | 上と同じ | 呼び出し元に戻っていない |
| 3 | `alt+j` → Esc | 上と同じ | 呼び出し元のまま。通知も出ない |
| 4 | エージェントを 1 つ閉じてから `alt+j` | 一覧の中身 | 閉じたペインが出ない |
| 5 | エージェントが自分だけの状態で `alt+j` | 通知 | 「他にエージェントはいません」 |

- [ ] **Step 5: 結果を記録してコミット**

`~/.config/herdr/` は別リポジトリなので、herdr-jump 側には検証結果だけ残す。`docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md` の「テスト」節に実施日と結果を追記する。

```bash
cd ~/project/herdr-jump
git add docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md
git commit -m "検証: 実機での手動検証を完了

- 5 項目すべて期待通り
- キーバインドは alt+j"
```

`~/.config` 側の変更は kay の判断で別途コミットする。

---

### Task 7: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: なし
- Produces: なし

file-picker には README が無く、後から仕様を思い出す手掛かりが git log しかない。同じ穴を開けない。

- [ ] **Step 1: README を書く**

`README.md`:

````markdown
# herdr-jump

Herdr でキーを 1 つ押すと、動いているエージェントの一覧が popup で出て、
選んだペインへフォーカスが飛ぶ。

Herdr は通知を出すが、通知をクリックしてもそのペインには飛ばない
（`[ui.toast]` にクリック時アクションの設定項目が存在しない）。
通知を起点にする代わりに、キーを起点にして「引き込む」ことで解決する。

## 必要なもの

- herdr 0.7.5+
- jq
- fzf

## 導入

```bash
ln -sf ~/project/herdr-jump/herdr-jump.sh ~/.local/bin/herdr-jump.sh
```

`~/.config/herdr/config.toml` に追記:

```toml
[[keys.command]]
key = "alt+j"
type = "pane"
command = "herdr-jump.sh"
description = "jump to agent"
```

## 使い方

`alt+j` を押すと一覧が出る。Enter で移動、Esc で取消。

```
● codex    w1:t2    レビュー待ち
◍ claude   w0:t4    完了
◐ claude   w0:t2    ovba-writer の CP932 まわり
○ claude   w0:t9    (idle)
```

| アイコン | 状態 |
|---|---|
| `●` | blocked（要対応） |
| `◍` | done（要対応） |
| `◐` | working |
| `○` | idle |
| `·` | 不明 |

上のグループほど上に並ぶ。同じグループの中では、直近で状態が変わったものが上。

3 列目の見出しは Claude Code が OSC タイトルに出しているタスク名をそのまま拾っている。
こちら側で何かを設定する必要はない。

## 設計上の判断

**絞り込まない。並べ替えるだけ。**
Herdr の `agent_status` は信用できない（`agent explain` が `working` と判定している
ペインを `blocked` と報告する不整合を実測で確認）。`blocked` でフィルタすると
本当に用のある子を隠しかねない。隠すのは致命的で、余分に 1 行並ぶのは無害。
この非対称性から、絞らずに順番だけ変えている。

## 制約

- 飛べるのは Herdr がエージェントとして認識しているペインだけ。素のシェルペインには
  飛べない（`herdr agent focus` が `agent_not_found` を返す）
- popup は終了と同時に消えるため、stderr に出したものは目に映らない。
  想定外の失敗は `herdr notification show` で外に出している

## テスト

```bash
bash tests/run.sh
```

整形ロジック（`format_agents`）のみを対象にしている。herdr 実プロセスと fzf の対話が
要る部分は自動テストできないので、`docs/superpowers/plans/` の手動検証手順で確かめる。

`tests/probe_focus_retention.sh` は「popup が閉じた後もフォーカスが移動先に残るか」を
実機で確かめるプローブ。設計の前提が壊れていないかの回帰確認に使う。

## 詳細

`docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md`
````

- [ ] **Step 2: コミット**

```bash
cd ~/project/herdr-jump
git add README.md
git commit -m "文書: README を追加

- 導入手順・アイコン表・設計判断・制約
- file-picker に README が無く仕様が git log にしか残らない状態だったため"
```

---

## 完了条件

- `bash tests/run.sh` が全 PASS
- `alt+j` で一覧が出て、選んだペインへフォーカスが移動する（`pane list` の `focused` で確認済み）
- Esc で何も起きない
- エージェントが自分だけのときに通知が出る
- README を読めば再導入できる
