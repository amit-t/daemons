#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
jqf="${script_dir}/../lib/compute-caps.jq"

run_jq() { print -r -- "$1" | jq -c -f "$jqf" }

# 1. Day-1: nothing consumed -> team_level flat split, floor(pool/N).
out=$(run_jq '{"pool":24000,"users":[{"email":"a@x","consumed":0},{"email":"b@x","consumed":0}]}')
assert_contains "day1 mode" "$out" '"mode":"team_level"'
assert_contains "day1 flat" "$out" '"flat_cap":12000'

# 2. Mid-month remaining-pool split: pool 1000, consumed 100+300=400, remaining 600,
#    share floor(600/2)=300 -> caps 400 and 600. sum_caps=1000 <= pool.
out=$(run_jq '{"pool":1000,"users":[{"email":"a@x","consumed":100},{"email":"b@x","consumed":300}]}')
assert_contains "mid mode" "$out" '"mode":"per_user"'
assert_contains "mid capA" "$out" '{"email":"a@x","consumed":100,"cap":400}'
assert_contains "mid capB" "$out" '{"email":"b@x","consumed":300,"cap":600}'

# 2b. User IDs pass through for v3beta1 per-user PATCH targets.
out=$(run_jq '{"pool":1000,"users":[{"user_id":"email|a","email":"a@x","consumed":100},{"user_id":"email|b","email":"b@x","consumed":300}]}')
assert_contains "user id A passthrough" "$out" '"user_id":"email|a"'
assert_contains "user id B passthrough" "$out" '"user_id":"email|b"'
assert_contains "mid sum" "$out" '"sum_caps":1000'

# 3. Fractional consumption rounds: floor(consumed)+share keeps sum<=pool.
#    pool 1000, consumed 100.7+300.9=401.6, remaining 598.4, share=floor(299.2)=299
#    caps: floor(100.7)+299=399, floor(300.9)+299=599 -> sum 998 <= 1000.
out=$(run_jq '{"pool":1000,"users":[{"email":"a@x","consumed":100.7},{"email":"b@x","consumed":300.9}]}')
assert_contains "frac capA" "$out" '"cap":399'
assert_contains "frac capB" "$out" '"cap":599'
assert_contains "frac sum" "$out" '"sum_caps":998'

# 4. Single user gets whole remainder.
out=$(run_jq '{"pool":500,"users":[{"email":"a@x","consumed":100}]}')
assert_contains "single cap" "$out" '"cap":500'

# 5. Overconsumed pool: remaining <= 0 -> freeze at ceil(consumed), warn.
out=$(run_jq '{"pool":300,"users":[{"email":"a@x","consumed":150.2},{"email":"b@x","consumed":200}]}')
assert_contains "over warn" "$out" 'pool exhausted'
assert_contains "over capA" "$out" '"cap":151'
assert_contains "over capB" "$out" '"cap":200'

# 6. share == 0 (remaining < N): freeze + warn.
out=$(run_jq '{"pool":401,"users":[{"email":"a@x","consumed":200},{"email":"b@x","consumed":200}]}')
assert_contains "tiny warn" "$out" 'smaller than team size'

# 7. Empty roster -> error object.
out=$(run_jq '{"pool":1000,"users":[]}')
assert_contains "empty" "$out" '"error"'

# 8. Default reservation set excludes inactive or non-current-member users.
#    Only active current members consume/reserve pool share. Former/inactive users
#    are surfaced for audit, but receive no cap row.
out=$(run_jq '{"pool":1000,"users":[
  {"user_id":"email|active","email":"active@x","consumed":100,"member":true,"active":true},
  {"user_id":"email|inactive","email":"inactive@x","consumed":300,"member":true,"active":false},
  {"user_id":"email|inactive-string","email":"inactive-string@x","consumed":50,"member":true,"active":"inactive"},
  {"user_id":"email|former","email":"former@x","consumed":400,"member":false,"active":false}
]}')
assert_contains "active-only count" "$out" '"eligible_user_count":1'
assert_contains "active-only cap" "$out" '{"email":"active@x","consumed":100,"user_id":"email|active","cap":1000}'
if [[ "$out" == *'"email":"inactive@x","consumed":300,"user_id":"email|inactive","cap"'* ]]; then
  _fail "inactive user received cap"
else
  _ok
fi
if [[ "$out" == *'"email":"former@x","consumed":400,"user_id":"email|former","cap"'* ]]; then
  _fail "former user received cap"
else
  _ok
fi
if [[ "$out" == *'"email":"inactive-string@x","consumed":50,"user_id":"email|inactive-string","cap"'* ]]; then
  _fail "inactive status string user received cap"
else
  _ok
fi
assert_contains "inactive excluded audit" "$out" '{"email":"inactive@x","user_id":"email|inactive","consumed":300,"member":true,"active":false,"reasons":["inactive"]}'
assert_contains "inactive string excluded audit" "$out" '{"email":"inactive-string@x","user_id":"email|inactive-string","consumed":50,"member":true,"active":false,"reasons":["inactive"]}'
assert_contains "former excluded audit" "$out" '{"email":"former@x","user_id":"email|former","consumed":400,"member":false,"active":false,"reasons":["not_current_member","inactive"]}'

report
