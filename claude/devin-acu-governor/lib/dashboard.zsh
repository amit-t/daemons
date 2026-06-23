#!/usr/bin/env zsh
# dag dashboard — local, read-only ACU burn-rate + forecast dashboard.
# Fetches Devin v3 consumption (cycles, enterprise daily, orgs, per-org daily,
# users, per-user daily, per-user Local Agent limits, Devin Cloud sessions) and
# optionally Windsurf per-user model/IDE analytics, computes burn-rate +
# forecast via lib/dashboard.jq into data.json, then serves the React app in
# web/dashboard-app (built once, on first run) over a localhost HTTP server.
# With --refresh, a background loop refetches data.json on the cadence; the
# app polls status.json/data.json silently — no page reloads. The localhost
# server also accepts POST /__dag_refresh_now, writing a local signal file that
# interrupts the countdown for an immediate backend refetch. Local-only: the
# server binds 127.0.0.1 and nothing here is ever deployed.
# Read-only: GET requests only, no API writes. The cog_ key travels only as a
# curl Authorization header — never printed, logged, or written to a file.
#
# Requires: $daemon_dir set and lib/key-resolve.zsh sourced (bin/dag does both).
# DAG_NOW_EPOCH overrides "now" for deterministic tests.
# Test hooks: DAG_DASHBOARD_REFRESH_ONCE=1 (one refresh iteration),
# DAG_DASHBOARD_SERVE_ONCE=1 (start server, verify, stop, return).

# Gateway/overload HTTP classes that typically clear on retry. A 504 Gateway
# Time-out from Devin's edge (HTML body, not JSON) is the canonical case.
_dag_dash_is_transient_code() { [[ "$1" == (429|502|503|504) ]] }

# Record whether the last fetch's final failure was transient. _dag_dash_fetch
# almost always runs inside a $(...) command substitution, so a plain global
# cannot reach the caller — the flag is persisted to DAG_FETCH_FLAG_FILE (set by
# the writer) which survives the subshell. Callers read it via _last_transient.
_dag_dash_mark_transient() {  # $1 = 0|1
  DAG_FETCH_LAST_TRANSIENT=$1
  [[ -n "${DAG_FETCH_FLAG_FILE:-}" ]] && print -r -- "$1" > "${DAG_FETCH_FLAG_FILE}"
}
_dag_dash_last_transient() {  # true iff the last fetch failed transiently
  [[ "$(<"${DAG_FETCH_FLAG_FILE}" 2>/dev/null)" == 1 ]]
}

# ---- Refresh status channel ------------------------------------------------
# status.json sits next to data.json and is rewritten far more often than the
# heavy data.json: the countdown writes it once per cycle, a refresh writes it
# at every phase. The browser polls it (tiny, ~1s) to drive a live "next
# refresh in …" countdown and a "Refreshing N%" progress bar; the terminal
# prints the same to a single rewritten line. Written tmp+mv so a poll never
# reads a half-written file.
# $1=out_dir $2=state(counting_down|refreshing|static) $3=pct $4=phase
#   $5=detail $6=interval_seconds $7=next_refresh_epoch(0=none)
#   $8=generated_at('' = none)
_dag_dash_status_write() {
  local out_dir=$1 state=$2 pct=${3:-0} phase=${4:-} detail=${5:-}
  local interval=${6:-0} next=${7:-0} gen=${8:-} now
  [[ -d "$out_dir" ]] || return 0
  now="${DAG_NOW_EPOCH:-$(date +%s)}"
  jq -n \
    --arg state "$state" --argjson pct "$pct" \
    --arg phase "$phase" --arg detail "$detail" \
    --argjson interval "$interval" --argjson next "$next" \
    --argjson now "$now" --arg gen "$gen" \
    '{
      state: $state, pct: $pct, phase: $phase, detail: $detail,
      interval_seconds: $interval,
      next_refresh_epoch: (if $next == 0 then null else $next end),
      updated_at_epoch: $now,
      generated_at: (if $gen == "" then null else $gen end)
    }' > "${out_dir}/status.json.tmp" 2>/dev/null \
    && mv "${out_dir}/status.json.tmp" "${out_dir}/status.json" 2>/dev/null
  return 0
}

# Emit one refresh-progress step: persist a refreshing status.json (for the
# browser) and overwrite a single terminal line (for the operator). Carries the
# PREVIOUS generated_at so a polling browser does not pull the half-written
# data.json mid-refresh; the countdown/static write that follows carries the new
# one and is the single signal to refetch data.json.
# $1=out_dir $2=pct $3=phase $4=detail $5=prev_generated_at
_dag_dash_emit() {
  local out_dir=$1 pct=$2 phase=$3 detail=${4:-} gen=${5:-}
  _dag_dash_status_write "$out_dir" refreshing "$pct" "$phase" "$detail" 0 0 "$gen"
  [[ -t 1 ]] && print -n -- $'\r\033[K'"⟳ refreshing ${pct}%  ·  ${phase}${detail:+ (${detail})}"
}

# Terminal "snapshot ready" state — no live loop, so no countdown. The browser
# falls back to "data refreshed X ago" + an enabled Refresh-now button.
# $1=out_dir
_dag_dash_status_static() {
  local out_dir=$1 gen
  gen=$(jq -r '.generated_at // empty' "${out_dir}/data.json" 2>/dev/null)
  _dag_dash_status_write "$out_dir" static 100 "" "" 0 0 "$gen"
}

_dag_dash_fmt_dur() {  # $1=seconds -> "45s" | "4m 32s" | "1h 5m"
  local s=${1:-0}
  (( s < 0 )) && s=0
  if (( s < 60 )); then
    print -r -- "${s}s"
  elif (( s < 3600 )); then
    print -r -- "$(( s / 60 ))m $(( s % 60 ))s"
  else
    print -r -- "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
  fi
}

# Live countdown to the next refresh. Sleeps in 1-second steps, overwriting a
# single terminal line ("next refresh in 4m 32s"), and writes one counting_down
# status.json (with next_refresh_epoch) the browser turns into the same
# countdown without re-reading the file each second. $1=out_dir $2=seconds
# $3=watch_pid('' skips the liveness check) $4=request_file('' skips manual).
# Returns 1 only if the watched server died mid-countdown.
_dag_dash_countdown() {
  local out_dir=$1 secs=$2 watch_pid=${3:-} request_file=${4:-} now next gen remain
  now="$(date +%s)"
  next=$(( now + secs ))
  gen=$(jq -r '.generated_at // empty' "${out_dir}/data.json" 2>/dev/null)
  _dag_dash_status_write "$out_dir" counting_down 0 "" "" "$secs" "$next" "$gen"
  while :; do
    if _dag_dash_take_refresh_request "$request_file"; then
      [[ -t 1 ]] && print -n -- $'\r\033[K'"⟳ manual refresh requested"
      break
    fi
    remain=$(( next - $(date +%s) ))
    (( remain <= 0 )) && break
    if [[ -n "$watch_pid" ]] && ! kill -0 "$watch_pid" 2>/dev/null; then
      print -ru2 -- "dag dashboard: local server exited; stopping refresh loop"
      return 1
    fi
    [[ -t 1 ]] && print -n -- $'\r\033[K'"⟳ next refresh in $(_dag_dash_fmt_dur "$remain")  ·  Ctrl-C to stop"
    sleep 1
  done
  [[ -t 1 ]] && print -n -- $'\r\033[K'
  return 0
}

# $1=url $2=auth-header-file -> body on stdout; any failure quotes the exact
# diagnostics on stderr and returns 1. Transient failures (curl transport error,
# or HTTP 429/502/503/504) are retried with bounded linear backoff before giving
# up; DAG_FETCH_RETRIES (default 3) and DAG_FETCH_RETRY_SLEEP seconds (default 2,
# multiplied by attempt number) tune it. On the final give-up, the global
# DAG_FETCH_LAST_TRANSIENT is set to 1 for transient classes and 0 for hard
# errors, so callers can choose to degrade gracefully instead of aborting the
# whole dashboard. The header file (not argv) carries the key so it never shows
# in process listings; -q (first arg) ignores ~/.curlrc.
_dag_dash_fetch() {
  local url=$1 hdr=$2 response code body crc
  local retries=${DAG_FETCH_RETRIES:-3} sleep_base=${DAG_FETCH_RETRY_SLEEP:-2} attempt=0 wait
  _dag_dash_mark_transient 0
  while true; do
    response=$(curl -q -sS -w $'\n%{http_code}' -H "@${hdr}" "$url" 2>"${hdr:h}/curl-err")
    crc=$?
    code=${response##*$'\n'}
    body=${response%$'\n'*}
    if (( crc != 0 )); then
      # Transport-level failure (timeout, partial body, reset) — always transient.
      _dag_dash_mark_transient 1
      if (( attempt < retries )); then
        wait=$(( sleep_base * (attempt + 1) ))
        print -ru2 -- "dag dashboard: GET ${url} curl exit ${crc}; transient; retry $((attempt + 1))/${retries} in ${wait}s"
        (( wait > 0 )) && sleep "$wait"
        (( attempt++ )); continue
      fi
      print -ru2 -- "dag dashboard: GET ${url} failed: curl exit ${crc}: $(<"${hdr:h}/curl-err")"
      return 1
    fi
    if [[ "$code" != 200 ]]; then
      if _dag_dash_is_transient_code "$code"; then
        _dag_dash_mark_transient 1
        if (( attempt < retries )); then
          wait=$(( sleep_base * (attempt + 1) ))
          print -ru2 -- "dag dashboard: GET ${url} [${code}] transient; retry $((attempt + 1))/${retries} in ${wait}s"
          (( wait > 0 )) && sleep "$wait"
          (( attempt++ )); continue
        fi
      fi
      print -ru2 -- "dag dashboard: GET ${url} failed [${code}]: ${body}"
      return 1
    fi
    if ! jq -e . <<<"$body" >/dev/null 2>&1; then
      print -ru2 -- "dag dashboard: GET ${url} returned invalid JSON: ${body}"
      return 1
    fi
    print -r -- "$body"
    return 0
  done
}

_dag_dash_urlencode() {  # $1=raw string -> URL-encoded on stdout
  jq -nr --arg s "$1" '$s | @uri'
}

_dag_dash_fetch_members() {  # $1=base $2=auth-header-file $3=output-file
  local base=$1 hdr=$2 out=$3 pages="${3}.pages" cursor="" cursor_q="" url page has_next
  : > "$pages" || return 1
  while true; do
    url="${base}/v3/enterprise/members/users?first=200"
    if [[ -n "$cursor" ]]; then
      cursor_q=$(_dag_dash_urlencode "$cursor") || return 1
      url="${url}&after=${cursor_q}"
    fi
    page=$(_dag_dash_fetch "$url" "$hdr") || return 1
    print -r -- "$page" >> "$pages" || return 1
    has_next=$(jq -r '.has_next_page // false' <<<"$page") || return 1
    cursor=$(jq -r '.end_cursor // empty' <<<"$page") || return 1
    [[ "$has_next" == "true" && -n "$cursor" ]] || break
  done
  jq -s '{
    items: [.[].items[]?],
    end_cursor: (.[-1].end_cursor // null),
    has_next_page: false,
    total: ([.[].items[]?] | length)
  }' "$pages" > "$out"
}

# Devin Cloud sessions created inside the cycle (cursor pagination, like members).
# $1=base $2=auth-header-file $3=after $4=before $5=output-file
_dag_dash_fetch_sessions() {
  local base=$1 hdr=$2 after=$3 before=$4 out=$5 pages="${5}.pages" cursor="" cursor_q="" url page has_next
  : > "$pages" || return 1
  while true; do
    url="${base}/v3/enterprise/sessions?first=200&created_after=${after}&created_before=${before}"
    if [[ -n "$cursor" ]]; then
      cursor_q=$(_dag_dash_urlencode "$cursor") || return 1
      url="${url}&after=${cursor_q}"
    fi
    page=$(_dag_dash_fetch "$url" "$hdr") || return 1
    print -r -- "$page" >> "$pages" || return 1
    has_next=$(jq -r '.has_next_page // false' <<<"$page") || return 1
    cursor=$(jq -r '.end_cursor // empty' <<<"$page") || return 1
    [[ "$has_next" == "true" && -n "$cursor" ]] || break
  done
  jq -s '{available: true, items: [.[].items[]?]}' "$pages" > "$out"
}

# Per-user model/IDE ACU split for the cycle, from the Windsurf analytics API
# (separate service key; GET /api/v2alpha/analytics/consumption grouped by
# user,model_uid,ide). Optional enrichment — never fails the dashboard:
#   - no Windsurf key       -> {available:false, reason:"no_windsurf_key"}
#   - previous fetch younger than DAG_MODEL_ANALYTICS_TTL_MINUTES (default 20)
#                            -> previous data.json section reused, no request
#                              (the API allows only 10 requests/hour/team)
#   - request refused        -> previous good section carried forward stale:true,
#                              else {available:false, reason:"fetch_failed"}
# $1=out_dir $2=work $3=now $4=after $5=before; writes $2/model-analytics.json.
_dag_dash_fetch_model_analytics() {
  local out_dir=$1 work=$2 now=$3 after=$4 before=$5
  local out="${work}/model-analytics.json" prev="${out_dir}/data.json"
  local ttl_min="${DAG_MODEL_ANALYTICS_TTL_MINUTES:-20}"
  local wkey
  if ! wkey=$(dag_resolve_service_key); then
    jq -n '{available: false, reason: "no_windsurf_key", stale: false, fetched_at: null, rows: []}' > "$out"
    return 0
  fi

  local prev_sect=""
  if [[ -f "$prev" ]]; then
    prev_sect=$(jq -c 'if (.model_analytics.available // false) == true then .model_analytics else empty end' "$prev" 2>/dev/null)
  fi
  if [[ -n "$prev_sect" ]]; then
    local prev_epoch
    prev_epoch=$(jq -r '.fetched_at_epoch // 0' <<<"$prev_sect")
    if (( now - prev_epoch < ttl_min * 60 )); then
      print -r -- "$prev_sect" > "$out"
      return 0
    fi
  fi

  # Separate header file: this is the Windsurf key, not the cog_ key.
  local whdr="${work}/windsurf-auth-header"
  print -r -- "Authorization: Bearer ${wkey}" > "$whdr" || return 1
  chmod 600 "$whdr"

  local wbase="${DAG_WINDSURF_API_BASE:-https://server.codeium.com}"
  local start_date end_date eff_end=$(( now < before ? now : before ))
  start_date=$(date -u -r "$after" +%Y-%m-%d)
  end_date=$(date -u -r "$eff_end" +%Y-%m-%d)

  local pages="${out}.pages" cursor="" cursor_q="" url page
  : > "$pages" || return 1
  while true; do
    url="${wbase}/api/v2alpha/analytics/consumption?start_date=${start_date}&end_date=${end_date}&product=agent&group_by=user,model_uid,ide&page_size=10000"
    if [[ -n "$cursor" ]]; then
      cursor_q=$(_dag_dash_urlencode "$cursor") || return 1
      url="${url}&page_cursor=${cursor_q}"
    fi
    if ! page=$(_dag_dash_fetch "$url" "$whdr"); then
      if [[ -n "$prev_sect" ]]; then
        jq -c '. + {stale: true}' <<<"$prev_sect" > "$out"
        print -ru2 -- "dag dashboard: Windsurf model analytics refused (rate limit is 10 req/hr/team); carrying previous snapshot forward (stale)"
      else
        jq -n '{available: false, reason: "fetch_failed", stale: false, fetched_at: null, rows: []}' > "$out"
        print -ru2 -- "dag dashboard: Windsurf model analytics unavailable; user detail views will omit the model split"
      fi
      return 0
    fi
    print -r -- "$page" >> "$pages" || return 1
    cursor=$(jq -r '.pagination.next_page_cursor // empty' <<<"$page") || return 1
    [[ -n "$cursor" ]] || break
  done

  local fetched_at
  fetched_at=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)
  jq -s --arg fetched_at "$fetched_at" --argjson now "$now" \
    --arg start_date "$start_date" --arg end_date "$end_date" '{
      available: true, reason: null, stale: false,
      fetched_at: $fetched_at, fetched_at_epoch: $now,
      start_date: $start_date, end_date: $end_date,
      rows: [.[].data[]? | {
        user_id: (.user_id // ""),
        user_email: (.user_email // ""),
        model: (.model_uid // "unknown"),
        ide: (.ide // "unknown"),
        acus: (.consumption.billed_acus // 0),
        messages: (.consumption.message_count // 0)
      }]
    }' "$pages" > "$out"
}

# Fetch everything and write ${out_dir}/data.json atomically.
# $1=out_dir $2=refresh_minutes-or-empty (recorded as metadata for the UI).
_dag_dashboard_write_data() {
  local out_dir=$1 refresh_minutes=${2:-}
  local key
  if ! key=$(dag_resolve_cog_key); then
    print -ru2 -- "dag dashboard: no Devin API v3 service-user key (cog_...) found."
    print -ru2 -- "  Keychain: security add-generic-password -s ${DAG_COG_KEYCHAIN_SERVICE:-devin-cog-key} -a \"\$USER\" -w 'cog_...'"
    print -ru2 -- "  Or: export DEVIN_COG_KEY=cog_..."
    return 1
  fi

  local base="${DAG_API_BASE_V3:-https://api.devin.ai}"
  local now="${DAG_NOW_EPOCH:-$(date +%s)}"
  local pool="${DAG_MONTHLY_ACU_POOL:-24000}"

  # Previous snapshot timestamp, carried on every refreshing status so a polling
  # browser does not pull the not-yet-rewritten data.json mid-refresh. Create
  # out_dir up front so the status channel works from the very first run too.
  local prev_gen
  prev_gen=$(jq -r '.generated_at // empty' "${out_dir}/data.json" 2>/dev/null)
  mkdir -p "$out_dir" || return 1

  local work hdr DAG_FETCH_FLAG_FILE
  work=$(mktemp -d) || return 1
  {
    # mktemp dir is 0700; the header file keeps the key out of curl's argv.
    hdr="${work}/auth-header"
    # Subshell-surviving channel for the fetch transient flag (see _dag_dash_fetch).
    DAG_FETCH_FLAG_FILE="${work}/fetch-transient"
    print -r -- "Authorization: Bearer ${key}" > "$hdr" || return 1
    chmod 600 "$hdr"

    local cycles after before
    cycles=$(_dag_dash_fetch "${base}/v3/enterprise/consumption/cycles" "$hdr") || return 1
    after=$(jq -r --argjson now "$now" \
      '[.items[]? | select(.after <= $now and $now < .before)][0].after // empty' <<<"$cycles")
    before=$(jq -r --argjson now "$now" \
      '[.items[]? | select(.after <= $now and $now < .before)][0].before // empty' <<<"$cycles")
    if [[ -z "$after" || -z "$before" ]]; then
      print -ru2 -- "dag dashboard: no current billing cycle (now=${now}) in response: ${cycles}"
      return 1
    fi
    _dag_dash_emit "$out_dir" 5 "billing cycle" "" "$prev_gen"

    _dag_dash_fetch "${base}/v3/enterprise/consumption/daily?time_after=${after}&time_before=${before}" "$hdr" \
      > "${work}/enterprise-daily.json" || return 1
    _dag_dash_emit "$out_dir" 10 "enterprise daily" "" "$prev_gen"
    _dag_dash_fetch "${base}/v3/enterprise/organizations" "$hdr" \
      > "${work}/organizations.json" || return 1
    _dag_dash_emit "$out_dir" 14 "organizations" "" "$prev_gen"
    _dag_dash_fetch_members "$base" "$hdr" "${work}/members-users.json" || return 1
    _dag_dash_emit "$out_dir" 18 "members" "" "$prev_gen"
    # Default per-user ACU cap. A persistent transient failure here must not nuke
    # the whole dashboard: fall back to "no default" (uncapped) and warn loudly.
    local default_limit_json
    if ! default_limit_json=$(_dag_dash_fetch "${base}/v3beta1/enterprise/users/consumption/acu-limits" "$hdr"); then
      _dag_dash_last_transient || return 1
      print -ru2 -- "dag dashboard: default ACU-limit endpoint unavailable after retries; users without an explicit cap will show uncapped"
      default_limit_json='{}'
    fi
    print -r -- "$default_limit_json" > "${work}/user-default-limit.json" || return 1
    _dag_dash_emit "$out_dir" 22 "default caps" "" "$prev_gen"

    # Devin Cloud sessions: enrichment for the per-user detail view. Any
    # failure (including a missing ViewOrgSessions permission) degrades to
    # "unavailable" instead of nuking the whole dashboard.
    if ! _dag_dash_fetch_sessions "$base" "$hdr" "$after" "$before" "${work}/sessions.json"; then
      print -ru2 -- "dag dashboard: enterprise sessions endpoint unavailable; user detail views will omit Devin Cloud session stats"
      print -r -- '{"available": false, "items": []}' > "${work}/sessions.json" || return 1
    fi
    _dag_dash_emit "$out_dir" 26 "cloud sessions" "" "$prev_gen"

    # Windsurf model/IDE analytics: optional second key; degrades internally.
    _dag_dash_fetch_model_analytics "$out_dir" "$work" "$now" "$after" "$before" || return 1
    _dag_dash_emit "$out_dir" 30 "model analytics" "" "$prev_gen"

    : > "${work}/org-dailies.json"
    local oid od n_orgs i_org=0
    n_orgs=$(jq '[.items[]?.org_id] | length' "${work}/organizations.json")
    for oid in $(jq -r '.items[]?.org_id' "${work}/organizations.json"); do
      od=$(_dag_dash_fetch "${base}/v3/enterprise/consumption/daily/organizations/${oid}?time_after=${after}&time_before=${before}" "$hdr") || return 1
      jq -n --arg org_id "$oid" --argjson daily "$od" \
        '{org_id: $org_id, daily: $daily}' >> "${work}/org-dailies.json" || return 1
      (( i_org++ ))
      (( n_orgs > 0 )) && _dag_dash_emit "$out_dir" $(( 30 + i_org * 8 / n_orgs )) "org dailies" "${i_org}/${n_orgs}" "$prev_gen"
    done

    : > "${work}/user-dailies.json"
    : > "${work}/user-limits.json"
    local uid uid_q ud ul n_users i_user=0
    n_users=$(jq '[.items[]?.user_id] | length' "${work}/members-users.json")
    while IFS= read -r uid; do
      [[ -z "$uid" ]] && continue
      uid_q=$(_dag_dash_urlencode "$uid") || return 1
      ud=$(_dag_dash_fetch "${base}/v3/enterprise/consumption/daily/users/${uid_q}?time_after=${after}&time_before=${before}" "$hdr") || return 1
      jq -n --arg user_id "$uid" --argjson daily "$ud" \
        '{user_id: $user_id, daily: $daily}' >> "${work}/user-dailies.json" || return 1
      # Per-user explicit cap. Called once per user, so it is the endpoint most
      # likely to hit a transient 504 at scale. A persistent transient failure
      # degrades to "no explicit cap" (user falls back to the default) instead of
      # aborting the entire dashboard for everyone else.
      if ! ul=$(_dag_dash_fetch "${base}/v3beta1/enterprise/users/${uid_q}/consumption/acu-limits" "$hdr"); then
        _dag_dash_last_transient || return 1
        print -ru2 -- "dag dashboard: user ${uid} ACU-limit endpoint unavailable after retries; using default cap"
        ul='{}'
      fi
      jq -n --arg user_id "$uid" --argjson limits "$ul" \
        '{user_id: $user_id, limits: $limits}' >> "${work}/user-limits.json" || return 1
      (( i_user++ ))
      (( n_users > 0 )) && _dag_dash_emit "$out_dir" $(( 40 + i_user * 52 / n_users )) "user dailies" "${i_user}/${n_users}" "$prev_gen"
    done < <(jq -r '.items[]?.user_id' "${work}/members-users.json")

    _dag_dash_emit "$out_dir" 94 "computing forecast" "" "$prev_gen"
    local generated_at
    generated_at=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)

    if ! jq -n \
      --argjson now "$now" --argjson pool "$pool" \
      --argjson after "$after" --argjson before "$before" \
      --arg generated_at "$generated_at" \
      --arg refresh_minutes "$refresh_minutes" \
      --slurpfile ent "${work}/enterprise-daily.json" \
      --slurpfile orgs "${work}/organizations.json" \
      --slurpfile orgd "${work}/org-dailies.json" \
      --slurpfile users "${work}/members-users.json" \
      --slurpfile userd "${work}/user-dailies.json" \
      --slurpfile userl "${work}/user-limits.json" \
      --slurpfile defaultl "${work}/user-default-limit.json" \
      --slurpfile sessions "${work}/sessions.json" \
      --slurpfile modela "${work}/model-analytics.json" \
      -f "${daemon_dir}/lib/dashboard.jq" > "${out_dir}/data.json.tmp"; then
      rm -f "${out_dir}/data.json.tmp"
      print -ru2 -- "dag dashboard: failed to compute dashboard data (lib/dashboard.jq)"
      return 1
    fi
    mv "${out_dir}/data.json.tmp" "${out_dir}/data.json" || return 1
    _dag_dash_emit "$out_dir" 100 "snapshot ready" "" "$prev_gen"
    [[ -t 1 ]] && print -n -- $'\r\033[K'
    print -r -- "✓ refreshed at $(date -r "$now" +%H:%M:%S)"
    return 0
  } always {
    rm -rf "$work"
  }
}

# Ensure the React app is built; one-time npm install + build on first run.
# $1=1 forces a rebuild. Echoes nothing; dist lives at ${app_dir}/dist.
_dag_dash_ensure_app() {
  local force=${1:-0}
  local app_dir="${DAG_DASHBOARD_APP_DIR:-${daemon_dir}/web/dashboard-app}"
  local npm_cmd="${DAG_DASHBOARD_NPM:-npm}"
  if [[ ! -f "${app_dir}/package.json" ]]; then
    print -ru2 -- "dag dashboard: app source missing: ${app_dir}/package.json"
    return 1
  fi
  if (( ! force )) && [[ -f "${app_dir}/dist/index.html" ]]; then
    return 0
  fi
  if ! (( $+commands[$npm_cmd] )) && [[ ! -x "$npm_cmd" ]]; then
    print -ru2 -- "dag dashboard: '${npm_cmd}' not found — install Node.js (https://nodejs.org) to build the dashboard app (one-time)."
    return 1
  fi
  print -r -- "Building dashboard app (one-time): ${app_dir}"
  if [[ ! -d "${app_dir}/node_modules" ]]; then
    "$npm_cmd" --prefix "$app_dir" install --no-fund --no-audit || {
      print -ru2 -- "dag dashboard: npm install failed in ${app_dir}"
      return 1
    }
  fi
  "$npm_cmd" --prefix "$app_dir" run build || {
    print -ru2 -- "dag dashboard: npm run build failed in ${app_dir}"
    return 1
  }
  [[ -f "${app_dir}/dist/index.html" ]] || {
    print -ru2 -- "dag dashboard: build produced no dist/index.html in ${app_dir}"
    return 1
  }
}

# Copy the built app into out_dir next to data.json. Old hashed assets are
# cleared so the served dir never accumulates stale bundles.
_dag_dash_stage_app() {  # $1=out_dir
  local out_dir=$1
  local app_dir="${DAG_DASHBOARD_APP_DIR:-${daemon_dir}/web/dashboard-app}"
  mkdir -p "$out_dir" || return 1
  rm -rf "${out_dir}/assets"
  cp -R "${app_dir}/dist/." "$out_dir/" || {
    print -ru2 -- "dag dashboard: failed to stage app from ${app_dir}/dist into ${out_dir}"
    return 1
  }
}

_dag_dash_python() { print -r -- "${DAG_DASHBOARD_PYTHON:-python3}" }

_dag_dash_port_free() {  # $1=port -> 0 iff bindable on 127.0.0.1
  "$(_dag_dash_python)" -c '
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
' "$1" 2>/dev/null
}

_dag_dash_free_port() {  # -> an OS-assigned free port on stdout
  "$(_dag_dash_python)" -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
' 2>/dev/null
}

# Consume a pending browser-triggered refresh request, if any. The local server
# writes this signal file from POST /__dag_refresh_now; the dashboard loop owns
# the actual API fetch so keys stay in the zsh process, never the browser/server.
_dag_dash_take_refresh_request() {  # $1=request_file -> 0 iff consumed
  local request_file=${1:-}
  [[ -n "$request_file" && -f "$request_file" ]] || return 1
  rm -f "$request_file"
  return 0
}

_dag_dash_wait_manual_refresh() {  # $1=request_file $2=watch_pid
  local request_file=$1 watch_pid=${2:-}
  while :; do
    if _dag_dash_take_refresh_request "$request_file"; then
      [[ -t 1 ]] && print -n -- $'\r\033[K'"⟳ manual refresh requested"
      return 0
    fi
    if [[ -n "$watch_pid" ]] && ! kill -0 "$watch_pid" 2>/dev/null; then
      print -ru2 -- "dag dashboard: local server exited; stopping refresh loop"
      return 1
    fi
    sleep 1
  done
}

# Start the localhost dashboard server in the background; sets the caller-scoped
# _dag_dash_server_pid. Static files are served from out_dir, and POST
# /__dag_refresh_now writes a local signal file that the zsh loop consumes.
# $1=out_dir $2=port $3=refresh-request-file.
_dag_dash_serve_start() {
  local out_dir=$1 port=$2 request_file=$3 py
  py=$(_dag_dash_python)
  if ! (( $+commands[$py] )) && [[ ! -x "$py" ]]; then
    print -ru2 -- "dag dashboard: '${py}' not found — needed to serve the dashboard locally."
    return 1
  fi
  "$py" -c '
import http.server
import os
import pathlib
import socketserver
import sys
import time
import urllib.parse

PORT = int(sys.argv[1])
DIRECTORY = sys.argv[2]
REQUEST_FILE = sys.argv[3]
ENDPOINT = "/__dag_refresh_now"

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def log_message(self, format, *args):
        return

    def _send_json(self, code, body):
        payload = (body + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if path != ENDPOINT:
            self.send_error(404)
            return
        if self.headers.get("X-DAG-Refresh") != "1":
            self._send_json(403, "{\"ok\":false,\"error\":\"missing refresh header\"}")
            return
        try:
            request_path = pathlib.Path(REQUEST_FILE)
            request_path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = request_path.with_name(f"{request_path.name}.tmp.{os.getpid()}")
            tmp_path.write_text(f"{time.time_ns()}\n", encoding="utf-8")
            os.replace(tmp_path, request_path)
        except OSError:
            self._send_json(500, "{\"ok\":false,\"error\":\"failed to queue refresh\"}")
            return
        self._send_json(202, "{\"ok\":true}")

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == ENDPOINT:
            self.send_error(405)
            return
        super().do_GET()

class ReuseServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReuseServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
' "$port" "$out_dir" "$request_file" >/dev/null 2>&1 &
  _dag_dash_server_pid=$!
  sleep "${DAG_DASHBOARD_SERVE_GRACE:-0.3}"
  if ! kill -0 "$_dag_dash_server_pid" 2>/dev/null; then
    print -ru2 -- "dag dashboard: local server failed to start on 127.0.0.1:${port}"
    _dag_dash_server_pid=""
    return 1
  fi
}

_dag_dash_serve_stop() {
  if [[ -n "${_dag_dash_server_pid:-}" ]]; then
    kill "$_dag_dash_server_pid" 2>/dev/null
    wait "$_dag_dash_server_pid" 2>/dev/null
    _dag_dash_server_pid=""
  fi
}

dag_dashboard() {
  local open_after=1 json_only=0 out_dir="" refresh_minutes="" refresh_seconds=0
  local port="${DAG_DASHBOARD_PORT:-}" rebuild=0
  while (( $# )); do
    case "$1" in
      --no-open)   open_after=0 ;;
      --json-only) json_only=1 ;;
      --rebuild)   rebuild=1 ;;
      --out)
        shift
        if [[ -z "${1:-}" || "$1" == -* ]]; then
          print -ru2 -- "dag dashboard: --out requires a directory argument"
          return 2
        fi
        out_dir="$1"
        ;;
      --port)
        shift
        if [[ -z "${1:-}" || "$1" != <1-65535> ]]; then
          print -ru2 -- "dag dashboard: --port requires a port number (1-65535)"
          return 2
        fi
        port="$1"
        ;;
      --refresh)
        shift
        if [[ -z "${1:-}" || "$1" == -* ]]; then
          print -ru2 -- "dag dashboard: --refresh requires minutes: 5, 10, 15, or 30"
          return 2
        fi
        case "$1" in
          5|10|15|30) refresh_minutes="$1" ;;
          *)
            print -ru2 -- "dag dashboard: --refresh must be 5, 10, 15, or 30 minutes (got: $1)"
            return 2
            ;;
        esac
        ;;
      *)
        print -ru2 -- "dag dashboard: unknown flag '$1' (expected --no-open, --json-only, --rebuild, --out <dir>, --port <n>, --refresh <5|10|15|30>)"
        return 2
        ;;
    esac
    shift
  done
  : ${out_dir:=${DAG_STATE_DIR}/dashboard/latest}
  out_dir=${out_dir:A}

  # --json-only: data artifact only — no app build, no server, no browser.
  if (( json_only )); then
    if [[ -z "$refresh_minutes" ]]; then
      _dag_dashboard_write_data "$out_dir" "" || return $?
      _dag_dash_status_static "$out_dir"
      return 0
    fi
    refresh_seconds=$(( refresh_minutes * 60 ))
    while true; do
      _dag_dashboard_write_data "$out_dir" "$refresh_minutes" || return $?
      print -r -- "Refresh: every ${refresh_minutes} minute(s). Keep this command running; press Ctrl-C to stop."
      [[ "${DAG_DASHBOARD_REFRESH_ONCE:-}" == "1" ]] && { _dag_dash_status_static "$out_dir"; return 0; }
      _dag_dash_countdown "$out_dir" "$refresh_seconds" ""
    done
  fi

  _dag_dash_ensure_app "$rebuild" || return 1
  _dag_dashboard_write_data "$out_dir" "$refresh_minutes" || return 1
  _dag_dash_stage_app "$out_dir" || return 1

  if [[ -z "$port" ]]; then
    port="${DAG_DASHBOARD_DEFAULT_PORT:-8642}"
    if ! _dag_dash_port_free "$port"; then
      local fallback
      fallback=$(_dag_dash_free_port)
      if [[ -z "$fallback" ]]; then
        print -ru2 -- "dag dashboard: port ${port} busy and no free port found"
        return 1
      fi
      print -ru2 -- "dag dashboard: port ${port} busy; using ${fallback} (pin with --port or DAG_DASHBOARD_PORT)"
      port="$fallback"
    fi
  fi

  local _dag_dash_server_pid=""
  local _dag_dash_refresh_request_file="${out_dir}/.dag-refresh-request"
  rm -f "$_dag_dash_refresh_request_file"
  # `always` does not run when the shell dies on a signal — without these traps
  # a TERM/HUP to dag would orphan the python server on the port forever.
  trap '_dag_dash_serve_stop; trap - INT TERM HUP; return 130' INT TERM HUP
  {
    _dag_dash_serve_start "$out_dir" "$port" "$_dag_dash_refresh_request_file" || return 1
    local url="http://127.0.0.1:${port}/"
    print -r -- "Dashboard serving:"
    print -r -- "  ${url}"
    print -r -- "  data: ${out_dir}/data.json"
    if [[ -n "$refresh_minutes" ]]; then
      print -r -- "Refresh: data refetched every ${refresh_minutes} minute(s) in the background; the page updates itself without reloading."
    else
      print -r -- "Refresh: static snapshot — rerun with --refresh <5|10|15|30> for live data."
    fi
    print -r -- "Press Ctrl-C to stop the server."
    (( open_after )) && open "$url"

    [[ "${DAG_DASHBOARD_SERVE_ONCE:-}" == "1" ]] && { _dag_dash_status_static "$out_dir"; return 0; }

    if [[ -z "$refresh_minutes" ]]; then
      _dag_dash_status_static "$out_dir"
      while true; do
        _dag_dash_wait_manual_refresh "$_dag_dash_refresh_request_file" "$_dag_dash_server_pid" || return 1
        _dag_dashboard_write_data "$out_dir" "" || return $?
        _dag_dash_status_static "$out_dir"
      done
    fi

    refresh_seconds=$(( refresh_minutes * 60 ))
    while true; do
      [[ "${DAG_DASHBOARD_REFRESH_ONCE:-}" == "1" ]] && { _dag_dash_status_static "$out_dir"; return 0; }
      # Live countdown (terminal + browser); returns 1 if the server died.
      _dag_dash_countdown "$out_dir" "$refresh_seconds" "$_dag_dash_server_pid" "$_dag_dash_refresh_request_file" || return 1
      _dag_dashboard_write_data "$out_dir" "$refresh_minutes" || return $?
    done
  } always {
    _dag_dash_serve_stop
  }
}
