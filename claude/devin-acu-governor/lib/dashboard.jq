# dag dashboard — build the dashboard data document from Devin v3 responses.
# Invoked by lib/dashboard.zsh as:
#   jq -n --argjson now/pool/after/before --arg generated_at \
#     --slurpfile ent      <enterprise daily response> \
#     --slurpfile orgs     <organizations response> \
#     --slurpfile orgd     <stream of {org_id, daily} docs, one per org> \
#     --slurpfile users    <enterprise members/users response> \
#     --slurpfile userd    <stream of {user_id, daily} docs, one per user> \
#     --slurpfile userl    <stream of {user_id, limits} docs, one per user> \
#     --slurpfile defaultl <default user ACU-limit response> \
#     -f lib/dashboard.jq

def ceil_(x): (x | floor) as $f | if x == $f then $f else $f + 1 end;
def r2: (. * 100 | round) / 100;
def r3: (. * 1000 | round) / 1000;

# The live API serves consumption_by_date[].date as a Unix epoch (PST midnight);
# accept a "YYYY-MM-DD" string too and emit both forms.
def day_forms:
  if (. | type) == "number"
  then {epoch: ., date: (. | gmtime | strftime("%Y-%m-%d"))}
  else {epoch: (. | strptime("%Y-%m-%d") | mktime), date: .}
  end;

# Status order matters: forecast_over outranks critical/warning — an org whose
# projection already crosses the cap is in worse shape than one merely close.
def org_status($consumed; $limit; $projected):
  if $limit == null then "uncapped"
  elif $limit == 0 then (if $consumed > 0 then "over" else "blocked" end)
  elif $consumed >= $limit then "over"
  elif $projected > $limit then "forecast_over"
  elif ($consumed / $limit) >= 0.95 then "critical"
  elif ($consumed / $limit) >= 0.85 then "warning"
  else "ok"
  end;

def user_status($consumed; $limit):
  if $limit == null then "uncapped"
  elif $limit == 0 then (if $consumed > 0 then "over" else "blocked" end)
  elif $consumed >= $limit then "over"
  elif ($consumed / $limit) >= 0.95 then "critical"
  elif ($consumed / $limit) >= 0.85 then "warning"
  else "ok"
  end;

($refresh_minutes | if . == "" then null else tonumber end) as $refresh_min
| ceil_(($before - $after) / 86400) as $cycle_days
| ([$now, $before] | min) as $eff_now
| ([1, ceil_(($eff_now - $after) / 86400)] | max) as $elapsed_days
| ([0, $cycle_days - $elapsed_days] | max) as $left_days
| $ent[0] as $daily_resp
| ($daily_resp.total_acus // 0) as $consumed
| ($consumed / $elapsed_days) as $rate
| ($rate * $cycle_days) as $projected
| ($orgs[0].items // []) as $orglist
| ($orgd | map({key: .org_id, value: (.daily.total_acus // 0)}) | from_entries) as $org_consumed
| ($orglist | map(
    . as $o
    | ($org_consumed[$o.org_id] // 0) as $c
    | ($c / $elapsed_days) as $orate
    | ($orate * $cycle_days) as $oproj
    | {
        org_id: $o.org_id,
        name: ($o.name // $o.org_id),
        consumed: ($c | r2),
        daily_run_rate: ($orate | r2),
        projected: ($oproj | r2),
        max_cycle_acu_limit: $o.max_cycle_acu_limit,
        max_session_acu_limit: $o.max_session_acu_limit,
        pct_limit: (if ($o.max_cycle_acu_limit // 0) == 0 then null
                    else (($c / $o.max_cycle_acu_limit) | r3) end),
        status: org_status($c; $o.max_cycle_acu_limit; $oproj)
      }
  )) as $org_rows
| ($users[0].items // []) as $userlist
| ($userd | map({key: .user_id, value: (.daily.total_acus // 0)}) | from_entries) as $user_consumed
| ($userl | map({key: .user_id, value: (.limits // {})}) | from_entries) as $user_limits
| ($defaultl[0].local_agent.cycle_acu_limit // null) as $default_user_limit
| ($userlist | map(
    . as $u
    | ($user_consumed[$u.user_id] // 0) as $uc
    | ($user_limits[$u.user_id] // {}) as $lim
    | ($lim.local_agent.cycle_acu_limit // null) as $explicit_limit
    | (if $explicit_limit == null then $default_user_limit else $explicit_limit end) as $effective_limit
    | {
        user_id: $u.user_id,
        email: ($u.email // ""),
        name: ($u.name // $u.email // $u.user_id),
        consumed: ($uc | r2),
        explicit_cycle_acu_limit: $explicit_limit,
        default_cycle_acu_limit: $default_user_limit,
        effective_cycle_acu_limit: $effective_limit,
        cap_source: (if $explicit_limit != null then "explicit"
                     elif $default_user_limit != null then "default"
                     else "uncapped" end),
        billing_org_id: ($lim.billing_org_id // null),
        headroom: (if $effective_limit == null then null else (($effective_limit - $uc) | r2) end),
        pct_limit: (if ($effective_limit // 0) == 0 then null
                    else (($uc / $effective_limit) | r3) end),
        status: user_status($uc; $effective_limit)
      }
  ) | sort_by(-.consumed, .email)) as $user_rows
| {
    generated_at: $generated_at,
    refresh: {
      enabled: ($refresh_min != null),
      interval_minutes: $refresh_min,
      interval_ms: (if $refresh_min == null then null else ($refresh_min * 60000) end)
    },
    cycle: {
      after: $after,
      before: $before,
      start_date: ($after | gmtime | strftime("%Y-%m-%d")),
      end_date: ($before | gmtime | strftime("%Y-%m-%d")),
      cycle_days: $cycle_days,
      elapsed_days: $elapsed_days,
      left_days: $left_days
    },
    pool: $pool,
    enterprise: {
      consumed: ($consumed | r2),
      remaining: (($pool - $consumed) | r2),
      daily_run_rate: ($rate | r2),
      projected_cycle_total: ($projected | r2),
      projected_over_under: (($pool - $projected) | r2),
      verdict: (if $projected > $pool then "OVER" else "UNDER" end)
    },
    product_split: (["devin", "cascade", "terminal", "review"] | map(
      . as $p
      | {product: $p,
         acus: (([($daily_resp.consumption_by_date // [])[] | (.acus_by_product[$p] // 0)] | add // 0) | r2)}
    )),
    daily: (($daily_resp.consumption_by_date // []) | map((.date | day_forms) as $d | {
      date: $d.date,
      epoch: $d.epoch,
      acus: ((.acus // 0) | r2),
      devin: ((.acus_by_product.devin // 0) | r2),
      cascade: ((.acus_by_product.cascade // 0) | r2),
      terminal: ((.acus_by_product.terminal // 0) | r2),
      review: ((.acus_by_product.review // 0) | r2)
    })),
    orgs: $org_rows,
    users: $user_rows,
    warnings: (
      [$org_rows[] | select(.status == "over")
        | "\(.name) is OVER its cycle cap: \(.consumed) of \(.max_cycle_acu_limit) ACUs consumed"]
      + [$org_rows[] | select(.status == "forecast_over")
        | "\(.name) is forecast to exceed its cycle cap: projected \(.projected) vs cap \(.max_cycle_acu_limit)"]
      + [$org_rows[] | select(.status == "uncapped")
        | "\(.name) has no max_cycle_acu_limit (uncapped)"]
      + [$user_rows[] | select(.status == "over")
        | "\(.email) is OVER effective user cap: \(.consumed) of \(.effective_cycle_acu_limit) ACUs consumed"]
    )
  }
