#!/bin/bash
# 現状を1画面で報告する。action なので TTY は無い（出力は plugin log へ）
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

cfg="$(island_config_path)"

echo "config: $cfg"
if [ -f "$cfg" ]; then
  grep -q '\$reason' "$cfg" && echo "  reason 行: あり" || echo "  reason 行: なし"
  grep -q 'rows_by_agent' "$cfg" \
    && echo "  rows_by_agent: あり（追加した行が無効化されます）" \
    || echo "  rows_by_agent: なし"
else
  echo "  ファイルがありません"
fi

echo "依存:"
for c in herdr jq python3; do
  command -v "$c" >/dev/null 2>&1 && echo "  $c: あり" || echo "  $c: なし"
done

echo "hook の配線:"
# エージェントごとに出す。合算値だと「片方だけ配線済み」が見えない
bash "$root/lib/hooks.sh" status | while IFS= read -r line; do echo "  $line"; done

echo "絞り込み:"
[ -f "${HERDR_PLUGIN_STATE_DIR:-/nonexistent}/view.json" ] \
  && echo "  適用中" || echo "  未適用"

echo "旧 herdr-jump:"
if bash "$root/lib/legacy.sh" detect 2>/dev/null | sed 's/^/  /'; then
  echo "  ↑ 痕跡があります。setup から撤去できます"
else
  echo "  痕跡なし"
fi
