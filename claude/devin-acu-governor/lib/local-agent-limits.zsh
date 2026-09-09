#!/usr/bin/env zsh
# Org ACU limit helpers for dag (Local Agent + Devin Cloud org gates).
# Deterministic local commands: no agent launch. Uses Devin V3 beta ACU-limit
# endpoints, quotes exact API error bodies, and verifies writes with a follow-up GET.
# Gate selector: `local` (default) writes local_agent.cycle_acu_limit,
# `cloud` writes cloud_agent.cycle_acu_limit.
# Parent-org rule: the org named/id'd by DAG_PARENT_ORG (default "Vontier") is
# the umbrella billing org — its gate must equal Σ of every other org's cap for
# that gate, or the parent gate blocks members of child orgs. All-org writes
# therefore target the non-parent orgs and reconcile the parent to the sum.
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

_dag_limits_parent_row() {  # $1=orgs-json -> compact parent org row or nothing
  local orgs=$1 parent="${DAG_PARENT_ORG:-Vontier}"
  jq -c --arg p "$parent" \
    '[.items[]? | select(.org_id == $p or ((.name // "") | ascii_downcase) == ($p | ascii_downcase))][0] // empty' <<<"$orgs"
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

_dag_limits_child_cap_sum() {  # $1=key $2=base $3=gate $4=orgs-json $5=parent-org-id
  # Prints Σ of every non-parent org's explicit gate cap. Returns 1 (and lists
  # the uncapped orgs on stderr) when any non-parent org has no explicit cap —
  # the parent sum is undefined in that case.
  local key=$1 base=$2 gate=$3 orgs=$4 parent_id=$5 row org_id org_name cap sum=0
  local -a uncapped
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    org_id=$(jq -r '.org_id' <<<"$row")
    [[ "$org_id" == "$parent_id" ]] && continue
    org_name=$(jq -r '.name // "<unnamed>"' <<<"$row")
    _dag_limits_request GET "${base}/v3beta1/enterprise/organizations/${org_id}/consumption/acu-limits" "$key" ""
    if [[ "$_dag_limits_code" != 200 ]]; then
      print -ru2 -- "dag set limit global: GET org limits for ${org_id} (${org_name}) failed [${_dag_limits_code}]: ${_dag_limits_body}"
      return 1
    fi
    cap=$(jq -r --arg g "${gate}_agent" '.[$g].cycle_acu_limit // empty' <<<"$_dag_limits_body" 2>/dev/null)
    if [[ -z "$cap" ]]; then
      uncapped+=("${org_id} (${org_name})")
    else
      (( sum += cap ))
    fi
  done < <(jq -c '.items[]?' <<<"$orgs")
  if (( ${#uncapped[@]} > 0 )); then
    print -ru2 -- "dag set limit global: cannot reconcile parent ${gate} gate — non-parent org(s) without an explicit ${gate}_agent cap:"
    print -ru2 -l -- "  ${(@)uncapped}"
    return 1
  fi
  print -r -- "$sum"
}

_dag_limits_reconcile_parent() {  # $1=key $2=base $3=gate $4=orgs-json $5=parent-row
  # Parent-org rule: parent gate cap = Σ non-parent org caps for the gate.
  local key=$1 base=$2 gate=$3 orgs=$4 parent_row=$5 parent_id parent_name sum
  parent_id=$(jq -r '.org_id' <<<"$parent_row")
  parent_name=$(jq -r '.name // "<unnamed>"' <<<"$parent_row")
  if ! sum=$(_dag_limits_child_cap_sum "$key" "$base" "$gate" "$orgs" "$parent_id"); then
    print -ru2 -- "dag set limit global: parent org ${parent_id} (${parent_name}) left unreconciled."
    return 1
  fi
  print -r -- "Parent-org rule: reconciling ${parent_name} ${gate}_agent cap to Σ non-parent caps = ${sum}."
  _dag_limits_apply_org_limit "$key" "$base" "$gate" "$sum" "$parent_row"
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
  local parent_row parent_id="" target_is_parent=0
  _dag_limits_request GET "${base}/v3/enterprise/organizations" "$key" ""
  orgs="$_dag_limits_body"
  if [[ "$_dag_limits_code" != 200 ]]; then
    print -ru2 -- "dag set limit global: GET ${base}/v3/enterprise/organizations failed [${_dag_limits_code}]: ${orgs}"
    return 1
  fi
  parent_row=$(_dag_limits_parent_row "$orgs")
  [[ -n "$parent_row" ]] && parent_id=$(jq -r '.org_id' <<<"$parent_row")

  selected=$(_dag_limits_select_orgs "$orgs" "$selector") || return $?

  if [[ -z "$selector" && -n "$parent_id" ]]; then
    # All-org mode with a known parent: the amount targets the non-parent orgs;
    # the parent is reconciled to the sum afterwards, never written the raw amount.
    selected=$(jq -c --arg p "$parent_id" 'select(.org_id != $p)' <<<"$selected")
    if [[ -z "${selected//$'\n'/}" ]]; then
      # Roster contains only the parent org — nothing to sum; write it directly.
      selected=$(jq -c '.items[]?' <<<"$orgs")
      parent_id=""
    fi
  fi
  if [[ -n "$selector" && -n "$parent_id" ]]; then
    [[ "$(jq -r '.org_id' <<<"$selected")" == "$parent_id" ]] && target_is_parent=1
  fi

  selected_count=$(sed '/^$/d' <<<"$selected" | wc -l | tr -d ' ')

  if [[ -z "$selector" ]]; then
    if [[ -n "$parent_id" ]]; then
      print -r -- "No org selector passed; applying to all ${selected_count} non-parent organizations (gate: ${gate}). Parent $(jq -r '.name // .org_id' <<<"$parent_row") is reconciled to the sum afterwards."
    else
      print -r -- "No org selector passed; applying to all ${selected_count} organizations."
    fi
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

  if [[ -n "$parent_id" && $target_is_parent == 0 ]]; then
    if (( failures == 0 )); then
      _dag_limits_reconcile_parent "$key" "$base" "$gate" "$orgs" "$parent_row" || (( failures++ )) || true
    else
      print -ru2 -- "dag set limit global: skipping parent reconciliation — ${failures} org write(s) failed above."
    fi
  elif (( target_is_parent )); then
    print -r -- "Explicit parent-org write: parent-org rule not applied (amount written as given). Parent cap should equal Σ non-parent org caps for the ${gate} gate."
  fi

  _dag_limits_print_ui_hint
  (( failures == 0 ))
}
