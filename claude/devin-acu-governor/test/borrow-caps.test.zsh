#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/borrow-caps.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# A. even_share: donors have ample headroom; remaining budget prorated.
#    base_sum=100+200+300=600, donor avail=1000, share=floor((1000-600)/3)=133.
#    caps 233/333/433 sum 999. borrowed 999 taken from the single lowest-consumer
#    donor (cap 1000 -> 1). 1 ACU of headroom stays with the donor. Zero-sum.
out=$(run_jq '{"recipients":[{"email":"r1@x","consumed":100},{"email":"r2@x","consumed":200},{"email":"r3@x","consumed":300}],
  "donors":[{"email":"d1@x","cap":1000,"consumed":0}]}')
assert_contains "A mode" "$out" '"mode":"even_share"'
assert_contains "A share" "$out" '"share":133'
assert_contains "A cap r1" "$out" '{"email":"r1@x","consumed":100,"cap":233}'
assert_contains "A cap r3" "$out" '{"email":"r3@x","consumed":300,"cap":433}'
assert_contains "A borrowed" "$out" '"borrowed":999'
assert_contains "A take" "$out" '{"email":"d1@x","cap_before":1000,"cap_after":1,"given":999}'
assert_contains "A sum_before" "$out" '"sum_before":1000'
assert_contains "A sum_after" "$out" '"sum_after":1000'
assert_contains "A zero_sum" "$out" '"zero_sum":true'
assert_contains "A no warnings" "$out" '"warnings":[]'

# B. min_cover: donors cover consumption exactly, no growth headroom (share would be 0).
#    base_sum=300, donor avail=300, 300 >= base_sum(300)+n(2)? no -> constrained.
#    Both funded at ceil(consumed): 100, 200. Zero-sum. Warn: consumption only.
out=$(run_jq '{"recipients":[{"email":"r1@x","consumed":100},{"email":"r2@x","consumed":200}],
  "donors":[{"email":"d1@x","cap":300,"consumed":0}]}')
assert_contains "B mode" "$out" '"mode":"min_cover"'
assert_contains "B cap r1" "$out" '{"email":"r1@x","consumed":100,"cap":100}'
assert_contains "B cap r2" "$out" '{"email":"r2@x","consumed":200,"cap":200}'
assert_contains "B borrowed" "$out" '"borrowed":300'
assert_contains "B skipped empty" "$out" '"recipients_skipped":[]'
assert_contains "B warn" "$out" 'consumed ACUs only'
assert_contains "B zero_sum" "$out" '"zero_sum":true'

# C. partial: donor avail (200) cannot fund everyone zero-sum. Cheapest funded
#    first (r1=50, r2=100 -> 150 used), r3 (400) left uncapped. Zero-sum.
out=$(run_jq '{"recipients":[{"email":"r1@x","consumed":50},{"email":"r2@x","consumed":100},{"email":"r3@x","consumed":400}],
  "donors":[{"email":"d1@x","cap":200,"consumed":0}]}')
assert_contains "C mode" "$out" '"mode":"partial"'
assert_contains "C cap r1" "$out" '{"email":"r1@x","consumed":50,"cap":50}'
assert_contains "C cap r2" "$out" '{"email":"r2@x","consumed":100,"cap":100}'
assert_contains "C skipped r3" "$out" '"recipients_skipped":[{"email":"r3@x","consumed":400}]'
assert_contains "C borrowed" "$out" '"borrowed":150'
assert_contains "C take" "$out" '{"email":"d1@x","cap_before":200,"cap_after":50,"given":150}'
assert_contains "C warn" "$out" 'cannot fund all 3 users'
assert_contains "C warn names" "$out" 'left uncapped: r3@x'
assert_contains "C zero_sum" "$out" '"zero_sum":true'

# D. No donors: nothing to borrow. All recipients skipped, no caps applied. Zero-sum (0==0).
out=$(run_jq '{"recipients":[{"email":"r1@x","consumed":100}],"donors":[]}')
assert_contains "D mode" "$out" '"mode":"partial"'
assert_contains "D borrowed" "$out" '"borrowed":0'
assert_contains "D capped empty" "$out" '"recipients_capped":[]'
assert_contains "D skipped" "$out" '"recipients_skipped":[{"email":"r1@x","consumed":100}]'
assert_contains "D warn none" "$out" 'no caps applied: no donor headroom'
assert_contains "D zero_sum" "$out" '"zero_sum":true'

# E. No recipients: error, no plan.
out=$(run_jq '{"recipients":[],"donors":[{"email":"d1@x","cap":100,"consumed":10}]}')
assert_contains "E error" "$out" '"error":"no uncapped users to seed"'

# F. donor_buffer override (0): floor = ceil(consumed*1) = consumed, full headroom above consumption.
#    donor cap 1000 consumed 100 -> avail 900. base_sum 100, share floor((900-100)/1)=800, cap 900.
out=$(run_jq '{"donor_buffer":0,"recipients":[{"email":"r1@x","consumed":100}],
  "donors":[{"email":"d1@x","cap":1000,"consumed":100}]}')
assert_contains "F donor_buffer" "$out" '"donor_buffer":0'
assert_contains "F cap" "$out" '{"email":"r1@x","consumed":100,"cap":900}'
assert_contains "F take cap_after" "$out" '"cap_after":100'
assert_contains "F zero_sum" "$out" '"zero_sum":true'

# G. Lowest-consumer-first draw + buffer + user_id passthrough.
#    d2 (consumed 5) drained before d1 (consumed 100). d1 keeps a ~10% buffer above
#    100 (FP: ceil(100*1.1)=111 -> floor 111, avail 39). user_id flows to outputs.
out=$(run_jq '{"recipients":[{"email":"r1@x","user_id":"email|r1","consumed":100}],
  "donors":[{"email":"d1@x","cap":150,"consumed":100},{"email":"d2@x","user_id":"email|d2","cap":1000,"consumed":5}]}')
assert_contains "G recipient user_id" "$out" '"user_id":"email|r1"'
assert_contains "G draw d2 first" "$out" '{"email":"d2@x","cap_before":1000,"cap_after":6,"given":994,"user_id":"email|d2"}'
assert_contains "G draw d1 second" "$out" '{"email":"d1@x","cap_before":150,"cap_after":111,"given":39}'
assert_contains "G zero_sum" "$out" '"zero_sum":true'

# H. Multi-donor even_share, single recipient: draw spans donors lowest-first, buffer respected.
#    d1 cap500 c0 avail500; d2 cap500 c200 floor ceil(200*1.1)=221 avail279. total 779.
#    share floor((779-100)/1)=679, cap 779. Draw d1(500) then d2(279): d2 cap_after 221.
out=$(run_jq '{"recipients":[{"email":"r1@x","consumed":100}],
  "donors":[{"email":"d1@x","cap":500,"consumed":0},{"email":"d2@x","cap":500,"consumed":200}]}')
assert_contains "H cap" "$out" '{"email":"r1@x","consumed":100,"cap":779}'
assert_contains "H d1 drained" "$out" '{"email":"d1@x","cap_before":500,"cap_after":0,"given":500}'
assert_contains "H d2 buffered" "$out" '{"email":"d2@x","cap_before":500,"cap_after":221,"given":279}'
assert_contains "H zero_sum" "$out" '"zero_sum":true'

# I. Default reservation set excludes inactive or non-current-member users.
#    Only active current-member recipients get seeded, and inactive/former donors
#    do not inflate active-member cap reservations.
out=$(run_jq '{"recipients":[
    {"email":"r-active@x","user_id":"email|r-active","consumed":100,"member":true,"active":true},
    {"email":"r-inactive@x","user_id":"email|r-inactive","consumed":50,"member":true,"active":false},
    {"email":"r-former@x","user_id":"email|r-former","consumed":1,"member":false,"active":false}
  ],
  "donors":[
    {"email":"d-active@x","user_id":"email|d-active","cap":500,"consumed":0,"member":true,"active":true},
    {"email":"d-inactive@x","user_id":"email|d-inactive","cap":10000,"consumed":0,"member":true,"active":false},
    {"email":"d-inactive-string@x","user_id":"email|d-inactive-string","cap":10000,"consumed":0,"member":true,"active":"inactive"}
  ]}')
assert_contains "I active recipient capped" "$out" '{"email":"r-active@x","consumed":100,"cap":500,"user_id":"email|r-active"}'
if [[ "$out" == *'"email":"r-inactive@x","consumed":50,"cap"'* ]]; then
  _fail "inactive recipient received cap"
else
  _ok
fi
if [[ "$out" == *'"email":"r-former@x","consumed":1,"cap"'* ]]; then
  _fail "former recipient received cap"
else
  _ok
fi
assert_contains "I inactive recipient audit" "$out" '{"email":"r-inactive@x","user_id":"email|r-inactive","consumed":50,"member":true,"active":false,"reasons":["inactive"]}'
assert_contains "I former recipient audit" "$out" '{"email":"r-former@x","user_id":"email|r-former","consumed":1,"member":false,"active":false,"reasons":["not_current_member","inactive"]}'
assert_contains "I inactive donor audit" "$out" '{"email":"d-inactive@x","user_id":"email|d-inactive","consumed":0,"cap":10000,"member":true,"active":false,"reasons":["inactive"]}'
assert_contains "I inactive string donor audit" "$out" '{"email":"d-inactive-string@x","user_id":"email|d-inactive-string","consumed":0,"cap":10000,"member":true,"active":false,"reasons":["inactive"]}'
assert_contains "I borrowed only active donor" "$out" '"borrowed":500'
assert_contains "I active donor take" "$out" '{"email":"d-active@x","cap_before":500,"cap_after":0,"given":500,"user_id":"email|d-active"}'

report
