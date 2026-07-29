#!/bin/bash
# herdr Agents パネル拡充の配線。何度実行しても同じ結果になる。
#
# 触るファイル:
#   ~/.claude/settings.json      … reason フックの 4 イベント
#   ~/.config/herdr/config.toml  … 行テンプレートと agent_panel_sort
#   ~/.local/bin/ccstatus        … usage push の 1 行
#   ~/.codex/hooks.json          … reason、model、context 使用率のフック
#
# ~/.codex/config.toml は触らない。trusted_hash の入力正規化を特定できないため、
# 推測した値を書くと Codex がフックを黙って無効化する。承認は次回起動時に 1 回。

set -uo pipefail

PREFIX="${HERDR_JUMP_PREFIX:-$HOME}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ミリ秒まで入れる。秒精度だと同一秒内に 2 回実行したとき（テストの連続実行や
# 利用者の素早い再実行）2 回目が 1 回目のバックアップを上書きしてしまう
STAMP="$(date +%Y%m%d-%H%M%S-%3N)"

# フックには実体の絶対パスを書く。symlink 経由で呼ばれると
# dirname "${BASH_SOURCE[0]}" がリンクの置き場所を指し、隣の
# reason-filter.jq を見つけられなくなる
HOOK="$HERE/hooks/herdr-jump-reason.sh"
CODEX_USAGE="$HERE/hooks/herdr-codex-usage.sh"
PUSH="$HERE/statusline/herdr-usage-push"
ROWS="$HERE/config/agents-rows.toml"

SETTINGS="$PREFIX/.claude/settings.json"
HERDRCFG="$PREFIX/.config/herdr/config.toml"
CCSTATUS="$PREFIX/.local/bin/ccstatus"
CODEXHOOKS="$PREFIX/.codex/hooks.json"

command -v jq      >/dev/null 2>&1 || { echo "jq が必要です" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 が必要です" >&2; exit 1; }

# 一時ファイルは作業ディレクトリ 1 つにまとめ、trap でまるごと消す。
# 個別に配列へ追記する方式は使えない —— tmp="$(mktmp)" のコマンド置換は
# サブシェルで走るので、関数内での配列追記が親プロセスに伝わらず、
# 変換の失敗経路（mv に届かない）で毎回 1 個ずつ漏れる。
WORKDIR="$(mktemp -d)" || { echo "一時ディレクトリを作れません" >&2; exit 1; }
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# tmpfor <対象ファイル> <用途> : WORKDIR の中に衝突しない一時パスを返す
tmpfor() { printf '%s/%s.%s' "$WORKDIR" "$(basename "$1")" "$2"; }

backup() { [ -f "$1" ] && cp -p "$1" "$1.bak.$STAMP"; return 0; }

# --- フックイベントの配線（Claude Code / Codex 共通） ------------------------
#
# Claude Code と Codex はフックスキーマが互換なので、同じ jq を両方に当てる。
# 「既存の herdr-jump エントリを消してから足す」ので何度でも実行できる。

wire_hook_events() {
  local f="$1"
  local with_model="${2:-0}"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  [ -f "$f" ] || echo '{}' > "$f" || return 1
  backup "$f"

  # jq は 1 回で完結させる。2 段に分けると 1 段目が入れたエントリを 2 段目の
  # purge が巻き込んで消す（実際にそうなっていて、Codex の Stop から reason の
  # clear が消えていた ＝ 拒否・中断時に理由が TTL まで残る状態だった）
  local tmp; tmp="$(tmpfor "$f" json)"
  jq \
    --arg set        "bash '$HOOK' set" \
    --arg clear      "bash '$HOOK' clear" \
    --arg model      "bash '$HOOK' model" \
    --arg usage      "bash '$CODEX_USAGE'" \
    --arg with_model "$with_model" '
    # 自分が入れたエントリだけを取り除く。他人のフック（superset や herdr 公式の
    # herdr-agent-state.sh）には触らない。
    # .hooks が無い / null のグループがあっても落ちないよう (. // []) で守る
    # （落ちると jq が非ゼロで終わり、配線がまるごと黙って飛ぶ）
    def purge:
      (. // [])
      | map(.hooks |= ((. // []) | map(select(
          ((.command // "") | test("herdr-jump-reason|herdr-codex-usage")) | not))))
      | map(select((.hooks | length) > 0));

    def entry($matcher; $cmd):
      (if $matcher == "" then {} else {matcher: $matcher} end)
      + {hooks: [{type: "command", command: $cmd, timeout: 5}]};

      .hooks                     = (.hooks // {})
    | .hooks.PermissionRequest   = ((.hooks.PermissionRequest | purge) + [entry("*"; $set)])
    | .hooks.PreToolUse          = ((.hooks.PreToolUse        | purge) + [entry("AskUserQuestion"; $set)])
    | .hooks.PostToolBatch       = ((.hooks.PostToolBatch     | purge) + [entry(""; $clear)])
    # Stop は reason の clear が本体。Codex ではそこに usage の収集を足す。
    # 順序は clear → usage（どちらも独立だが、消す方を先に通す）
    | .hooks.Stop                = ((.hooks.Stop              | purge) + [entry(""; $clear)]
                                    + (if $with_model == "1" then [entry(""; $usage)] else [] end))
    # Codex の共通フック入力には active model slug がある。SessionStart は
    # startup / resume / clear / compact の全経路で走るため matcher 無しで拾う
    | (if $with_model == "1"
       then .hooks.SessionStart = ((.hooks.SessionStart | purge) + [entry(""; $model)])
       else . end)
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- ~/.config/herdr/config.toml ---------------------------------------------

wire_herdr_config() {
  local f="$1"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  [ -f "$f" ] || : > "$f" || return 1
  backup "$f"

  local tmp t2
  tmp="$(tmpfor "$f" toml)"
  t2="$(tmpfor "$f" toml2)"

  # 既存のマーカーブロックを落とす
  awk '
    /^# >>> herdr-jump \(managed\) >>>/ { skip = 1 }
    skip != 1 { print }
    /^# <<< herdr-jump \(managed\) <<</ { skip = 0 }
  ' "$f" > "$tmp" || return 1

  # agent_panel_sort は [ui] テーブルのキーなので、末尾に追記される
  # マーカーブロックの中には書けない（config/agents-rows.toml の冒頭コメント参照）。
  # 3 経路で [ui] に入れる。
  local need_ui=0
  if grep -qE '^[[:space:]]*agent_panel_sort[[:space:]]*=' "$tmp"; then
    # 1) 既にある（前回の実行か、利用者が自分で書いた）→ 値を揃える
    sed -E 's|^([[:space:]]*)agent_panel_sort[[:space:]]*=.*|\1agent_panel_sort = "priority"  # herdr-jump|' \
      "$tmp" > "$t2" && mv "$t2" "$tmp"
  elif grep -qE '^\[ui\][[:space:]]*$' "$tmp"; then
    # 2) [ui] がある → その直後に挿入
    awk '
      { print }
      /^\[ui\][[:space:]]*$/ && !inserted {
        print "agent_panel_sort = \"priority\"  # herdr-jump"
        inserted = 1
      }
    ' "$tmp" > "$t2" && mv "$t2" "$tmp"
  else
    # 3) [ui] が無い → ブロックの後ろに [ui] を作る（下で処理）
    need_ui=1
  fi

  # 末尾の空行をいったん全部落としてから、区切りの空行を 1 つだけ置く。
  # 無条件に足すと実行ごとに空行が 1 つ増えて冪等でなくなる。逆に空行が
  # 無いと直前の行にマーカーコメントがくっついて TOML が壊れる
  awk '{ buf[NR] = $0 }
       END { last = NR
             while (last > 0 && buf[last] == "") last--
             for (i = 1; i <= last; i++) print buf[i] }' "$tmp" > "$t2" || return 1
  mv "$t2" "$tmp"
  printf '\n' >> "$tmp"
  cat "$ROWS" >> "$tmp" || return 1

  # [ui.sidebar.agents] を先に書いてから [ui] を明示定義するのは TOML で許される
  # （暗黙テーブルの後付け定義）。実測で確認済み
  if [ "$need_ui" = "1" ]; then
    printf '\n[ui]\nagent_panel_sort = "priority"  # herdr-jump\n' >> "$tmp"
  fi

  mv "$tmp" "$f"
}

# --- ~/.local/bin/ccstatus ---------------------------------------------------

wire_ccstatus() {
  local f="$1"
  # ここは他と違ってファイルを新規作成しない。ccstatus は利用者の statusLine
  # スクリプトなので、無い環境では配線する相手がいない。
  # return 1 にして呼び出し側の "ok:" を出させない（skip と ok が並ぶと嘘になる）
  if [ ! -f "$f" ]; then
    echo "  skip: $f が見つかりません（statusLine を使っていない環境）" >&2
    return 1
  fi
  grep -q 'herdr-usage-push' "$f" && return 0
  backup "$f"

  local tmp; tmp="$(tmpfor "$f" sh)"
  # input=$(cat) の直後に差し込む。awk は行ごとに全ルールを評価するので、
  # 実際には先に現れるこちらが勝つ。$input が定義された直後で、crmux 行の
  # 有無に関係なく同じ位置に入るためこの方が安定する。
  # crmux ルールは input=$(cat) の形が違う ccstatus 向けのフォールバック
  awk -v push="$PUSH" '
    { print }
    !inserted && /^input=\$\(cat\)/ {
      printf "echo \"$input\" | %s &  # herdr-jump\n", push
      inserted = 1
    }
    !inserted && /crmux rpc status-update/ {
      printf "echo \"$input\" | %s &  # herdr-jump\n", push
      inserted = 1
    }
  ' "$f" > "$tmp" || return 1

  # 挿入位置が見つからなければ awk は入力をそのまま出す。黙って ok を出さず、
  # 手で足す方法を示す
  if ! grep -q 'herdr-usage-push' "$tmp"; then
    cat >&2 <<WARN
  warn: $f に挿入位置が見つかりませんでした。
        input=\$(cat) の行も crmux の行も無いため、usage は表示されません。
        次の 1 行を \$input を組み立てた後に手で足してください:
          echo "\$input" | $PUSH &
WARN
    return 1
  fi

  mv "$tmp" "$f"
  chmod +x "$f"
}

# --- 実行 -------------------------------------------------------------------

chmod +x "$HOOK" "$PUSH" "$CODEX_USAGE" 2>/dev/null

echo "herdr-jump をインストールします (prefix: $PREFIX)"
wire_hook_events   "$SETTINGS"   && echo "  ok: $SETTINGS"
wire_herdr_config  "$HERDRCFG"   && echo "  ok: $HERDRCFG"
wire_ccstatus      "$CCSTATUS"   && echo "  ok: $CCSTATUS"
wire_hook_events   "$CODEXHOOKS" 1 && echo "  ok: $CODEXHOOKS"

# v1 の名残を知らせる。消すのは越権なので警告だけ出す
if [ -f "$HERDRCFG" ] && grep -q 'herdr-jump\.sh' "$HERDRCFG"; then
  cat <<'WARN'

注意: config.toml に herdr-jump.sh を参照するキーバインドが残っています。
      v1 のペイン切り替え UI は撤去したのでこのバインドは動きません。
      [[keys.command]] の該当ブロックを手で消してください。
      (他人の keys 設定を install.sh が消すのは越権なので警告だけ出します)
WARN
fi

cat <<'NOTE'

完了しました。

  * Claude Code は次のセッションから有効になります
  * herdr は設定の再読み込みが要ります: herdr server reload-config
    (restart は使わないこと。herdr のペインの中から叩くと自分ごと落ちる)
  * Codex は次回起動時にフックの承認プロンプトが 1 回出ます。
    trusted_hash は自動登録できないため、そこで許可してください

バックアップは各ファイルの隣に .bak.<timestamp> で置いてあります。
NOTE
