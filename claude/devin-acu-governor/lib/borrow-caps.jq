# Zero-sum cap-seeding for dag set-limits-new.
# Give an explicit Local Agent cap to users who currently have NONE (recipients),
# funded entirely by Borrowing cap headroom from high-surplus users who already
# HAVE explicit caps (donors); consumption breaks equal-surplus ties. Total Σ explicit caps is unchanged
# (zero-sum), so the team never tips into overage.
#
# Input:
# {
#   "donor_buffer": <number=0.10>,                          # keep each donor this fraction above its consumed
#   "max_headroom": <number=500>,                            # maximum new cap headroom per recipient
#   "donor_floor_min": <number=0>,                           # absolute minimum cap left to any donor (never raises a cap)
#   "days_left": <number=0>,                                 # cycle days left, for donor run-rate projection
#   "recipients": [{"email","user_id"?,"consumed","member"?,"active"?}, ...],
#                                                            # uncapped users (no explicit cap today)
#   "donors":     [{"email","user_id"?,"cap","consumed","run_rate"?,"member"?,"active"?}, ...]
#                                                            # capped users = candidate donors
# }
#
# Donor run_rate (recent ACUs/day, e.g. last-7-day average): when present, the donor's
# protected floor covers projected end-of-cycle consumption, not just current burn —
# floor = max(ceil(consumed*(1+donor_buffer)), ceil((consumed + run_rate*days_left)*(1+donor_buffer))).
# available = cap - floor. Donors are ranked highest available first, consumed as tie-break.
# Absent run_rate the floor is exactly the legacy ceil(consumed*(1+donor_buffer)).
#
# Output:
# {
#   mode: "even_share" | "min_cover" | "partial",
#   donor_buffer, total_available, recipients_total, borrowed,
#   share?,                                  # even_share only
#   recipients_capped: [{email,user_id?,consumed,cap}],
#   recipients_skipped: [{email,user_id?,consumed}],   # could not be funded zero-sum
#   donor_takes: [{email,user_id?,cap_before,cap_after,given}],   # high surplus first
#   recipients_excluded, donors_excluded, eligible_recipient_count,
#   eligible_donor_count, sum_donor_before, sum_donor_after, sum_before,
#   sum_after, zero_sum, warnings
# }  or  {error} on empty/fully-ineligible recipient set.
#
# Modes:
#   even_share  donors can fund floor(consumed)+share for every recipient (share>=1),
#               capped by max_headroom (500 ACUs by global policy).
#   min_cover   donors can cover each recipient's consumed ACUs only (no growth headroom).
#   partial     donors cannot fund everyone; cheapest recipients funded first, rest left uncapped.
# Invariant: borrowed == Σ recipients_capped[].cap == Σ donor_takes[].given, and
#            sum_after == sum_before (true zero-sum) in every mode.

def uid: if has("user_id") then {user_id} else {} end;

def boolish($v; $default):
  if $v == null then $default
  elif ($v | type) == "boolean" then $v
  elif ($v | type) == "number" then ($v != 0)
  elif ($v | type) == "string" then
    ($v | ascii_downcase) as $s
    | ($s == "active" or $s == "true" or $s == "yes" or $s == "enabled" or $s == "current" or $s == "member")
  else $default
  end;

def current_member:
  if has("member") then boolish(.member; true)
  elif has("current_member") then boolish(.current_member; true)
  elif has("is_current_member") then boolish(.is_current_member; true)
  else true
  end;

def active_member:
  if has("active") then boolish(.active; true)
  elif has("is_active") then boolish(.is_active; true)
  elif has("teamStatus") then boolish(.teamStatus; false)
  elif has("team_status") then boolish(.team_status; false)
  else true
  end;

def exclusion_reasons:
  []
  + (if current_member then [] else ["not_current_member"] end)
  + (if active_member then [] else ["inactive"] end);

def eligible: current_member and active_member;

def excluded_recipient_row:
  {email}
  + uid
  + {consumed, member: current_member, active: active_member, reasons: exclusion_reasons};

def excluded_donor_row:
  {email}
  + uid
  + {consumed, cap, member: current_member, active: active_member, reasons: exclusion_reasons};

(.donor_buffer // 0.10) as $dbuf
| (.max_headroom // 500) as $max_headroom
| (.donor_floor_min // 0) as $floor_min
| (.days_left // 0) as $days_left
| (.recipients // []) as $all_recips
| (.donors // [])     as $all_donors
| ([ $all_recips[] | select(eligible) ]) as $recips
| ([ $all_donors[] | select(eligible) ]) as $donors
| ([ $all_recips[] | select(eligible | not) | excluded_recipient_row ]) as $recips_excluded
| ([ $all_donors[] | select(eligible | not) | excluded_donor_row ]) as $donors_excluded
| ($recips | length)  as $n
| if ($all_recips | length) == 0 then
    {error: "no uncapped users to seed",
     eligible_recipient_count: 0,
     eligible_donor_count: ($donors | length),
     recipients_excluded: [],
     donors_excluded: $donors_excluded}
  elif $n == 0 then
    {error: "no active current-member uncapped users to seed",
     eligible_recipient_count: 0,
     eligible_donor_count: ($donors | length),
     recipients_excluded: $recips_excluded,
     donors_excluded: $donors_excluded}
  else
    # Donor headroom above a buffer over consumption — projected to cycle end when a
    # run_rate is known — ranked by highest safe surplus.
    ([ $donors[]
       | ((.consumed * (1 + $dbuf)) | ceil) as $base_floor
       | (if (.run_rate // null) != null
            then ([$base_floor, (((.consumed + (.run_rate * $days_left)) * (1 + $dbuf)) | ceil)] | max)
            else $base_floor end) as $proj_floor
       | ([$proj_floor, $floor_min] | max) as $floor
       | {email, consumed, cap, floor: $floor, available: ([.cap - $floor, 0] | max)} + uid ]
     | sort_by(-.available, .consumed)) as $cands
    | ([ $cands[].available ] | add // 0)      as $total_available
    | ([ $recips[].consumed | floor ] | add)   as $base_sum
    | ([ $donors[].cap ] | add // 0)           as $sum_donor_before
    # Plan recipient caps.
    | (if $total_available >= ($base_sum + $n) then
         ((($total_available - $base_sum) / $n) | floor) as $raw_share
         | ([$raw_share, $max_headroom] | min) as $share
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
    # Draw exactly $borrowed from high-surplus donors first; consumption breaks ties.
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
        max_headroom: $max_headroom,
        donor_floor_min: $floor_min,
        total_available: $total_available,
        recipients_total: $n,
        eligible_recipient_count: $n,
        eligible_donor_count: ($donors | length),
        borrowed: $borrowed,
        recipients_capped: $plan.capped,
        recipients_skipped: $plan.skipped,
        recipients_excluded: $recips_excluded,
        donor_takes: $draw.takes,
        donors_excluded: $donors_excluded,
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
