# herdr-jump 実装時の調査記録

実装中に立てた仮説を実測でどう潰したかの記録。結論は
[spec 第 11 節](../specs/2026-07-30-herdr-agent-status-design.md) に移してあるので、
ここに残すのは**過程**（何を試して何が外れたか）。同じ壁に当たったときの再調査を省くため。

元は SDD の進捗 ledger。作業ディレクトリは締めのときに消したので、こちらが正本。

---

# SDD ledger — plan: docs/superpowers/plans/2026-07-30-herdr-agent-status.md

branch: feat/agent-status (main から分岐。remote 無しのローカルリポジトリ)
実装はコントローラが行う。この環境ではサブエージェントが読み取り専用のため、
サブエージェントはレビューにのみ用いる。

## Pre-flight scan

plan 内で見つけた2件。いずれも機能を変えない範囲で実装時に是正する。

1. `install.sh` の `wire_claude_settings` と `wire_codex_hooks` が jq フィルタを
   完全重複させている。review rubric の "verbatim duplication of a logic block" に
   当たるため、共通関数 `wire_hook_events <file>` に切り出す。plan の意図
   （4イベントを両方へ配線）は保たれる。
2. `tests/run.sh` は `for t in "$here"/test_*.sh` に nullglob が無いため、
   テストが0件のときリテラル `test_*.sh` を bash に渡して誤爆する。
   plan の Task 1 Step 2 は「0件でも通る」ことを期待しているが実際は落ちる。
   Task 1 で `run.sh` に nullglob を足して是正する。

## 実機検証で判明した重大事項（spec の前提が2つ崩れた）

### 1. herdr 0.7.5 の CLI は `--source` に値を渡せない（**設計変更が必要**）

`herdr pane report-metadata --help` は `Usage: ... [OPTIONS] --source <ID> <PANE_ID>` と
書いているが、実装が対応していない。13 パターン試した結果:

| 形式 | 結果 |
|---|---|
| `--source hj` | `unknown option: hj` |
| `--source=hj` | 認識されず → `missing required --source` |
| `--source 1`（数値） | `unknown option: 1` |
| 位置引数 `w0:p1` | `unknown option: w0:p1`（常に拒否） |
| `-- w0:p1` | `unknown option: --` |
| `--token reason=X` | **通る**（スペース形式） |
| `--seq T` | **通る**（`--seq=T` は拒否） |

rtk バイパス・`env -i` の最小環境でも同じ。環境要因ではない。
`--token` と `--seq` はスペース形式で通るので、`--source` 固有の不具合。

**socket API 直叩きなら動く**（実測で `{"result":{"type":"ok"}}`）:

```
method: pane.report_metadata
params 必須: pane_id, source
params 任意: tokens(object) / seq(int) / ttl_ms(int) / agent / title /
             display_agent / state_labels / applies_to_source /
             clear_title / clear_display_agent / clear_state_labels
socket: $HERDR_SOCKET_PATH (= ~/.config/herdr/herdr.sock)
```

- **クリアは `tokens: {reason: null}`**（実測: snapshot の `tokens` が `null` になる）。
  `clear_token` に相当するパラメータは RPC に無い
- トークンの格納先は `snapshot.panes[].tokens.<name>` と `snapshot.agents[].tokens.<name>`。
  `herdr api snapshot` で検証できる
- herdr 公式フック `herdr-agent-state.sh` も CLI を使わず socket 直叩き（python3）。
  つまりこれが herdr の想定経路
- 送信手段の候補: `python3`（公式フックと同じ・Arch 標準）/ `nc -U -N`（実測で動作）

→ **Global Constraints「依存は jq と herdr CLI のみ」が維持できない。** kay の判断待ち。

### 2. カスタムトークンは `$` 接頭辞が必須（**修正済み**）

```
invalid ui config: unknown sidebar token `reason`;
custom tokens must start with `$` ; keeping current ui settings
```

`token = "reason"` ではなく `token = "$reason"`。**しかも失敗すると `[ui]` 設定が
丸ごと拒否される**（"keeping current ui settings"）ので、他の行も一切効かなくなる。
built-in セグメント（`state_icon` など）は `$` 無し。
修正後 `herdr server reload-config` が `status: applied` を返すことを確認。

### 3. その他の実機所見

- 設定リロードは `herdr server reload-config`（`herdr config reload` は存在しない）
- kay の config.toml に v1 の `command = "herdr-jump.sh"` キーバインドが残っている。
  Task 1 でファイルを消したので壊れている。install.sh は警告のみ出す（消すのは越権）
- ccstatus への挿入位置は `crmux` 行の直後ではなく `input=$(cat)` の直後になった。
  awk は行ごとに全ルールを評価するので先に現れる方が勝つ。機能は同じで、
  crmux 行が無い環境でも同位置に入るのでこちらの方が安定。コメントを実態に合わせた

## 進捗

- Task 1: complete (commits 85cae3f..354eb07, review clean)
  - nullglob 追加は brief 範囲内の必須修正とレビューで判定
- Task 2: complete (commits 354eb07..e77320c, review clean, minor 3 件 deferred)
  - `label` が jq の予約語だったため関数名を `heading` に変更（レビューで妥当と判定）
  - Task 2: minor (deferred): `tool_input` が truthy かつ非 object のとき jq が exit 5。
    実測で確認済み（`Cannot index string with string`）。Task 3 の `2>/dev/null` +
    空チェックで握り潰されるので、フィルタ側は変えずテストで固定する
  - Task 2: minor (deferred): `tool_name` 欠落時の reason が `?` の 1 文字になる
  - Task 2: minor (deferred): `file_path` が `/` 終わりだと見出しのみになる（実測: `Edit`。クラッシュはしない）
  - ⚠️ 解決済み: 「型不正で exit 0 が保たれるか」は Task 3 の層で担保。テスト追加で固定する
- Task 3: 実装完了 (e77320c..5f28d28)、テスト 13/13 pass、レビュー中
- Task 4: 実装完了 (5f28d28..a608bf3)、テスト 12/12 pass
- Task 5: 実装完了 (a608bf3..b0fad41)、テスト 12/12 pass
  - TSV 分解を `IFS=$'\t' read` に変更。パラメータ展開ではタブ非マッチ時に
    limits が ctx と同じ値に汚染される
  - Task 4 と 5 はフィルタと呼び出し側の対なので 1 パッケージでレビューする
- Task 3: complete (commits e77320c..5f28d28, review clean, minor 2 件 deferred)
  - Task 3: minor (deferred): herdr CLI がハングした場合の timeout が無い。
    ただし settings.json のエントリに `timeout: 5` を入れるので Claude Code 側が切る。
    usage 側は `&` 起動なので ccstatus をブロックしない
  - Task 3: minor (deferred): herdr 不在 / jq 不在の経路が未テスト
  - ⚠️ 未解決 → Task 7 で確認: symlink 経由で呼ばれると `dirname "${BASH_SOURCE[0]}"` が
    リンクの置き場所を指す。install.sh が実体の絶対パスで配線すれば問題にならない
- 型不正ケースのテストを追加 (a3d0ce8)。Task 2/3 のレビュー指摘への対処。
  フィルタは変えず、フックの層で握り潰されることを固定
- Task 6: 実装完了 (a3d0ce8..5bd171e)、TOML パース検証済み
  - **計画からの逸脱**: `agent_panel_sort` をブロックから外した。実測で判明:
    ブロック内 `[ui]` は既存 `[ui]` と衝突して TOML エラー、
    `ui.agent_panel_sort = "..."` は直前テーブル内のキーと解釈され
    `ui.ui.agent_panel_sort` になる（**パースは通るのでサイレント失敗**）。
    install.sh が既存 `[ui]` へ挿入する形に変更。3経路の可否を実測済み:
    既存 `[ui]` 直後への挿入 OK / `[ui.sidebar.agents]` の後に `[ui]` を
    後付け定義するのも OK
  - **後で判明**: `token = "$reason"` と `$` を付けないと `[ui]` 設定が丸ごと拒否される。
    修正済み（未 commit）
- Task 4+5: complete (commits 5f28d28..b0fad41, review Approved)
  - fix round 1 (ff9063c..f810368): 偽 herdr の `"$*"` が word splitting を隠す
    Important 指摘に対処。`"$@"` の 1 引数 1 行記録を追加し、mutation で有効性を確認。
    re-review → ADDRESSED / 新規 breakage なし
  - Task 4: minor (deferred): `context_window_size` が負値・文字列のときの型ガードが無い
  - Task 4: minor (deferred): 逸脱 1 の理由づけが過大だった。`@tsv` は常にタブを出すので
    パラメータ展開でも実害は無かった。`IFS=read` への変更自体は安全なので残す
- Task 7: 実装完了 (5bd171e..ff9063c)、テスト 21/21、レビュー Approved だが **Important 4 件**
  1. `STAMP` が秒精度なので同一秒内の再実行でバックアップを上書きする
  2. `wire_ccstatus` はマーカー行が無い ccstatus に何も挿入せず、それでも `ok:` を出す
  3. `mktemp` の一時ファイルが変換失敗時にリークする（trap も rm も無い）
  4. 「[ui] 無し」経路は run1→run2 でレイアウトが変わる（run2 以降は不動点）。
     テストは run1 vs run2 の完全比較をしていない
- 本番へのインストールは実施済み（バックアップ + 事前退避あり）。2 回実行で重複ゼロを実機確認
- socket 移行 + Task 7 Important 4 件対処 (d22a177..2048b55)、テスト 89/89 pass
  - kay の判断で送信手段は python3（`nc -U -N` も動作確認済みだが公式フックと同経路を選ぶ）
  - Task 7 Important 4 件すべて対処済み: STAMP にミリ秒 / wire_ccstatus の警告 /
    trap で一時ファイル片付け / [ui] 無し経路の不動点テスト
  - テストは偽 herdr → 偽 socket サーバに置換。JSON 検証なのでクォート漏れの
    失敗モードが構造的に消え、fix round 1 の word splitting 検出は不要になった
- Task 8: README / spec を実態に更新。spec は第 11 節「実装時に判明して設計を変えた点」
  として追記（本文を上書きする旨を明記）
- kay が config.toml の v1 キーバインド (L34-38) を削除。install.sh の警告も消えた

## 実機で確認できたこと

```
tokens = {"ctx": "32%", "limits": "5h 4% | 7d 13%",
          "reason": "Bash: 実機テスト: node_modules を削除"}
```

- reason はフック経由、ctx/limits は statusLine 経由で届く（本物の値）
- clear で reason だけ消え、usage は残る（設計の意図通り）
- ~~install.sh を繰り返しても一時ファイルが増えない（trap が効いている）~~
  → **誤記録。** 最終レビューの実測で trap は機能していなかった。`tmp="$(mktmp)"` の
  コマンド置換がサブシェルなので配列追記が親に伝わらず、cleanup は常に空配列を見ていた。
  happy path では mv するのでゴミが残らず、この確認をすり抜けた。db4ebf7 で
  作業ディレクトリ方式に修正し、挿入位置の無い ccstatus で 3 回実行しても
  増えないことを実測
- `herdr server reload-config` が `status: applied` を返す

## 実機スクリーンショットで確認（4 行すべて表示）

```
✓ ~ · 1
  claude · Opus 5 (1M context)
  idle
  39% · 5h 12% | 7d 14%
✓ ~ · 3
  codex
  idle
```

- 4 行とも表示され、行数の上限には当たっていない
- `agent_panel_sort = "priority"` も効いている（パネル右上に `priority`）
- セグメント区切りは herdr が `·` を自動で入れる
- codex は model/ctx/limits が入らないので 3 行（statusLine が無い）
- **`Stop` フックは現セッションで既に効いている。** settings.json は「次セッションから」
  と思っていたが、install.sh 実行後のターン終了時に reason がクリアされていた。
  「reason が消える」を 3 回故障として追いかけたが仕様通りの動作だった

## 未検証

- **`$reason` の実地表示**。止まっている最中しか値が入らないので、許可プロンプトか
  `AskUserQuestion` で実際に止まる必要がある。フック本体を手で叩く検証は済み
  （snapshot に値が入る）
- **auto mode では許可プロンプトがほぼ出ない**（スクリーンショットに `auto mode on`）。
  常用環境で実際に効くのは `AskUserQuestion` の経路。`PermissionRequest` の出番は少ない
- **拒否時に `PostToolBatch` が発火するか**（`Stop` が保険なのでどちらでも消える）
- **Codex 側**（承認プロンプトを 1 回通す必要がある）
- 40 文字がパネル幅に対して適切か

