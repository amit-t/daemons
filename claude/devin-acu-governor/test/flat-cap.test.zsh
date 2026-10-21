#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/flat-cap.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# 1. Basic flat cap: uncapped active users below the flat get exactly flat_cap.
out=$(run_jq '{"flat_cap":250,"users":[
  {"email":"a@x","consumed":0},
  {"email":"b@x","consumed":100}]}')
assert_contains "basic mode" "$out" '"mode":"flat_cap"'
assert_contains "basic flat echoed" "$out" '"flat_cap":250'
assert_contains "basic capA" "$out" '"email":"a@x","consumed":0,"cap_before":null,"cap":250,"change":"new"'
assert_contains "basic capB" "$out" '"email":"b@x","consumed":100,"cap_before":null,"cap":250,"change":"new"'
assert_contains "basic sum_after" "$out" '"sum_after":500'
assert_contains "basic eligible count" "$out" '"eligible_user_count":2'

# 2. Over-consumer floor: consumed > flat -> cap = ceil(consumed), never below consumption.
out=$(run_jq '{"flat_cap":250,"users":[{"email":"heavy@x","consumed":312.4}]}')
assert_contains "over-consumer cap" "$out" '"cap":313'
assert_contains "over-consumer raised list" "$out" '"raised_above_flat":["heavy@x"]'

# 3. Boundary: consumed == flat stays at flat; a hair over rounds up.
out=$(run_jq '{"flat_cap":250,"users":[{"email":"edge@x","consumed":250},{"email":"edge2@x","consumed":250.1}]}')
assert_contains "boundary exact" "$out" '"email":"edge@x","consumed":250,"cap_before":null,"cap":250'
assert_contains "boundary over" "$out" '"email":"edge2@x","consumed":250.1,"cap_before":null,"cap":251'

# 4. Change classification against existing explicit caps.
out=$(run_jq '{"flat_cap":250,"users":[
  {"email":"down@x","consumed":100,"cap":400},
  {"email":"up@x","consumed":90,"cap":100},
  {"email":"same@x","consumed":10,"cap":250}]}')
assert_contains "reduce row" "$out" '"email":"down@x","consumed":100,"cap_before":400,"cap":250,"change":"reduce"'
assert_contains "raise row" "$out" '"email":"up@x","consumed":90,"cap_before":100,"cap":250,"change":"raise"'
assert_contains "unchanged row" "$out" '"email":"same@x","consumed":10,"cap_before":250,"cap":250,"change":"unchanged"'
if [[ "$out" == *'"email":"same@x","consumed":10,"cap_before":250,"cap":250,"change":"unchanged"'* ]]; then
  # unchanged row must live in "unchanged", not "caps" (no write planned).
  caps_part="${out%%\"unchanged\":*}"
  if [[ "$caps_part" == *'"email":"same@x"'* ]]; then _fail "unchanged user listed in caps write set"; else _ok; fi
fi
# sums: before 400+100+250=750, after 250+250+250=750, delta 0.
assert_contains "sums before" "$out" '"sum_before":750'
assert_contains "sums after" "$out" '"sum_after":750'
assert_contains "sums delta" "$out" '"delta":0'

# 5. user_id passthrough for v3beta1 PATCH targets.
out=$(run_jq '{"flat_cap":250,"users":[{"user_id":"email|a","email":"a@x","consumed":1}]}')
assert_contains "user_id passthrough" "$out" '"user_id":"email|a"'

# 6. Eligibility: inactive / former users get no cap row, audited with reasons.
out=$(run_jq '{"flat_cap":250,"users":[
  {"user_id":"email|ok","email":"ok@x","consumed":10,"member":true,"active":true},
  {"user_id":"email|idle","email":"idle@x","consumed":5,"member":true,"active":false},
  {"user_id":"email|gone","email":"gone@x","consumed":7,"member":false,"active":false}]}')
assert_contains "eligible count excludes" "$out" '"eligible_user_count":1'
if [[ "$out" == *'"email":"idle@x"'*'"change"'* && "$out" == *'"email":"idle@x","consumed":5,"cap'* ]]; then
  _fail "inactive user received cap row"
else
  _ok
fi
assert_contains "inactive audit" "$out" '"email":"idle@x","user_id":"email|idle","consumed":5,"member":true,"active":false,"reasons":["inactive"]'
assert_contains "former audit" "$out" '"email":"gone@x","user_id":"email|gone","consumed":7,"member":false,"active":false,"reasons":["not_current_member","inactive"]'

# 7. Hard rule 11 clamp: flat above max_headroom clamps low consumers to consumed + max_headroom.
out=$(run_jq '{"flat_cap":400,"users":[
  {"email":"zero@x","consumed":0},
  {"email":"mid@x","consumed":200}]}')
assert_contains "clamped zero consumer" "$out" '"email":"zero@x","consumed":0,"cap_before":null,"cap":250'
assert_contains "unclamped mid consumer" "$out" '"email":"mid@x","consumed":200,"cap_before":null,"cap":400'
assert_contains "clamp warning" "$out" 'max_headroom'

# 8. max_headroom hard backstop 500: a larger value is clamped to 500.
out=$(run_jq '{"flat_cap":600,"max_headroom":9999,"users":[{"email":"zero@x","consumed":0}]}')
assert_contains "backstop clamp" "$out" '"cap":500'

# 9. days_left guard: run_rate without top-level days_left -> error, no plan.
out=$(run_jq '{"flat_cap":250,"users":[{"email":"u@x","consumed":100,"run_rate":5}]}')
assert_contains "days guard" "$out" 'days_left missing while user run_rate supplied'

# 10. Projection warning: projected end-of-cycle consumption above the proposed cap.
out=$(run_jq '{"flat_cap":250,"days_left":20,"users":[{"email":"burn@x","consumed":100,"run_rate":30}]}')
assert_contains "projected value" "$out" '"projected":700'
assert_contains "projected warning" "$out" 'burn@x projected 700 ACUs by cycle end exceeds proposed cap 250'

# 11. org_deltas: net explicit-cap movement per billing org, from write rows only.
out=$(run_jq '{"flat_cap":250,"users":[
  {"email":"a@x","consumed":0,"billing_org_id":"orgA"},
  {"email":"b@x","consumed":100,"cap":400,"billing_org_id":"orgB"},
  {"email":"c@x","consumed":10,"cap":250,"billing_org_id":"orgC"}]}')
assert_contains "orgA delta" "$out" '{"org_id":"orgA","delta":250}'
assert_contains "orgB delta" "$out" '{"org_id":"orgB","delta":-150}'
if [[ "$out" == *'"org_id":"orgC"'* ]]; then _fail "unchanged user produced an org delta"; else _ok; fi

# 12. Write row without billing_org_id -> unattributed warning.
out=$(run_jq '{"flat_cap":250,"users":[{"email":"noorg@x","consumed":0}]}')
assert_contains "unattributed warning" "$out" 'noorg@x'
assert_contains "unattributed label" "$out" 'billing_org_id'

# 13. Tight headroom warning: cap within 25 ACUs of consumption.
out=$(run_jq '{"flat_cap":250,"users":[{"email":"tight@x","consumed":240,"billing_org_id":"o"}]}')
assert_contains "tight headroom warning" "$out" 'tight@x'
assert_contains "tight headroom text" "$out" 'within 25 ACUs'

# 14. Errors: bad flat_cap, empty roster, fully ineligible roster.
out=$(run_jq '{"flat_cap":0,"users":[{"email":"a@x","consumed":0}]}')
assert_contains "zero flat error" "$out" '"error"'
out=$(run_jq '{"users":[{"email":"a@x","consumed":0}]}')
assert_contains "missing flat error" "$out" '"error"'
out=$(run_jq '{"flat_cap":250,"users":[]}')
assert_contains "empty roster error" "$out" '"error"'
out=$(run_jq '{"flat_cap":250,"users":[{"email":"a@x","consumed":0,"active":false}]}')
assert_contains "no eligible error" "$out" '"error"'

report
