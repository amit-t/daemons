#!/usr/bin/env zsh
# Local Agent ACU limit helpers for dag.
# Deterministic local commands: no agent launch. Uses Devin V3 beta ACU-limit
# endpoints, quotes exact API error bodies, and verifies writes with a follow-up GET.
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

_dag_limits_resolve_org() {  # $1=orgs-json $2=selector-or-empty -> writes globals _dag_limit_org_id/name
  local orgs=$1 selector=${2:-} count row
  if [[ -z "$selector" ]]; then
    count=$(jq '.items | length' <<<"$orgs")
    if [[ "$count" == 1 ]]; then
      typeset -g _dag_limit_org_id=$(jq -r '.items[0].org_id' <<<"$orgs")
      typeset -g _dag_limit_org_name=$(jq -r '.items[0].name // "<unnamed>"' <<<"$orgs")
      return 0
    fi
    print -ru2 -- "dag set limit global: multiple organizations found. Pass org_id or name after <acus>."
    _dag_limits_list_orgs "$orgs" >&2
    return 2
  fi

  count=$(jq --arg s "$selector" '[.items[]? | select(.org_id == $s or ((.name // "") | ascii_downcase) == ($s | ascii_downcase))] | length' <<<"$orgs")
  if [[ "$count" == 0 ]]; then
    print -ru2 -- "dag set limit global: organization not found for selector '${selector}'. Pass org_id or name."
    _dag_limits_list_orgs "$orgs" >&2
    return 2
  fi
  if [[ "$count" != 1 ]]; then
    print -ru2 -- "dag set limit global: selector '${selector}' matched multiple organizations. Pass org_id."
    jq -r --arg s "$selector" '.items[]? | select(.org_id == $s or ((.name // "") | ascii_downcase) == ($s | ascii_downcase)) | "  \(.org_id)  \(.name // "<unnamed>")"' <<<"$orgs" >&2
    return 2
  fi
  row=$(jq -c --arg s "$selector" '[.items[]? | select(.org_id == $s or ((.name // "") | ascii_downcase) == ($s | ascii_downcase))][0]' <<<"$orgs")
  typeset -g _dag_limit_org_id=$(jq -r '.org_id' <<<"$row")
  typeset -g _dag_limit_org_name=$(jq -r '.name // "<unnamed>"' <<<"$row")
}

dag_set_limit_global() {  # <acus> [org_id-or-name]
  local amount=${1:-} selector=${2:-}
  if [[ -z "$amount" || "$amount" != <-> ]]; then
    print -ru2 -- "dag set limit global: <acus> must be a non-negative integer (0 blocks Local Agent usage)."
    print -ru2 -- "Usage: dag set limit global <acus> [org_id|org_name]"
    return 2
  fi
  if (( $# > 2 )); then
    print -ru2 -- "dag set limit global: too many arguments."
    print -ru2 -- "Usage: dag set limit global <acus> [org_id|org_name]"
    return 2
  fi

  local key
  if ! key=$(dag_resolve_cog_key); then
    print -ru2 -- "dag set limit global: no Devin API v3 service-user key (cog_...) found."
    print -ru2 -- "  Keychain: security add-generic-password -s ${DAG_COG_KEYCHAIN_SERVICE:-devin-cog-key} -a \"\$USER\" -w 'cog_...'"
    print -ru2 -- "  Or: export DEVIN_COG_KEY=cog_..."
    return 1
  fi

  local base="${DAG_API_BASE_V3:-https://api.devin.ai}"
  local orgs body url verify_body actual
  _dag_limits_request GET "${base}/v3/enterprise/organizations" "$key" ""
  orgs="$_dag_limits_body"
  if [[ "$_dag_limits_code" != 200 ]]; then
    print -ru2 -- "dag set limit global: GET ${base}/v3/enterprise/organizations failed [${_dag_limits_code}]: ${orgs}"
    return 1
  fi
  _dag_limits_resolve_org "$orgs" "$selector" || return $?

  body=$(jq -cn --argjson n "$amount" '{local_agent:{cycle_acu_limit:$n}}')
  url="${base}/v3beta1/enterprise/organizations/${_dag_limit_org_id}/consumption/acu-limits"

  print -r -- "dag set limit global — org ${_dag_limit_org_id} (${_dag_limit_org_name})"
  print -r -- "Setting local_agent.cycle_acu_limit=${amount} ACUs via Devin V3 beta ACU limits API."

  local patch_body
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
  actual=$(jq -r '.local_agent.cycle_acu_limit // empty' <<<"$verify_body" 2>/dev/null)
  if [[ "$actual" != "$amount" ]]; then
    print -ru2 -- "dag set limit global: verification failed — expected local_agent.cycle_acu_limit=${amount}, got ${actual:-<unset>}."
    print -ru2 -- "Response: ${verify_body}"
    return 1
  fi

  print -r -- "confirmed local_agent.cycle_acu_limit=${amount} for ${_dag_limit_org_id} (${_dag_limit_org_name})"
  _dag_limits_print_ui_hint
}
