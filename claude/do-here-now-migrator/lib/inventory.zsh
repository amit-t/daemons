#!/usr/bin/env zsh
# do-here-now-migrator — phase 1: inventory.
#
# Read-only discovery of the DigitalOcean resources belonging to one site.
# Nothing here mutates anything. The output is a plan document that later
# phases consume, and that a human can read before authorising destruction.
#
# Attribution is deliberately conservative. An App is claimed only when its
# spec names the repository being migrated or a domain being migrated. A
# database is claimed only when a claimed App references it. Everything else
# on the account is reported as "other" and never touched — a shared account
# hosting unrelated projects is the normal case, not the exception.

dhm_do_apps_json() {
  doctl apps list --output json 2>/dev/null || print -r -- '[]'
}

# Does this app spec belong to the repo or domains under migration?
dhm_do_app_matches() {  # dhm_do_app_matches <app-json> <repo-slug> <domain ...>
  local app=$1 repo=$2; shift 2
  local -a domains=("$@")

  if [[ -n "$repo" ]]; then
    local repos
    repos=$(jq -r '
      [ (.spec.services // [])[], (.spec.static_sites // [])[],
        (.spec.workers // [])[], (.spec.jobs // [])[] ]
      | map(.github.repo // .gitlab.repo // empty) | .[]' <<<"$app" 2>/dev/null)
    if print -r -- "$repos" | grep -qxF -- "$repo"; then
      print -r -- "repo"
      return 0
    fi
  fi

  local d appdomains
  appdomains=$(jq -r '(.spec.domains // [])[] | .domain' <<<"$app" 2>/dev/null)
  for d in "${domains[@]}"; do
    [[ -z "$d" ]] && continue
    if print -r -- "$appdomains" | grep -qxF -- "$d"; then
      print -r -- "domain"
      return 0
    fi
    if print -r -- "$appdomains" | grep -qxF -- "www.${d}"; then
      print -r -- "domain"
      return 0
    fi
  done
  return 1
}

# Build the full inventory document.
dhm_inventory_build() {  # dhm_inventory_build <repo-slug> <domain ...>
  local repo=$1; shift
  local -a domains=("$@")
  local apps; apps=$(dhm_do_apps_json)

  local matched='[]' others='[]' app id name reason
  local count; count=$(jq 'length' <<<"$apps" 2>/dev/null || print -r -- 0)
  local i
  for (( i = 0; i < count; i++ )); do
    app=$(jq -c ".[$i]" <<<"$apps")
    id=$(jq -r '.id' <<<"$app")
    name=$(jq -r '.spec.name' <<<"$app")
    if reason=$(dhm_do_app_matches "$app" "$repo" "${domains[@]}"); then
      matched=$(jq -c \
        --arg id "$id" --arg name "$name" --arg reason "$reason" \
        --argjson spec "$(jq -c '.spec' <<<"$app")" \
        --arg ingress "$(jq -r '.default_ingress // ""' <<<"$app")" \
        '. + [{id:$id, name:$name, matched_by:$reason, ingress:$ingress,
               domains: [($spec.domains // [])[] | .domain],
               databases: [($spec.databases // [])[] | .cluster_name]}]' \
        <<<"$matched")
    else
      others=$(jq -c --arg id "$id" --arg name "$name" '. + [{id:$id, name:$name}]' <<<"$others")
    fi
  done

  # Databases: claimed only when a matched app references the cluster by name.
  local dbs claimed_dbs='[]' other_dbs='[]'
  dbs=$(doctl databases list --output json 2>/dev/null || print -r -- '[]')
  local wanted
  wanted=$(jq -r '[.[].databases[]] | unique | .[]' <<<"$matched" 2>/dev/null)
  local dcount; dcount=$(jq 'length' <<<"$dbs" 2>/dev/null || print -r -- 0)
  local db dbname dbid dbengine
  for (( i = 0; i < dcount; i++ )); do
    db=$(jq -c ".[$i]" <<<"$dbs")
    dbid=$(jq -r '.id' <<<"$db")
    dbname=$(jq -r '.name' <<<"$db")
    dbengine=$(jq -r '.engine' <<<"$db")
    if [[ -n "$wanted" ]] && print -r -- "$wanted" | grep -qxF -- "$dbname"; then
      claimed_dbs=$(jq -c --arg id "$dbid" --arg n "$dbname" --arg e "$dbengine" \
        --arg size "$(jq -r '.size // ""' <<<"$db")" \
        --arg region "$(jq -r '.region // ""' <<<"$db")" \
        '. + [{id:$id, name:$n, engine:$e, size:$size, region:$region}]' <<<"$claimed_dbs")
    else
      other_dbs=$(jq -c --arg id "$dbid" --arg n "$dbname" --arg e "$dbengine" \
        '. + [{id:$id, name:$n, engine:$e}]' <<<"$other_dbs")
    fi
  done

  # DNS zones for the migrating domains, with a full record dump for rollback.
  local zones='[]' d records
  for d in "${domains[@]}"; do
    [[ -z "$d" ]] && continue
    records=$(doctl compute domain records list "$d" --output json 2>/dev/null || print -r -- '[]')
    zones=$(jq -c --arg d "$d" --argjson r "$records" '. + [{domain:$d, records:$r}]' <<<"$zones")
  done

  # Everything else that costs money, reported but never claimed automatically.
  local droplets volumes lbs
  droplets=$(doctl compute droplet list --output json 2>/dev/null || print -r -- '[]')
  volumes=$(doctl compute volume list --output json 2>/dev/null || print -r -- '[]')
  lbs=$(doctl compute load-balancer list --output json 2>/dev/null || print -r -- '[]')

  jq -n \
    --arg at "$(dhm_now_utc)" --arg repo "$repo" \
    --argjson domains "$(printf '%s\n' "${domains[@]}" | jq -R . | jq -sc 'map(select(length>0))')" \
    --argjson apps "$matched" --argjson other_apps "$others" \
    --argjson databases "$claimed_dbs" --argjson other_databases "$other_dbs" \
    --argjson zones "$zones" \
    --argjson droplets "$(jq -c 'map({id, name})' <<<"$droplets")" \
    --argjson volumes "$(jq -c 'map({id, name})' <<<"$volumes")" \
    --argjson load_balancers "$(jq -c 'map({id, name})' <<<"$lbs")" \
    '{generated_at:$at, repo:$repo, domains:$domains,
      claimed:{apps:$apps, databases:$databases},
      untouched:{apps:$other_apps, databases:$other_databases,
                 droplets:$droplets, volumes:$volumes, load_balancers:$load_balancers},
      dns_zones:$zones}'
}

# Human-readable rendering of the plan. This is what the operator reads before
# typing a destructive confirmation, so it must be unambiguous about the
# boundary between "will be destroyed" and "will be left alone".
dhm_inventory_render() {  # dhm_inventory_render <inventory-json>
  local inv=$1
  print -r -- ""
  print -r -- "DigitalOcean inventory for ${DHM_C_BOLD}$(jq -r '.repo // "(no repo)"' <<<"$inv")${DHM_C_RESET}"
  print -r -- ""

  print -r -- "${DHM_C_RED}WILL BE DESTROYED${DHM_C_RESET} (after the live site is verified):"
  local n
  n=$(jq '.claimed.apps | length' <<<"$inv")
  if (( n == 0 )); then
    print -r -- "  apps:      none matched"
  else
    jq -r '.claimed.apps[] | "  app:       \(.name)  [\(.id)]  matched by \(.matched_by)\n             domains: \(.domains | join(", ") // "none")"' <<<"$inv"
  fi
  n=$(jq '.claimed.databases | length' <<<"$inv")
  if (( n == 0 )); then
    print -r -- "  databases: none matched"
  else
    jq -r '.claimed.databases[] | "  database:  \(.name)  [\(.id)]  \(.engine) \(.size) \(.region)"' <<<"$inv"
  fi

  print -r -- ""
  print -r -- "${DHM_C_GREEN}LEFT ALONE${DHM_C_RESET}:"
  jq -r '"  other apps:      \(.untouched.apps | length)"' <<<"$inv"
  jq -r '.untouched.apps[]? | "                   - \(.name)"' <<<"$inv"
  jq -r '"  other databases: \(.untouched.databases | length)"' <<<"$inv"
  jq -r '.untouched.databases[]? | "                   - \(.name) (\(.engine))"' <<<"$inv"
  jq -r '"  droplets:        \(.untouched.droplets | length)"' <<<"$inv"
  jq -r '"  volumes:         \(.untouched.volumes | length)"' <<<"$inv"
  jq -r '"  load balancers:  \(.untouched.load_balancers | length)"' <<<"$inv"
  print -r -- "  DNS zones:       kept (records rewritten for apex and www only)"
  print -r -- ""
}
