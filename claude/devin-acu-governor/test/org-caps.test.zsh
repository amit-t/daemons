#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/org-caps.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# A. prorated: pool 1000, mh 100.
#    floors: A ceil(300)+100=400, B 200, C(idle) 100 -> sum 700, surplus 300.
#    shares by consumed (300/100/0): extra 225/75/0 -> caps 625/275/100.
#    sum_after 1000, unallocated 0. delta only where cap_before existed.
out=$(run_jq '{"pool":1000,"min_headroom":100,
  "orgs":[{"org_id":"a","name":"A","local_consumed":300,"cap_before":500},
          {"org_id":"b","name":"B","local_consumed":100},
          {"org_id":"c","name":"C","local_consumed":0,"cap_before":50}]}')
assert_contains "A mode" "$out" '"mode":"prorated"'
assert_contains "A cap a" "$out" '"cap_after":625'
assert_contains "A cap b" "$out" '"cap_after":275'
assert_contains "A cap c (idle floor)" "$out" '"cap_after":100'
assert_contains "A delta a" "$out" '"delta":125'
assert_contains "A delta b null" "$out" '"delta":null'
assert_contains "A sum_before" "$out" '"sum_before":550'
assert_contains "A sum_after" "$out" '"sum_after":1000'
assert_contains "A unallocated" "$out" '"unallocated":0'
assert_contains "A no warnings" "$out" '"warnings":[]'
if [[ $(print -r -- "$out" | jq -r '.proposed[0].org_id') == "a" ]]; then _ok; else _fail "A sorted by consumed desc"; fi

# B. even: every org idle -> surplus split evenly, remainder unallocated.
#    floors 100 each (sum 300), surplus 700, extra floor(700/3)=233 -> caps 333.
out=$(run_jq '{"pool":1000,"min_headroom":100,
  "orgs":[{"org_id":"a","name":"A","local_consumed":0},
          {"org_id":"b","name":"B","local_consumed":0},
          {"org_id":"c","name":"C","local_consumed":0}]}')
assert_contains "B mode" "$out" '"mode":"even"'
assert_contains "B cap" "$out" '"cap_after":333'
assert_contains "B sum_after" "$out" '"sum_after":999'
assert_contains "B unallocated" "$out" '"unallocated":1'

# C. infeasible: floors 550+350=900 > pool 500 -> error with shortfall, no caps.
out=$(run_jq '{"pool":500,"min_headroom":250,
  "orgs":[{"org_id":"a","name":"A","local_consumed":300},
          {"org_id":"b","name":"B","local_consumed":100}]}')
assert_contains "C error" "$out" '"error":"pool cannot cover every org'
assert_contains "C sum_floors" "$out" '"sum_floors":900'
assert_contains "C shortfall" "$out" '"shortfall":400'

# D. projection warning: A run_rate 100 over 5 days left -> projected 600 > cap 300.
out=$(run_jq '{"pool":600,"min_headroom":100,"days_left":5,
  "orgs":[{"org_id":"a","name":"A","local_consumed":100,"run_rate":100},
          {"org_id":"b","name":"B","local_consumed":100}]}')
assert_contains "D cap a" "$out" '"cap_after":300'
assert_contains "D projected a" "$out" '"projected":600'
assert_contains "D warning" "$out" 'A projected 600 ACUs by cycle end exceeds proposed cap 300'

# E. min_headroom clamps at 500 (hard-rule-11 analogue); single idle org takes pool.
out=$(run_jq '{"pool":2000,"min_headroom":900,
  "orgs":[{"org_id":"a","name":"A","local_consumed":0}]}')
assert_contains "E clamped" "$out" '"min_headroom":500'
assert_contains "E cap" "$out" '"cap_after":2000'

# F. degenerate inputs error out.
out=$(run_jq '{"pool":0,"orgs":[{"org_id":"a","name":"A","local_consumed":1}]}')
assert_contains "F pool error" "$out" '"error":"pool must be positive"'
out=$(run_jq '{"pool":100,"orgs":[]}')
assert_contains "F empty error" "$out" '"error":"no orgs supplied"'

report
