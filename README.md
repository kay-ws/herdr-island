# herdr-jump

herdr の Agents パネルに「何で止まっているか」と context 使用率を表示する。

パネルを見れば用のあるエージェントが分かり、その行をクリックすればペインへ飛べる。
飛ぶ機能自体は herdr 0.7.5 の Agents パネルが内蔵しているので、こちらは**飛ぶ判断に
必要な情報をパネルへ流し込むこと**に徹する。

## 何が出るか

```
● ws0  tab1
  Bash: Remove node_modules        ← 何で止まっているか
  42%  5h 11% | 7d 3%              ← context 使用率と rate limits
```

| 行 | 出所 | 発火 |
|---|---|---|
| reason | `PermissionRequest` / `PreToolUse(AskUserQuestion)` フック | 止まった瞬間に1回 |
| ctx / limits | `ccstatus`（statusLine）の stdin JSON | 毎ターン |

止まり方は1種類ではない。許可待ち（`PermissionRequest`）と質問待ち
（`AskUserQuestion`）は別のイベントで届くので、両方を拾っている。

reason と usage は独立した2本の配管で、互いを知らない。**それが成り立つのは herdr が
`tokens` をキー単位でマージするから** —— 毎ターン走る usage push が `{ctx, limits}` を
送っても `reason` は残る（実測で確認済み）。置換方式なら usage push が reason を消し
続けて機能しないので、これは配管を分ける前提そのもの。

Codex では reason のみ（statusLine 相当の仕組みが無いため）。

reason は 40 文字で切る。切り捨ては jq の文字列スライスで行うので、日本語混じりでも
バイト境界を割らない。

## インストール

```bash
./install.sh
```

以下を冪等に書き換える。何度実行しても結果は同じで、既存のフックは潰さない。
書き換え前に `.bak.<timestamp>` を取る。

| ファイル | 何を足すか |
|---|---|
| `~/.claude/settings.json` | `PermissionRequest` / `PreToolUse` / `PostToolBatch` / `Stop` の4フック |
| `~/.config/herdr/config.toml` | `[ui.sidebar.agents]` の行テンプレートと `agent_panel_sort` |
| `~/.local/bin/ccstatus` | usage push の1行（`crmux` 行の直後） |
| `~/.codex/hooks.json` | 同じ4フック（Codex はスキーマ互換） |

インストール後:

- Claude Code は次のセッションから有効
- herdr は設定の再読み込みが必要（`herdr server reload-config`。**`restart` は使わない**
  —— herdr のペインの中で作業していると自分ごと落ちる）
- **Codex は次回起動時にフックの承認プロンプトが1回出る**

Codex の `trusted_hash` を自動登録していないのは、ハッシュの入力正規化を特定できな
かったため（コマンド文字列・改行付き・`hooks.json` 全体・フック本体・JSON シリアライズ
の計6候補すべて不一致）。推測値を書くと Codex がフックを黙って無効化し、「なぜか
動かない」という気づけない壊れ方になる。承認1回のほうが安い。

## 依存

`jq` と `python3`。

**herdr CLI は使わない。** 0.7.5 の `herdr pane report-metadata` は `--source` に値を
渡せない —— help は `[OPTIONS] --source <ID> <PANE_ID>` と書いているが実装が対応して
おらず、`--source hj` は `unknown option: hj`、`--source=hj` は認識されず
`missing required --source` になる。位置引数の `<PANE_ID>` も常に拒否される
（`--token` と `--seq` はスペース形式で通るので `--source` 固有の不具合）。

そのため socket API（`pane.report_metadata`）を直接叩いている。herdr 公式のフック
`herdr-agent-state.sh` も同じく socket 直叩きなので、これが herdr の想定経路。
送信は `lib/herdr-send.py` の 40 行程度が担い、JSON の組み立ては `jq` が行う。

## テスト

```bash
bash tests/run.sh
```

偽の UNIX socket サーバを立てて、フックが送った JSON-RPC をそのまま検証する
（`tests/fake_socket.sh`）。本番と同じ経路を通るので、herdr 本体もエージェントも
要らない。JSON で送るため値の空白や `|` はそのまま 1 フィールドとして届き、
シェル引数のクォート漏れという失敗モードが構造的に存在しない。

## うまく動かないとき

**パネルに何も出ない** — トークンを送るだけでは表示されない。`~/.config/herdr/config.toml`
の `[ui.sidebar.agents.rows_by_agent]` に置き場が要る。値の送信と並べ方は別の担当で、
片方だけでは何も起きない。切り分けは手でフックを叩くのが速い:

```bash
printf '{"tool_name":"Bash","tool_input":{"description":"手動テスト"}}' \
  | bash hooks/herdr-jump-reason.sh set
```

**送れたかどうかは snapshot で確認できる** —— パネルの見え方と切り離して判定できる:

```bash
herdr api snapshot | jq '.result.snapshot.panes[]
  | select(.pane_id == env.HERDR_PANE_ID) | .tokens'
```

`tokens` に値が入っているのにパネルに出ないなら表示層（`config.toml`）の問題、
`tokens` が空ならフック側の問題。**カスタムトークンの `$` を忘れると herdr が
`[ui]` 設定を丸ごと拒否する**ので、その場合は
`herdr server reload-config` の出力に診断が出る。

**reason が消えない** — 許可を拒否したときは `PostToolBatch` が発火しない可能性がある。
`Stop` フックがその取りこぼしを回収する設計なので、`~/.claude/settings.json` の `Stop`
エントリを確認する。最後の保険として TTL 15 分で自動的に消える。

**Codex で出ない** — 承認プロンプトを通したか確認する。`~/.codex/config.toml` の
`[hooks.state]` に該当エントリが増えていれば通っている。

**`agent_panel_sort` を自分の値にしたい** — install.sh は既存の `agent_panel_sort` を
**無警告で `"priority"` に書き換える**。`"spaces"` などを使いたい場合は install.sh を
走らせた後に手で戻す（バックアップは `.bak.<timestamp>` に残っている）。

このキーは `[ui]` テーブルに属するので、手で書くなら `[ui]` セクションの中に置く。
マーカーブロックの中に書いても効かない —— そこは末尾に追記されるため、`[ui]` を
再定義すると TOML エラーになり、`ui.agent_panel_sort = ...` と書くと直前のテーブル内の
キーとして解釈されて**パースは通るのに効かない**。

## 設計

[docs/superpowers/specs/2026-07-30-herdr-agent-status-design.md](docs/superpowers/specs/2026-07-30-herdr-agent-status-design.md)

実装計画は
[docs/superpowers/plans/2026-07-30-herdr-agent-status.md](docs/superpowers/plans/2026-07-30-herdr-agent-status.md)。

v1（fzf によるペイン切り替え）の設計は
[docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md](docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md)
に残してある。そこで「できない」として落とした2件が実は両方できたことが、本設計の
出発点になっている。
