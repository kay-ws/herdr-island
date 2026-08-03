#!/bin/bash
# 現状を1画面で報告する。action なので TTY は無い（出力は plugin log へ）
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HERDR_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
source "$here/_config.sh"

cfg="$(island_config_path)"

echo "config: $cfg"
if [ -f "$cfg" ]; then
  grep -q '\$reason' "$cfg" && echo "  reason line: present" || echo "  reason line: absent"
  grep -q 'rows_by_agent' "$cfg" \
    && echo "  rows_by_agent: present (it disables the added row)" \
    || echo "  rows_by_agent: absent"
else
  echo "  file does not exist"
fi

echo "dependencies:"
for c in herdr jq python3; do
  command -v "$c" >/dev/null 2>&1 && echo "  $c: found" || echo "  $c: not found"
done

echo "hook wiring:"
# エージェントごとに出す。合算値だと「片方だけ配線済み」が見えない
bash "$root/lib/hooks.sh" status | while IFS= read -r line; do echo "  $line"; done

echo "filtering:"
[ -f "${HERDR_PLUGIN_STATE_DIR:-/nonexistent}/view.json" ] \
  && echo "  active" || echo "  inactive"

echo "old herdr-jump:"
if bash "$root/lib/legacy.sh" detect 2>/dev/null | sed 's/^/  /'; then
  echo "  ^ traces found. Remove them from setup"
else
  echo "  no traces"
fi
