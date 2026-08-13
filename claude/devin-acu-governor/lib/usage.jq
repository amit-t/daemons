# Per-user consumed-vs-cap table math for `dag usage`.
# Input:
#   { pool, generated_at, cycle:{after,before}, default_cap:(number|null),
#     donor_baselines?:{email: baseline_cap},   # current-cycle donor record (hard rule 13)
#     users:[ {email, user_id, name, consumed:(number), override:(number|null),
#              last3_acus?:(number), last3_by_product?:object,
#              idp_orgs?:array, idp_roles?:array} ] }
# Output:
#   { generated_at, pool, default_cap, cycle,
#     totals:{users, total_consumed, sum_caps, n_over, n_near, n_donor, n_unlimited, n_blocked},
#     rows:[ {email, user_id, name, consumed, cap:(number|null), source, ratio:(number|null),
#             state, raw_state, donor_baseline:(number|null), sort_key} ] }
#
# Effective cap precedence: explicit per-user override, else default user limit, else none.
# A user override replaces (not adds to) the default. cap 0 blocks usage for that scope.
# DONOR state: a recorded current-cycle donor whose raw state is OVER/NEAR but whose
# consumed < 0.85 x baseline_cap (the cap they held before DAG Borrows reduced it) is
# labeled DONOR — the pressure is an artifact of the reduction, not real usage.
# All math here — no caller arithmetic.

def effrow:
  . as $u
  | (if $u.override != null then {cap: $u.override, source: "override"}
     elif $u.default_cap != null then {cap: $u.default_cap, source: "default"}
     else {cap: null, source: "none"} end) as $e
  | ($e.cap) as $cap
  | ($u.consumed) as $c
  | ($u.last3_acus // null) as $last3
  | ($u.last3_by_product // {}) as $last3_by_product
  | (if $cap == null then null
     elif $cap == 0 then null
     else ($c / $cap) end) as $ratio
  | (if $cap == null then "UNLIMITED"
     elif $cap == 0 then (if $c > 0 then "OVER" else "BLOCKED" end)
     elif $ratio >= 1 then "OVER"
     elif $ratio >= 0.8 then "NEAR"
     else "OK" end) as $raw_state
  | ($u.donor_baseline // null) as $base
  | (($base != null) and ($base > 0)
     and ($raw_state == "OVER" or $raw_state == "NEAR")
     and ($c < 0.85 * $base)) as $donor_suppressed
  | (if $donor_suppressed then "DONOR" else $raw_state end) as $state
  # sort_key: most-pressured first; DONOR sinks below OK; unlimited and
  # unused-blocked sink to the bottom.
  | (if $donor_suppressed then -0.25
     elif $cap == 0 and $c > 0 then 1000000000 + $c
     elif $cap == null then -1
     elif $cap == 0 then -0.5
     else $ratio end) as $sort_key
  | {email: $u.email, user_id: $u.user_id, name: ($u.name // ""),
     consumed: $c, cap: $cap, source: $e.source, ratio: $ratio,
     state: $state, raw_state: $raw_state, donor_baseline: $base,
     sort_key: $sort_key,
     last3_acus: $last3,
     last3_avg_per_day: (if $last3 == null then null else ($last3 / 3) end),
     last3_by_product: {
       devin: ($last3_by_product.devin // 0),
       cascade: ($last3_by_product.cascade // 0),
       terminal: ($last3_by_product.terminal // 0),
       review: ($last3_by_product.review // 0)
     },
     idp_orgs: ($u.idp_orgs // []),
     idp_roles: ($u.idp_roles // [])};

.pool as $pool
| .generated_at as $gen
| .cycle as $cycle
| .default_cap as $default_cap
| (.donor_baselines // {}) as $donor_baselines
| ([.users[]
    | . + {default_cap: $default_cap,
           donor_baseline: ($donor_baselines[.email // ""] // null)}
    | effrow]
   | sort_by(.sort_key) | reverse) as $rows
| {
    generated_at: $gen,
    pool: $pool,
    default_cap: $default_cap,
    cycle: $cycle,
    totals: {
      users: ($rows | length),
      total_consumed: ([$rows[].consumed] | add // 0),
      sum_caps: ([$rows[] | select(.cap != null) | .cap] | add // 0),
      n_over: ([$rows[] | select(.state == "OVER")] | length),
      n_near: ([$rows[] | select(.state == "NEAR")] | length),
      n_donor: ([$rows[] | select(.state == "DONOR")] | length),
      n_unlimited: ([$rows[] | select(.state == "UNLIMITED")] | length),
      n_blocked: ([$rows[] | select(.state == "BLOCKED")] | length),
      last3_acus: ([$rows[] | .last3_acus // 0] | add // 0),
      last3_by_product: (reduce $rows[] as $r (
        {devin:0, cascade:0, terminal:0, review:0};
        .devin += ($r.last3_by_product.devin // 0)
        | .cascade += ($r.last3_by_product.cascade // 0)
        | .terminal += ($r.last3_by_product.terminal // 0)
        | .review += ($r.last3_by_product.review // 0)
      ))
    },
    rows: $rows
  }
