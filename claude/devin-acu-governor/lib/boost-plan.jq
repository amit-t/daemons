# Zero-sum boost plan for dag boost.
# Reallocate ACUs to a heavy user by taking from the lowest consumers, keeping the
# total allocation (Σ caps) unchanged so the team never tips into overage.
#
# Input:
# {
#   "pool": <int>, "share": <number>,        # share = pool / N (even per-user share)
#   "recipient_buffer": <number=0.15>,        # comfort buffer over projected month-end
#   "donor_buffer": <number=0.10>,            # keep donor this fraction of share above consumed
#   "max_headroom": <number=500>,             # hard ceiling: recommended cap <= consumed + max_headroom
#   "min_donor_cap_after"?: <number=50>,      # never borrow a donor below this cap floor
#   "min_donor_give"?: <number=5>,            # skip skim donors with less than this safe headroom
#   "days_left"?: <number>,                   # cycle days left for donor run-rate projection (defaults to recipient.days_left)
#   "recipient": {"email","cap","consumed","run_rate","days_left", "delta_override"?},
#   "donors": [{"email","cap","consumed","run_rate"?}, ...]   # candidate donor pool
# }
# Output: {recommended_cap, current_cap, projected_month_end, delta, funded, shortfall,
#          takes:[{email,cap_before,cap_after,given}], recipient_after:{email,cap_before,cap_after},
#          warnings, sum_before, sum_after}.
#
# Headroom policy: recommended_cap is clamped to floor(consumed) + max_headroom (default 500)
# even when delta_override is supplied; a clamp emits a warning.
# Donor run_rate (recent ACUs/day): when present, a donor's protected floor also covers
# projected end-of-cycle consumption — max(base floor, ceil((consumed + run_rate*days_left)
# * (1 + donor_buffer))) — and donors are ranked by highest safe surplus first (consumed
# as tie-break). Absent run_rate keeps the legacy lowest-consumer-first behavior exactly.
#
# Invariant (when takes is the participant set): sum_after == sum_before.

.pool as $pool
| .share as $share
| .recipient as $r
| (.recipient_buffer // 0.15) as $rbuf
| (.donor_buffer // 0.10) as $dbuf
| (.min_donor_cap_after // 50) as $mincap
| (.min_donor_give // 5) as $mingive
| (.max_headroom // 500) as $max_headroom
| (.days_left // $r.days_left // 0) as $days_left
| ($r.consumed + ($r.run_rate * $r.days_left)) as $projected
| (if ($r.delta_override // null) != null
     then ($r.cap + $r.delta_override)
     else (($projected * (1 + $rbuf)) | ceil) end) as $unclamped
| ((($r.consumed | floor) + $max_headroom)) as $headroom_ceiling
| ([$unclamped, $headroom_ceiling] | min) as $recommended
| ($unclamped > $headroom_ceiling) as $clamped
| ([$recommended - $r.cap, 0] | max) as $delta
| ([ .donors[]
     | ([((.consumed + ($dbuf * $share)) | ceil), $mincap] | max) as $base_floor
     | (if (.run_rate // null) != null
          then ([$base_floor, (((.consumed + (.run_rate * $days_left)) * (1 + $dbuf)) | ceil)] | max)
          else $base_floor end) as $floor
     | {email, cap, consumed, floor: $floor, available: ([.cap - $floor, 0] | max)}
     | select(.available >= $mingive) ]) as $pool_cands
| (if any(.donors[]; (.run_rate // null) != null)
     then ($pool_cands | sort_by(-.available, .consumed))
     else ($pool_cands | sort_by(.consumed)) end) as $cands
| (reduce range(0; ($cands | length)) as $i ({remaining: $delta, takes: []};
     $cands[$i] as $d
     | (any($cands[($i + 1):][]; .available >= $mingive)) as $has_later
     | (if .remaining >= $mingive and $d.available >= $mingive
          then ([$d.available, .remaining] | min)
          else 0 end) as $base_give
     | (if ($base_give > 0)
             and ((.remaining - $base_give) > 0)
             and ((.remaining - $base_give) < $mingive)
             and $has_later
             and (($base_give - ($mingive - (.remaining - $base_give))) >= $mingive)
          then ($base_give - ($mingive - (.remaining - $base_give)))
          else $base_give end) as $give
     | {remaining: (.remaining - $give),
        takes: (.takes + (if $give > 0
                  then [{email: $d.email, cap_before: $d.cap, cap_after: ($d.cap - $give), given: $give}]
                  else [] end))}
   )) as $alloc
| ($delta - $alloc.remaining) as $funded
| {
    recommended_cap: $recommended,
    current_cap: $r.cap,
    max_headroom: $max_headroom,
    projected_month_end: ($projected | ceil),
    delta: $delta,
    funded: $funded,
    shortfall: $alloc.remaining,
    takes: $alloc.takes,
    recipient_after: {email: $r.email, cap_before: $r.cap, cap_after: ($r.cap + $funded)},
    warnings: (
      (if $clamped
         then ["recommended cap \($unclamped) exceeds the consumed + \($max_headroom) ACU direct-headroom ceiling; clamped to \($recommended) (hard max \($max_headroom) ACUs of headroom; prefer <= 250)"]
         else [] end)
      + (if $alloc.remaining > 0
           then ["donors can only fund \($funded) of \($delta) ACUs under donor safety policy (min cap after \($mincap), min donor give \($mingive)); recipient raised by \($funded) only. Add more high-headroom donors, lower donor safety thresholds explicitly, or cover \($alloc.remaining) from pool headroom (creates overage risk)."]
           else [] end)
    )
  }
| . + {
    sum_before: ([.recipient_after.cap_before] + [.takes[].cap_before] | add),
    sum_after:  ([.recipient_after.cap_after]  + [.takes[].cap_after]  | add)
  }
