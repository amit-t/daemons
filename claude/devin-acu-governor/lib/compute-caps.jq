# Remaining-pool split for dag set-limits.
# Input:  {"pool": <int>, "days_left"?: <number>, "users": [{"email": <str>,
#          "consumed": <number>, "member"?: <bool>, "active"?: <bool>,
#          "run_rate"?: <number>}, ...]}
# Output: {mode, total_consumed, remaining, share?, flat_cap?,
#          caps: [{email, consumed, cap, projected}],
#          sum_caps, eligible_user_count, excluded_users, warnings: [..]}
#          or {"error": ..} on empty/fully-ineligible roster.
#
# Invariant: when share >= 1, cap_i = floor(consumed_i) + share, so
# sum(caps) <= total_consumed + remaining = pool.
# Degenerate cases freeze caps at ceil(consumed) and warn.
#
# Forecast: projected = ceil(consumed + run_rate * days_left) when a user
# carries run_rate, else null. No cap values change from a forecast; a
# projected > cap only appends a warning.

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

def excludedrow:
  {email}
  + uid
  + {consumed, member: current_member, active: active_member, reasons: exclusion_reasons};

def caprow($cap; $days_left):
  {email, consumed}
  + uid
  + {cap: $cap,
     projected: (if (.run_rate // null) == null then null
                 else ((.consumed + .run_rate * $days_left) | ceil) end)};

(.users // []) as $all_users
| (.days_left // 0) as $days_left
| ([ $all_users[] | select(eligible) ]) as $users
| ([ $all_users[] | select(eligible | not) | excludedrow ]) as $excluded
| ($users | length) as $n
| .pool as $pool
| if ($all_users | length) == 0 then
    {error: "no users in roster", eligible_user_count: 0, excluded_users: []}
  elif $n == 0 then
    {error: "no active current-member users in roster", eligible_user_count: 0, excluded_users: $excluded}
  else
    ([$users[].consumed] | add) as $total
    | ($pool - $total) as $remaining
    | (if $total == 0 then
        (($pool / $n) | floor) as $flat
        | {mode: "team_level", flat_cap: $flat, total_consumed: 0, remaining: $pool,
           caps: [$users[] | caprow($flat; $days_left)], warnings: []}
      elif $remaining <= 0 then
        {mode: "per_user", total_consumed: $total, remaining: $remaining,
         caps: [$users[] | caprow((.consumed | ceil); $days_left)],
         warnings: ["pool exhausted: remaining \($remaining); caps frozen at current consumption"]}
      else
        (($remaining / $n) | floor) as $share
        | if $share == 0 then
            {mode: "per_user", total_consumed: $total, remaining: $remaining,
             caps: [$users[] | caprow((.consumed | ceil); $days_left)],
             warnings: ["remaining pool (\($remaining)) smaller than team size (\($n)); caps frozen at current consumption"]}
          else
            {mode: "per_user", total_consumed: $total, remaining: $remaining, share: $share,
             caps: [$users[] | caprow(((.consumed | floor) + $share); $days_left)],
             warnings: []}
          end
      end)
    | . + {sum_caps: ([.caps[].cap] | add)}
    | . + {warnings: (.warnings + [ .caps[]
        | select(.projected != null and .projected > .cap)
        | "\(.email) projected \(.projected) ACUs by cycle end exceeds proposed cap \(.cap) — even share will not hold; plan a boost or exclude from donor pools" ])}
    | . + {eligible_user_count: $n, excluded_users: $excluded}
  end
