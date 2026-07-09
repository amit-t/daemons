# Boost headroom check for dag boost.
# Input:  {"pool": <int>, "current_cap": <int>, "increment": <int>, "sum_caps": <int>}
# Output: {new_cap, new_sum, headroom_after, over_pool}
(.current_cap + .increment) as $new_cap
| (.sum_caps + .increment) as $new_sum
| {new_cap: $new_cap, new_sum: $new_sum,
   headroom_after: (.pool - $new_sum), over_pool: ($new_sum > .pool)}
