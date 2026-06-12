#!/usr/bin/env zsh
# dag dashboard — local, read-only ACU burn-rate + forecast dashboard.
# Fetches Devin v3 consumption (cycles, enterprise daily, orgs, per-org daily,
# users, per-user daily, per-user Local Agent limits), computes burn-rate +
# forecast via lib/dashboard.jq, writes data.json + dashboard-data.js and a
# static HTML/CSS/JS app, and optionally opens it.
# Read-only: GET requests only, no API writes. The cog_ key travels only as a
# curl Authorization header — never printed, logged, or written to a file.
#
# Requires: $daemon_dir set and lib/key-resolve.zsh sourced (bin/dag does both).
# DAG_NOW_EPOCH overrides "now" for deterministic tests.

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

_dag_dashboard_write_once() {  # $1=open_after $2=json_only $3=out_dir $4=refresh_minutes-or-empty
  local open_after=$1 json_only=$2 out_dir=$3 refresh_minutes=${4:-}
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

    _dag_dash_fetch "${base}/v3/enterprise/consumption/daily?time_after=${after}&time_before=${before}" "$hdr" \
      > "${work}/enterprise-daily.json" || return 1
    _dag_dash_fetch "${base}/v3/enterprise/organizations" "$hdr" \
      > "${work}/organizations.json" || return 1
    _dag_dash_fetch_members "$base" "$hdr" "${work}/members-users.json" || return 1
    # Default per-user ACU cap. A persistent transient failure here must not nuke
    # the whole dashboard: fall back to "no default" (uncapped) and warn loudly.
    local default_limit_json
    if ! default_limit_json=$(_dag_dash_fetch "${base}/v3beta1/enterprise/users/consumption/acu-limits" "$hdr"); then
      _dag_dash_last_transient || return 1
      print -ru2 -- "dag dashboard: default ACU-limit endpoint unavailable after retries; users without an explicit cap will show uncapped"
      default_limit_json='{}'
    fi
    print -r -- "$default_limit_json" > "${work}/user-default-limit.json" || return 1

    : > "${work}/org-dailies.json"
    local oid od
    for oid in $(jq -r '.items[]?.org_id' "${work}/organizations.json"); do
      od=$(_dag_dash_fetch "${base}/v3/enterprise/consumption/daily/organizations/${oid}?time_after=${after}&time_before=${before}" "$hdr") || return 1
      jq -n --arg org_id "$oid" --argjson daily "$od" \
        '{org_id: $org_id, daily: $daily}' >> "${work}/org-dailies.json" || return 1
    done

    : > "${work}/user-dailies.json"
    : > "${work}/user-limits.json"
    local uid uid_q ud ul
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
    done < <(jq -r '.items[]?.user_id' "${work}/members-users.json")

    local generated_at
    generated_at=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$out_dir"
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
      -f "${daemon_dir}/lib/dashboard.jq" > "${out_dir}/data.json.tmp"; then
      rm -f "${out_dir}/data.json.tmp"
      print -ru2 -- "dag dashboard: failed to compute dashboard data (lib/dashboard.jq)"
      return 1
    fi
    mv "${out_dir}/data.json.tmp" "${out_dir}/data.json" || return 1

    {
      print -rn -- "window.DAG_DASHBOARD_DATA = "
      cat "${out_dir}/data.json"
      print -r -- ";"
    } > "${out_dir}/dashboard-data.js.tmp"
    mv "${out_dir}/dashboard-data.js.tmp" "${out_dir}/dashboard-data.js" || return 1

    if (( ! json_only )); then
      cp "${daemon_dir}/web/dashboard/dashboard.html" \
         "${daemon_dir}/web/dashboard/dashboard.css" \
         "${daemon_dir}/web/dashboard/dashboard.js" \
         "${out_dir}/" || return 1
    fi

    print -r -- "Dashboard written:"
    (( ! json_only )) && print -r -- "  ${out_dir}/dashboard.html"
    print -r -- "  ${out_dir}/dashboard-data.js"
    print -r -- "  ${out_dir}/data.json"
    if [[ -n "$refresh_minutes" ]]; then
      print -r -- "Refresh: every ${refresh_minutes} minute(s). Keep this command running; press Ctrl-C to stop."
    fi
    if (( ! json_only )); then
      print -r -- "Open:"
      print -r -- "  file://${out_dir}/dashboard.html"
      (( open_after )) && open "${out_dir}/dashboard.html"
    fi
    return 0
  } always {
    rm -rf "$work"
  }
}

dag_dashboard() {
  local open_after=1 json_only=0 out_dir="" refresh_minutes="" refresh_seconds=0
  while (( $# )); do
    case "$1" in
      --no-open)   open_after=0 ;;
      --json-only) json_only=1 ;;
      --out)
        shift
        if [[ -z "${1:-}" || "$1" == -* ]]; then
          print -ru2 -- "dag dashboard: --out requires a directory argument"
          return 2
        fi
        out_dir="$1"
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
        print -ru2 -- "dag dashboard: unknown flag '$1' (expected --no-open, --json-only, --out <dir>, --refresh <5|10|15|30>)"
        return 2
        ;;
    esac
    shift
  done
  : ${out_dir:=${DAG_STATE_DIR}/dashboard/latest}
  out_dir=${out_dir:A}

  if [[ -z "$refresh_minutes" ]]; then
    _dag_dashboard_write_once "$open_after" "$json_only" "$out_dir" ""
    return $?
  fi

  refresh_seconds=$(( refresh_minutes * 60 ))
  while true; do
    _dag_dashboard_write_once "$open_after" "$json_only" "$out_dir" "$refresh_minutes" || return $?
    [[ "${DAG_DASHBOARD_REFRESH_ONCE:-}" == "1" ]] && return 0
    sleep "$refresh_seconds"
    open_after=0
  done
}
