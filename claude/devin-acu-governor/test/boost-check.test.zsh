#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/boost-check.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# 1. Within pool.
out=$(run_jq '{"pool":24000,"current_cap":230,"increment":50,"sum_caps":23000}')
assert_contains "ok newcap" "$out" '"new_cap":280'
assert_contains "ok newsum" "$out" '"new_sum":23050'
assert_contains "ok headroom" "$out" '"headroom_after":950'
assert_contains "ok flag" "$out" '"over_pool":false'

# 2. Pushes past pool.
out=$(run_jq '{"pool":24000,"current_cap":230,"increment":50,"sum_caps":23980}')
assert_contains "over flag" "$out" '"over_pool":true'
assert_contains "over headroom" "$out" '"headroom_after":-30'

report
