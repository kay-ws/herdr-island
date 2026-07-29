# herdr Agents パネル情報拡充 — 設計

- 日付: 2026-07-30
- ステータス: 承認済み
- 前 spec: [2026-07-29-herdr-agent-jump-design.md](2026-07-29-herdr-agent-jump-design.md)（**却下理由に誤りあり。第2節参照**）

## 1. 背景

herdr-jump v1 が提供したのは fzf によるペイン切り替えだけだった。しかし herdr 0.7.5 は
Agents パネルを内蔵しており、クリック1つで同じことができる。v1 は内蔵機能の再実装であり、
存在価値が無い。

Vibe Island (https://vibeisland.app/) を参考に同種ツールの機能を分解すると、動詞は4つある。

| 動詞 | 内容 | herdr での状況 |
|---|---|---|
| Jump | 該当ペインへ移動 | **内蔵済み**（Agents パネルのクリック） |
| Monitor | 各エージェントの状態を一覧 | 内蔵。ただし state アイコンとラベルのみで情報が薄い |
| Approve | 許可要求への応答 | 無し |
| Ask | 質問への応答 | 無し |

Approve / Ask は**スコープ外**とする。該当ペインへ飛べば本物の UI で応答できるので、
中間 UI を挟む必然性が無い。fzf ポップアップで選択肢を出す設計は破棄する。

よって本 spec のスコープは **Monitor の情報密度を上げること** に一本化される。
パネルを見れば「何で止まっているか」が分かり、そこをクリックすれば実画面に飛べる、
という状態を作る。

## 2. 前 spec の却下理由が誤りだった件

前 spec は2つの機能を「スコープ外」として落としたが、いずれも**調査ではなく優先度の
言い切り**による却下であり、実測の結果どちらも誤りだった。記録として残す。

**却下1「Agents パネルの表示内容は herdr 側の管轄で拡張できない」** — 誤り。
`herdr pane report-metadata` という display-only のメタデータ報告 API が存在する。
任意の `--token NAME=VALUE` を送り、`[ui.sidebar.agents]` の行テンプレートに `$NAME`
として埋め込める。値の送信（report-metadata）と並べ方（config の `rows`）の2者分担に
なっており、**片方だけでは何も表示されない**。前 spec は API 側だけを見て「表示できない」
と判断した可能性が高い。

**却下2「許可要求の内容はフックから取れない」** — 誤り。`PreToolUse` を入口と誤認して
いた。`PreToolUse` は全 tool 呼び出しで発火するので確かに「止まっている」の判定には
使えないが、**`PermissionRequest` は許可を求める時だけ発火する**専用イベントであり、
`tool_name` と `tool_input` を含む。

**学び:** 「できない」と書く前に一次ソースを引く。両方とも実測5分で覆った。

## 3. スコープ

**やる**

- 「何で止まっているか」を Agents パネルへ出す（reason 配管）
- context 使用率を Agents パネルへ出す（usage 配管）
- 上記を Claude Code と Codex の両方で
- `install.sh` による既存ファイルの自動書き換え

**やらない**

- 許可・質問への応答 UI（第1節の判断）
- ペイン切り替え UI（herdr 内蔵で足りる）
- 並べ替えの自前実装（`agent_panel_sort = "priority"` 1行で済む）
- Codex 側の `trusted_hash` 自動登録（第8節の理由により不可能）

## 4. アーキテクチャ

独立した2本の配管。互いに知らないし、片方が壊れてももう片方は動く。

```
[reason 配管]                          [usage 配管]

Claude/Codex のフック                   ccstatus (statusLine)
  PermissionRequest ──┐                   │ stdin に JSON
  PreToolUse(AskUQ) ──┼─ set               │
  Elicitation       ──┘                   ▼
  PostToolBatch     ──┬─ clear        herdr-usage-push
  Stop              ──┘                   │
        │                                 │
        └──── herdr pane report-metadata ─┘
                        │
                        ▼
              [ui.sidebar.agents.rows_by_agent]
                        │
                        ▼
                 Agents パネル
```

| | reason | usage |
|---|---|---|
| 出所 | フック | statusLine の stdin JSON |
| 発火 | 止まった瞬間に1回 | 毎ターン |
| 寿命 | 応答したら消さないと嘘になる | 常に上書き。消す概念が無い |
| pane 特定 | `$HERDR_PANE_ID` | `$HERDR_PANE_ID` |
| 失敗時 | 出ないだけ | 出ないだけ |

**共通の大原則:** どの配管も失敗を握り潰す。フックが非ゼロ終了すると Claude Code の
動作に影響しうるので、全経路で `|| true` / `2>/dev/null` を徹底し、必ず `exit 0` する。
表示が出ないのは許容できるが、エージェントが止まるのは許容できない。

**依存:** `jq` と `herdr` CLI のみ。`python3` は使わない（後述の理由により不要になった）。

## 5. reason 配管

### 5.1 止まり方は3種類ある

前 spec は「許可プロンプト」だけを見ていたが、実際には止まり方が3つある。

| 止まり方 | イベント | matcher | 取れる材料 |
|---|---|---|---|
| 許可待ち | `PermissionRequest` | `*` | `tool_name` / `tool_input` |
| 質問待ち | `PreToolUse` | `AskUserQuestion` | `tool_input.questions[0].header` |
| MCP 入力待ち | `Elicitation` | — | `mcp_server_name` / `message` |

`AskUserQuestion` は許可を要さない tool なので `PermissionRequest` が発火しない。
`PreToolUse` を matcher で `AskUserQuestion` に絞ることで、
「全 tool で発火する」問題を回避しつつ質問待ちだけを拾える。

### 5.2 reason 文字列の組み立て

`PermissionRequest` の実 payload（公式リファレンスより）:

```json
{ "hook_event_name": "PermissionRequest", "tool_name": "Bash",
  "tool_input": { "command": "rm -rf node_modules",
                  "description": "Remove node_modules directory" },
  "permission_suggestions": [ ... ] }
```

`tool_input.description` に**既に人間向けの一行説明が入っている**のが大きい。
要約を自前で組み立てる必要がほぼ無い。以下の優先順で拾う。

| tool | 本文 | 例 |
|---|---|---|
| `Bash` | `.description` → 無ければ `.command` | `Bash: Remove node_modules directory` |
| `Edit` / `Write` / `Read` | `.file_path` の basename | `Edit: herdr-jump.sh` |
| `AskUserQuestion` | `.questions[0].header` | `質問: 実装方針` |
| （Elicitation） | `.message` | `MCP: 認証が必要です` |
| その他 | tool 名のみ | `WebFetch` |

### 5.3 切り捨て

Agents パネルは幅が限られるので **40 文字で切り、`…` を付ける**。

切り捨ては **jq の文字列スライスで行う**。jq のスライスは UTF-8 コードポイント単位で
動くので、日本語混じりでもバイト境界を割らない。bash の `${#str}` は locale 依存、
`cut -c` は実装依存で、どちらも信用できない。JSON パースで jq がどのみち必要なので、
依存を増やさずに正しく切れる。

```jq
def trunc($n): if (. | length) > $n then (.[0:$n-1] + "…") else . end;
```

### 5.4 消し方（3段重ね）

| 契機 | 役割 |
|---|---|
| `PostToolBatch` | 通常クリア。バッチごとに1回だけ発火するので、並列 tool 呼び出しでも socket を N 回叩かない |
| `Stop` | 取りこぼし回収。**許可を拒否した時に `PostToolBatch` が発火するかは未確認**。発火しないなら、これが無いと赤い表示が残り続ける |
| `--ttl-ms 900000` | 最後の保険。フックが全部落ちても15分で消える |

`Stop` は「once per turn」なので、拒否・中断・エラーのいずれでも必ず通る。

### 5.5 送信コマンド

```sh
herdr pane report-metadata \
  --source herdr-jump \
  --token reason="$REASON" \
  --seq "$(date +%s%3N)" \
  --ttl-ms 900000 \
  "$HERDR_PANE_ID"
```

クリアは `--clear-token reason`。

`--seq` にミリ秒 epoch を渡すのは順序保証のため。フックは並行に起動しうるので、
到着順と発生順が食い違った時に古い値で上書きされるのを防ぐ。

### 5.6 ガード

`~/.claude/hooks/herdr-agent-state.sh`（herdr 管理の既存フック）の作法に倣う。

```sh
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
```

`HERDR_PANE_ID` は herdr がペイン内の**全プロセスツリーに継承**させる env なので、
その存在自体がペイン所属の証明になる（`herdr server` 自身は持っていない）。

### 5.7 Codex との共有

Codex は Claude Code 互換のフックスキーマを持つ（バイナリ 0.146.0 の strings に
`PermissionRequest` / `PreToolUse` / `PostToolUse` / `SessionStart` / `Stop` /
`UserPromptSubmit` / `Notification` が PascalCase で存在）。

したがって**フック本体は1本を両者で共有する**。配線先の設定ファイルが違うだけ。

## 6. usage 配管

### 6.1 出所

context 使用率の出所は transcript ではなく **statusLine の stdin JSON**。
`~/.local/bin/ccstatus` が既に全材料を持っている。

```
.context_window.context_window_size          … 分母
.context_window.current_usage                … input + cache_creation + cache_read
.rate_limits.five_hour.used_percentage       … 5h（Pro/Max のみ）
.rate_limits.seven_day.used_percentage       … 7d（Pro/Max のみ）
```

transcript を読む案は破棄する。実行中/未応答の tool_use は transcript に書かれないので、
リアルタイム用途には使えない（実測: 全セッションで未応答 tool_use = 0 件）。

### 6.2 配線

`ccstatus` の5行目に既に丸投げの前例がある。

```bash
echo "$input" | crmux rpc status-update &
echo "$input" | herdr-usage-push &          # ← 足す1行
```

`ccstatus` 本体のロジックには一切触らない。`herdr-usage-push` が stdin の JSON から
値を読み、`report-metadata` を打つ。

### 6.3 トークン

| トークン | 内容 | 例 |
|---|---|---|
| `$ctx` | context 使用率 | `42%` |
| `$limits` | 5h / 7d | `5h 11% \| 7d 2%` |

`rate_limits` はセッション最初の API 応答後にしか出現しないので、無ければ `$limits` は
送らない（クリアもしない。前の値が TTL まで残るが実害が無い）。

usage 側の `--ttl-ms` は **3600000（1時間）**。reason の15分より長くする。usage は
「今どれくらい使っているか」の継続的な状態であって、応答すれば消えるべき事象ではない。
短い TTL を付けると、エージェントが単に長考している間に数字が消えてしまう。一方で
無期限にすると閉じたセッションの古い数字が残り続けるので、1時間で落とす。

モデル名は送らない。herdr が `agent` セグメントを既に持っており冗長。

### 6.4 キャッシュは持たない

statusLine は毎ターン走るので `herdr-usage-push` も毎ターン起動する。前回値と比較して
スキップする最適化は**入れない**。状態ファイルを持つ複雑さと、1プロセス分のコストが
釣り合わない。

### 6.5 Codex には無い

Codex に statusLine 相当の仕組みが無いため、usage は Claude ペインのみ。
これは Codex 側の制約で、こちらで埋めようがない。

## 7. 表示層

`~/.config/herdr/config.toml` へ追記する。

**現状、kay の config は `rows` が未設定**（＝デフォルト
`rows = [["state_icon","workspace","tab"],["agent"]]` が効いている）。この状態では
トークンを送っても**描画先が無いので何も出ない**。表示層の設定が本機能の必須条件である。

```toml
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
```

`agent_panel_sort = "priority"` は herdr 内蔵の attention queue 順。止まっている
ペインが上に来る。v1 が jq で自前実装していた `sort_by` はこれで置き換わる。

色は catppuccin（kay の現テーマ）に合わせる。claude = red 系、codex = yellow 系。

## 8. install.sh

4ファイルを触る。全て `.bak.YYYYMMDD-HHMMSS` を取ってから書き換える。
何度実行しても同じ結果になること（冪等）。

### 8.1 `~/.claude/settings.json`

`jq` で書き換える。`PermissionRequest` には**既に superset の `notify.sh` が居る**ので、
上書きせず**配列へ追記**する。冪等判定は command 文字列に含めた固定マーカー
`herdr-jump` の有無で行う。

| イベント | matcher | 動作 |
|---|---|---|
| `PermissionRequest` | `*` | set（既存配列へ追記） |
| `PreToolUse` | `AskUserQuestion` | set |
| `PostToolBatch` | — | clear |
| `Stop` | — | clear |

### 8.2 `~/.config/herdr/config.toml`

TOML なので `jq` が使えない。マーカーで囲んだブロックを末尾に置き、再インストール時は
`awk` でブロックごと差し替える。

```toml
# >>> herdr-jump (managed) >>>
agent_panel_sort = "priority"
[ui.sidebar.agents]
...
# <<< herdr-jump (managed) <<<
```

kay の config は末尾が `[[keys.command]]` なので、後ろに新しいテーブルヘッダを足すのは
安全（後続行が無く、意図しないテーブルへの吸い込みが起きない）。

### 8.3 `~/.local/bin/ccstatus`

マーカー付きの1行を `crmux` 行の直後に挿入。既にあれば何もしない。

### 8.4 `~/.codex/hooks.json`

`jq` で既存の `SessionStart` を保ったまま4イベントを追記。

**`~/.codex/config.toml` は読まない・書かない。** Codex は `[hooks.state]` に
フックの `trusted_hash` を登録するが、そのハッシュの入力正規化は特定できなかった
（コマンド文字列・改行付き・`hooks.json` 全体・フック本体・JSON シリアライズ2種の
計6候補すべて不一致）。

推測したハッシュを書き込むと Codex が起動時にフックを黙って無効化し、
「なぜか動かない」という**失敗が見えない形の壊れ方**になる。これは承認プロンプト1回
より遥かに高くつく。よって自動化しない。

なお `[hooks.state]` の登録済みエントリを調べると、現在の `hooks.json` に存在しない
イベント（`user_prompt_submit` / `stop`）が残っており、それでも Codex は正常動作して
いる。つまり**古い行が残っても害が無い**設計であり、install.sh が何度走っても
`[hooks.state]` を汚さないことが保証される。

install.sh は最後に「Codex は次回起動時に承認が1回必要」と表示して終わる。

## 9. リポジトリの畳み方

**消す**

- `herdr-jump.sh`（108行）— fzf による切り替え UI。herdr 内蔵と重複
- `tests/test_format_agents.sh` — `format_agents()` の検査。対象が消えるため
- `tests/probe_focus_retention.sh` — フォーカス挙動の探り。役目を終えた
- fzf 依存

**残す**

- `tests/assert.sh` / `tests/run.sh` — テストの骨格。第10節で再利用する
- `docs/superpowers/specs/2026-07-29-*.md` — 履歴。第2節が参照する
- `docs/superpowers/plans/2026-07-29-*.md` — 同上
- git 履歴

**新規**

```
hooks/herdr-jump-reason.sh     # set/clear 両方（引数で分岐）。claude/codex 共用
statusline/herdr-usage-push    # ccstatus から呼ばれる
config/agents-rows.toml        # config.toml へ挿入するブロックの原本
install.sh                     # 冪等な配線
README.md                      # 全面書き換え
```

**リポジトリ名は `herdr-jump` のまま**とする。jump は死んだ機能ではなく、herdr 内蔵の
Agents パネルクリックとして生きている。本プロジェクトは「jump するために必要な情報を
パネルに出す」ものになったと読めば名前と実態は合う。改名して git remote・ローカルパス・
memory 記載を張り替えるコストに見合う利得が無い。

## 10. 検証

**単体テスト**（`tests/assert.sh` + `tests/run.sh` を再利用）

reason 文字列の組み立ては純粋関数（stdin JSON → 1行の文字列）なので、
herdr も Claude Code も無しにテストできる。ここが本機能で唯一ロジックらしいロジック。

| ケース | 入力 | 期待 |
|---|---|---|
| Bash + description | `{tool_name:"Bash", tool_input:{command:"...", description:"Remove X"}}` | `Bash: Remove X` |
| Bash description 無し | `{tool_name:"Bash", tool_input:{command:"ls -la"}}` | `Bash: ls -la` |
| Edit | `{tool_name:"Edit", tool_input:{file_path:"/a/b/c.sh"}}` | `Edit: c.sh` |
| AskUserQuestion | `{tool_name:"AskUserQuestion", tool_input:{questions:[{header:"実装方針"}]}}` | `質問: 実装方針` |
| 未知 tool | `{tool_name:"WebFetch", tool_input:{}}` | `WebFetch` |
| 40字超（ASCII） | 長い command | 39字 + `…` |
| 40字超（日本語） | 長い日本語 header | 39文字 + `…`（バイト境界を割らない） |
| 空の tool_input | `{tool_name:"Bash", tool_input:{}}` | `Bash` |

usage 側も同様に、statusLine の stdin JSON サンプルから `$ctx` / `$limits` を組み立てる
部分をテストする。`rate_limits` が無い場合に `$limits` を送らないことを含む。

**手動検証**（実機）

1. Claude ペインで許可を要する操作を叩き、別ペインから Agents パネルに reason が出るか
2. 許可を**拒否**して reason が消えるか（`Stop` 経路の確認。ここが一番壊れやすい）
3. `AskUserQuestion` が出た時に `質問: <header>` が出るか
4. `$ctx` が毎ターン更新されるか
5. Codex ペインで reason が出るか（承認プロンプトを1回通した後）
6. `install.sh` を2回連続で実行し、settings.json / config.toml / ccstatus が
   重複エントリを持たないこと

## 11. 実装時に判明して設計を変えた点

実装後に追記。**以下は本文（第1〜10節）の記述を上書きする。**

### 11.1 herdr CLI は使えない → socket API 直叩き

第5.5節は `herdr pane report-metadata` を送信手段としていたが、**herdr 0.7.5 の
この CLI は `--source` に値を渡せない**。13 パターン試した結果:

| 渡し方 | 結果 |
|---|---|
| `--source hj` | `unknown option: hj` |
| `--source=hj` | 認識されず → `missing required --source` |
| `--source 1`（数値） | `unknown option: 1` |
| 位置引数 `w0:p1` | `unknown option: w0:p1`（常に拒否） |
| `-- w0:p1` | `unknown option: --` |
| `--token reason=X` | **通る**（スペース形式） |
| `--seq T` | **通る**（`--seq=T` は拒否） |

help は `Usage: ... [OPTIONS] --source <ID> <PANE_ID>` と書いているが実装が伴っていない。
rtk バイパス・`env -i` の最小環境でも同じで、環境要因ではない。

**socket API なら動く**（実測で `{"result":{"type":"ok"}}`）:

```
method: pane.report_metadata
params 必須: pane_id, source
params 任意: tokens(object) / seq(int) / ttl_ms(int) / agent / title /
             display_agent / state_labels / applies_to_source /
             clear_title / clear_display_agent / clear_state_labels
socket: $HERDR_SOCKET_PATH
```

- **クリアは `tokens: {reason: null}`**（実測: snapshot の `tokens` が `null` になる）。
  `clear_token` に相当するパラメータは RPC に無い —— title / display_agent /
  state_labels には専用フラグがあるのに token には無いので、null を入れるのが設計上の手段
- トークンの格納先は `snapshot.panes[].tokens.<name>` と `snapshot.agents[].tokens.<name>`。
  `herdr api snapshot` で検証できるので、**パネルの見え方と切り離して切り分けられる**
- herdr 公式フック `herdr-agent-state.sh` も CLI を使わず socket 直叩き（python3）。
  つまりこれが herdr の想定経路で、CLI を選んだ本設計が筋悪だった

**依存が変わる。** 第4節の「依存は `jq` と `herdr` CLI のみ」→ **`jq` と `python3`**。
送信手段は `nc -U -N` でも動いたが python3 を選んだ（kay の判断）。理由は公式フックと
同じ経路であること、netcat は実装が3系統あって `-U` / `-N` の可否が環境で変わること。

副産物としてテストが単純になった。JSON を送るので値の空白や `|` はそのまま 1
フィールドとして届き、**シェル引数のクォート漏れという失敗モードが構造的に消える**。
偽 socket サーバ（`tests/fake_socket.sh`）が受信 JSON をそのまま検証する。

### 11.2 カスタムトークンは `$` 接頭辞が必須

第7節の `{ token = "reason", ... }` は誤り。正しくは `{ token = "$reason", ... }`。

```
invalid ui config: unknown sidebar token `reason`;
custom tokens must start with `$` ; keeping current ui settings
```

**`$` を忘れると `[ui]` 設定が丸ごと拒否される**（"keeping current ui settings"）ので、
`row_gap` も `rows` も一切効かなくなる。built-in セグメント（`state_icon` /
`workspace` / `tab` / `agent`）は `$` 無し。

### 11.3 `agent_panel_sort` はマーカーブロックに書けない

第7節・第8.2節はブロック内に `agent_panel_sort = "priority"` を書く形だったが、
これは末尾追記されるブロックでは不可能:

- ブロック内で `[ui]` を定義すると既存 `[ui]` と衝突して `Cannot declare ('ui',) twice`
- `ui.agent_panel_sort = "..."` と書くと直前のテーブル内のキーと解釈され
  `ui.ui.agent_panel_sort` になる。**パースは通るので気づけない**

install.sh が3経路で `[ui]` へ入れる形にした（既存キーの置換 / `[ui]` 直後への挿入 /
`[ui]` が無ければブロックの後に `[ui]` を作る）。`[ui.sidebar.agents]` を先に書いてから
`[ui]` を後付け定義するのは TOML で許されることを実測で確認済み。

### 11.4 `tokens` はキー単位でマージされる（配管を分ける前提）

第4節は reason と usage を「独立した2本の配管」としたが、**両方が同じ `tokens`
オブジェクトに書く**ので、herdr が置換方式なら毎ターン走る usage push が reason を
消し続けて機能が成立しない。設計時にこれを確認していなかった。

実測ではキー単位のマージだった:

```
1) reason を送る    → {"ctx":"34%", "limits":"5h 6% | 7d 13%", "reason":"Bash: Remove node_modules"}
2) usage push       → {"ctx":"35%", "limits":"5h 6% | 7d 13%", "reason":"Bash: Remove node_modules"}
3) usage push 2回目 → {"ctx":"36%", "limits":"5h 6% | 7d 13%", "reason":"Bash: Remove node_modules"}
```

`ctx` は更新され `reason` は残る。クリアも `tokens: {reason: null}` で reason だけが
消え `ctx` は残る。したがって配管の独立性はこのマージ挙動に依存している。
**herdr 側の実装に依存する前提なので、herdr の更新時に再確認すべき項目。**
偽 socket サーバは受信 JSON を記録するだけなのでテストでは固定できない。

### 11.5 その他

- 設定リロードは `herdr server reload-config`（`herdr config reload` は存在しない）
- `tests/run.sh` は nullglob が無く、テスト 0 件のとき glob がリテラルのまま bash に
  渡って誤爆していた。Task 1 で修正
- `label` は jq の予約語（`label $out | break`）なので関数名に使えない。`heading` にした

## 12. 未解決 / 実装時に決めること

- `Elicitation` イベントの実 payload を未確認。`reason-filter.jq` は扱えるが
  `install.sh` は**意図的に配線していない**。payload を確認できたら 1 エントリ足すだけ。
  許可待ち・質問待ちはこれと独立に動くので未配線でも機能は完結している
- 40文字が実際の Agents パネル幅に対して適切かは実機で見て調整する（未確認）
- herdr 側がトークンを自動 truncate するのか、はみ出すのかは未確認
- **許可プロンプトでの自動発火は未検証。** フック本体を手で叩いた検証は済んでいる
  （`tokens` に値が入ることを snapshot で確認）が、`settings.json` の配線経由で
  実際に `PermissionRequest` が飛ぶかは次セッション以降でしか見られない
  （Claude Code はフック設定を起動時に読む）
- **拒否時に `PostToolBatch` が発火するかは未確認。** `Stop` フックが取りこぼしを
  回収する設計なので、どちらでも reason は消えるはず
