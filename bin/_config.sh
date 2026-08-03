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
