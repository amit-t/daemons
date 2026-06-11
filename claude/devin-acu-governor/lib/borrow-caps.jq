# Zero-sum cap-seeding for dag set-limits-new.
# Give an explicit Local Agent cap to users who currently have NONE (recipients),
# funded entirely by Borrowing cap headroom from the lowest-consuming users who
# already HAVE explicit caps (donors). Total Σ explicit caps is unchanged
# (zero-sum), so the team never tips into overage.
#
# Input:
# {
#   "donor_buffer": <number=0.10>,                          # keep each donor this fraction above its consumed
#   "recipients": [{"email","user_id"?,"consumed"}, ...],   # uncapped users (no explicit cap today)
#   "donors":     [{"email","user_id"?,"cap","consumed"}, ...]  # capped users = candidate donors
# }
#
# Output:
# {
#   mode: "even_share" | "min_cover" | "partial",
#   donor_buffer, total_available, recipients_total, borrowed,
#   share?,                                  # even_share only
#   recipients_capped: [{email,user_id?,consumed,cap}],
#   recipients_skipped: [{email,user_id?,consumed}],   # could not be funded zero-sum
#   donor_takes: [{email,user_id?,cap_before,cap_after,given}],   # lowest consumer first
#   sum_donor_before, sum_donor_after, sum_before, sum_after, zero_sum, warnings
# }  or  {error} on empty recipient set.
#
# Modes:
#   even_share  donors can fund floor(consumed)+share for every recipient (share>=1).
#   min_cover   donors can cover each recipient's consumed ACUs only (no growth headroom).
#   partial     donors cannot fund everyone; cheapest recipients funded first, rest left uncapped.
# Invariant: borrowed == Σ recipients_capped[].cap == Σ donor_takes[].given, and
#            sum_after == sum_before (true zero-sum) in every mode.

def uid: if has("user_id") then {user_id} else {} end;

(.donor_buffer // 0.10) as $dbuf
| (.recipients // []) as $recips
| (.donors // [])     as $donors
| ($recips | length)  as $n
| if $n == 0 then {error: "no uncapped users to seed"}
  else
    # Donor headroom above a buffer over consumption, lowest consumer first.
    ([ $donors[]
       | ((.consumed * (1 + $dbuf)) | ceil) as $floor
       | {email, consumed, cap, floor: $floor, available: ([.cap - $floor, 0] | max)} + uid ]
     | sort_by(.consumed)) as $cands
    | ([ $cands[].available ] | add // 0)      as $total_available
    | ([ $recips[].consumed | floor ] | add)   as $base_sum
    | ([ $donors[].cap ] | add // 0)           as $sum_donor_before
    # Plan recipient caps.
    | (if $total_available >= ($base_sum + $n) then
         ((($total_available - $base_sum) / $n) | floor) as $share
         | { mode: "even_share", share: $share,
             capped: [ $recips[] | {email, consumed, cap: ((.consumed | floor) + $share)} + uid ],
             skipped: [] }
       else
         # Constrained: fund cheapest recipients first at cap = ceil(consumed).
         ($recips | sort_by(.consumed)) as $rs
         | reduce $rs[] as $r ({remaining: $total_available, capped: [], skipped: []};
             (.remaining) as $rem
             | (($r.consumed | ceil)) as $cost
             | if $cost > 0 and $rem >= $cost
               then {remaining: ($rem - $cost),
                     capped: (.capped + [ ({email: $r.email, consumed: $r.consumed, cap: $cost} + ($r | uid)) ]),
                     skipped: .skipped}
               else {remaining: $rem, capped: .capped,
                     skipped: (.skipped + [ ({email: $r.email, consumed: $r.consumed} + ($r | uid)) ])}
               end)
         | {mode: (if (.skipped | length) > 0 then "partial" else "min_cover" end),
            capped: .capped, skipped: .skipped}
       end) as $plan
    | ([ $plan.capped[].cap ] | add // 0) as $borrowed
    # Draw exactly $borrowed from donors, lowest consumer first.
    | (reduce $cands[] as $d ({remaining: $borrowed, takes: []};
         (if .remaining > 0 and $d.available > 0
            then ([$d.available, .remaining] | min) else 0 end) as $give
         | {remaining: (.remaining - $give),
            takes: (.takes + (if $give > 0
                      then [ ({email: $d.email, cap_before: $d.cap, cap_after: ($d.cap - $give), given: $give} + ($d | uid)) ]
                      else [] end))})) as $draw
    | ($sum_donor_before - $borrowed) as $sum_donor_after
    | {
        mode: $plan.mode,
        donor_buffer: $dbuf,
        total_available: $total_available,
        recipients_total: $n,
        borrowed: $borrowed,
        recipients_capped: $plan.capped,
        recipients_skipped: $plan.skipped,
        donor_takes: $draw.takes,
        sum_donor_before: $sum_donor_before,
        sum_donor_after: $sum_donor_after,
        sum_before: $sum_donor_before,
        sum_after: ($sum_donor_after + $borrowed),
        warnings: (
          []
          + (if $plan.mode == "min_cover"
               then ["donor headroom covers each user's consumed ACUs only; capped at consumption, no growth headroom"] else [] end)
          + (if ($plan.skipped | length) > 0
               then ["donor headroom (\($total_available)) cannot fund all \($n) users zero-sum; \($plan.skipped | length) left uncapped: \([$plan.skipped[].email] | join(", "))"] else [] end)
          + (if $borrowed == 0
               then ["no caps applied: no donor headroom to borrow"] else [] end)
        )
      }
    | (if ($plan | has("share")) then . + {share: $plan.share} else . end)
    | . + {zero_sum: (.sum_before == .sum_after)}
  end
