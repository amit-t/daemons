# Flat per-user Local Agent cap planner for dag flat-cap.
# Every active current-member user gets the same proposed cap (flat_cap),
# raised to ceil(consumed) for anyone already above it — a cap is never set
# below current consumption. Hard rule 11 clamp: no proposed cap sits more
# than max_headroom (default 250, backstop 500) above ceil(consumed), so a
# flat_cap above max_headroom clamps low consumers to consumed + max_headroom.
#
# Input:  {"flat_cap": <int>, "max_headroom"?: <n=250, clamped 0..500>,
#          "days_left"?: <number>,
#          "users": [{"email", "user_id"?, "consumed",
#                     "cap"?: <current explicit cap or null>,
#                     "member"?, "active"?, "run_rate"?, "billing_org_id"?}]}
# Output: {mode: "flat_cap", flat_cap, max_headroom,
#          caps:      [{email, consumed, user_id?, cap_before, cap, change,
#                       projected, billing_org_id?}],   # write rows only
#          unchanged: [same shape, change == "unchanged"],
#          raised_above_flat: [emails with cap == ceil(consumed) > flat],
#          sum_before, sum_after, delta,                # Σ explicit caps, eligible set
#          org_deltas: [{org_id, delta}],               # per billing org, write rows only
#          eligible_user_count, excluded_users, warnings}
#          or {"error": ..} on bad flat_cap / empty / fully-ineligible roster.
#
# change: "new" (no explicit cap before), "raise", "reduce"; equal caps land
# in `unchanged` and plan no write. Forecast: projected = ceil(consumed +
# run_rate * days_left); projected > cap only appends a warning. days_left
# guard matches compute-caps.jq: run_rate without a top-level days_left key
# errors instead of silently collapsing projections.

def ceil_(x): (x | floor) as $f | if x == $f then $f else $f + 1 end;
def clamp(lo; hi): if . < lo then lo elif . > hi then hi else . end;

def uid: if has("user_id") then {user_id} else {} end;
def borg: if has("billing_org_id") then {billing_org_id} else {} end;

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

def excludedrow:
  {email}
  + uid
  + {consumed, member: current_member, active: active_member, reasons: exclusion_reasons};

(has("days_left")) as $has_days
| (.days_left // 0) as $days_left
| (.flat_cap // null) as $flat
| ((.max_headroom // 250) | floor | clamp(0; 500)) as $mh
| (.users // []) as $all_users
| ([ $all_users[] | select(eligible) ]) as $users
| ([ $all_users[] | select(eligible | not) | excludedrow ]) as $excluded
| ($users | length) as $n
| if ($flat | type) != "number" or $flat <= 0 then
    {error: "flat_cap must be a positive number", flat_cap: $flat}
  elif ($all_users | length) == 0 then
    {error: "no users in roster", eligible_user_count: 0, excluded_users: []}
  elif $n == 0 then
    {error: "no active current-member users in roster", eligible_user_count: 0, excluded_users: $excluded}
  elif ($has_days | not) and any($all_users[]; (.run_rate // null) != null) then
    {error: "days_left missing while user run_rate supplied — forecast projections would collapse to consumed-only; pass days_left"}
  else
    ($users | map(
        ceil_(.consumed) as $floorcap
        | ([$floorcap, ([$flat, $floorcap + $mh] | min)] | max) as $cap
        | {email, consumed}
          + uid
          + {cap_before: (.cap // null), cap: $cap,
             change: (if (.cap // null) == null then "new"
                      elif $cap > .cap then "raise"
                      elif $cap < .cap then "reduce"
                      else "unchanged" end),
             projected: (if (.run_rate // null) == null then null
                         else ceil_(.consumed + .run_rate * $days_left) end),
             clamped: ($floorcap + $mh < $flat and $cap < $flat)}
          + borg)) as $rows
    | ([$rows[] | select(.change != "unchanged") | del(.clamped)]) as $writes
    | ([$rows[] | select(.change == "unchanged") | del(.clamped)]) as $same
    | ([$rows[] | select(.cap > $flat) | .email]) as $raised
    | ([$rows[] | .cap_before // 0] | add // 0) as $sum_before
    | ([$rows[] | .cap] | add // 0) as $sum_after
    | (reduce ($writes[] | {org: (.billing_org_id // "unattributed"),
                            d: (.cap - (.cap_before // 0))}) as $w
         ({}; .[$w.org] = ((.[$w.org] // 0) + $w.d))) as $odmap
    | {mode: "flat_cap", flat_cap: $flat, max_headroom: $mh,
       caps: $writes, unchanged: $same, raised_above_flat: $raised,
       sum_before: $sum_before, sum_after: $sum_after, delta: ($sum_after - $sum_before),
       org_deltas: ([$odmap | to_entries[] | select(.key != "unattributed")
                     | {org_id: .key, delta: .value}]),
       eligible_user_count: $n, excluded_users: $excluded,
       warnings: (
         (if any($rows[]; .clamped)
          then ["flat cap \($flat) exceeds max_headroom \($mh): \([$rows[] | select(.clamped) | .email] | join(", ")) clamped to consumed + max_headroom (hard rule 11)"]
          else [] end)
         + ([$rows[] | select(.projected != null and .projected > .cap)
             | "\(.email) projected \(.projected) ACUs by cycle end exceeds proposed cap \(.cap) — the flat cap will not hold; plan a boost or exclude from donor pools"])
         + ([$writes[] | select(.cap - .consumed < 25)
             | "\(.email) left within 25 ACUs of consumption (consumed \(.consumed), cap \(.cap)) — will hit the cap quickly; plan a boost"])
         + (if ($odmap | has("unattributed"))
            then ["write rows missing billing_org_id (org attribution unresolved; resolve before org-gate rebalance): \([$writes[] | select(has("billing_org_id") | not) | .email] | join(", "))"]
            else [] end))}
  end
