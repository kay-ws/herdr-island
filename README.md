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

`herdr server reload-config` で反映する。**`restart` は使わない** —
Herdr のペインの中で作業している場合、自分ごと落ちる。

`alt+j` は 0.7.5 の組込みキーと衝突しない（組込みの `alt+` 系は `alt+g` と `alt+n`）。

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

**自己クローズを書かない。**
`type = "pane"` の popup は、起動したコマンドが終了した時点で Herdr が自前で畳む
（実測）。スクリプト側で閉じると、閉じる主体が二重になる。

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
要る部分は自動テストできない。その範囲の手順と実施結果は spec の「テスト」節にある。

`tests/probe_focus_retention.sh` は「popup が閉じた後もフォーカスが移動先に残るか」を
実機で確かめるプローブ。この設計はそこが崩れると根本から成立しないので、Herdr の更新後に
挙動を疑ったらこれを回す。一時的にキーへ割り当てて実行し、結果は
`~/.cache/herdr-jump-probe.txt` に出る。

## 詳細

`docs/superpowers/specs/2026-07-29-herdr-agent-jump-design.md`
