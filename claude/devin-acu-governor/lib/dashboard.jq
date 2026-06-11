# dag dashboard — build the dashboard data document from Devin v3 responses.
# Invoked by lib/dashboard.zsh as:
#   jq -n --argjson now/pool/after/before --arg generated_at \
#     --slurpfile ent  <enterprise daily response> \
#     --slurpfile orgs <organizations response> \
#     --slurpfile orgd <stream of {org_id, daily} docs, one per org> \
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
  elif $consumed >= $limit then "over"
  elif $projected > $limit then "forecast_over"
  elif ($consumed / $limit) >= 0.95 then "critical"
  elif ($consumed / $limit) >= 0.85 then "warning"
  else "ok"
  end;

ceil_(($before - $after) / 86400) as $cycle_days
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
| {
    generated_at: $generated_at,
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
    warnings: (
      [$org_rows[] | select(.status == "over")
        | "\(.name) is OVER its cycle cap: \(.consumed) of \(.max_cycle_acu_limit) ACUs consumed"]
      + [$org_rows[] | select(.status == "forecast_over")
        | "\(.name) is forecast to exceed its cycle cap: projected \(.projected) vs cap \(.max_cycle_acu_limit)"]
      + [$org_rows[] | select(.status == "uncapped")
        | "\(.name) has no max_cycle_acu_limit (uncapped)"]
    )
  }
