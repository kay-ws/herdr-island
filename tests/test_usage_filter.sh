#!/bin/bash

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./assert.sh
source "$here/assert.sh"

FILTER="$here/../statusline/usage-filter.jq"

# ctx <json> / lim <json> : TSV の 1 列目 / 2 列目
ctx() { printf '%s' "$1" | jq -r -f "$FILTER" | cut -f1; }
lim() { printf '%s' "$1" | jq -r -f "$FILTER" | cut -f2; }
mdl() { printf '%s' "$1" | jq -r -f "$FILTER" | cut -f3; }

full='{"model":{"display_name":"Opus 5"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":81000}},"rate_limits":{"five_hour":{"used_percentage":11.4},"seven_day":{"used_percentage":2.6}}}'

assert_eq "42%" "$(ctx "$full")" "84000/200000 は 42%"
assert_eq "5h 11% | 7d 3%" "$(lim "$full")" "rate limits は丸めて連結"

no_limits='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":50000}}}'
assert_eq "25%" "$(ctx "$no_limits")" "rate_limits が無くても ctx は出る"
assert_eq "" "$(lim "$no_limits")" "rate_limits が無ければ limits は空"

only_5h='{"context_window":{"context_window_size":100,"current_usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"rate_limits":{"five_hour":{"used_percentage":80}}}'
assert_eq "5h 80%" "$(lim "$only_5h")" "片方だけでも出る"

only_7d='{"context_window":{"context_window_size":100,"current_usage":{"input_tokens":10}},"rate_limits":{"seven_day":{"used_percentage":5}}}'
assert_eq "7d 5%" "$(lim "$only_7d")" "7d だけでも出る"

no_usage='{"context_window":{"context_window_size":200000,"current_usage":null}}'
assert_eq "" "$(ctx "$no_usage")" "current_usage が null なら空"

partial='{"context_window":{"context_window_size":1000,"current_usage":{"input_tokens":100}}}'
assert_eq "10%" "$(ctx "$partial")" "cache 系フィールドが無くても落ちない"

zero='{"context_window":{"context_window_size":0,"current_usage":{"input_tokens":5}}}'
assert_eq "" "$(ctx "$zero")" "0 除算を踏まない"

assert_eq "" "$(ctx '{}')" "空 payload でも落ちない"
assert_eq "" "$(lim '{}')" "空 payload では limits も空"

# 端数は切り捨て。199999/200000 は 99% であって 100% ではない
almost='{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":199999}}}'
assert_eq "99%" "$(ctx "$almost")" "端数は切り捨て"

assert_eq "Opus 5" "$(mdl "$full")" "model は display_name をそのまま出す"
assert_eq ""       "$(mdl '{}')"    "model が無ければ空"

finish
