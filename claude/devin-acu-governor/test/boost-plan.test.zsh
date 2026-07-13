#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/boost-plan.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# A. Projection-sized boost, donors fund it fully (zero-sum, sum invariant).
#    share 250, recipient consumed 180 + run_rate 10*5 days = 230 projected,
#    recommended ceil(230*1.15)=265, delta 65.
#    d1 floor ceil(20 + 0.10*250)=45 -> available 205; lowest consumer, funds all 65.
out=$(run_jq '{"pool":1000,"share":250,"recipient_buffer":0.15,"donor_buffer":0.10,
  "recipient":{"email":"r@x","cap":200,"consumed":180,"run_rate":10,"days_left":5},
  "donors":[{"email":"d1@x","cap":250,"consumed":20},{"email":"d2@x","cap":250,"consumed":100}]}')
assert_contains "A recommended" "$out" '"recommended_cap":265'
assert_contains "A delta" "$out" '"delta":65'
assert_contains "A funded" "$out" '"funded":65'
assert_contains "A shortfall" "$out" '"shortfall":0'
assert_contains "A donor take" "$out" '{"email":"d1@x","cap_before":250,"cap_after":185,"given":65}'
assert_contains "A recip after" "$out" '"cap_after":265'
assert_contains "A sum_before" "$out" '"sum_before":450'
assert_contains "A sum_after" "$out" '"sum_after":450'

# B. Shortfall: donors cannot fully fund; recipient raised only by what is funded.
#    recommended ceil((180+200)*1.15)=437, delta 237. d1 floor 105 -> available 0;
#    d2 floor ceil(200+25)=225 -> available 25. funded 25, shortfall 212, recipient 200->225.
out=$(run_jq '{"pool":1000,"share":250,"recipient_buffer":0.15,"donor_buffer":0.10,
  "recipient":{"email":"r@x","cap":200,"consumed":180,"run_rate":20,"days_left":10},
  "donors":[{"email":"d1@x","cap":100,"consumed":80},{"email":"d2@x","cap":250,"consumed":200}]}')
assert_contains "B delta" "$out" '"delta":237'
assert_contains "B funded" "$out" '"funded":25'
assert_contains "B shortfall" "$out" '"shortfall":212'
assert_contains "B recip after" "$out" '"cap_after":225'
assert_contains "B warn" "$out" 'can only fund'

# C. Explicit delta override ignores projection.
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,
  "recipient":{"email":"r@x","cap":200,"consumed":100,"run_rate":5,"days_left":4,"delta_override":30},
  "donors":[{"email":"d1@x","cap":300,"consumed":50}]}')
assert_contains "C recommended" "$out" '"recommended_cap":230'
assert_contains "C delta" "$out" '"delta":30'
assert_contains "C take" "$out" '"given":30'
assert_contains "C recip after" "$out" '"cap_after":230'

# D. No boost needed: projection below current cap -> delta 0, no donors touched.
out=$(run_jq '{"pool":1000,"share":250,"recipient_buffer":0.15,"donor_buffer":0.10,
  "recipient":{"email":"r@x","cap":500,"consumed":100,"run_rate":1,"days_left":5},
  "donors":[{"email":"d1@x","cap":250,"consumed":20}]}')
assert_contains "D delta" "$out" '"delta":0'
assert_contains "D takes empty" "$out" '"takes":[]'
assert_contains "D recip same" "$out" '"cap_after":500'
assert_contains "D sum invariant" "$out" '"sum_before":500'

# E. Donor safety policy: avoid low-cap skim donors and preserve a 50 ACU floor.
#    low@x has old-rule availability (19 - ceil(0 + 20) = -1? no useful headroom) and
#    skim@x would have one ACU above old floor, but both are below the global 50 ACU floor.
#    high@x funds the request while staying at/above 50.
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,
  "recipient":{"email":"r@x","cap":0,"consumed":0,"run_rate":0,"days_left":1,"delta_override":50},
  "donors":[{"email":"low@x","cap":19,"consumed":0},{"email":"skim@x","cap":51,"consumed":0},{"email":"high@x","cap":100,"consumed":0}]}')
assert_contains "E funded" "$out" '"funded":50'
takes=$(print -r -- "$out" | jq -c '.takes')
assert_eq "E uses only high-headroom donor" '[{"email":"high@x","cap_before":100,"cap_after":50,"given":50}]' "$takes"

# F. Remainder-aware donor safety: do not leave a sub-min-give shortfall when
#    another high-headroom donor can cover it by taking less from the current donor.
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,
  "recipient":{"email":"r@x","cap":0,"consumed":0,"run_rate":0,"days_left":1,"delta_override":50},
  "donors":[{"email":"d1@x","cap":55,"consumed":0},{"email":"d2@x","cap":57,"consumed":0},{"email":"d3@x","cap":57,"consumed":0},{"email":"d4@x","cap":62,"consumed":0},{"email":"d5@x","cap":56,"consumed":0},{"email":"d6@x","cap":61,"consumed":0},{"email":"d7@x","cap":64,"consumed":0}]}')
assert_contains "F fully funded" "$out" '"funded":50'
assert_contains "F no shortfall" "$out" '"shortfall":0'
assert_contains "F recipient full cap" "$out" '"cap_after":50'
takes=$(print -r -- "$out" | jq -c '[.takes[].given]')
assert_eq "F no donor below min give" '[5,7,7,12,6,8,5]' "$takes"

report
