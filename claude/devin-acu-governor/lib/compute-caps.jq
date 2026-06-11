# Remaining-pool split for dag set-limits.
# Input:  {"pool": <int>, "users": [{"email": <str>, "consumed": <number>}, ...]}
# Output: {mode, total_consumed, remaining, share?, flat_cap?, caps: [{email, consumed, cap}],
#          sum_caps, warnings: [..]}  or  {"error": ..} on empty roster.
#
# Invariant: when share >= 1, cap_i = floor(consumed_i) + share, so
# sum(caps) <= total_consumed + remaining = pool.
# Degenerate cases freeze caps at ceil(consumed) and warn.

def caprow($cap):
  {email, consumed}
  + (if has("user_id") then {user_id} else {} end)
  + {cap: $cap};

(.users | length) as $n
| .pool as $pool
| if $n == 0 then {error: "no users in roster"}
  else
    ([.users[].consumed] | add) as $total
    | ($pool - $total) as $remaining
    | (if $total == 0 then
        (($pool / $n) | floor) as $flat
        | {mode: "team_level", flat_cap: $flat, total_consumed: 0, remaining: $pool,
           caps: [.users[] | caprow($flat)], warnings: []}
      elif $remaining <= 0 then
        {mode: "per_user", total_consumed: $total, remaining: $remaining,
         caps: [.users[] | caprow((.consumed | ceil))],
         warnings: ["pool exhausted: remaining \($remaining); caps frozen at current consumption"]}
      else
        (($remaining / $n) | floor) as $share
        | if $share == 0 then
            {mode: "per_user", total_consumed: $total, remaining: $remaining,
             caps: [.users[] | caprow((.consumed | ceil))],
             warnings: ["remaining pool (\($remaining)) smaller than team size (\($n)); caps frozen at current consumption"]}
          else
            {mode: "per_user", total_consumed: $total, remaining: $remaining, share: $share,
             caps: [.users[] | caprow(((.consumed | floor) + $share))],
             warnings: []}
          end
      end)
    | . + {sum_caps: ([.caps[].cap] | add)}
  end
