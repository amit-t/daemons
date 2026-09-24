#!/usr/bin/env zsh
# Org ACU limit helpers for dag (Local Agent + Devin Cloud org gates).
# Deterministic local commands: no agent launch. Uses Devin V3 beta ACU-limit
# endpoints, quotes exact API error bodies, and verifies writes with a follow-up GET.
# Gate selector: `local` (default) writes local_agent.cycle_acu_limit,
# `cloud` writes cloud_agent.cycle_acu_limit.
# Org ceiling rule: consumption bills to exactly one org and each org gate caps
# only that org's usage, so the enterprise-wide org ceiling is Σ of EVERY org's
# explicit local + cloud caps (umbrella org included — there is no hierarchy).
# A write is refused before any PATCH when it would leave that Σ above
# DAG_MONTHLY_ACU_POOL and higher than it was; writes that shrink an
# already-over layer are allowed (they move it toward the ceiling).
# Requires: lib/key-resolve.zsh sourced by bin/dag.

_dag_limits_request() {  # $1=method $2=url $3=key $4=json-body-or-empty -> globals _dag_limits_code/body
  local method=$1 url=$2 key=$3 body=${4:-} response
  local -a args
  args=(-sS -w $'\n%{http_code}' -X "$method" -H "Authorization: Bearer ${key}")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  response=$(curl "${args[@]}" "$url" 2>/dev/null) || response=$'\n000'
  typeset -g _dag_limits_code="${response##*$'\n'}"
  typeset -g _dag_limits_body="${response%$'\n'*}"
}

_dag_limits_print_ui_hint() {
  print -r -- "View in UI:"
  print -r -- "  app.devin.ai > Enterprise Settings > Consumption"
  print -r -- "  You can view current-cycle Local Agent ACU usage by product or user there."
  print -r -- "  Limits themselves are API-managed; use this command's live GET verification for the configured limit."
}

_dag_limits_list_orgs() {  # $1=orgs-json
  jq -r '.items[]? | "  \(.org_id)  \(.name // "<unnamed>")"' <<<"$1"
}

_dag_limits_select_orgs() {  # $1=orgs-json $2=selector-or-empty -> compact org JSON rows on stdout
  local orgs=$1 selector=${2:-} count
  if [[ -z "$selector" ]]; then
    count=$(jq '.items | length' <<<"$orgs")
    if [[ "$count" == 0 ]]; then
      print -ru2 -- "dag set limit global: no organizations returned by API."
      return 2
    fi
    jq -c '.items[]?' <<<"$orgs"
    return 0
  fi

  count=$(jq --arg s "$selector" '[.items[]? | select(.org_id == $s or ((.name // "") | ascii_downcase) == ($s | ascii_downcase))] | length' <<<"$orgs")
  if [[ "$count" == 0 ]]; then
    print -ru2 -- "dag set limit global: organization not found for selector '${selector}'. Pass org_id or name, or omit selector to update all orgs."
    _dag_limits_list_orgs "$orgs" >&2
    return 2
  fi
  if [[ "$count" != 1 ]]; then
    print -ru2 -- "dag set limit global: selector '${selector}' matched multiple organizations. Pass org_id, or omit selector to update all orgs."
    jq -r --arg s "$selector" '.items[]? | select(.org_id == $s or ((.name // "") | ascii_downcase) == ($s | ascii_downcase)) | "  \(.org_id)  \(.name // "<unnamed>")"' <<<"$orgs" >&2
    return 2
  fi
  jq -c --arg s "$selector" '[.items[]? | select(.org_id == $s or ((.name // "") | ascii_downcase) == ($s | ascii_downcase))][0]' <<<"$orgs"
}

_dag_limits_apply_org_limit() {  # $1=key $2=base $3=gate $4=amount $5=org-json-row
  local key=$1 base=$2 gate=$3 amount=$4 row=$5 body url patch_body verify_body actual org_id org_name
  org_id=$(jq -r '.org_id' <<<"$row")
  org_name=$(jq -r '.name // "<unnamed>"' <<<"$row")
  body=$(jq -cn --arg g "${gate}_agent" --argjson n "$amount" '{($g):{cycle_acu_limit:$n}}')
  url="${base}/v3beta1/enterprise/organizations/${org_id}/consumption/acu-limits"

  print -r -- "dag set limit global — org ${org_id} (${org_name})"
  print -r -- "Setting ${gate}_agent.cycle_acu_limit=${amount} ACUs via Devin V3 beta ACU limits API."

  _dag_limits_request PATCH "$url" "$key" "$body"
  patch_body="$_dag_limits_body"
  if [[ "$_dag_limits_code" != 204 && "$_dag_limits_code" != 200 ]]; then
    print -ru2 -- "dag set limit global: PATCH ${url} failed [${_dag_limits_code}]: ${patch_body}"
    return 1
  fi

  _dag_limits_request GET "$url" "$key" ""
  verify_body="$_dag_limits_body"
  if [[ "$_dag_limits_code" != 200 ]]; then
    print -ru2 -- "dag set limit global: verification GET ${url} failed [${_dag_limits_code}]: ${verify_body}"
    return 1
  fi
  actual=$(jq -r --arg g "${gate}_agent" '.[$g].cycle_acu_limit // empty' <<<"$verify_body" 2>/dev/null)
  if [[ "$actual" != "$amount" ]]; then
    print -ru2 -- "dag set limit global: verification failed — expected ${gate}_agent.cycle_acu_limit=${amount}, got ${actual:-<unset>} for ${org_id} (${org_name})."
    print -ru2 -- "Response: ${verify_body}"
    return 1
  fi

  print -r -- "confirmed ${gate}_agent.cycle_acu_limit=${amount} for ${org_id} (${org_name})"
}

_dag_limits_layer_state() {  # $1=key $2=base $3=orgs-json -> [{org_id,name,local,cloud}] JSON on stdout
  # Live GET of every org's gates; null = no explicit cap (unlimited).
  local key=$1 base=$2 orgs=$3 row org_id org_name
  local -a rows
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    org_id=$(jq -r '.org_id' <<<"$row")
    org_name=$(jq -r '.name // "<unnamed>"' <<<"$row")
    _dag_limits_request GET "${base}/v3beta1/enterprise/organizations/${org_id}/consumption/acu-limits" "$key" ""
    if [[ "$_dag_limits_code" != 200 ]]; then
      print -ru2 -- "dag set limit global: GET org limits for ${org_id} (${org_name}) failed [${_dag_limits_code}]: ${_dag_limits_body}"
      return 1
    fi
    rows+=("$(jq -c --arg id "$org_id" --arg n "$org_name" \
      '{org_id: $id, name: $n, local: (.local_agent.cycle_acu_limit // null), cloud: (.cloud_agent.cycle_acu_limit // null)}' \
      <<<"$_dag_limits_body")")
  done < <(jq -c '.items[]?' <<<"$orgs")
  (( ${#rows} )) && print -rl -- "${rows[@]}" | jq -sc '.' || print -r -- '[]'
}

_dag_limits_ceiling_check() {  # $1=layer-json $2=gate $3=amount $4=selected-rows -> 0 ok, 3 refused
  local layer=$1 gate=$2 amount=$3 selected=$4 ceiling="${DAG_MONTHLY_ACU_POOL:-24000}" verdict
  verdict=$(jq -c --arg g "$gate" --argjson n "$amount" --argjson c "$ceiling" \
    --argjson ids "$(jq -sc '[.[].org_id]' <<<"$selected")" '
      def total: [.[] | (.local // 0) + (.cloud // 0)] | add // 0;
      (total) as $before
      | (map(if (.org_id as $id | $ids | index($id)) then .[$g] = $n else . end)) as $after_rows
      | ($after_rows | total) as $after
      | {before: $before, after: $after, ceiling: $c,
         uncapped: [$after_rows[] | select(.local == null) | .name],
         refused: ($after > $c and $after > $before)}' <<<"$layer")
  local before after uncapped
  before=$(jq -r '.before' <<<"$verdict")
  after=$(jq -r '.after' <<<"$verdict")
  print -r -- "Org ceiling: Σ org caps (local + cloud, every org) ${before} → ${after} ACUs; ceiling ${ceiling} (DAG_MONTHLY_ACU_POOL)."
  uncapped=$(jq -r '.uncapped | join(", ")' <<<"$verdict")
  [[ -n "$uncapped" ]] && print -r -- "Warning: org(s) with no explicit local_agent cap are unlimited, so the ceiling is unenforceable until capped: ${uncapped}"
  if [[ "$(jq -r '.refused' <<<"$verdict")" == true ]]; then
    print -ru2 -- "dag set limit global: refused — Σ org caps would rise to ${after} ACUs, above the ${ceiling} ACU ceiling. Org caps are zero-sum under the ceiling: lower another org first, or run dag slg to replan every org."
    return 3
  fi
  if (( before > ceiling && after <= before )); then
    print -r -- "Note: org layer is over the ceiling by $(( after > ceiling ? after - ceiling : 0 )) ACUs after this write — allowed because it does not grow the layer."
  fi
  return 0
}

dag_set_limit_global() {  # [local|cloud] <acus> [org_id-or-name]
  local gate=local
  case "${1:-}" in
    local|cloud) gate=$1; shift ;;
  esac
  local amount=${1:-} selector=${2:-}
  local usage="Usage: dag set limit global [local|cloud] <acus> [org_id|org_name]"
  if [[ -z "$amount" || "$amount" != <-> ]]; then
    print -ru2 -- "dag set limit global: <acus> must be a non-negative integer (0 blocks ${gate} agent usage for that scope)."
    print -ru2 -- "$usage"
    return 2
  fi
  if (( $# > 2 )); then
    print -ru2 -- "dag set limit global: too many arguments."
    print -ru2 -- "$usage"
    return 2
  fi

  local key
  if ! key=$(dag_resolve_cog_key); then
    print -ru2 -- "dag set limit global: no Devin API v3 service-user key (cog_...) found."
    print -ru2 -- "  Keychain: security add-generic-password -s ${DAG_COG_KEYCHAIN_SERVICE:-devin-cog-key} -a \"$USER\" -w 'cog_...'"
    print -ru2 -- "  Or: export DEVIN_COG_KEY=cog_..."
    return 1
  fi

  local base="${DAG_API_BASE_V3:-https://api.devin.ai}"
  local orgs selected selected_count row failures=0 applied=0
  _dag_limits_request GET "${base}/v3/enterprise/organizations" "$key" ""
  orgs="$_dag_limits_body"
  if [[ "$_dag_limits_code" != 200 ]]; then
    print -ru2 -- "dag set limit global: GET ${base}/v3/enterprise/organizations failed [${_dag_limits_code}]: ${orgs}"
    return 1
  fi

  selected=$(_dag_limits_select_orgs "$orgs" "$selector") || return $?
  selected_count=$(sed '/^$/d' <<<"$selected" | wc -l | tr -d ' ')

  local layer
  layer=$(_dag_limits_layer_state "$key" "$base" "$orgs") || return 1
  _dag_limits_ceiling_check "$layer" "$gate" "$amount" "$selected" || return $?

  if [[ -z "$selector" ]]; then
    print -r -- "No org selector passed; applying to all ${selected_count} organizations."
  fi

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    if _dag_limits_apply_org_limit "$key" "$base" "$gate" "$amount" "$row"; then
      (( applied++ )) || true
    else
      (( failures++ )) || true
    fi
  done <<<"$selected"

  print -r -- "dag set limit global summary: ${applied}/${selected_count} organization(s) verified at ${amount} ACUs (${gate}_agent)."

  _dag_limits_print_ui_hint
  (( failures == 0 ))
}
