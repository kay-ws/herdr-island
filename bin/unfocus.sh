#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 "$root/lib/view.py" clear
echo "すべてのエージェントを表示します。"
