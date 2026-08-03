#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 "$root/lib/view.py" set
echo "待っているエージェントだけを表示します。"
