#!/usr/bin/env zsh
# do-here-now-migrator — phase 10: decommission.
#
# The only irreversible phase. Every guard in this file exists because the
# alternative is unrecoverable data loss.
#
# Preconditions, all mandatory:
#   1. A backup exists and was verified by reading it back.
#   2. Verification of the live site passed, unless the operator explicitly
#      chose --decommission-first and accepted downtime.
#   3. The operator typed the exact resource name, not "y".
#
# What is never destroyed: DNS zones, MX/TXT/CAA records, and any resource the
# inventory did not positively attribute to this site.

dhm_decom_preconditions() {  # dhm_decom_preconditions <site>
  local site=$1 backup verified

  backup=$(dhm_fact_get "$site" backup_dir)
  if [[ -z "$backup" ]]; then
    dhm_error "no backup recorded for '${site}' — refusing to destroy anything"
    return 1
  fi
  if ! dhm_backup_verify "$backup"; then
    dhm_error "the recorded backup at ${backup} did not verify — refusing to destroy anything"
    return 1
  fi

  if [[ -n "${DHM_DECOMMISSION_FIRST:-}" ]]; then
    dhm_warn "--decommission-first: destroying before the replacement site is verified"
    dhm_warn "the site will be OFFLINE from now until the here.now deployment is live"
    return 0
  fi

  verified=$(dhm_phase_status "$site" verify)
  if [[ "$verified" != done ]]; then
    dhm_error "the verify phase has not passed (status: ${verified})"
    dhm_error "  run 'dhm verify --site ${site}' first, or accept downtime with --decommission-first"
    return 1
  fi
  dhm_ok "preconditions met: backup verified, live site verified"
  return 0
}

dhm_decom_destroy_database() {  # dhm_decom_destroy_database <id> <name> <engine>
  local id=$1 name=$2 engine=$3

  print -r -- ""
  dhm_warn "about to permanently destroy managed ${engine} cluster '${name}' (${id})"
  dhm_warn "this cannot be undone; DigitalOcean keeps no copy once the cluster is gone"
  dhm_confirm_phrase "$name" "Confirm destruction of database '${name}'." || {
    dhm_warn "skipping ${name}"
    return 2
  }

  if dhm_dry "destroy database cluster ${name} (${id})"; then return 0; fi

  if doctl databases delete "$id" --force >/dev/null 2>&1; then
    dhm_ok "destroyed database ${name}"
    return 0
  fi
  dhm_error "failed to destroy database ${name}"
  return 1
}

dhm_decom_destroy_app() {  # dhm_decom_destroy_app <id> <name>
  local id=$1 name=$2

  print -r -- ""
  dhm_warn "about to permanently destroy App Platform app '${name}' (${id})"
  dhm_warn "its deploy-on-push integration and App-managed DNS records go with it"
  dhm_confirm_phrase "$name" "Confirm destruction of app '${name}'." || {
    dhm_warn "skipping ${name}"
    return 2
  }

  if dhm_dry "destroy app ${name} (${id})"; then return 0; fi

  if doctl apps delete "$id" --force >/dev/null 2>&1; then
    dhm_ok "destroyed app ${name}"
    return 0
  fi
  dhm_error "failed to destroy app ${name}"
  return 1
}

# Order matters. The app is destroyed before its databases so the running
# service is not left thrashing against a cluster that has vanished, and so the
# App-managed DNS records are released for the DNS phase.
dhm_decom_run() {  # dhm_decom_run <site> <inventory-json>
  local site=$1 inv=$2

  dhm_decom_preconditions "$site" || return 1

  dhm_inventory_render "$inv"

  local napps ndbs
  napps=$(jq '.claimed.apps | length' <<<"$inv")
  ndbs=$(jq '.claimed.databases | length' <<<"$inv")
  if (( napps == 0 && ndbs == 0 )); then
    dhm_ok "nothing attributed to this site on DigitalOcean; nothing to destroy"
    return 0
  fi

  print -r -- ""
  dhm_confirm_phrase "DESTROY" \
    "This destroys ${napps} app(s) and ${ndbs} database(s) on DigitalOcean. Backups are at $(dhm_fact_get "$site" backup_dir)." \
    || { dhm_warn "decommission aborted; nothing was destroyed"; return 1 }

  local i id name engine rc skipped=0
  for (( i = 0; i < napps; i++ )); do
    id=$(jq -r ".claimed.apps[$i].id" <<<"$inv")
    name=$(jq -r ".claimed.apps[$i].name" <<<"$inv")
    dhm_decom_destroy_app "$id" "$name"; rc=$?
    (( rc == 1 )) && return 1
    (( rc == 2 )) && skipped=1
  done

  for (( i = 0; i < ndbs; i++ )); do
    id=$(jq -r ".claimed.databases[$i].id" <<<"$inv")
    name=$(jq -r ".claimed.databases[$i].name" <<<"$inv")
    engine=$(jq -r ".claimed.databases[$i].engine" <<<"$inv")
    dhm_decom_destroy_database "$id" "$name" "$engine"; rc=$?
    (( rc == 1 )) && return 1
    (( rc == 2 )) && skipped=1
  done

  (( skipped )) && dhm_warn "some resources were skipped and still exist"
  return 0
}

# Confirm the account no longer bills for anything belonging to this site, and
# that unrelated resources survived untouched.
dhm_decom_sweep() {  # dhm_decom_sweep <inventory-json>
  local inv=$1
  if dhm_dry "sweep DigitalOcean for surviving resources"; then return 0; fi

  print -r -- ""
  dhm_info "post-decommission sweep"

  local i n id name
  n=$(jq '.claimed.apps | length' <<<"$inv")
  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".claimed.apps[$i].id" <<<"$inv")
    name=$(jq -r ".claimed.apps[$i].name" <<<"$inv")
    if doctl apps get "$id" >/dev/null 2>&1; then
      dhm_warn "app ${name} still exists"
    else
      dhm_ok "app ${name} is gone"
    fi
  done

  n=$(jq '.claimed.databases | length' <<<"$inv")
  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".claimed.databases[$i].id" <<<"$inv")
    name=$(jq -r ".claimed.databases[$i].name" <<<"$inv")
    local db_status
    db_status=$(doctl databases get "$id" --format Status --no-header 2>/dev/null)
    if [[ -z "$db_status" || "$db_status" == decommissioned ]]; then
      dhm_ok "database ${name} is gone${db_status:+ (${db_status})}"
    else
      dhm_warn "database ${name} still reports status '${db_status}'"
    fi
  done

  # Unrelated resources must have survived. A migration that took out a
  # bystander is a failed migration even if the site works.
  n=$(jq '.untouched.apps | length' <<<"$inv")
  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".untouched.apps[$i].id" <<<"$inv")
    name=$(jq -r ".untouched.apps[$i].name" <<<"$inv")
    if doctl apps get "$id" >/dev/null 2>&1; then
      dhm_ok "unrelated app ${name} untouched"
    else
      dhm_error "unrelated app ${name} is missing — it should not have been affected"
    fi
  done

  n=$(jq '.untouched.databases | length' <<<"$inv")
  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".untouched.databases[$i].id" <<<"$inv")
    name=$(jq -r ".untouched.databases[$i].name" <<<"$inv")
    if doctl databases get "$id" >/dev/null 2>&1; then
      dhm_ok "unrelated database ${name} untouched"
    else
      dhm_error "unrelated database ${name} is missing — it should not have been affected"
    fi
  done

  # Anything still billable across the account, for the operator's awareness.
  print -r -- ""
  dhm_info "remaining billable resources on the account:"
  local kind
  for kind in "apps:doctl apps list --format Spec.Name --no-header" \
              "databases:doctl databases list --format Name,Status --no-header" \
              "droplets:doctl compute droplet list --format Name --no-header" \
              "volumes:doctl compute volume list --format Name --no-header" \
              "load-balancers:doctl compute load-balancer list --format Name --no-header"; do
    local label=${kind%%:*} cmd=${kind#*:} out
    out=$(eval "$cmd" 2>/dev/null | grep -v '^$')
    if [[ -z "$out" ]]; then
      dhm_log "  ${label}: none"
    else
      dhm_log "  ${label}:"
      print -r -- "$out" | sed 's/^/      /' >&2
    fi
  done
  return 0
}

# Credentials that lived in a destroyed app spec are inert, but they are often
# reused. Say so explicitly rather than leaving it implied.
dhm_decom_secret_advice() {  # dhm_decom_secret_advice <backup-dir>
  local dir=$1 specs
  specs=("${dir}"/app-specs/*.yaml(N))
  (( ${#specs} == 0 )) && return 0
  local found
  found=$(grep -hoiE '^[[:space:]]*(- )?key: [A-Z0-9_]*(PASSWORD|SECRET|TOKEN|KEY|URI|URL)[A-Z0-9_]*' "${specs[@]}" 2>/dev/null \
    | sed -E 's/.*key: //' | sort -u)
  [[ -z "$found" ]] && return 0
  print -r -- ""
  dhm_warn "the destroyed app spec carried these credential-shaped values:"
  print -r -- "$found" | sed 's/^/      /' >&2
  dhm_warn "they are inert now, but rotate any that are reused elsewhere."
  dhm_warn "the archived spec at ${dir}/app-specs/ is itself a secret-bearing file (mode 600)."
}
