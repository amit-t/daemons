#!/usr/bin/env zsh
# dag dashboard — local, read-only ACU burn-rate + forecast dashboard.
# Fetches Devin v3 consumption (cycles, enterprise daily, orgs, per-org daily),
# computes burn-rate + forecast via lib/dashboard.jq, writes data.json +
# dashboard-data.js and a static HTML/CSS/JS app, and optionally opens it.
# Read-only: GET requests only, no API writes. The cog_ key travels only as a
# curl Authorization header — never printed, logged, or written to a file.
#
# Requires: $daemon_dir set and lib/key-resolve.zsh sourced (bin/dag does both).
# DAG_NOW_EPOCH overrides "now" for deterministic tests.

# $1=url $2=auth-header-file -> body on stdout; any failure quotes the exact
# diagnostics on stderr and returns 1. The header file (not argv) carries the
# key so it never shows in process listings; -q (first arg) ignores ~/.curlrc.
_dag_dash_fetch() {
  local url=$1 hdr=$2 response code body crc
  response=$(curl -q -sS -w $'\n%{http_code}' -H "@${hdr}" "$url" 2>"${hdr:h}/curl-err")
  crc=$?
  if (( crc != 0 )); then
    print -ru2 -- "dag dashboard: GET ${url} failed: curl exit ${crc}: $(<"${hdr:h}/curl-err")"
    return 1
  fi
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  if [[ "$code" != 200 ]]; then
    print -ru2 -- "dag dashboard: GET ${url} failed [${code}]: ${body}"
    return 1
  fi
  if ! jq -e . <<<"$body" >/dev/null 2>&1; then
    print -ru2 -- "dag dashboard: GET ${url} returned invalid JSON: ${body}"
    return 1
  fi
  print -r -- "$body"
}

dag_dashboard() {
  local open_after=1 json_only=0 out_dir=""
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
      *)
        print -ru2 -- "dag dashboard: unknown flag '$1' (expected --no-open, --json-only, --out <dir>)"
        return 2
        ;;
    esac
    shift
  done
  : ${out_dir:=${DAG_STATE_DIR}/dashboard/latest}
  out_dir=${out_dir:A}

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

  local work hdr
  work=$(mktemp -d) || return 1
  {
    # mktemp dir is 0700; the header file keeps the key out of curl's argv.
    hdr="${work}/auth-header"
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

    : > "${work}/org-dailies.json"
    local oid od
    for oid in $(jq -r '.items[]?.org_id' "${work}/organizations.json"); do
      od=$(_dag_dash_fetch "${base}/v3/enterprise/consumption/daily/organizations/${oid}?time_after=${after}&time_before=${before}" "$hdr") || return 1
      jq -n --arg org_id "$oid" --argjson daily "$od" \
        '{org_id: $org_id, daily: $daily}' >> "${work}/org-dailies.json" || return 1
    done

    local generated_at
    generated_at=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$out_dir"
    if ! jq -n \
      --argjson now "$now" --argjson pool "$pool" \
      --argjson after "$after" --argjson before "$before" \
      --arg generated_at "$generated_at" \
      --slurpfile ent "${work}/enterprise-daily.json" \
      --slurpfile orgs "${work}/organizations.json" \
      --slurpfile orgd "${work}/org-dailies.json" \
      -f "${daemon_dir}/lib/dashboard.jq" > "${out_dir}/data.json"; then
      rm -f "${out_dir}/data.json"
      print -ru2 -- "dag dashboard: failed to compute dashboard data (lib/dashboard.jq)"
      return 1
    fi

    {
      print -rn -- "window.DAG_DASHBOARD_DATA = "
      cat "${out_dir}/data.json"
      print -r -- ";"
    } > "${out_dir}/dashboard-data.js"

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
