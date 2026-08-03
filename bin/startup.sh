#!/bin/bash
# view は揮発性なので、保存してあれば起動時に再適用する
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 "$root/lib/view.py" restore
exit 0
