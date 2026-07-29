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

キーバインド起動のコマンドには以下が注入される（herdr 0.7.5 で `env | grep ^HERDR` を実測）。

命名は **無印 = popup 自身 / `ACTIVE_` 付き = 呼び出し元** で、pane・tab・workspace の 3 階層すべてがこの対で揃っている。

| 変数 | 内容 | 実測値の例 |
|---|---|---|
| `HERDR_ENV` | Herdr セッション内なら `1` | `1` |
| `HERDR_PANE_ID` | popup 自身のペイン ID | `w0:pD` |
| `HERDR_TAB_ID` | popup 自身のタブ ID | `w0:t1` |
| `HERDR_WORKSPACE_ID` | popup 自身のワークスペース ID | `w0` |
| `HERDR_ACTIVE_PANE_ID` | 呼び出し元ペイン | `w0:p1` |
| `HERDR_ACTIVE_PANE_CWD` | 呼び出し元の cwd | `/home/kay` |
| `HERDR_ACTIVE_TAB_ID` | 呼び出し元のタブ ID | `w0:t1` |
| `HERDR_ACTIVE_WORKSPACE_ID` | 呼び出し元のワークスペース ID | `w0` |
| `HERDR_BIN_PATH` | herdr 実行ファイルの絶対パス | `/home/kay/.local/bin/herdr` |
| `HERDR_SOCKET_PATH` | herdr サーバの制御 socket | `~/.config/herdr/herdr.sock` |

`HERDR_ACTIVE_PANE_ID` は通常のシェルには注入されない（キーバインド起動時のみ）。

`HERDR_SELF_PANE` という変数は**存在しない**。当初 file-picker の記憶からそう書いていたが、実測では未定義だった。popup 自身を指すのは `HERDR_PANE_ID`。

`HERDR_SOCKET_PATH` があるため、popup から `setsid` で切り離した子プロセスも herdr CLI を叩き続けられる。popup の寿命を超えて動く処理を持たせる余地がある。

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
                 スクリプト終了 → herdr が popup ペインを自前で畳む
```

`herdr-file-picker.sh` と同じ骨格に揃える。`#!/bin/bash` / `set -euo pipefail` / `HERDR_ENV` ガード / fzf `--reverse` / 日本語コメント。

**自己クローズは書かない。** `type = "pane"` の popup は、起動したコマンドが終了した時点で herdr が閉じる（実測。`HERDR_PANE_ID` を参照しないプローブでも popup は消えた）。`trap EXIT → herdr pane close` を足すのは無駄であり、閉じる主体が二重になるぶん壊れやすい。

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

### 手動検証の結果（2026-07-30 実施）

キーバインドは `alt+j` に決めた。`herdr --default-config` の全 314 行に `alt+j` は無く、組込みの `alt+` 系は `alt+g` と `alt+n` のみだった。

観測は、フォーカスの変化点だけを 0.3 秒間隔で拾うウォッチャーを操作の前に切り離して起動した（Task 1 と同じ理由による）。記録:

```
  0s  focus: w0:p1     起点
 38s  focus: w0:pE     popup
 41s  focus: w0:p9     着地
 44s  focus: w0:p1     手動で復帰
 46s  focus: w0:pF     popup
 49s  focus: w0:p8     着地
 55s  focus: w0:p1     手動で復帰
 66s  focus: w0:pG     popup
 67s  focus: w0:p1     Esc
```

| # | 項目 | 結果 |
|---|---|---|
| 1 | 選んだペインへ着地する | 合格（41s / 49s） |
| 2 | popup close がフォーカスを引き戻さない | 合格。49s→55s の 6 秒間 `w0:p8` を維持 |
| 3 | Esc で何も起きない | 合格。`w0:p1` のまま、通知も出ない |
| 4 | 閉じたペインは一覧に出ない | 合格。`agent list` からも fzf 行からも消えた |
| 5 | 他にエージェントが居なければ通知 | 合格。「他にエージェントはいません」が出た |

fzf の表示は読める形で出て、アイコンと日本語タイトルの桁も崩れていなかった。

#5 は他のエージェントを全て閉じて実際にその状態を作った。`agent list` が自分 1 件だけ、整形結果が 0 行になることを確認した上で `alt+j` を押しており、`main` → `format_agents` → 0 件分岐 → `notify` の経路が実機で通っている。

この観測で分かった副産物を 3 つ記録しておく。

- **popup のペイン ID は毎回変わる**（`pE` → `pF` → `pG`）。popup は使い捨てのペインとして都度作られ都度破棄される。自己クローズを書かない判断はここでも裏付けられた。
- **popup ペイン自身がフォーカスを取る。** だから fzf がキー入力を受け取れる。フォーカスを取らない設計だったらこの方式は成立しなかった。
- **無フォーカスの瞬間が一度も観測されない。** popup 破棄と着地の間に隙間が無いので、入力が宙に浮く心配は要らない。

## 最大のリスクと、それを潰した実測（2026-07-30）

懸念は **popup を閉じる際に Herdr が呼び出し元ペインへフォーカスを戻すのではないか** という点だった。もし戻すなら `agent focus` の効果が打ち消され、「飛ばない」という現状と同じ症状になる。設計の成否を分けるため、実装の一手目をこの検証に充てた。

**結果は白。** `tests/probe_focus_retention.sh` を `alt+p` にバインドして実機で計測した。

| 時点 | フォーカス位置 |
|---|---|
| popup 起動直後 | `w0:pC`（popup 自身） |
| `agent focus w0:p8` 直後（popup はまだ開いている） | `w0:p8` |
| popup 消滅後 1〜5 秒（1 秒刻みで 5 回） | `w0:p8` のまま |

呼び出し元 `w0:p1` へ戻る挙動は観測されなかった。目視でも、押した本人が codex ペインに着地して手で戻る必要があった。

回避策の検討（子プロセスへの退避、`type` の変更、Herdr 本体のソース読解）はいずれも不要になった。

計測にあたっては 2 点はまった。どちらも観測手法の問題で、設計そのものとは無関係:

- **観測者を `agent focus` より後に起動すると死ぬ。** popup がフォーカスを失った時点で herdr がペインを畳むため、スクリプト末尾に置いた `setsid` に到達できない。観測者は状態を壊す操作より前に切り離す。
- **手で戻る操作が測定を汚す。** 押した本人が 5 秒以内に元ペインへ戻ると、自動観測と人間の操作が同じ状態を奪い合う。測定窓を明示的に空ける。

## スコープ外

以下は意図的に作らない。

- **常駐デーモン（`events.subscribe` による状態履歴）** — 「何分前から詰まっているか」「順番待ち」は複数エージェントが同時に詰まる状況で効くが、現状その必要性シグナルが出ていない
- **アクション付き通知の自前発行** — pull 型で解けるなら push 型の作り込みは不要
- **Agents サイドバーへの情報追加（`pane.report_metadata`）** — 表示密度は優先度最下位であり、必要な情報は `terminal_title_stripped` で既に取れている
- **許可プロンプトのインライン承認** — Herdr から許可内容（対象ファイル・差分）を取得する経路がなく、Claude Code 側の `PreToolUse` フック自作が必要になる。別プロジェクト
