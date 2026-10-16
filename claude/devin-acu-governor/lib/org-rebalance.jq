# Zero-sum org-gate rebalance for the boost family (hard rule 15).
# After a confirmed user-cap write, the orgs whose members gained cap may need
# more org-gate room. This planner MOVES org Local Agent cap from donor orgs
# with projected-safe surplus to those orgs. It never grows the org layer:
# Σ org caps stays at sum_before (zero-sum), and never ends above `ceiling`
# (DAG_MONTHLY_ACU_POOL) unless it already started above it. Whatever cannot
# be funded is reported as `unfunded` — the org gate is the intended brake.
#
# Org consumption attribution is disjoint (each ACU bills to exactly one org;
# Σ per-org consumption == enterprise total), and each org gate caps only the
# usage billed to that org. So the real enterprise ceiling is Σ of EVERY org's
# caps, parent/umbrella org included — there is no org hierarchy.
#
# Input:
# {
#   "ceiling": <number>,              # DAG_MONTHLY_ACU_POOL — hard max for Σ org caps
#   "min_donor_headroom": <n=250>,    # donor keeps cap >= ceil(max(consumed, projected)) + this;
#                                     # clamped to [0, 500]
#   "days_left": <number=0>,
#   "use_slack": <bool=false>,        # fund the remainder from (ceiling - sum_before)
#                                     # only on explicit in-session request (not zero-sum)
#   "slack_only": <bool=false>,       # donors give nothing (every donor surplus treated as 0);
#                                     # funding comes only from ceiling slack. Implies slack use
#                                     # regardless of use_slack. Echoed in output as `slack_only`.
#   "target_headroom": <n=250>,       # used only by need:"auto"; clamped to [0, 500]
#   "full_shortfall": <bool=false>,   # numeric needs fund in full: the shortfall portion
#                                     # equals the need itself (like auto needs), skipping
#                                     # the absorb formula. For explicit operator requests
#                                     # (dag org-cap) where the asked-for cap must be
#                                     # reached or the gap reported.
#   "orgs": [{"org_id","name","local_cap","cloud_cap"?,"local_consumed","run_rate"?}],
#                                     # local_cap/cloud_cap: explicit cap or null (unset = unlimited)
#   "needs": [{"org_id","need"}]      # net member-cap growth this run, per billing org.
#                                     # Numeric entries aggregate per org; non-numeric,
#                                     # non-"auto" values are ignored. need may be "auto":
#                                     # resolved per org as
#                                     #   max(0, ceil(projected) + target_headroom - cap_before)
#                                     # (projected = consumed + run_rate * days_left). A resolved
#                                     # need of 0 yields no recipient row. An auto entry for an
#                                     # org_id not in `orgs`, or for an uncapped org (local_cap
#                                     # null), is dropped.
# }
#
# Output:
# { ceiling, slack_only, sum_before, sum_after, zero_sum, over_ceiling, overage,
#   uncapped_orgs, ceiling_slack, slack_used,
#   recipients: [{org_id, name, cap_before, consumed, projected, need,
#                 shortfall, from_donors, from_slack, unfunded, cap_after}],
#   donors: [{org_id, name, cap_before, consumed, projected, floor, surplus,
#             given, cap_after}],                    # only donors that gave
#   writes: [{org_id, name, cap_before, cap_after}], # every changed org
#   warnings: [...] }
#
# Σ org caps = Σ explicit local_cap + Σ explicit cloud_cap over all orgs.
# Recipient shortfall, numeric portion = min(num, max(0, ceil(projected + num - local_cap))):
# only the part of the new member room the org gate cannot already absorb.
# With full_shortfall:true the numeric portion is the need itself instead.
# An auto-resolved need is already the gap to the target cap, so its shortfall
# portion equals the need itself. An org with both kinds adds the two portions.

def ceil_(x): (x | floor) as $f | if x == $f then $f else $f + 1 end;
def r2: (. * 100 | round) / 100;
def clamp(lo; hi): if . < lo then lo elif . > hi then hi else . end;

(.ceiling // 0) as $ceiling
| ((.min_donor_headroom // 250) | floor | clamp(0; 500)) as $mdh
| (.days_left // 0) as $days_left
| (.slack_only // false) as $slack_only
| ((.use_slack // false) or $slack_only) as $use_slack
| ((.target_headroom // 250) | floor | clamp(0; 500)) as $th
| (.full_shortfall // false) as $full
| (.orgs // []) as $orgs_in
| (reduce ((.needs // [])[] | select((.need | type) == "number" and .need > 0)) as $n
    ({}; .[$n.org_id] = ((.[$n.org_id] // 0) + ($n.need | ceil_(.))))) as $needs_num
| ([(.needs // [])[] | select(.need == "auto") | .org_id] | unique) as $auto_ids
| if $ceiling <= 0 then {error: "ceiling must be positive", ceiling: $ceiling}
  else
    ($orgs_in | map({
        org_id,
        name: (.name // .org_id),
        cap_before: .local_cap,
        cloud_cap: (.cloud_cap // null),
        consumed: ((.local_consumed // 0) | r2),
        run_rate: ((.run_rate // 0) | r2)
      }
      | .projected = ((.consumed + .run_rate * $days_left) | r2))) as $orgs
    | (reduce ($orgs[] | select(.org_id as $id | $auto_ids | index($id))
                       | select(.cap_before != null)) as $o
         ({};
          ([ceil_($o.projected) + $th - $o.cap_before, 0] | max) as $auto
          | if $auto > 0 then .[$o.org_id] = $auto else . end)) as $needs_auto
    | (reduce (($needs_num | to_entries) + ($needs_auto | to_entries))[] as $e
         ({}; .[$e.key] = ((.[$e.key] // 0) + $e.value))) as $needs
    | ([$orgs[] | (.cap_before // 0) + (.cloud_cap // 0)] | add // 0) as $sum_before
    | ([$orgs[] | select(.cap_before == null) | .name]) as $uncapped
    | (if ($uncapped | length) > 0 then 0
       else ([($ceiling - $sum_before), 0] | max) end) as $slack
    | ($orgs
       | map(select($needs[.org_id] != null and .cap_before != null)
             | ($needs_num[.org_id] // 0) as $num
             | ($needs_auto[.org_id] // 0) as $auto
             | .need = ($num + $auto)
             # Numeric growth only needs what the gate cannot absorb; an auto
             # need is already the gap to the target cap, so it funds in full.
             # full_shortfall makes numeric needs fund in full too.
             | .shortfall = ((if $full then $num
                              else ([$num, ([ceil_(.projected + $num - .cap_before), 0] | max)] | min) end) + $auto))
       | sort_by(-.shortfall, .name)) as $recips
    | ([$recips[].org_id]) as $recip_ids
    | (if $slack_only then [] else $orgs end
       | map(select(.cap_before != null and (.org_id as $id | $recip_ids | index($id) | not))
             | .floor = (ceil_([.consumed, .projected] | max) + $mdh)
             | .surplus = ([.cap_before - .floor, 0] | max))
       | sort_by(-.surplus, .consumed, .name)) as $donor_pool
    # Greedy: each recipient (largest shortfall first) drains donors in order.
    | (reduce $recips[] as $r
        ({donors: $donor_pool, slack: $slack, out: []};
         ($r.shortfall) as $want
         | (reduce range(0; (.donors | length)) as $i
             ({left: $want, donors: .donors};
              if .left <= 0 then .
              else (.donors[$i].surplus - (.donors[$i].given // 0)) as $avail
                   | ([$avail, .left] | min) as $take
                   | if $take <= 0 then .
                     else .donors[$i].given = ((.donors[$i].given // 0) + $take)
                          | .left -= $take end end)) as $d
         | .donors = $d.donors
         | (if $use_slack then ([.slack, $d.left] | min) else 0 end) as $from_slack
         | .slack -= $from_slack
         | .out += [$r + {from_donors: ($want - $d.left),
                          from_slack: $from_slack,
                          unfunded: ($d.left - $from_slack),
                          cap_after: ($r.cap_before + $want - $d.left + $from_slack)}])
      ) as $plan
    | ($plan.donors | map(select((.given // 0) > 0) | .cap_after = (.cap_before - .given))) as $givers
    | ($plan.out) as $recipients
    | ($sum_before + ([$recipients[].from_slack] | add // 0)) as $sum_after
    | {
        ceiling: $ceiling,
        slack_only: $slack_only,
        sum_before: $sum_before,
        sum_after: $sum_after,
        zero_sum: ($sum_after == $sum_before),
        over_ceiling: ($sum_before > $ceiling),
        overage: ([$sum_before - $ceiling, 0] | max),
        uncapped_orgs: $uncapped,
        ceiling_slack: $slack,
        slack_used: ([$recipients[].from_slack] | add // 0),
        recipients: ($recipients | map({org_id, name, cap_before, consumed, projected,
                                        need, shortfall, from_donors, from_slack,
                                        unfunded, cap_after})),
        donors: ($givers | map({org_id, name, cap_before, consumed, projected,
                                floor, surplus, given, cap_after})),
        writes: ([($recipients[] | select(.cap_after != .cap_before)),
                  $givers[]]
                 | map({org_id, name, cap_before, cap_after})),
        warnings: (
          (if $sum_before > $ceiling
           then ["org layer already exceeds the ceiling: Σ org caps \($sum_before) > \($ceiling) (overage \($sum_before - $ceiling)) — run dag slg to replan every org under the ceiling"]
           else [] end)
          + (if ($uncapped | length) > 0
             then ["uncapped org(s) have no Local Agent gate, so the ceiling is unenforceable: \($uncapped | join(", ")) — cap them (dag slg / dag set-limits-global)"]
             else [] end)
          + ([$needs | keys[] as $id
              | select([$orgs[] | select(.org_id == $id and .cap_before == null)] | length > 0)
              | "org \($id) has no explicit Local Agent cap — its gate cannot block, no org move needed"])
          + [$recipients[] | select(.unfunded > 0)
             | "\(.name): \(.unfunded) ACUs of new member room unfunded at org level — the org gate stays the brake (users there block once org consumption reaches \(.cap_after))"])
      }
  end
