#!/usr/bin/env zsh
# do-here-now-migrator — DNS cutover.
#
# The safety rule of this module: only apex and `www` records of type A, AAAA,
# or CNAME may ever be created or deleted. Everything else in the zone is
# untouchable — MX, TXT, SPF, DKIM, DMARC, CAA, SRV, NS, SOA, and every
# unrelated subdomain. Losing a zone's MX records silently breaks the owner's
# email for as long as it takes them to notice, which can be weeks.
#
# DigitalOcean is the only provider that can be edited automatically. Any other
# authoritative provider gets printed instructions instead of a silent no-op.

# Record types this module is permitted to create or delete.
typeset -ga DHM_DNS_MUTABLE_TYPES=(A AAAA CNAME)
# Hosts this module is permitted to touch.
typeset -ga DHM_DNS_MUTABLE_HOSTS=('@' www)

dhm_dns_type_is_mutable() {  # dhm_dns_type_is_mutable <type>
  local t
  for t in "${DHM_DNS_MUTABLE_TYPES[@]}"; do [[ "${1:u}" == "$t" ]] && return 0; done
  return 1
}

dhm_dns_host_is_mutable() {  # dhm_dns_host_is_mutable <name>
  local h
  for h in "${DHM_DNS_MUTABLE_HOSTS[@]}"; do [[ "${1:l}" == "$h" ]] && return 0; done
  return 1
}

# The single predicate every deletion must pass.
dhm_dns_record_is_mutable() {  # dhm_dns_record_is_mutable <type> <name>
  dhm_dns_type_is_mutable "$1" && dhm_dns_host_is_mutable "$2"
}

# Split a zone's records into the ones we may replace and the ones we must
# preserve. Emits a JSON object so both halves can be shown to the operator.
dhm_dns_classify() {  # dhm_dns_classify <records-json>
  jq -c '
    def mutable: (.type | ascii_upcase) as $t
      | (.name | ascii_downcase) as $n
      | (["A","AAAA","CNAME"] | index($t)) != null
        and (["@","www"] | index($n)) != null;
    { replaceable: [ .[] | select(mutable) ],
      preserved:   [ .[] | select(mutable | not) ] }' <<<"$1"
}

dhm_dns_zone_exists_on_do() {  # dhm_dns_zone_exists_on_do <domain>
  doctl compute domain get "$1" >/dev/null 2>&1
}

# Who is actually authoritative right now? A DigitalOcean zone that the
# registrar does not delegate to is inert, and editing it changes nothing that
# the internet can see. That failure mode is invisible without this check.
dhm_dns_authoritative_ns() {  # dhm_dns_authoritative_ns <domain>
  dhm_have dig || return 1
  dig +short NS "$1" 2>/dev/null | sed 's/\.$//' | sort
}

dhm_dns_check_delegation() {  # dhm_dns_check_delegation <domain>
  local domain=$1 ns
  ns=$(dhm_dns_authoritative_ns "$domain")
  if [[ -z "$ns" ]]; then
    dhm_warn "${domain} has no nameservers in public DNS — the domain may be unregistered or fully dark"
    return 1
  fi
  dhm_log "${domain} nameservers: $(print -r -- "$ns" | tr '\n' ' ')"
  if print -r -- "$ns" | grep -qi 'digitalocean\.com'; then
    dhm_ok "${domain} is delegated to DigitalOcean; edits here take effect"
    return 0
  fi
  dhm_warn "${domain} is NOT delegated to DigitalOcean"
  dhm_warn "  editing the DigitalOcean zone will have no public effect until the"
  dhm_warn "  registrar's nameservers are changed to ns1/ns2/ns3.digitalocean.com"
  return 2
}

# Render the records a provider requires, for manual application.
dhm_dns_print_instructions() {  # dhm_dns_print_instructions <domain> <instructions-json>
  local domain=$1 inst=$2
  print -r -- ""
  print -r -- "Apply these records at the authoritative DNS provider for ${domain}:"
  print -r -- ""
  printf '  %-6s %-6s %s\n' TYPE HOST VALUE
  jq -r '.[] | "  \(.type)\t\(.host)\t\(.value)"' <<<"$inst" \
    | awk -F'\t' '{printf "  %-6s %-6s %s\n", $1, $2, $3}'
  print -r -- ""
  print -r -- "  '@' means the root domain. TTL may stay at the provider default."
  print -r -- ""
}

# Delete one record, translating DigitalOcean's App-managed refusal into an
# actionable message instead of an opaque 422.
dhm_dns_delete_record() {  # dhm_dns_delete_record <domain> <id> <label>
  local domain=$1 id=$2 label=$3 out
  if dhm_dry "delete DNS record ${label} [${id}] from ${domain}"; then return 0; fi
  if out=$(doctl compute domain records delete "$domain" "$id" --force 2>&1); then
    dhm_ok "deleted ${label}"
    return 0
  fi
  if print -r -- "$out" | grep -q 'managed by an App'; then
    dhm_error "record ${label} is managed by a DigitalOcean App and cannot be deleted directly"
    dhm_error "  the App must release the domain first — this happens automatically when the App is destroyed"
    return 2
  fi
  if print -r -- "$out" | grep -q '404'; then
    dhm_log "record ${label} already gone"
    return 0
  fi
  dhm_error "failed to delete ${label}: $(print -r -- "$out" | dhm_redact)"
  return 1
}

dhm_dns_create_record() {  # dhm_dns_create_record <domain> <type> <name> <data> <ttl>
  local domain=$1 type=$2 name=$3 data=$4 ttl=${5:-600} out
  [[ "${type:u}" == CNAME && "$data" != *. ]] && data="${data}."
  if dhm_dry "create ${type} ${name} -> ${data} (ttl ${ttl}) in ${domain}"; then return 0; fi
  if out=$(doctl compute domain records create "$domain" \
      --record-type "$type" --record-name "$name" --record-data "$data" \
      --record-ttl "$ttl" --output json 2>&1); then
    dhm_ok "created ${type} ${name} -> ${data}"
    return 0
  fi
  dhm_error "failed to create ${type} ${name}: $(print -r -- "$out" | dhm_redact)"
  return 1
}

# Apply here.now's dns_instructions to a DigitalOcean zone, replacing only the
# apex/www A, AAAA, and CNAME records and reporting everything preserved.
dhm_dns_apply() {  # dhm_dns_apply <domain> <instructions-json> <ttl>
  local domain=$1 inst=$2 ttl=${3:-600}

  # Validate the input before touching the provider. An empty instruction set
  # would delete the site's records and put nothing back, so it is rejected
  # before anything is read, let alone deleted.
  local want; want=$(jq 'length' <<<"$inst" 2>/dev/null || print -r -- 0)
  if (( want == 0 )); then
    dhm_error "no DNS instructions to apply — refusing to delete existing records"
    return 1
  fi

  if ! dhm_dns_zone_exists_on_do "$domain"; then
    dhm_warn "${domain} is not a DigitalOcean DNS zone; cannot apply records automatically"
    dhm_dns_print_instructions "$domain" "$inst"
    return 2
  fi

  dhm_dns_check_delegation "$domain" || true

  local records classified replaceable preserved
  records=$(doctl compute domain records list "$domain" --output json 2>/dev/null) || {
    dhm_error "could not read the ${domain} zone"; return 1
  }
  classified=$(dhm_dns_classify "$records")
  replaceable=$(jq -c '.replaceable' <<<"$classified")
  preserved=$(jq -c '.preserved' <<<"$classified")

  print -r -- ""
  dhm_info "${domain}: $(jq 'length' <<<"$replaceable") record(s) will be replaced, $(jq 'length' <<<"$preserved") preserved"
  jq -r '.[] | "    preserve  \(.type)\t\(.name)\t\(.data)"' <<<"$preserved" \
    | awk -F'\t' '{printf "%s %-6s %s\n", $1, $2, $3}' >&2
  jq -r '.[] | "    replace   \(.type)\t\(.name)\t\(.data)"' <<<"$replaceable" \
    | awk -F'\t' '{printf "%s %-6s %s\n", $1, $2, $3}' >&2
  print -r -- ""

  local id type name rc deferred=0 i n
  n=$(jq 'length' <<<"$replaceable")
  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".[$i].id" <<<"$replaceable")
    type=$(jq -r ".[$i].type" <<<"$replaceable")
    name=$(jq -r ".[$i].name" <<<"$replaceable")
    dhm_dns_record_is_mutable "$type" "$name" || {
      dhm_error "internal guard tripped: refusing to delete ${type} ${name}"
      return 1
    }
    dhm_dns_delete_record "$domain" "$id" "${type} ${name}"
    rc=$?
    (( rc == 2 )) && deferred=1
    (( rc == 1 )) && return 1
  done

  if (( deferred )); then
    dhm_warn "some records are still held by a DigitalOcean App."
    dhm_warn "run the decommission phase first, then re-run the DNS phase."
    return 3
  fi

  n=$(jq 'length' <<<"$inst")
  local host value
  for (( i = 0; i < n; i++ )); do
    type=$(jq -r ".[$i].type" <<<"$inst")
    host=$(jq -r ".[$i].host" <<<"$inst")
    value=$(jq -r ".[$i].value" <<<"$inst")
    [[ -z "$host" || "$host" == "@" ]] && host='@'
    dhm_dns_record_is_mutable "$type" "$host" || {
      dhm_error "refusing to create ${type} ${host}: outside the apex/www A/AAAA/CNAME allowlist"
      return 1
    }
    dhm_dns_create_record "$domain" "$type" "$host" "$value" "$ttl" || return 1
  done

  dhm_ok "${domain} DNS updated"
  return 0
}

# Confirm the change is visible on independent public resolvers, not just in
# the provider's own API.
dhm_dns_verify_propagation() {  # dhm_dns_verify_propagation <domain> <instructions-json>
  local domain=$1 inst=$2
  dhm_have dig || { dhm_warn "dig not installed; skipping propagation check"; return 0 }
  if dhm_dry "verify DNS propagation for ${domain}"; then return 0; fi

  local resolver ok=1 want got type host fqdn i n
  n=$(jq 'length' <<<"$inst")
  for resolver in 1.1.1.1 8.8.8.8; do
    for (( i = 0; i < n; i++ )); do
      type=$(jq -r ".[$i].type" <<<"$inst")
      host=$(jq -r ".[$i].host" <<<"$inst")
      want=$(jq -r ".[$i].value" <<<"$inst")
      if [[ -z "$host" || "$host" == "@" ]]; then fqdn="$domain"; else fqdn="${host}.${domain}"; fi
      got=$(dig "@${resolver}" +short "$type" "$fqdn" 2>/dev/null | sed 's/\.$//')
      if print -r -- "$got" | grep -qxF -- "${want%.}"; then
        dhm_ok "@${resolver} ${type} ${fqdn} -> ${want}"
      else
        dhm_warn "@${resolver} ${type} ${fqdn} does not yet return ${want} (got: ${got:-nothing})"
        ok=0
      fi
    done
  done
  (( ok )) && return 0
  dhm_warn "DNS has not fully propagated yet; this is normal for a few minutes"
  return 1
}
