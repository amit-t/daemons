#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/org-rebalance.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }
field() { print -r -- "$1" | jq -c "$2" }

# A. zero-sum move: recipient R (cap 1000, projected 950) needs 200 of new member
#    room -> shortfall min(200, ceil(950+200-1000)=150) = 150. Donors ranked by
#    surplus: D1 cap 2000, consumed 500 -> floor 750, surplus 1250; D2 cap 400,
#    consumed 100 -> floor 350, surplus 50. D1 gives all 150. Σ unchanged.
out=$(run_jq '{"ceiling":24000,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"cloud_cap":0,"local_consumed":950},
          {"org_id":"d1","name":"D1","local_cap":2000,"cloud_cap":0,"local_consumed":500},
          {"org_id":"d2","name":"D2","local_cap":400,"cloud_cap":0,"local_consumed":100}],
  "needs":[{"org_id":"r","need":200}]}')
assert_eq "A shortfall" 150 "$(field "$out" '.recipients[0].shortfall')"
assert_eq "A recipient cap_after" 1150 "$(field "$out" '.recipients[0].cap_after')"
assert_eq "A donor" '"d1"' "$(field "$out" '.donors[0].org_id')"
assert_eq "A donor cap_after" 1850 "$(field "$out" '.donors[0].cap_after')"
assert_eq "A one donor" 1 "$(field "$out" '.donors | length')"
assert_eq "A sum_before" 3400 "$(field "$out" '.sum_before')"
assert_eq "A sum_after" 3400 "$(field "$out" '.sum_after')"
assert_eq "A zero_sum" true "$(field "$out" '.zero_sum')"
assert_eq "A writes" 2 "$(field "$out" '.writes | length')"
assert_eq "A no warnings" '[]' "$(field "$out" '.warnings')"

# B. org gate already absorbs the need: cap 5000, projected 1000, need 300 -> no move.
out=$(run_jq '{"ceiling":24000,
  "orgs":[{"org_id":"r","name":"R","local_cap":5000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":0}],
  "needs":[{"org_id":"r","need":300}]}')
assert_eq "B shortfall 0" 0 "$(field "$out" '.recipients[0].shortfall')"
assert_eq "B no writes" '[]' "$(field "$out" '.writes')"
assert_eq "B zero_sum" true "$(field "$out" '.zero_sum')"

# C. donors run dry: shortfall 500, only 100 donor surplus; never raises the layer.
#    Remainder unfunded (org gate is the brake), Σ unchanged.
out=$(run_jq '{"ceiling":24000,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":450,"local_consumed":100}],
  "needs":[{"org_id":"r","need":500}]}')
assert_eq "C from_donors" 100 "$(field "$out" '.recipients[0].from_donors')"
assert_eq "C unfunded" 400 "$(field "$out" '.recipients[0].unfunded')"
assert_eq "C cap_after" 1100 "$(field "$out" '.recipients[0].cap_after')"
assert_eq "C sum unchanged" true "$(field "$out" '.sum_after == .sum_before')"
assert_contains "C unfunded warning" "$out" 'R: 400 ACUs of new member room unfunded at org level'

# D. use_slack only on request, and never past the ceiling.
#    Σ before 1450 + cloud 0, ceiling 1500 -> slack 50.
out=$(run_jq '{"ceiling":1500,"use_slack":true,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":450,"local_consumed":100}],
  "needs":[{"org_id":"r","need":500}]}')
assert_eq "D slack" 50 "$(field "$out" '.ceiling_slack')"
assert_eq "D from_slack" 50 "$(field "$out" '.recipients[0].from_slack')"
assert_eq "D unfunded" 350 "$(field "$out" '.recipients[0].unfunded')"
assert_eq "D sum_after = ceiling" 1500 "$(field "$out" '.sum_after')"
assert_eq "D not zero_sum" false "$(field "$out" '.zero_sum')"

# E. layer already over the ceiling (parent mirror doubling it): no slack even
#    when requested, warning names the overage; cloud caps count in Σ.
out=$(run_jq '{"ceiling":24000,"use_slack":true,
  "orgs":[{"org_id":"v","name":"Vontier","local_cap":23998,"cloud_cap":100,"local_consumed":1700},
          {"org_id":"i","name":"ICS","local_cap":13608,"cloud_cap":100,"local_consumed":13600},
          {"org_id":"p","name":"Passport","local_cap":10390,"cloud_cap":0,"local_consumed":976}],
  "needs":[{"org_id":"i","need":250}]}')
assert_eq "E sum_before" 48196 "$(field "$out" '.sum_before')"
assert_eq "E over" true "$(field "$out" '.over_ceiling')"
assert_eq "E overage" 24196 "$(field "$out" '.overage')"
assert_eq "E slack 0" 0 "$(field "$out" '.ceiling_slack')"
assert_eq "E zero_sum" true "$(field "$out" '.zero_sum')"
assert_eq "E funded by parent-as-donor" '"v"' "$(field "$out" '.donors[0].org_id')"
assert_contains "E overage warning" "$out" 'org layer already exceeds the ceiling: Σ org caps 48196 > 24000'

# F. donor floor uses projection: D consumed 100, run_rate 50, 10 days -> projected 600,
#    floor 850, cap 900 -> surplus 50 only.
out=$(run_jq '{"ceiling":24000,"days_left":10,
  "orgs":[{"org_id":"r","name":"R","local_cap":100,"local_consumed":100},
          {"org_id":"d","name":"D","local_cap":900,"local_consumed":100,"run_rate":50}],
  "needs":[{"org_id":"r","need":200}]}')
assert_eq "F donor floor" 850 "$(field "$out" '.donors[0].floor')"
assert_eq "F given" 50 "$(field "$out" '.donors[0].given')"

# G. uncapped recipient needs no move; uncapped org blocks slack + warns.
out=$(run_jq '{"ceiling":24000,"use_slack":true,
  "orgs":[{"org_id":"r","name":"R","local_cap":null,"local_consumed":10},
          {"org_id":"d","name":"D","local_cap":500,"local_consumed":0}],
  "needs":[{"org_id":"r","need":200}]}')
assert_eq "G no recipients" '[]' "$(field "$out" '.recipients')"
assert_eq "G slack 0" 0 "$(field "$out" '.ceiling_slack')"
assert_contains "G uncapped warning" "$out" 'uncapped org(s) have no Local Agent gate'
assert_contains "G no-move note" "$out" 'org r has no explicit Local Agent cap'

# H. multiple recipients share donors; needs for the same org aggregate; negatives ignored.
out=$(run_jq '{"ceiling":24000,"min_donor_headroom":0,
  "orgs":[{"org_id":"a","name":"A","local_cap":100,"local_consumed":100},
          {"org_id":"b","name":"B","local_cap":100,"local_consumed":100},
          {"org_id":"d","name":"D","local_cap":150,"local_consumed":0}],
  "needs":[{"org_id":"a","need":60},{"org_id":"a","need":40},{"org_id":"b","need":80},{"org_id":"d","need":-30}]}')
assert_eq "H a need" 100 "$(field "$out" '[.recipients[] | select(.org_id=="a")][0].need')"
assert_eq "H a funded first" 100 "$(field "$out" '[.recipients[] | select(.org_id=="a")][0].from_donors')"
assert_eq "H b partial" 50 "$(field "$out" '[.recipients[] | select(.org_id=="b")][0].from_donors')"
assert_eq "H donor drained" 0 "$(field "$out" '.donors[0].cap_after')"
assert_eq "H zero_sum" true "$(field "$out" '.zero_sum')"

# I. min_donor_headroom clamps to 500; bad ceiling errors.
out=$(run_jq '{"ceiling":24000,"min_donor_headroom":9000,"orgs":[],"needs":[]}')
assert_eq "I empty writes" '[]' "$(field "$out" '.writes')"
out=$(run_jq '{"ceiling":0,"orgs":[],"needs":[]}')
assert_contains "I error" "$out" '"error":"ceiling must be positive"'

# H. slack_only: donors untouched, funding purely from ceiling slack.
#    Σ before 1450, ceiling 2000 -> slack 550; need 500 fully slack-funded.
out=$(run_jq '{"ceiling":2000,"slack_only":true,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":450,"local_consumed":100}],
  "needs":[{"org_id":"r","need":500}]}')
assert_eq "H slack_only echoed" true "$(field "$out" '.slack_only')"
assert_eq "H no donors" '[]' "$(field "$out" '.donors')"
assert_eq "H from_slack" 500 "$(field "$out" '.recipients[0].from_slack')"
assert_eq "H from_donors" 0 "$(field "$out" '.recipients[0].from_donors')"
assert_eq "H cap_after" 1500 "$(field "$out" '.recipients[0].cap_after')"
assert_eq "H sum_after" 1950 "$(field "$out" '.sum_after')"
assert_eq "H zero_sum" false "$(field "$out" '.zero_sum')"
assert_eq "H one write" 1 "$(field "$out" '.writes | length')"

# I. slack_only never passes the ceiling: slack 50 < need 500 -> 450 unfunded.
out=$(run_jq '{"ceiling":1500,"slack_only":true,
  "orgs":[{"org_id":"r","name":"R","local_cap":1000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":450,"local_consumed":100}],
  "needs":[{"org_id":"r","need":500}]}')
assert_eq "I from_slack" 50 "$(field "$out" '.recipients[0].from_slack')"
assert_eq "I unfunded" 450 "$(field "$out" '.recipients[0].unfunded')"
assert_eq "I sum_after = ceiling" 1500 "$(field "$out" '.sum_after')"

# J. auto-need: projected 1000 (consumed 1000, no run_rate), cap 900,
#    target_headroom default 250 -> need = 1000 + 250 - 900 = 350.
out=$(run_jq '{"ceiling":24000,"min_donor_headroom":250,
  "orgs":[{"org_id":"r","name":"R","local_cap":900,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "J auto need" 350 "$(field "$out" '.recipients[0].need')"
assert_eq "J cap_after" 1250 "$(field "$out" '.recipients[0].cap_after')"

# K. auto-need already satisfied: cap 2000 >= projected 1000 + 250 -> need 0, no recipient row, no writes.
out=$(run_jq '{"ceiling":24000,
  "orgs":[{"org_id":"r","name":"R","local_cap":2000,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "K no recipients" '[]' "$(field "$out" '.recipients')"
assert_eq "K no writes" '[]' "$(field "$out" '.writes')"

# L. target_headroom clamps at 500 (hard rule 11): 900 -> 500; need = 1000+500-900 = 600.
out=$(run_jq '{"ceiling":24000,"target_headroom":900,
  "orgs":[{"org_id":"r","name":"R","local_cap":900,"local_consumed":1000},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "L clamped need" 600 "$(field "$out" '.recipients[0].need')"

# M. auto-need with run_rate: projected = 100 + 10*5 = 150, cap 100 -> need 150+250-100 = 300.
out=$(run_jq '{"ceiling":24000,"days_left":5,
  "orgs":[{"org_id":"r","name":"R","local_cap":100,"local_consumed":100,"run_rate":10},
          {"org_id":"d","name":"D","local_cap":5000,"local_consumed":500}],
  "needs":[{"org_id":"r","need":"auto"}]}')
assert_eq "M forecast need" 300 "$(field "$out" '.recipients[0].need')"

report
