#!/bin/bash
# Views are transient, so re-apply the saved one at startup if there is one.
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 "$root/lib/view.py" restore
exit 0
