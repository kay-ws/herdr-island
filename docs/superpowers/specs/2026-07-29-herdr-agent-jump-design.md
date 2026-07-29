# herdr-jump — キー一発で「用のあるエージェント」へ飛ぶ

作成日: 2026-07-29
対象: Herdr 0.7.5

## 背景

複数の AI エージェントを Herdr 上で並列に動かしていると、止まっている子を見つけて移動する操作が作業の律速になる。Herdr は通知を出すが、**通知をクリックしてもそのペインには飛ばない**。

調査の結果、これは設定ミスではなく Herdr の設計上の欠落だと確定した。

- `herdr --default-config` の `[ui.toast]` が持つキーは `delivery` と `delay_seconds` のみ。クリック時アクションを指定する項目がどこにも存在しない
- `herdr notification` のサブコマンドは `show` だけ
- 現行設定は `delivery = "terminal"`。OSC で外側の kitty に渡す**片道**の経路で、翻訳された時点で pane_id が落ちる
- 実行環境側でも経路が切れている。`~/.config/mako/config` は存在せず mako は完全デフォルト（左クリックは `dismiss`）、kitty の remote control も無効（`allow_remote_control no` / `listen_on none` がいずれもコメントアウト状態のデフォルト）

## 設計の起点：押し出しをやめて引き込みにする

通知クリックを起点にすると、**compositor 層（sway のウィンドウフォーカス）と Herdr 層（ペインフォーカス）の 2 段**を越える必要がある。

Herdr 内のキーバインドを起点にすると、押した時点で対象ウィンドウにフォーカスがある。**compositor 層が丸ごと不要になる** —— `swaymsg` も mako 設定も kitty remote control も要らない。

副次効果として、pull 型は誤検知に強い。押した時だけ一覧を見るので、余計な 1 行が混ざっても作業は中断されない。push 型（通知）で同じことが起きると割り込みそのものが害になる。

## 検証で確定した事実（2026-07-29 実測）

実装前に確かめた内容。推論ではなく実行結果である。

### `herdr agent focus <pane_id>` は ID 指定でフォーカスを動かす

`pane focus` は `--direction` 必須で ID 指定できないが、`agent focus` は単一 positional を取り、実際に移動する。

```
A) pane split --no-focus 直後   : focused = w0:p1
B) pane focus --direction right : focused = w0:p4    ← 一度退かす
C) agent focus w0:p1            : focused = w0:p1    ← ID 指定で戻った
```

### `agent focus` はエージェント登録済みペインしか受け付けない

素のシェルペインに対しては `{"error":{"code":"agent_not_found"}}`。`agent wait` と同じゲート。飛び先はエージェントに限られる。

このときの終了コードは **1**。`herdr` はエラーを JSON で出しつつ非ゼロで終わるので、エラー判定に `.error` を JSON パースする必要はなく `if ! herdr ...` で足りる。

### `pane current` はフォーカス位置を返さない

`pane current` が返すのは「その CLI 呼び出しが走っているペイン」であって、フォーカスされているペインではない。フォーカスの観測には **`pane list` の各要素の `focused` フラグ**を使うこと。

（既存 memory の「split 後に `pane current` を叩くと base ペインが返る」という記録は、結論は正しいが理由の帰属が誤っていた。原因は split の挙動ではなくこの仕様。）

### `agent_status` は信用できない。`agent explain` は正しい

同一ペインについて両者が食い違う。

```
agent list    →  agent_status: "blocked"
agent explain →  state: working
                 rule: osc_title_working (region=osc_title priority=1100)
                 evidence: "⠐ Herdrプラグインでvibe island機能を実現"
```

検出エンジン自体は OSC タイトルのスピナー字を根拠に正しく `working` と判定している。壊れているのは API が露出する `agent_status` 側。既知の誤検知（memory 2026-07-25）は判定ミスではなく**判定結果が status フィールドに反映されない不整合**である。upstream 報告の候補。

### `terminal_title` がタスク見出しをそのまま持っている

`terminal_title` = `"⠐ Herdrプラグインでvibe island機能を実現"`、`terminal_title_stripped` = スピナー字を除いた版。**`pane.report_metadata` を一切書かずに「この子は今なにをしているか」が取れる。**

表示には必ず `terminal_title_stripped` を使う。生の `terminal_title` はスピナー字が毎フレーム変わるため表示がちらつく。

### 環境変数

キーバインド起動のコマンドには以下が注入される（file-picker 実装で確認）。

| 変数 | 内容 |
|---|---|
| `HERDR_ENV` | Herdr セッション内なら `1` |
| `HERDR_ACTIVE_PANE_ID` | 呼び出し元ペイン（＝自分） |
| `HERDR_ACTIVE_PANE_CWD` | 同 cwd |
| `HERDR_SELF_PANE` | popup 自身のペイン ID |

`HERDR_ACTIVE_PANE_ID` は通常のシェルには注入されない（キーバインド起動時のみ）。

## 構造

プラグイン機構は使わない。config 4 行 + スクリプト 1 本。

```
config.toml:  [[keys.command]] key="alt+j" type="pane" command="herdr-jump.sh"
                       │
                       ▼   popup ペインが開き、env が注入される
                 herdr-jump.sh
                       │  ① herdr agent list        全エージェント＋状態＋タイトル
                       │  ② jq                      整形・並べ替え・自ペイン除外
                       │  ③ fzf                     選択
                       │  ④ herdr agent focus <pane_id>
                       ▼
                 trap EXIT → herdr pane close "$HERDR_SELF_PANE"
```

`herdr-file-picker.sh` と同じ骨格に揃える。`#!/bin/bash` / `set -euo pipefail` / `HERDR_ENV` ガード / trap 自己クローズ / fzf `--reverse` / 日本語コメント。

配置は既存の慣習に従う。

```
~/project/herdr-jump/herdr-jump.sh
~/.local/bin/herdr-jump.sh -> 上記へのシンボリックリンク
```

依存: `herdr` 0.7.5+、`jq`、`fzf`（いずれも導入済みを確認）。

キーは `alt+j` を暫定とする。既存割り当て（`ctrl+f` = file picker、`alt+g` = lazygit）とは衝突しないが、Herdr 組み込みキーとの衝突は実装時に確認する。

### なぜプラグインにしないか

Herdr のプラグイン機構（`herdr-plugin.toml` の `[[panes]] placement = "popup"`）でも同じことはできるが、増えるのは配布性と `plugin pane` のライフサイクル管理だけで、解こうとしている問題には効かない。

スクリプト本体は将来プラグイン化する際にそのまま流用できる（popup の中で走るコマンドが同じ）。捨てるのは manifest 数行のみ。したがって先に最小形で運用し、必要性が実測で出てから移行する。

## 表示仕様

### 絞り込まない。並べ替えるだけ

**この設計で最も重要な判断。**

`agent_status` が信用できない以上、`blocked` でフィルタすると**本当に用のある子を隠す**危険がある。隠すのは致命的、余分に 1 行並ぶのは無害。この非対称性から、絞らずに順番だけ変える。

### 並び順

1. 要対応（`blocked` / `done`）
2. `working`
3. `idle` / `unknown`

同グループ内は `state_change_seq` の降順（直近で状態が変わった順）。

### 行フォーマット

```
● claude  w0:t1  Herdrプラグインでvibe island機能を実現
◍ codex   w1:t2  レビュー待ち
◐ claude  w1:t3  ovba-writer の CP932 まわり
○ claude  w1:t4  (idle)
```

列は 状態アイコン / `agent` / `tab_id` / `terminal_title_stripped`。

`tab_id` は `"w0:t1"` の形で workspace prefix を既に含む（実測確認済み）。`workspace_id` と連結すると `w0:w0:t1` になるので連結しない。

状態アイコンの対応は以下で固定する。

| `agent_status` | アイコン | 並び順グループ |
|---|---|---|
| `blocked` | `●` | 1（要対応） |
| `done` | `◍` | 1（要対応） |
| `working` | `◐` | 2 |
| `idle` | `○` | 3 |
| `unknown` / 上記以外 | `·` | 3 |

`terminal_title_stripped` が空の場合は `(idle)` などの状態語をフォールバックとして出す。

自ペイン（`HERDR_ACTIVE_PANE_ID` と一致するもの）は一覧から除外する。

## エラー処理

### 横断的な制約：popup は失敗を飲み込む

`type = "pane"` の popup はスクリプト終了と同時に消えるため、**stderr に出した内容は目に映らない**。エラー処理の設計はほぼこの 1 点に集約される。

方針は二段構え。

| 区分 | 出口 |
|---|---|
| 想定内の中断（Esc / 対象なし） | 黙って閉じる。何も起きないのが正しい |
| 想定外の失敗（focus 失敗 / サーバ死亡） | `herdr notification show` で外へ出す |

`notification show` を使うのは、popup が消えた後も残る唯一の出口だからである。

### ケース一覧

| ケース | 挙動 |
|---|---|
| `HERDR_ENV != 1` | stderr にエラーを出して非ゼロ終了（Herdr 外からの誤実行） |
| `HERDR_ACTIVE_PANE_ID` 未設定 | 同上 |
| 自分以外のエージェントが 0 件 | notification で「他にエージェントはいません」→ 正常終了 |
| fzf を Esc でキャンセル | 何もせず終了。`\|\| true` で `pipefail` に殺されないようにする |
| `agent focus` が `agent_not_found` | 選択後に対象が消えた場合。notification で通知 |
| `herdr` コマンド自体の失敗 | `main` を包み、notification に流してから非ゼロ終了 |

## テスト

### 自動テスト：整形ロジックのみ

Herdr は実プロセスを要するため、テスト可能な範囲を切り出す。

```
入力: agent list の JSON（固定フィクスチャ）
出力: 表示行 + pane_id のタブ区切り
```

純関数なので固定入力で回せる。`tests/` に置く（file-picker と同じ構成）。

用意するフィクスチャ:

- 状態混在（blocked / working / idle が並ぶ）
- 自ペイン除外が効いているか
- 日本語タイトル（幅計算の崩れ）
- `terminal_title_stripped` が空
- エージェント 1 件のみ（自分を除くと 0 件になるケース）
- エージェント 0 件

### 手動検証：実機

判定材料には**フォーカスが動いた時にしか真にならないもの**を使う。`pane list` の `focused` フラグがそれに当たる。目視だけでは「popup が閉じてスッキリしただけ」と区別がつかない。

1. 2 ペインでエージェントを起動 → `alt+j` → 相手を選ぶ → `focused` が移動しているか（＋目視）
2. **popup close がフォーカスを引き戻さないか**
3. Esc で何も起きないか
4. 対象ペインを閉じてから `alt+j` → 一覧に出ないか

## 未検証のリスクと実装の一手目

**popup を閉じる際に Herdr が呼び出し元ペインへフォーカスを戻す可能性がある。** もし戻すなら `agent focus` の直後に trap がそれを打ち消し、「飛ばない」という現状と同じ症状になる。

これは設計の成否を分けるので、**実装の一手目をこの検証に充てる**。上記テスト項目 2 を最小スクリプトで単独に確かめてから本体を書く。

黒だった場合の回避策候補（実測してから選ぶ）:

- フォーカス処理を popup 終了後まで生き残る子プロセスへ逃がす
- `type` を変えて popup を使わない形にする
- `~/project/herdr/` にある Herdr 本体のソースを読み、フォーカス復帰の条件を確定させる

## スコープ外

以下は意図的に作らない。

- **常駐デーモン（`events.subscribe` による状態履歴）** — 「何分前から詰まっているか」「順番待ち」は複数エージェントが同時に詰まる状況で効くが、現状その必要性シグナルが出ていない
- **アクション付き通知の自前発行** — pull 型で解けるなら push 型の作り込みは不要
- **Agents サイドバーへの情報追加（`pane.report_metadata`）** — 表示密度は優先度最下位であり、必要な情報は `terminal_title_stripped` で既に取れている
- **許可プロンプトのインライン承認** — Herdr から許可内容（対象ファイル・差分）を取得する経路がなく、Claude Code 側の `PreToolUse` フック自作が必要になる。別プロジェクト
