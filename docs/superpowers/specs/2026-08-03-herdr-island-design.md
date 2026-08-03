# herdr-island — 設計

- 日付: 2026-08-03
- ステータス: 承認済み
- 前 spec: [2026-07-30-herdr-agent-status-design.md](2026-07-30-herdr-agent-status-design.md)
- 本 spec は前 spec の成果物を **herdr プラグインとして再構成し、公開する**ための設計。
  前 spec に記載された herdr の挙動のうち、第7節に挙げたものは実測により**訂正**される。

## 1. 背景

前 spec で Agents パネルに「停止理由」「context 使用率」「モデル名」を出す機能を作り、
`install.sh` による手動配置で運用してきた。その後、herdr 0.7.5 にプラグイン機構が
あることが判明したため、配布形態をプラグインへ移し、あわせて公開する。

### 1.1 プラグイン機構の存在

`herdr --help` のサブコマンド一覧に `plugin` は**載っていない**が、`herdr plugin --help`
を直接叩くと全機能が存在する（`install` / `uninstall` / `link` / `unlink` / `enable` /
`disable` / `list` / `config-dir` / `action` / `log` / `pane`）。前 spec の時点で
「herdr 側の管轄で拡張できない」と判断していたら、これも誤りだったことになる。
**help の一覧に無いことを機能の不在の根拠にしない。**

### 1.2 先行プラグインの調査

GitHub topic `herdr-plugin` に 471 リポジトリ（2026-08-03 時点）。Agents パネル周辺は
既に混雑しており、本プロジェクトの3機能のうち2つは先行実装がある。

| 機能 | 先行 | 判定 |
|---|---|---|
| context 使用率・モデル名 | `senna-lang/herdr-agent-usage`（id `usagebar`） | 重複。譲る |
| Space による絞り込み | `ShankyJS/herdr-space-scoped-agents` | 重複 |
| **停止理由** | 該当なし | **空いている** |

停止理由だけが空いているのは参入コストの差による。使用率は herdr の snapshot から
取れるが、停止理由は **Claude / Codex の hook に入り込んで `AskUserQuestion` や
`PermissionRequest` の payload を捕まえないと取得できない**。

「使用率」は見て回る情報だが、「停止理由」は**操作を待っているというシグナル**であり、
絞り込みの対象としての価値が異なる。よって本 spec は看板を
**「待たせているエージェントを見つける」** に置く。

## 2. スコープ

**含む**

- 停止理由（`$reason`）の収集・表示・**それによる絞り込み**
- herdr プラグインとしてのパッケージング（`herdr-plugin.toml`、`plugin install` 対応）
- `senna-lang/herdr-agent-usage` との**共存**
- 公開（GitHub topic `herdr-plugin`、marketplace 掲載）

**含まない**

- context 使用率 / モデル名 / rate limit の表示 — `usagebar` に譲る。
  既存の `$ctx` / `$limits` / `$model` は本プラグインから**削除**する
- Approve / Ask（許可要求・質問への応答 UI）— 前 spec の判断を維持。
  該当ペインへ飛べば本物の UI で応答できるため、中間 UI を挟む必然性が無い
- fzf によるペイン切り替え — herdr 内蔵機能と重複（v1 で撤去済み）

### 2.1 名前

- リポジトリ: `herdr-island`（topic `herdr-plugin` 内に `island` 系の衝突なし）
- プラグイン id: `island`（bare id は許容される。`usagebar` が前例）
- 表記は全小文字。調査した 471 件に大文字を含む id は無い
- 名前は [Vibe Island](https://vibeisland.app/) に由来する。README に出典を1行記載する。
  前 spec が同種ツールの機能分解に用いた参照であり、隠す理由が無い

## 3. 共存の契約

### 3.1 トークンは衝突しない

| | 本プラグイン | `usagebar` |
|---|---|---|
| トークン | `$reason` | `$title` `$provider` `$limit` `$context` |

第2節で使用率系を落とすため、意味的な重複（`$ctx`↔`$context`、`$limits`↔`$limit`）も
消える。

### 3.2 真の非互換は `rows_by_agent` にある

`ui.sidebar.agents.rows_by_agent` は設定リファレンス上
**"Complete Agent-row overrides"** と定義される。あるエージェント id に対して
`rows_by_agent` を書くと、そのエージェントには `ui.sidebar.agents.rows` が
**一切参照されなくなる**。

現行の herdr-jump は `rows_by_agent` に `claude` / `codex` を書いている。一方
`usagebar` の README はユーザに `rows` を編集させる。両方入れると:

1. ユーザが `usagebar` の指示どおり `rows` に `$context` `$limit` を入れる
2. 本プラグインが `rows_by_agent.claude` を書く
3. **Claude ペインからのみ `usagebar` の表示が消える**

`usagebar` は正常に動作しトークンも送っており、表示されないだけ。エラーも警告も出ない。
ユーザからは「`usagebar` が Claude で壊れた」に見え、原因が本プラグインにあると
気づく手がかりが無い。

### 3.3 設計原則

**原則1: `rows_by_agent` を書かない。`rows` に1行だけ足す。**
所有するトークンは `$reason` のみ。追加する行は次の1行で足りる。

```toml
[{ token = "$reason", fg = "#f38ba8", bold = true }]
```

`fg` の既定値は `#f38ba8`（現行実装の Claude 側と同じ）。`HERDR_PLUGIN_CONFIG_DIR` の
設定で変更できる。

**所有行の同定規則** — `apply` は「自分が書き込むはずの行」と**完全一致**する行が
既にあれば何もしない。`revert` は**完全一致する行のみ**を削除する。利用者が色や
`bold` を手で変えた行、あるいは `$reason` を他のトークンと同じ行に置いた場合は、
それは利用者の所有物とみなして**削除せず、その旨を報告する**。
`$reason` を含むことだけを根拠に削除しない。

**原則2: 書き込みは行単位のマージとし、テーブル単位の置換をしない。**
既存の `rows` を読み、`$reason` を含む行が無ければ末尾に足す。マーカーブロックで
`[ui.sidebar.agents]` ごと囲う方式は**採らない** — 他人の行を巻き込み、既存の `[ui]`
との二重定義（現行 `install.sh` が踏んでいる問題）も再発する。可逆性はマーカーではなく
「足した1行を同定して消す」で担保する。

**原則3: 表示ではなく絞り込みを主機能に置く。**
`agent.view.set` は `config.toml` を一切触らない。「待たせているエージェントだけ表示」は
**書き込みゼロで動く**。`rows` への行追加は「理由の本文も読みたい人向けの追加ステップ」に
格下げする。侵襲的な操作が主導線から外れる。

結果として役割が分かれる — `usagebar` が「どれだけ使ったか」、本プラグインが
「どれが待っているか」。

## 4. 構成要素

### 4.1 マニフェスト

エントリポイントの構成を示す**概略**であり、そのままの TOML ではない
（`[[panes]]` は実際には id ごとに別テーブルとして書く）。

```toml
id = "island"
name = "Island"
version = "1.0.0"
min_herdr_version = "0.7.5"
platforms = ["linux", "macos"]

[[panes]]      # 対話確認つき導入・撤去（popup は端末入力を全て受ける）
id = "setup"   / "remove"     placement = "popup"

[[actions]]    # 非対話。確認を出さない
id = "focus"   / "unfocus"    # view の適用・解除
id = "apply"   / "revert"     # config への行追加・除去（スクリプト用）
id = "doctor"                 # 診断

[[events]]
on = "pane.agent_status_changed"   # 理由のクリア

[[startup]]                        # 保存した view の再適用
```

`min_herdr_version` は 0.7.5。本 spec の全ての挙動は 0.7.5 で実測した。それより古い
バージョンでの `agent.view.set` の可用性は確認していないため、下限を下げない。

### 4.2 対話は popup、action は非対話

実測（`sh` で `test -t` を各 fd に対して実行）:

```
fd0=notty  fd1=notty  fd2=notty  TERM=xterm-kitty
```

**action に TTY は無い。** `TERM` は継承されるため、`TERM` の有無で端末を判定する実装は
**判定を通過するのに入力が読めない**という壊れ方をする。判定は `isatty`（`test -t 0`）で行う。

action の stdout は JSON にエスケープされて `herdr plugin log list` に記録される
（`"stdout":"fd0=notty\nfd1=notty\n..."`）。したがって
**「設定ブロックを表示するので手でコピーしてほしい」という導線は成立しない。**

対話確認は `[[panes]]` の `placement = "popup"` で行う。popup は Escape を含む端末入力を
全て受け取り、コマンド終了で閉じる。

### 4.3 データフロー — 理由の set と clear を分離する

現行は set も clear も agent CLI 側の hook が担い、clear 経路が3つある
（`PostToolBatch` / `Stop` / TTL 15分）。このため手動で送った理由が即座に消え、
目視確認ができない（過去に3回、故障と誤診している）。

役割で分ける:

| | 担当 | 根拠 |
|---|---|---|
| 理由を**立てる** | agent CLI 側の hook | 質問文は Claude / Codex の payload 内にしか無く、herdr からは見えない |
| 理由を**消す** | herdr の `pane.agent_status_changed` イベント | blocked を抜けたことは herdr が知っている |

効果:

- 他人の `settings.json` に入れる hook が **set の1本だけ**になる。公開物としての侵襲性が下がる
- clear が1経路に集約され、目視確認が可能になる
- Codex 側も同じイベントで消えるため、エージェントごとに clear を実装しなくてよい

### 4.4 依存

| 経路 | 手段 | 頻度 |
|---|---|---|
| 理由の push / clear | `herdr` CLI（`pane report-metadata`） | 高（hook のホットパス） |
| 理由の抽出 | `jq` | 高 |
| `agent.view.set` | socket 直叩き（python3） | 低（起動時・明示アクション時のみ） |

`agent.view.set` には CLI ラッパが存在しない（`herdr agent` は list/get/read/… のみ、
`herdr api` は snapshot/schema のみ）ため、socket 直叩きはここだけ残る。

現行の `lib/herdr-send.py` は「`report-metadata` CLI が壊れている」という前提で作られたが、
その前提は第7節のとおり誤りだったため、**ホットパスから python3 が消える**
（ツール呼び出しごとのインタプリタ起動コストが無くなる）。

### 4.5 状態

- `HERDR_PLUGIN_STATE_DIR` — 適用中の view クエリ。view は揮発性で、サーバ終了・
  プラグインの無効化 / unlink / uninstall・別 source による置換で消える。
  `[[startup]]` で読み直して再適用する（herdr 公式ドキュメントが示す作法）
- `HERDR_PLUGIN_CONFIG_DIR` — ユーザ設定（`$reason` の表示色、対象エージェント）
- `HERDR_PLUGIN_ROOT` には状態を置かない（GitHub 経由の install では管理下の
  チェックアウトであり、再インストールで置き換わる）

### 4.6 絞り込みクエリ

`agent.view.set` の filter は `{"token":"name"}` をフィールドに取れる。すなわち
**本プラグインが報告したトークンをそのまま絞り込み条件にできる**。

```json
{
  "method": "agent.view.set",
  "params": {
    "source": "plugin:island",
    "label": "waiting",
    "filter": { "op": "exists", "field": {"token": "reason"} },
    "sort": [
      {"field": "attention", "order": "desc"},
      {"field": "state_change_seq", "order": "desc"}
    ]
  }
}
```

`sort` を省略した場合は既存の `ui.agent_panel_sort` ポリシーが維持される。
指定した場合は **config を書き換えずに**一時的に置換される。これは
`agent_panel_sort` を config に書く際の既知の罠（`[ui]` テーブルのキーであるため
末尾追記ブロックに書くと `ui.ui.agent_panel_sort` に化け、パースは通るので気づけない）を
構造的に回避する。

解除は `agent.view.clear` を `source` 指定付きで行う（他者が所有権を奪っている場合に
横取りしない）。

## 5. エラー処理

### 5.1 config は「検証してから置く」

`HERDR_CONFIG_PATH` は `herdr config check` に効く。よって候補ファイルを一時領域で
検証してから本番に置ける。ロールバックより強い保証になる。

1. 現在の `config.toml` を読む。`$reason` の行が既にあれば**何もしない**（冪等）
2. 無ければ1行足した候補を一時ファイルに書く
3. `HERDR_CONFIG_PATH=<候補> herdr config check` を実行。**exit≠0 なら本番に触れずに中止**し、
   herdr の診断出力をそのまま popup に表示する
4. 通ったらタイムスタンプ付きバックアップを取得してから置き換え、
   `herdr server reload-config` を実行する

`herdr server restart` は使わない（herdr のペイン内から叩くと自分ごと落ちる）。

検証の実測（不正な config に対して exit=1 が返ることを確認済み）:

```
$ HERDR_CONFIG_PATH=bad.toml herdr config check ; echo $?
config: issues found
config parse error: TOML parse error at line 2, column 38
  |
2 | rows = [["state_icon", "workspace"], ["reason"]]
  |                                      ^^^^^^^^^^
1
```

なお `$` を付けないカスタムトークンは、実行時に `[ui]` 設定が丸ごと破棄される
（`custom tokens must start with $` / `keeping current ui settings`）。上記のとおり
`config check` が事前に捕捉する。

### 5.2 旧 herdr-jump からの移行を検出する

`setup` は最初に `rows_by_agent` の存在を検査する。見つかった場合、第3.2節の
complete override により**新しい `rows` が該当エージェントに効かない**ため、popup で
撤去の可否を問う。

この検査は自環境の旧ブロックだけでなく、他人が手書きした `rows_by_agent` にも効く。
**「動いているのに表示されない」を設計時に潰す**ことが目的。

### 5.3 その他

- socket 不在（サーバ未起動）— hook 側は静かに諦める。エージェントの動作を止めない
- `agent.view.set` はプラグインが missing / disabled のとき herdr 側が拒否する。
  本プラグインは失敗を報告するのみ
- `settings.json` への hook 追加も同じ手順（候補作成 → JSON パース確認 → バックアップ → 置換）
- `report-metadata` は成功時に無出力で exit=0 を返す。反映確認は
  `herdr api snapshot` の `.result.snapshot.agents[].tokens` で行う。
  **`panes[].tokens` を見て判断しない** — UI が読むのは `agents[]` 側

## 6. テスト

現行 123 本を土台とするが、本数の維持は目標にしない。使用率・モデル名・rate limit の
テスト（`test_usage_filter.sh` / `test_usage_push.sh` / `test_codex_usage_hook.sh` 系）は
対象機能ごと**削除**する。移植ではなくスコープ縮小であるため、テスト本数のパリティは
成立しない。

set / clear が CLI 経由に変わるため、PATH に偽 `herdr` を置いて argv を記録する方式を
追加する。`tests/fake_socket.sh` は `agent.view.set` の検証に引き続き使う。

必須のテスト:

- **引数順序の回帰** — `report-metadata` は PANE_ID をフラグより前に置かないと壊れる
  （第7.1節）。偽 `herdr` が受け取った argv をそのまま検証する
- **config の往復** — 適用 → `revert` → **元ファイルとバイト一致**。他人の行・コメント・
  空行を1文字も壊していないことの証明。「だいたい同じ」で通る判定にしない
- **検証ゲートの実出力** — 実際に壊れる config を食わせ、本物の `herdr config check` が
  exit=1 を返し、かつ**本番ファイルが変更されていない**ことを確認する。
  モックした戻り値では判定しない
- **`rows_by_agent` 影の検出** — 旧ブロックがある状態で警告が出ること
- **冪等性** — `apply` を2回実行しても行が増えないこと
- **共存** — `usagebar` の行（`$title` `$provider` `$limit` `$context`）を含む config に
  `apply` した後も、それらの行が保持されていること

## 7. 前 spec / notes の記述に対する訂正

前 spec および `docs/superpowers/notes/2026-07-30-*-investigation.md` の以下の記述は、
herdr 0.7.5 での実測により**現状に当てはまらない**。

### 7.1 `herdr pane report-metadata` CLI は使える

前 spec: 「`--source` に値を渡せないため socket 直叩きが正解」

実際は**引数の順序**が原因。位置引数の PANE_ID をフラグより**前**に置くと通る。

```
herdr pane report-metadata w0:p1 --source probe:cli --token probe=hello   # exit=0、反映される
herdr pane report-metadata --source probe:cli --token probe=hello w0:p1   # unknown option: probe:cli
```

`--help` の `Usage:` 行が `[OPTIONS] --source <ID> <PANE_ID>` と PANE_ID を最後に
書いているため、素直に従うと必ず踏む。

### 7.2 `--clear-token` は存在する

前 spec: 「RPC に `clear_token` 相当は無く、クリアは `tokens:{name:null}`」

0.7.5 の CLI には `--clear-token <NAME>` がある。`--seq` `--ttl-ms` も同様。

### 7.3 影響

7.1 と 7.2 により `lib/herdr-send.py` の存在理由が消える。ホットパスは CLI のみで
完結する。socket 直叩きが必要なのは `agent.view.set`（CLI ラッパ無し）だけになる。

## 8. 既存インストールの撤去（移行）

現行の `install.sh` に**アンインストール経路は存在しない**。撤去手順を書くこと自体が
本作業に含まれる。

### 8.1 書き込み先の棚卸し

`install.sh` は4箇所に書き込む。2026-08-03 時点で自環境の4箇所すべてに痕跡がある。

| 書き込み先 | 内容 | 新スコープでの扱い |
|---|---|---|
| `~/.claude/settings.json` | reason フック 4 イベント | **set の1本のみ残す**（4.3節。clear は herdr イベントへ） |
| `~/.config/herdr/config.toml` | 行テンプレートと `agent_panel_sort` | 置き換え（3.3節の原則に沿う形へ） |
| `~/.local/bin/ccstatus` | usage push の1行（`# herdr-jump` マーカー付き） | **不要になる**。使用率を落とすため |
| `~/.codex/hooks.json` | reason / model / context 使用率のフック | reason のみ残す |

`~/.local/bin/ccstatus` は**利用者自身の statusLine スクリプト**であり、本プロジェクトが
所有するファイルではない。使用率をスコープ外にした結果、他人のスクリプトへ注入する
連携点が丸ごと消える。公開物として説明の難しい箇所が1つ減る。

### 8.2 `config.toml` は2箇所に分かれている

撤去時に見落としやすいため明記する。

1. マーカーブロック `# >>> herdr-jump (managed) >>>` … `# <<< herdr-jump (managed) <<<`
   （`[ui.sidebar.agents]` と `[ui.sidebar.agents.rows_by_agent]` を含む）
2. **既存の `[ui]` セクション内に単独で挿入された行** — `agent_panel_sort = "priority"  # herdr-jump`

2 はブロックの外にある。これは `agent_panel_sort` が `[ui]` テーブルのキーであり、
末尾追記のブロック内に書くと `ui.ui.agent_panel_sort` に化けるため、`install.sh` が
意図的に別扱いにしたもの。**ブロックだけを消すと 2 が残る。**

新設計では並び順を `agent.view.set` の `sort` で扱う（4.6節）ため、2 は不要になる。
撤去は完全な除去であり、部分的な移行ではない。

### 8.3 手順

1. 撤去スクリプトを書き、上記4箇所すべてから痕跡を除去する。各ファイルは
   バックアップを取ってから編集する
2. 除去後に `herdr config check` が通ることを確認する
3. `grep -rE 'herdr-jump|herdr-usage-push'` を4箇所に対して実行し、**ゼロヒット**を確認する。
   マーカー名の照合だけを信じず、生の文字列で裏を取る
4. v1 の残骸に注意する。`install.sh` は「`config.toml` に `herdr-jump.sh` を参照する
   キーバインドが残っている」旨を警告する経路を持つ。該当があれば併せて除去する
5. その後に `herdr plugin link` で新プラグインを導入し、動作を確認する

撤去スクリプトは自環境専用の使い捨てにせず、**旧 herdr-jump 利用者向けの移行パスとして
リポジトリに残す**。公開時点で旧版の利用者は自分だけだが、5.2節の `rows_by_agent` 検出と
同じ問題を他人が手書き設定で踏みうるため、検出と撤去のロジックは共用する。

## 9. 公開

1. リポジトリを `herdr-island` にリネーム
2. de-personalize — docs / コメント / エラーメッセージ / README から個人環境固有の
   パス・ホスト名を除去する。公開ハンドルは `kay-ws`
3. README を英語で書く。Vibe Island への出典を1行入れる
4. LICENSE を置く
5. GitHub topic `herdr-plugin` を付与する。marketplace は次回の index 更新で自動的に拾う
   （申請・審査は無い）
6. `herdr plugin install kay-ws/herdr-island` で入ることを、リンク済みでない
   クリーンな状態から確認する
