#!/usr/bin/env zsh
# dag usage — local, read-only per-user consumed-vs-cap report.
# Lists every enterprise user with current-cycle consumed ACUs, their effective
# Local Agent cap (explicit per-user override, else default user limit, else none),
# and the consumed/cap ratio, sorted by most-pressured first.
#
# Deterministic and local: GET requests only, no API writes, no agent launch.
# All arithmetic lives in lib/usage.jq. The cog_ key travels only as a curl
# Authorization header file (0600) — never printed, logged, or written elsewhere.
#
# Requires: $daemon_dir set and lib/key-resolve.zsh sourced (bin/dag does both).
# DAG_NOW_EPOCH overrides "now" for deterministic tests.

# $1=url $2=hdr-file $3=allow404(0/1) -> body on stdout (or "{}" on tolerated 404);
# any failure quotes exact diagnostics on stderr and returns 1. The header file
# (not argv) carries the key so it never shows in process listings; -q ignores ~/.curlrc.
_dag_usage_fetch() {
  local url=$1 hdr=$2 allow404=${3:-0} response code body crc
  response=$(curl -q -sS -w $'\n%{http_code}' -H "@${hdr}" "$url" 2>"${hdr:h}/curl-err")
  crc=$?
  if (( crc != 0 )); then
    print -ru2 -- "dag usage: GET ${url} failed: curl exit ${crc}: $(<"${hdr:h}/curl-err")"
    return 1
  fi
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  if [[ "$code" == 404 && "$allow404" == 1 ]]; then
    print -r -- "{}"
    return 0
  fi
  if [[ "$code" != 200 ]]; then
    print -ru2 -- "dag usage: GET ${url} failed [${code}]: ${body}"
    return 1
  fi
  if ! jq -e . <<<"$body" >/dev/null 2>&1; then
    print -ru2 -- "dag usage: GET ${url} returned invalid JSON: ${body}"
    return 1
  fi
  print -r -- "$body"
}

# jq @uri-encode a single string (user_id can contain '|', cursors can carry reserved chars).
_dag_uri() { jq -rn --arg s "$1" '$s|@uri'; }

dag_usage_report() {
  local json_only=0 top=0
  while (( $# )); do
    case "$1" in
      --json) json_only=1 ;;
      --top)
        shift
        if [[ -z "${1:-}" || "$1" != <1-> ]]; then
          print -ru2 -- "dag usage: --top requires a positive integer"
          return 2
        fi
        top=$1
        ;;
      *)
        print -ru2 -- "dag usage: unknown flag '$1' (expected --json, --top <n>)"
        return 2
        ;;
    esac
    shift
  done

  local key
  if ! key=$(dag_resolve_cog_key); then
    print -ru2 -- "dag usage: no Devin API v3 service-user key (cog_...) found."
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
    hdr="${work}/auth-header"
    print -r -- "Authorization: Bearer ${key}" > "$hdr" || return 1
    chmod 600 "$hdr"

    # 1. Current billing cycle.
    local cycles after before
    cycles=$(_dag_usage_fetch "${base}/v3/enterprise/consumption/cycles" "$hdr") || return 1
    after=$(jq -r --argjson now "$now" \
      '[.items[]? | select(.after <= $now and $now < .before)][0].after // empty' <<<"$cycles")
    before=$(jq -r --argjson now "$now" \
      '[.items[]? | select(.after <= $now and $now < .before)][0].before // empty' <<<"$cycles")
    if [[ -z "$after" || -z "$before" ]]; then
      print -ru2 -- "dag usage: no current billing cycle (now=${now}) in response: ${cycles}"
      return 1
    fi

    # 2. Default per-user Local Agent limit (inherited when a user has no override).
    local defbody default_cap
    defbody=$(_dag_usage_fetch "${base}/v3beta1/enterprise/users/consumption/acu-limits" "$hdr" 1) || return 1
    default_cap=$(jq -c '.local_agent.cycle_acu_limit // null' <<<"$defbody")

    # 3. Roster (cursor pagination).
    local roster="${work}/roster.ndjson"
    : > "$roster"
    local cursor="" url page enc
    while :; do
      url="${base}/v3/enterprise/members/users?limit=100"
      if [[ -n "$cursor" ]]; then
        enc=$(_dag_uri "$cursor")
        url+="&after=${enc}"
      fi
      page=$(_dag_usage_fetch "$url" "$hdr") || return 1
      jq -c '.items[]? | {user_id, email, name}' <<<"$page" >> "$roster"
      [[ "$(jq -r '.has_next_page // false' <<<"$page")" == "true" ]] || break
      cursor=$(jq -r '.end_cursor // empty' <<<"$page")
      [[ -n "$cursor" ]] || break
    done

    local n_users
    n_users=$(wc -l < "$roster" | tr -d ' ')
    if [[ "$n_users" == 0 ]]; then
      print -ru2 -- "dag usage: roster is empty"
      return 1
    fi
    print -ru2 -- "dag usage: fetching consumption + cap for ${n_users} user(s)..."

    # 4. Per-user current-cycle consumption + explicit override.
    local users="${work}/users.ndjson"
    : > "$users"
    local line uid email name encid cbody obody consumed override i=0
    while IFS= read -r line; do
      uid=$(jq -r '.user_id' <<<"$line")
      email=$(jq -r '.email // ""' <<<"$line")
      name=$(jq -r '.name // ""' <<<"$line")
      encid=$(_dag_uri "$uid")
      (( i++ ))
      print -rnu2 -- $'\r'"  ${i}/${n_users}"

      cbody=$(_dag_usage_fetch \
        "${base}/v3/enterprise/consumption/daily/users/${encid}?time_after=${after}&time_before=${before}" \
        "$hdr" 1) || { print -ru2 -- ""; return 1; }
      consumed=$(jq -c '.total_acus // 0' <<<"$cbody")

      obody=$(_dag_usage_fetch \
        "${base}/v3beta1/enterprise/users/${encid}/consumption/acu-limits" \
        "$hdr" 1) || { print -ru2 -- ""; return 1; }
      override=$(jq -c '.local_agent.cycle_acu_limit // null' <<<"$obody")

      jq -nc --arg email "$email" --arg user_id "$uid" --arg name "$name" \
        --argjson consumed "$consumed" --argjson override "$override" \
        '{email:$email, user_id:$user_id, name:$name, consumed:$consumed, override:$override}' \
        >> "$users"
    done < "$roster"
    print -ru2 -- ""

    # 5. Compute table (all arithmetic in jq).
    local generated_at
    generated_at=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)

    local data
    data=$(jq -n \
      --argjson pool "$pool" --arg gen "$generated_at" \
      --argjson after "$after" --argjson before "$before" \
      --argjson default_cap "$default_cap" \
      --slurpfile users "$users" \
      '{pool:$pool, generated_at:$gen, cycle:{after:$after, before:$before},
        default_cap:$default_cap, users:$users[0:]}' \
      | jq -f "${daemon_dir}/lib/usage.jq") || {
        print -ru2 -- "dag usage: failed to compute usage table (lib/usage.jq)"
        return 1
      }

    if (( json_only )); then
      print -r -- "$data"
      return 0
    fi

    # 6. Render.
    local after_d before_d
    after_d=$(date -r "$after" +%F)
    before_d=$(date -r "$before" +%F)
    print -r -- "dag usage — per-user consumed vs Local Agent cap"
    print -r -- "  cycle: ${after_d} → ${before_d}   pool: ${pool} ACUs   generated: ${generated_at}"
    local defshow
    defshow=$(jq -r 'if .default_cap == null then "<unset>" else (.default_cap|tostring) end' <<<"$data")
    print -r -- "  default per-user Local Agent cap: ${defshow}"
    print -r -- ""

    local rows
    rows=$(jq -r '
      def r1($x): (($x*10)|round)/10;
      (["EMAIL","CONSUMED","CAP","USED%","SOURCE","STATE"]),
      (.rows[] | [
        .email,
        (r1(.consumed)|tostring),
        (if .cap == null then "∞" else (.cap|tostring) end),
        (if .ratio == null then "—" else (r1(.ratio*100)|tostring) end),
        .source,
        .state
      ]) | @tsv' <<<"$data")
    if (( top > 0 )); then
      rows=$(print -r -- "$rows" | head -n $(( top + 1 )))
    fi
    print -r -- "$rows" | column -t -s $'\t'
    print -r -- ""

    jq -r '.totals |
      "Totals: \(.users) users  consumed \((.total_consumed*10|round)/10)  sum_caps \(.sum_caps)  " +
      "OVER \(.n_over)  NEAR \(.n_near)  UNLIMITED \(.n_unlimited)  BLOCKED \(.n_blocked)"' <<<"$data"
    print -r -- "UI: app.devin.ai > Enterprise Settings > Consumption shows current-cycle Local Agent usage by product/user; Local Agent limits are API-managed."
    return 0
  } always {
    rm -rf "$work"
  }
}
