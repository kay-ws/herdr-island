#!/bin/bash
set -uo pipefail
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if python3 "$root/lib/view.py" clear; then
  echo "Showing all agents."
else
  echo "Could not clear the filter (unable to connect to herdr)." >&2
  exit 1
fi
