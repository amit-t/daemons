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
out=$(run_jq '{"pool":1000,"share":250,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
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
out=$(run_jq '{"pool":1000,"share":250,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":200,"consumed":180,"run_rate":20,"days_left":10},
  "donors":[{"email":"d1@x","cap":100,"consumed":80},{"email":"d2@x","cap":250,"consumed":200}]}')
assert_contains "B delta" "$out" '"delta":237'
assert_contains "B funded" "$out" '"funded":25'
assert_contains "B shortfall" "$out" '"shortfall":212'
assert_contains "B recip after" "$out" '"cap_after":225'
assert_contains "B warn" "$out" 'can only fund'

# C. Explicit delta override ignores projection.
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":200,"consumed":100,"run_rate":5,"days_left":4,"delta_override":30},
  "donors":[{"email":"d1@x","cap":300,"consumed":50}]}')
assert_contains "C recommended" "$out" '"recommended_cap":230'
assert_contains "C delta" "$out" '"delta":30'
assert_contains "C take" "$out" '"given":30'
assert_contains "C recip after" "$out" '"cap_after":230'

# D. No boost needed: projection below current cap -> delta 0, no donors touched.
out=$(run_jq '{"pool":1000,"share":250,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
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
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":0,"consumed":0,"run_rate":0,"days_left":1,"delta_override":50},
  "donors":[{"email":"low@x","cap":19,"consumed":0},{"email":"skim@x","cap":51,"consumed":0},{"email":"high@x","cap":100,"consumed":0}]}')
assert_contains "E funded" "$out" '"funded":50'
takes=$(print -r -- "$out" | jq -c '.takes')
assert_eq "E uses only high-headroom donor" '[{"email":"high@x","cap_before":100,"cap_after":50,"given":50}]' "$takes"

# F. Remainder-aware donor safety: do not leave a sub-min-give shortfall when
#    another high-headroom donor can cover it by taking less from the current donor.
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":0,"consumed":0,"run_rate":0,"days_left":1,"delta_override":50},
  "donors":[{"email":"d1@x","cap":55,"consumed":0},{"email":"d2@x","cap":57,"consumed":0},{"email":"d3@x","cap":57,"consumed":0},{"email":"d4@x","cap":62,"consumed":0},{"email":"d5@x","cap":56,"consumed":0},{"email":"d6@x","cap":61,"consumed":0},{"email":"d7@x","cap":64,"consumed":0}]}')
assert_contains "F fully funded" "$out" '"funded":50'
assert_contains "F no shortfall" "$out" '"shortfall":0'
assert_contains "F recipient full cap" "$out" '"cap_after":50'
takes=$(print -r -- "$out" | jq -c '[.takes[].given]')
assert_eq "F no donor below min give" '[5,7,7,12,6,8,5]' "$takes"

# G. Headroom ceiling: projection-driven recommendation clamped at consumed + 500.
#    consumed 100, run_rate 100, days_left 10 -> projected 1100, raw rec ceil(1100*1.15)=1265,
#    clamped to 100+500=600. delta 400, d1 floor max(ceil(10+50),50)=60 -> avail 940, funds all.
out=$(run_jq '{"pool":2000,"share":500,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":200,"consumed":100,"run_rate":100,"days_left":10},
  "donors":[{"email":"d1@x","cap":1000,"consumed":10}]}')
assert_contains "G clamped recommended" "$out" '"recommended_cap":600'
assert_contains "G max_headroom" "$out" '"max_headroom":500'
assert_contains "G delta" "$out" '"delta":400'
assert_contains "G clamp warning" "$out" 'direct-headroom ceiling'
assert_contains "G clamp warning value" "$out" 'clamped to 600'
assert_contains "G recip after" "$out" '"cap_after":600'

# H. delta_override is clamped too, with a warning.
#    cap 200 + override 900 = 1100 -> clamped to consumed(100)+500=600. delta 400.
out=$(run_jq '{"pool":2000,"share":500,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":200,"consumed":100,"run_rate":1,"days_left":10,"delta_override":900},
  "donors":[{"email":"d1@x","cap":1000,"consumed":10}]}')
assert_contains "H clamped recommended" "$out" '"recommended_cap":600'
assert_contains "H delta" "$out" '"delta":400'
assert_contains "H clamp warning" "$out" 'clamped to 600'
assert_contains "H recip after" "$out" '"cap_after":600'

# I. Clamp with no delta: cap already above the ceiling -> delta 0, no donors touched,
#    clamp warning still surfaces the policy.
out=$(run_jq '{"pool":2000,"share":500,"recipient_buffer":0.15,"donor_buffer":0.10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":700,"consumed":100,"run_rate":100,"days_left":10},
  "donors":[{"email":"d1@x","cap":1000,"consumed":10}]}')
assert_contains "I clamped recommended" "$out" '"recommended_cap":600'
assert_contains "I delta zero" "$out" '"delta":0'
assert_contains "I takes empty" "$out" '"takes":[]'
assert_contains "I clamp warning" "$out" 'direct-headroom ceiling'

# J. Donor run_rate protection + surplus-first ranking.
#    days_left 10. burner: cap 500, consumed 20, run_rate 40 -> projected 420,
#    floor max(max(ceil(20+20),50)=50, ceil(420*1.1)=462)=462 -> avail 38.
#    idle: cap 300, consumed 50, run_rate 0 -> floor max(ceil(70),50)=70 -> avail 230.
#    run_rate present -> rank by highest available: idle funds the whole 100; burner untouched.
out=$(run_jq '{"pool":1000,"share":200,"recipient_buffer":0.15,"donor_buffer":0.10,"days_left":10,"min_donor_headroom":0,"require_forecast":false,
  "recipient":{"email":"r@x","cap":100,"consumed":100,"run_rate":0,"days_left":10,"delta_override":100},
  "donors":[{"email":"burner@x","cap":500,"consumed":20,"run_rate":40},{"email":"idle@x","cap":300,"consumed":50,"run_rate":0}]}')
assert_contains "J funded" "$out" '"funded":100'
takes=$(print -r -- "$out" | jq -c '.takes')
assert_eq "J idle-first, burner protected" '[{"email":"idle@x","cap_before":300,"cap_after":200,"given":100}]' "$takes"

# N1. Donor headroom floor: donor consumed 45, cap 150, share 100.
#     floor = max(ceil(45+0.1*100)=55, ceil(45)+25=70, 50) = 70 -> avail 80, not 95.
#     delta_override 200 > avail, so the donor is drained exactly to its floor (70).
out=$(run_jq '{"pool":1000,"share":100,"require_forecast":false,
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":5,"days_left":10,"delta_override":200},
  "donors":[{"email":"d1@x","cap":150,"consumed":45}]}')
assert_contains "N1 floor 70" "$out" '"cap_after":70'
assert_contains "N1 min_donor_headroom" "$out" '"min_donor_headroom":25'

# N2. days_left guard: donor run_rate present, no days_left anywhere = error.
out=$(run_jq '{"pool":1000,"share":100,
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":5},
  "donors":[{"email":"d1@x","cap":150,"consumed":10,"run_rate":2}]}')
assert_contains "N2 error" "$out" 'days_left missing while donor run_rate supplied'

# N3. require_forecast default: run_rate-less donor excluded and named.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":5,"days_left":10},
  "donors":[{"email":"d-blind@x","cap":500,"consumed":0},
            {"email":"d-fc@x","cap":500,"consumed":0,"run_rate":0}]}')
assert_contains "N3 excluded list" "$out" '"donors_excluded_no_forecast":["d-blind@x"]'
assert_contains "N3 warn" "$out" 'excluded: no run_rate forecast'
assert_contains "N3 fc donor gives" "$out" '"email":"d-fc@x"'

# F1. Forecast-first: enterprise projected 3546 under pool, utilization 0.5
#     -> forecast_headroom 1773 fully funds delta; NO donor is cut.
out=$(run_jq '{"pool":24000,"share":100,"days_left":10,"require_forecast":false,
  "forecast":{"pool":24000,"projected_cycle_total":20454},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":8,"days_left":10,"delta_override":150},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F1 headroom" "$out" '"forecast_headroom":1773'
assert_contains "F1 funded" "$out" '"forecast_funded":150'
assert_contains "F1 no donor cut" "$out" '"takes":[]'
assert_contains "F1 not zero-sum" "$out" '"zero_sum":false'
assert_contains "F1 recipient" "$out" '"cap_after":250'
assert_contains "F1 warn" "$out" 'funded from enterprise forecast headroom'

# F2. Split funding: forecast covers 40, donors the rest.
#     utilization 0.5 on (1000-920)=80 -> headroom 40; delta 100 -> donors give 60.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":1000,"projected_cycle_total":920},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10,"delta_override":100},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F2 headroom" "$out" '"forecast_headroom":40'
assert_contains "F2 fc funded" "$out" '"forecast_funded":40'
assert_contains "F2 donor funded" "$out" '"donor_funded":60'
assert_contains "F2 donor take" "$out" '"given":60'

# F3. Projected OVER pool: headroom 0, behavior identical to zero-sum.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":1000,"projected_cycle_total":1200},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10,"delta_override":50},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F3 headroom 0" "$out" '"forecast_headroom":0'
assert_contains "F3 zero-sum" "$out" '"zero_sum":true'

# F4. Malformed forecast input.
out=$(run_jq '{"pool":1000,"share":100,"forecast":{"pool":1000},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10},"donors":[]}')
assert_contains "F4 error" "$out" '"error":"forecast requires pool and projected_cycle_total"'

# F5. Shared-budget clamp: computed headroom 1773 but remaining budget 30
#     -> forecast_headroom 30, forecast_funded 30, donors fund the rest (delta 150).
out=$(run_jq '{"pool":24000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":24000,"projected_cycle_total":20454,"remaining":30},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":8,"days_left":10,"delta_override":150},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F5 clamped headroom" "$out" '"forecast_headroom":30'
assert_contains "F5 fc funded 30" "$out" '"forecast_funded":30'
assert_contains "F5 donor funded 120" "$out" '"donor_funded":120'

# F6. Negative remaining must floor at 0, not go negative (would overdraw donors
#     and vanish ACUs from Σ caps). Same fixture as F5 but remaining:-10.
out=$(run_jq '{"pool":24000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":24000,"projected_cycle_total":20454,"remaining":-10},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":8,"days_left":10,"delta_override":150},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F6 headroom floored at 0" "$out" '"forecast_headroom":0'
assert_contains "F6 fc funded 0" "$out" '"forecast_funded":0'
assert_contains "F6 donor funded 150" "$out" '"donor_funded":150'

# FW1. Shortfall warning names donor_funded, not the forecast+donor combined total,
#      and separately calls out the forecast contribution when forecast_funded > 0.
#      forecast headroom 40 (pool 1000, projected 920, util 0.5); recipient delta 200
#      (delta_override); donor d1 cap 60 consumed 0 -> floor 50, avail 10, gives 10.
#      forecast_funded 40, donor_funded 10, funded 50, shortfall 150.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":1000,"projected_cycle_total":920},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10,"delta_override":200},
  "donors":[{"email":"d1@x","cap":60,"consumed":0}]}')
assert_contains "FW1 forecast_funded" "$out" '"forecast_funded":40'
assert_contains "FW1 donor_funded" "$out" '"donor_funded":10'
assert_contains "FW1 funded" "$out" '"funded":50'
assert_contains "FW1 shortfall" "$out" '"shortfall":150'
assert_contains "FW1 warn names donor_funded" "$out" 'donors can only fund 10 of 200'
assert_contains "FW1 warn notes forecast separately" "$out" '40 ACUs of that came from forecast headroom separately'

report
