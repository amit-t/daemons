#!/usr/bin/env zsh
# dag dashboard — org-gate overcommit detection. Even when every member's own
# explicit cap has headroom, the sum of member explicit caps can outstrip the
# org's Local Agent cap — that org gate can still block them. Exercises
# lib/dashboard.jq directly with the same jq invocation lib/dashboard.zsh uses,
# with a minimal fixture set: org-1 (Local Agent cap 100) and two members
# whose explicit caps (80 + 60 = 140) overcommit it by 40.
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
lib="${script_dir}/../lib"
tmp=$(mktemp -d); trap "rm -rf $tmp" EXIT

print -r -- '{"total_acus":0,"consumption_by_date":[]}' > $tmp/ent.json
print -r -- '{"items":[{"org_id":"org-1","name":"Org One","max_session_acu_limit":null,"max_cycle_acu_limit":null}]}' > $tmp/orgs.json
print -r -- '{"org_id":"org-1","daily":{"total_acus":0,"consumption_by_date":[]}}' > $tmp/orgd.json
print -r -- '{"org_id":"org-1","limits":{"local_agent":{"cycle_acu_limit":100}}}' > $tmp/orgl.json
print -r -- '{"items":[{"user_id":"u1","email":"u1@x","name":"U1","role_assignments":[{"org_id":"org-1"}]},{"user_id":"u2","email":"u2@x","name":"U2","role_assignments":[{"org_id":"org-1"}]}]}' > $tmp/users.json
print -r -- '{"user_id":"u1","daily":{"total_acus":0,"consumption_by_date":[]}}' > $tmp/userd.json
print -r -- '{"user_id":"u2","daily":{"total_acus":0,"consumption_by_date":[]}}' >> $tmp/userd.json
print -r -- '{"user_id":"u1","limits":{"local_agent":{"cycle_acu_limit":80,"billing_org_id":"org-1"}}}' > $tmp/userl.json
print -r -- '{"user_id":"u2","limits":{"local_agent":{"cycle_acu_limit":60,"billing_org_id":"org-1"}}}' >> $tmp/userl.json
print -r -- '{}' > $tmp/defaultl.json
print -r -- '{"available":false,"donors":{}}' > $tmp/donorrec.json
print -r -- '{"available":false,"items":[]}' > $tmp/sessions.json
print -r -- '{"available":false,"rows":[]}' > $tmp/modela.json

out=$(jq -c -n --argjson now 1756800000 --argjson pool 24000 \
  --argjson after 1755302400 --argjson before 1757894400 \
  --arg generated_at test --arg refresh_minutes "" \
  --slurpfile ent $tmp/ent.json --slurpfile orgs $tmp/orgs.json \
  --slurpfile orgd $tmp/orgd.json --slurpfile orgl $tmp/orgl.json \
  --slurpfile users $tmp/users.json --slurpfile userd $tmp/userd.json \
  --slurpfile userl $tmp/userl.json --slurpfile defaultl $tmp/defaultl.json \
  --slurpfile donorrec $tmp/donorrec.json --slurpfile sessions $tmp/sessions.json \
  --slurpfile modela $tmp/modela.json -f $lib/dashboard.jq)

assert_contains "org sum caps" "$out" '"sum_explicit_user_caps":140'
assert_contains "org overcommit" "$out" '"user_cap_overcommit":40'
assert_contains "org gate warn" "$out" 'blocked by the org gate'

report
