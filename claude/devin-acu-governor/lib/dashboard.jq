# dag dashboard — build the dashboard data document from Devin v3 responses.
# Invoked by lib/dashboard.zsh as:
#   jq -n --argjson now/pool/after/before --arg generated_at \
#     --slurpfile ent      <enterprise daily response> \
#     --slurpfile orgs     <organizations response> \
#     --slurpfile orgd     <stream of {org_id, daily} docs, one per org> \
#     --slurpfile orgl     <stream of {org_id, limits} docs, one per org: the
#                           v3beta1 org acu-limits settings (local_agent /
#                           cloud_agent cycle caps); limits == {} when degraded> \
#     --slurpfile users    <enterprise members/users response> \
#     --slurpfile userd    <stream of {user_id, daily} docs, one per user> \
#     --slurpfile userl    <stream of {user_id, limits} docs, one per user> \
#     --slurpfile defaultl <default user ACU-limit response> \
#     --slurpfile sessions <{available, items} Devin Cloud sessions for the cycle> \
#     --slurpfile modela   <{available, stale, reason, fetched_at, rows} Windsurf model/IDE analytics> \
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

# consumption_by_date[] -> the daily point shape the app charts (used for both
# org and user series so the two detail views stay in lock-step).
def day_points:
  map((.date | day_forms) as $d
      | {date: $d.date,
         epoch: $d.epoch,
         acus: ((.acus // 0) | r2),
         devin: ((.acus_by_product.devin // 0) | r2),
         cascade: ((.acus_by_product.cascade // 0) | r2),
         terminal: ((.acus_by_product.terminal // 0) | r2),
         review: ((.acus_by_product.review // 0) | r2)})
  | sort_by(.epoch);

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

# Worst-of for an org's two meters: the row-level status drives the table badge
# and the filter chips, so it must reflect the more alarming meter.
def status_rank:
  {"ok": 0, "uncapped": 1, "blocked": 2, "warning": 3, "critical": 4,
   "forecast_over": 5, "over": 6}[.];
def worst_status($a; $b): if ($a | status_rank) >= ($b | status_rank) then $a else $b end;

# One enforcement meter (Local Agent or Devin Cloud): its own consumption,
# enforced cap, run rate, forecast, and status.
def org_meter($consumed; $limit; $elapsed_days; $cycle_days):
  ($consumed / $elapsed_days) as $mrate
  | ($mrate * $cycle_days) as $mproj
  | {
      consumed: ($consumed | r2),
      limit: $limit,
      daily_run_rate: ($mrate | r2),
      projected: ($mproj | r2),
      pct_limit: (if ($limit // 0) == 0 then null else (($consumed / $limit) | r3) end),
      status: org_status($consumed; $limit; $mproj)
    };

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
| ($orgd | map({key: .org_id, value: (
    [(.daily.consumption_by_date // [])[].acus_by_product]
    | {devin: ([.[].devin // 0] | add // 0),
       cascade: ([.[].cascade // 0] | add // 0),
       terminal: ([.[].terminal // 0] | add // 0),
       review: ([.[].review // 0] | add // 0)}
  )}) | from_entries) as $org_products
| ($orgl | map({key: .org_id, value: (.limits // {})}) | from_entries) as $org_limits
| ($orgd | map({key: .org_id, value: (.daily.consumption_by_date // [])}) | from_entries) as $org_daily
# Sessions bind before the org rows: the org detail page shows per-org Devin
# Cloud session stats (all sessions in the org, service users included —
# they burn the org's cloud gate the same as humans).
| ($sessions[0] // {available: false, items: []}) as $sess
| (($sess.items // []) | map(select(.org_id != null)) | group_by(.org_id)
   | map({key: .[0].org_id,
          value: {count: length, acus: (([.[].acus_consumed // 0] | add) | r2)}})
   | from_entries) as $org_sessions
| ($orglist | map(
    . as $o
    | ($org_consumed[$o.org_id] // 0) as $c
    | ($c / $elapsed_days) as $orate
    | ($orate * $cycle_days) as $oproj
    | ($org_products[$o.org_id]
       // {devin: 0, cascade: 0, terminal: 0, review: 0}) as $p
    | ($org_limits[$o.org_id] // {}) as $olim
    # Two independent enforcement gates, so two meters:
    #   Local Agent (cascade + terminal) vs local_agent.cycle_acu_limit,
    #   Devin Cloud (devin)              vs cloud_agent.cycle_acu_limit.
    # The v3 roster's max_cycle_acu_limit equals the cloud cap and is only a
    # fallback for a degraded org acu-limits fetch — dividing the all-product
    # total by it produced the old false OVER. review counts in the totals but
    # in neither gate.
    | ($olim.local_agent.cycle_acu_limit // null) as $local_limit
    | (if ($olim | has("cloud_agent")) and ($olim.cloud_agent != null)
       then ($olim.cloud_agent.cycle_acu_limit // null)
       elif ($olim | length) == 0 then $o.max_cycle_acu_limit
       else null end) as $cloud_limit
    | org_meter($p.cascade + $p.terminal; $local_limit; $elapsed_days; $cycle_days) as $local
    | org_meter($p.devin; $cloud_limit; $elapsed_days; $cycle_days) as $cloud
    | {
        org_id: $o.org_id,
        name: ($o.name // $o.org_id),
        consumed: ($c | r2),
        daily_run_rate: ($orate | r2),
        projected: ($oproj | r2),
        max_session_acu_limit: $o.max_session_acu_limit,
        products: ($p | map_values(r2)),
        local: $local,
        cloud: $cloud,
        status: worst_status($local.status; $cloud.status),
        daily: (($org_daily[$o.org_id] // []) | day_points),
        sessions: (if $sess.available
                   then ($org_sessions[$o.org_id] // {count: 0, acus: 0})
                   else null end)
      }
  )) as $org_rows
# Enterprise burn not attributed to any org (users without billing_org_id).
# Org-level caps cannot see or gate it, so surface the gap instead of letting
# org totals silently disagree with the enterprise total.
| ([$org_rows[].consumed] | add // 0) as $org_attributed
| ($consumed - $org_attributed) as $unattributed
| ($users[0].items // []) as $userlist
| ($userd | map({key: .user_id, value: (.daily.total_acus // 0)}) | from_entries) as $user_consumed
| ($userl | map({key: .user_id, value: (.limits // {})}) | from_entries) as $user_limits
| ($defaultl[0].local_agent.cycle_acu_limit // null) as $default_user_limit
| ($userd | map({key: .user_id, value: (.daily.consumption_by_date // [])}) | from_entries) as $user_daily
| (($sess.items // []) | map(select(.user_id != null)) | group_by(.user_id)
   | map({key: .[0].user_id,
          value: {count: length, acus: (([.[].acus_consumed // 0] | add) | r2)}})
   | from_entries) as $user_sessions
| ($modela[0] // {available: false, rows: []}) as $ma
| (($ma.rows // []) | group_by(.user_id)
   | map({key: .[0].user_id, value: .}) | from_entries) as $ma_by_user
| (($ma.rows // []) | map(select(.user_email != "")) | group_by(.user_email)
   | map({key: .[0].user_email, value: .}) | from_entries) as $ma_by_email
# Aggregate one user's Windsurf rows along a dimension ("model" or "ide").
| def dim_split($rows; $key):
    ($rows | group_by(.[$key])
     | map({($key): .[0][$key],
            acus: (([.[].acus] | add) | r2),
            messages: ([.[].messages] | add)})
     | sort_by(-.acus, -.messages));
  ($userlist | map(
    . as $u
    | ($user_consumed[$u.user_id] // 0) as $uc
    | ($user_limits[$u.user_id] // {}) as $lim
    | ($lim.local_agent.cycle_acu_limit // null) as $explicit_limit
    | (if $explicit_limit == null then $default_user_limit else $explicit_limit end) as $effective_limit
    | (($user_daily[$u.user_id] // []) | day_points) as $udaily
    | ($ma_by_user[$u.user_id] // $ma_by_email[$u.email] // []) as $ma_rows
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
        status: user_status($uc; $effective_limit),
        daily: $udaily,
        product_totals: {
          devin: (([$udaily[].devin] | add // 0) | r2),
          cascade: (([$udaily[].cascade] | add // 0) | r2),
          terminal: (([$udaily[].terminal] | add // 0) | r2),
          review: (([$udaily[].review] | add // 0) | r2)
        },
        sessions: (if $sess.available
                   then ($user_sessions[$u.user_id] // {count: 0, acus: 0})
                   else null end),
        models: dim_split($ma_rows; "model"),
        ides: dim_split($ma_rows; "ide")
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
    cap_totals: {
      effective_user_cycle_acu_limit: (([$user_rows[] | select(.effective_cycle_acu_limit != null) | .effective_cycle_acu_limit] | add // 0) | r2),
      capped_users: ([$user_rows[] | select(.effective_cycle_acu_limit != null)] | length),
      uncapped_users: ([$user_rows[] | select(.effective_cycle_acu_limit == null)] | length),
      zero_cap_users: ([$user_rows[] | select(.effective_cycle_acu_limit == 0)] | length)
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
    sessions_info: {
      available: $sess.available,
      count: (($sess.items // []) | length),
      acus: ((([($sess.items // [])[].acus_consumed // 0] | add) // 0) | r2)
    },
    # Per-session rows for the org detail page ("who used those sessions").
    # Trimmed to the fields the UI shows; sorted newest-first. created_at may
    # be an epoch or ISO string depending on the deployment — sort_by handles
    # either as long as the stream is homogeneous.
    cloud_sessions: {
      available: $sess.available,
      items: (($sess.items // []) | map({
        session_id: .session_id,
        url: (.url // null),
        title: (.title // null),
        status: (.status // null),
        status_detail: (.status_detail // null),
        user_id: (.user_id // null),
        service_user_id: (.service_user_id // null),
        org_id: (.org_id // null),
        created_at: (.created_at // null),
        updated_at: (.updated_at // null),
        acus_consumed: ((.acus_consumed // 0) | r2),
        origin: (.origin // null),
        category: (.category // null),
        subcategory: (.subcategory // null),
        is_archived: (.is_archived // false),
        playbook_id: (.playbook_id // null),
        tags: (.tags // []),
        pull_requests: (.pull_requests // [])
      }) | sort_by(.created_at) | reverse)
    },
    model_analytics: {
      available: $ma.available,
      stale: ($ma.stale // false),
      reason: ($ma.reason // null),
      fetched_at: ($ma.fetched_at // null),
      fetched_at_epoch: ($ma.fetched_at_epoch // null),
      start_date: ($ma.start_date // null),
      end_date: ($ma.end_date // null),
      # rows kept verbatim so the next refresh can reuse this section (TTL /
      # rate-limit carry-forward) without refetching the Windsurf API.
      rows: ($ma.rows // [])
    },
    orgs: $org_rows,
    attribution: {
      org_attributed: ($org_attributed | r2),
      unattributed: ($unattributed | r2),
      pct_unattributed: (if $consumed > 0 then (($unattributed / $consumed) | r3) else null end)
    },
    users: $user_rows,
    warnings: (
      # Per-meter, because that is how the caps enforce: a Local Agent overage
      # says nothing about Devin Cloud and vice versa.
      [$org_rows[] | . as $r
        | [["Local Agent", .local], ["Devin Cloud", .cloud]][] | . as [$g, $m]
        | if $m.status == "over"
          then "\($r.name) \($g) is OVER its cycle cap: \($m.consumed) of \($m.limit) ACUs consumed"
          elif $m.status == "forecast_over"
          then "\($r.name) \($g) is forecast to exceed its cycle cap: projected \($m.projected) vs cap \($m.limit)"
          elif $m.status == "uncapped"
          then "\($r.name) has no \($g) cycle cap (uncapped)"
          else empty end]
      + [$user_rows[] | select(.status == "over")
        | "\(.email) is OVER effective user cap: \(.consumed) of \(.effective_cycle_acu_limit) ACUs consumed"]
      + (if $unattributed > 0
         then ["\($unattributed | r2) ACUs (\((($unattributed / ([$consumed, 0.0001] | max)) * 100) | round)% of enterprise burn) are attributed to no organization — users without billing_org_id; org caps cannot gate that usage"]
         else [] end)
    )
  }
