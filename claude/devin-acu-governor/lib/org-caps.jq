# Org-level Local Agent cap distribution for dag slg.
# Recommend an explicit org-level local_agent.cycle_acu_limit for EVERY billing
# org, distributing a fixed pool proportionally to current-cycle Local Agent
# consumption. Unlike borrow-caps.jq (zero-sum seeding of uncapped orgs), this
# replans the whole org layer: Σ proposed caps never exceeds the pool.
#
# Input:
# {
#   "pool": <number>,                 # DAG_MONTHLY_ACU_POOL — hard budget for Σ org caps
#   "min_headroom": <number=250>,     # guaranteed headroom above consumed for every org;
#                                     # also the whole floor for idle orgs (consumed 0).
#                                     # Hard-clamped to 500 (policy hard rule 11 analogue).
#   "days_left": <number=0>,          # cycle days left, for run-rate projection warnings
#   "orgs": [{"org_id","name","local_consumed","run_rate"?,"cap_before"?}, ...]
#                                     # local_consumed = cycle cascade+terminal ACUs;
#                                     # run_rate = last-7d Local Agent ACUs/day;
#                                     # cap_before = current explicit cap or null
# }
#
# Output:
# {
#   mode: "prorated" | "even",        # even when every org's local_consumed is 0
#   pool, min_headroom, days_left,
#   proposed: [{org_id, name, consumed, run_rate, projected,
#               cap_before, cap_after, headroom, delta}],   # sorted -consumed, name
#   sum_before,                       # Σ existing explicit caps (nulls ignored)
#   sum_after,                        # Σ proposed caps — always <= pool
#   unallocated,                      # pool - sum_after (rounding slack, stays unspent)
#   warnings: [ ... ]                 # e.g. proposed cap below run-rate projection
# }  or  {error, ...} when the pool cannot cover every org's floor.
#
# Algorithm: floor_i = ceil(consumed_i) + min_headroom (never below current burn,
# so no org is insta-blocked). surplus = pool - Σ floors, split by consumption
# share (evenly when all idle). Integer floors on shares leave a small
# unallocated remainder — reported, never silently spent.

def ceil_(x): (x | floor) as $f | if x == $f then $f else $f + 1 end;
def r2: (. * 100 | round) / 100;

(.pool // 0) as $pool
| ([((.min_headroom // 250) | floor), 500] | min) as $mh
| (if $mh < 0 then 0 else $mh end) as $mh
| (.days_left // 0) as $days_left
| (.orgs // []) as $orgs
| if ($orgs | length) == 0 then {error: "no orgs supplied"}
  elif $pool <= 0 then {error: "pool must be positive", pool: $pool}
  else
    ($orgs | map({
        org_id,
        name: (.name // .org_id),
        consumed: ((.local_consumed // 0) | r2),
        run_rate: ((.run_rate // 0) | r2),
        cap_before: (.cap_before // null)
      }
      | .projected = ((.consumed + .run_rate * $days_left) | r2)
      | .floor = (ceil_(.consumed) + $mh))) as $rows
    | ([$rows[].floor] | add) as $sum_floors
    | if $sum_floors > $pool
      then {error: "pool cannot cover every org's floor (consumed + min_headroom)",
            pool: $pool, min_headroom: $mh, sum_floors: $sum_floors,
            shortfall: ($sum_floors - $pool)}
      else
        ($pool - $sum_floors) as $surplus
        | ([$rows[].consumed] | add) as $sum_consumed
        | (if $sum_consumed > 0 then "prorated" else "even" end) as $mode
        | ($rows | map(
            .extra = (if $mode == "prorated"
                      then (($surplus * .consumed / $sum_consumed) | floor)
                      else (($surplus / ($rows | length)) | floor) end)
            | .cap_after = (.floor + .extra)
            | .headroom = ((.cap_after - .consumed) | r2)
            | .delta = (if .cap_before == null then null else .cap_after - .cap_before end))) as $planned
        | ($planned | sort_by(-.consumed, .name)) as $sorted
        | {
            mode: $mode,
            pool: $pool,
            min_headroom: $mh,
            days_left: $days_left,
            proposed: ($sorted | map({org_id, name, consumed, run_rate, projected,
                                      cap_before, cap_after, headroom, delta})),
            sum_before: ([$sorted[].cap_before | select(. != null)] | add // 0),
            sum_after: ([$sorted[].cap_after] | add),
            unallocated: ($pool - ([$sorted[].cap_after] | add)),
            warnings: ([$sorted[]
              | select(.projected > .cap_after)
              | "\(.name) projected \(.projected) ACUs by cycle end exceeds proposed cap \(.cap_after) — it will hit the org gate early; consider raising min_headroom or accepting the brake"])
          }
      end
  end
