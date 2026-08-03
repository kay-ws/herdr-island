#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if python3 "$root/lib/view.py" set; then
  echo "Showing only waiting agents."
else
  echo "Could not apply the filter (unable to connect to herdr)." >&2
  exit 1
fi
