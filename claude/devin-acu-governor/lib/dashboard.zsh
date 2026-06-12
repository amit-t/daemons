#!/usr/bin/env zsh
# dag dashboard — local, read-only ACU burn-rate + forecast dashboard.
# Fetches Devin v3 consumption (cycles, enterprise daily, orgs, per-org daily,
# users, per-user daily, per-user Local Agent limits), computes burn-rate +
# forecast via lib/dashboard.jq into data.json, then serves the React app in
# web/dashboard-app (built once, on first run) over a localhost HTTP server.
# With --refresh, a background loop refetches data.json on the cadence; the
# app polls it silently — no page reloads. Local-only: the server binds
# 127.0.0.1 and nothing here is ever deployed.
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
    print -r -- "Data written: ${out_dir}/data.json"
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

# Start the localhost static server in the background; sets the caller-scoped
# _dag_dash_server_pid. $1=out_dir $2=port.
_dag_dash_serve_start() {
  local out_dir=$1 port=$2 py
  py=$(_dag_dash_python)
  if ! (( $+commands[$py] )) && [[ ! -x "$py" ]]; then
    print -ru2 -- "dag dashboard: '${py}' not found — needed to serve the dashboard locally."
    return 1
  fi
  "$py" -m http.server "$port" --bind 127.0.0.1 --directory "$out_dir" >/dev/null 2>&1 &
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
      _dag_dashboard_write_data "$out_dir" ""
      return $?
    fi
    refresh_seconds=$(( refresh_minutes * 60 ))
    while true; do
      _dag_dashboard_write_data "$out_dir" "$refresh_minutes" || return $?
      print -r -- "Refresh: every ${refresh_minutes} minute(s). Keep this command running; press Ctrl-C to stop."
      [[ "${DAG_DASHBOARD_REFRESH_ONCE:-}" == "1" ]] && return 0
      sleep "$refresh_seconds"
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
  # `always` does not run when the shell dies on a signal — without these traps
  # a TERM/HUP to dag would orphan the python server on the port forever.
  trap '_dag_dash_serve_stop; trap - INT TERM HUP; return 130' INT TERM HUP
  {
    _dag_dash_serve_start "$out_dir" "$port" || return 1
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

    [[ "${DAG_DASHBOARD_SERVE_ONCE:-}" == "1" ]] && return 0

    if [[ -z "$refresh_minutes" ]]; then
      wait "$_dag_dash_server_pid"
      return 0
    fi

    refresh_seconds=$(( refresh_minutes * 60 ))
    while true; do
      [[ "${DAG_DASHBOARD_REFRESH_ONCE:-}" == "1" ]] && return 0
      sleep "$refresh_seconds"
      if ! kill -0 "$_dag_dash_server_pid" 2>/dev/null; then
        print -ru2 -- "dag dashboard: local server exited; stopping refresh loop"
        return 1
      fi
      _dag_dashboard_write_data "$out_dir" "$refresh_minutes" || return $?
    done
  } always {
    _dag_dash_serve_stop
  }
}
