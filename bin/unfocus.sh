#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if python3 "$root/lib/view.py" clear; then
  echo "すべてのエージェントを表示します。"
else
  echo "絞り込みを解除できませんでした（herdr に接続できません）。" >&2
  exit 1
fi
