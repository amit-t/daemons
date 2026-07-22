#!/usr/bin/env zsh
# do-here-now-migrator — here.now account, publishing, and custom domains.
#
# No here.now account is assumed. If no credential exists, this module runs the
# email one-time-code flow and stores the key at ~/.herenow/credentials with
# mode 600. An unauthenticated publish is treated as a hard failure, never a
# fallback: an anonymous Site expires in 24 hours, so silently accepting one
# would hand back a link that dies overnight.
#
# The API key is read into a local variable at the point of use and never
# printed, never written to state, and never passed on a command line.

typeset -g DHM_HN_API="${DHM_HERENOW_API:-https://here.now}"

dhm_hn_credentials_file() { print -r -- "${HOME}/.herenow/credentials" }

dhm_hn_have_credentials() {
  local f; f=$(dhm_hn_credentials_file)
  [[ -s "$f" ]]
}

# Refuse to use a credentials file that other users can read.
dhm_hn_check_credentials_mode() {
  local f mode
  f=$(dhm_hn_credentials_file)
  [[ -s "$f" ]] || return 1
  mode=$(command stat -f '%Lp' "$f" 2>/dev/null || command stat -c '%a' "$f" 2>/dev/null)
  if [[ "$mode" != 600 ]]; then
    dhm_warn "tightening ${f} from mode ${mode} to 600"
    chmod 600 "$f" || return 1
  fi
  return 0
}

dhm_hn_key() {  # prints the API key on stdout; callers must not log it
  dhm_hn_check_credentials_mode || return 1
  print -r -- "$(<"$(dhm_hn_credentials_file)")"
}

dhm_hn_store_key() {  # dhm_hn_store_key <key>
  local key=$1 f; f=$(dhm_hn_credentials_file)
  [[ -n "$key" ]] || { dhm_error "refusing to store an empty here.now key"; return 1 }
  mkdir -p "${f:h}" || return 1
  chmod 700 "${f:h}"
  umask 077
  print -r -- "$key" > "$f" || return 1
  chmod 600 "$f"
  dhm_ok "stored here.now credentials at ${f} (mode 600)"
}

# Interactive sign-in. Creates the account on first use — here.now issues a
# code to any address, so this doubles as registration.
dhm_hn_login() {  # dhm_hn_login [email]
  local email=$1 code resp key

  if [[ -z "$email" ]]; then
    email=$(dhm_prompt_value "here.now account email") || return 1
  fi
  [[ "$email" == *@*.* ]] || { dhm_error "'${email}' does not look like an email address"; return 1 }

  if dhm_dry "request a here.now sign-in code for ${email}"; then return 0; fi

  dhm_info "requesting a sign-in code for ${email}"
  if ! resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/auth/agent/request-code" \
       -H 'content-type: application/json' \
       -d "$(jq -nc --arg e "$email" '{email:$e}')" 2>&1); then
    dhm_error "here.now refused the sign-in request: $(print -r -- "$resp" | dhm_redact)"
    return 1
  fi

  print -ru2 -- ""
  print -ru2 -- "here.now has emailed a sign-in code to ${email}."
  code=$(dhm_prompt_value "sign-in code") || return 1
  [[ -n "$code" ]] || { dhm_error "no code entered"; return 1 }

  if ! resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/auth/agent/verify-code" \
       -H 'content-type: application/json' \
       -d "$(jq -nc --arg e "$email" --arg c "$code" '{email:$e, code:$c}')" 2>&1); then
    dhm_error "code verification failed"
    return 1
  fi
  key=$(jq -r '.apiKey // empty' <<<"$resp" 2>/dev/null)
  [[ -n "$key" ]] || { dhm_error "here.now returned no apiKey"; return 1 }
  dhm_hn_store_key "$key"
}

dhm_hn_ensure_account() {  # dhm_hn_ensure_account [email]
  if dhm_hn_have_credentials && dhm_hn_check_credentials_mode; then
    local key resp
    key=$(dhm_hn_key) || return 1
    if resp=$(curl -fsS --max-time 20 "${DHM_HN_API}/api/v1/publishes" \
         -H "Authorization: Bearer ${key}" 2>/dev/null); then
      unset key
      dhm_ok "here.now credentials valid ($(jq '.publishes | length' <<<"$resp" 2>/dev/null || print -r -- '?') existing site(s))"
      return 0
    fi
    unset key
    dhm_warn "existing here.now credentials were rejected; signing in again"
  else
    dhm_info "no here.now credentials found — signing in (this also creates the account)"
  fi
  dhm_hn_login "$1"
}

# ------------------------------------------------------------- publisher ----

dhm_hn_publisher_path() {
  local p
  for p in "${PWD}/.agents/skills/here-now/scripts/publish.sh" \
           "${HOME}/.agents/skills/here-now/scripts/publish.sh"; do
    [[ -x "$p" ]] && { print -r -- "$p"; return 0 }
  done
  return 1
}

dhm_hn_install_publisher() {
  if dhm_hn_publisher_path >/dev/null; then
    dhm_log "here.now publisher already installed at $(dhm_hn_publisher_path)"
    return 0
  fi
  if dhm_dry "install the official here.now publisher"; then return 0; fi
  dhm_require_cmds npx || return 1
  dhm_info "installing the official here.now skill"
  # --yes and --global keep the installer non-interactive. Without them it
  # prompts for target agents and installs nothing when there is no TTY.
  npx --yes skills add heredotnow/skill --skill here-now --yes --global >&2 </dev/null || true
  if ! dhm_hn_publisher_path >/dev/null; then
    dhm_error "here.now publisher not found after install"
    return 1
  fi
  dhm_ok "installed here.now publisher at $(dhm_hn_publisher_path)"
}

# Publish a directory. Prints the resulting slug on stdout. An anonymous
# publish is rejected rather than reported.
dhm_hn_publish() {  # dhm_hn_publish <dir> <client> [slug]
  local dir=$1 client=$2 slug=$3 publisher log auth_mode site_url got_slug

  [[ -d "$dir" ]] || { dhm_error "publish source '${dir}' is not a directory"; return 1 }
  [[ -f "${dir}/index.html" ]] || dhm_warn "${dir}/index.html not found — publishing anyway (file-only site?)"

  publisher=$(dhm_hn_publisher_path) || { dhm_error "here.now publisher not installed"; return 1 }

  if dhm_dry "publish ${dir} to here.now${slug:+ (slug ${slug})}"; then
    print -r -- "${slug:-dry-run-slug}"
    return 0
  fi

  dhm_hn_check_credentials_mode || { dhm_error "here.now credentials missing or unreadable"; return 1 }

  log=$(mktemp) || return 1
  {
    if [[ -n "$slug" ]]; then
      "$publisher" "$dir" --client "$client" --slug "$slug" 2>&1 | tee "$log" >&2
    else
      "$publisher" "$dir" --client "$client" 2>&1 | tee "$log" >&2
    fi
  }

  auth_mode=$(sed -n 's/^publish_result\.auth_mode=//p' "$log" | tail -n 1)
  got_slug=$(sed -n 's/^publish_result\.slug=//p' "$log" | tail -n 1)
  site_url=$(sed -n 's/^publish_result\.site_url=//p' "$log" | tail -n 1)
  rm -f -- "$log"

  if [[ "$auth_mode" != authenticated ]]; then
    dhm_error "publish ran in '${auth_mode:-unknown}' mode — the Site would expire in 24 hours"
    dhm_error "check ~/.herenow/credentials, then re-run"
    return 1
  fi
  if ! dhm_is_valid_slug "$got_slug"; then
    dhm_error "publisher reported an unusable slug: '${got_slug}'"
    return 1
  fi
  if [[ "$site_url" != "https://${got_slug}.here.now/" ]]; then
    dhm_error "reported site_url '${site_url}' does not match slug '${got_slug}'"
    return 1
  fi
  if [[ -n "$slug" && "$got_slug" != "$slug" ]]; then
    dhm_error "asked to update slug '${slug}' but publisher created '${got_slug}'"
    return 1
  fi
  dhm_ok "published to https://${got_slug}.here.now/ (authenticated, permanent)"
  print -r -- "$got_slug"
}

# --------------------------------------------------------------- domains ----

dhm_hn_domains_json() {
  local key resp
  key=$(dhm_hn_key) || return 1
  resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/v1/domains" \
    -H "Authorization: Bearer ${key}" 2>/dev/null)
  unset key
  [[ -n "$resp" ]] || return 1
  print -r -- "$resp"
}

# Count apex domains already attached to the account. The free plan allows one
# custom domain, so exceeding it must be reported before the attempt, not
# discovered as an opaque API error afterwards.
dhm_hn_apex_domain_count() {
  local json
  json=$(dhm_hn_domains_json) || { print -r -- 0; return 1 }
  jq '[.domains[]? | select(.is_apex == true)] | length' <<<"$json" 2>/dev/null || print -r -- 0
}

dhm_hn_domain_registered() {  # dhm_hn_domain_registered <domain>
  local json
  json=$(dhm_hn_domains_json) || return 1
  jq -e --arg d "$1" 'any(.domains[]?; .domain == $d)' <<<"$json" >/dev/null 2>&1
}

# Register a custom domain and print its dns_instructions as JSON.
dhm_hn_add_domain() {  # dhm_hn_add_domain <domain>
  local domain=$1 key resp count

  if dhm_hn_domain_registered "$domain"; then
    dhm_log "domain ${domain} is already registered on this here.now account"
    dhm_hn_domain_instructions "$domain"
    return 0
  fi

  count=$(dhm_hn_apex_domain_count)
  if (( count >= 1 )); then
    dhm_warn "this account already has ${count} apex custom domain(s)."
    dhm_warn "the here.now Free plan allows exactly one; adding another needs a paid plan."
    dhm_confirm_yes "attempt to add ${domain} anyway?" || return 1
  fi

  if dhm_dry "register custom domain ${domain} with here.now"; then return 0; fi

  key=$(dhm_hn_key) || return 1
  resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/v1/domains" \
    -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
    -d "$(jq -nc --arg d "$domain" '{domain:$d}')" 2>&1)
  local rc=$?
  unset key
  if (( rc != 0 )); then
    dhm_error "here.now rejected the domain registration: $(print -r -- "$resp" | dhm_redact)"
    return 1
  fi
  dhm_ok "registered ${domain} with here.now"
  jq -c '.dns_instructions // []' <<<"$resp"
}

dhm_hn_domain_instructions() {  # dhm_hn_domain_instructions <domain>
  local json
  json=$(dhm_hn_domains_json) || return 1
  jq -c --arg d "$1" '[.domains[]? | select(.domain == $d or .domain == ("www." + $d))
                       | .dns_instructions[]?] | unique_by(.type + .host + .value)' <<<"$json"
}

dhm_hn_domain_status() {  # dhm_hn_domain_status <domain>
  local key resp
  key=$(dhm_hn_key) || return 1
  resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/v1/domains/${1}" \
    -H "Authorization: Bearer ${key}" 2>/dev/null)
  unset key
  jq -r '.status // "unknown"' <<<"$resp" 2>/dev/null || print -r -- unknown
}

# Apex registration automatically creates a paired www domain. Both must be
# active before production verification, because each gets its own TLS state.
dhm_hn_domain_family_status() {  # dhm_hn_domain_family_status <domain>
  local domain=$1 json row is_apex name member_status
  local -a names statuses
  json=$(dhm_hn_domains_json) || { print -r -- unknown; return 1 }
  row=$(jq -c --arg d "$domain" \
    'first(.domains[]? | select(.domain == $d)) // empty' <<<"$json")
  [[ -n "$row" ]] || { print -r -- unknown; return 1 }
  is_apex=$(jq -r '.is_apex == true' <<<"$row")
  names=("$domain")
  [[ "$is_apex" == true ]] && names+=("www.${domain}")

  for name in "${names[@]}"; do
    member_status=$(dhm_hn_domain_status "$name")
    statuses+=("$member_status")
  done
  for member_status in "${statuses[@]}"; do
    [[ "$member_status" == active ]] || { print -r -- pending; return 0 }
  done
  print -r -- active
}

dhm_hn_wait_domain_active() {  # dhm_hn_wait_domain_active <domain> [attempts] [sleep]
  local domain=$1 attempts=${2:-20} nap=${3:-15} i domain_status
  if dhm_dry "wait for ${domain} to become active"; then return 0; fi
  for (( i = 1; i <= attempts; i++ )); do
    domain_status=$(dhm_hn_domain_family_status "$domain")
    dhm_log "domain family ${domain} attempt ${i}/${attempts}: ${domain_status}"
    [[ "$domain_status" == active ]] && { dhm_ok "${domain} is active"; return 0 }
    (( i < attempts )) && sleep "$nap"
  done
  dhm_error "${domain} did not reach 'active' after ${attempts} attempt(s)"
  return 1
}

# ----------------------------------------------------------------- links ----
#
# Registering and verifying a domain does NOT serve a Site from it. Without an
# explicit root link the apex returns here.now's empty-domain placeholder, which
# is a 200 and therefore invisible to a naive health check. This is the single
# easiest step in the whole migration to miss.

dhm_hn_root_link_slug() {  # dhm_hn_root_link_slug <domain> ; prints bound slug or empty
  local key resp
  key=$(dhm_hn_key) || return 1
  if ! resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/v1/domains/${1}" \
      -H "Authorization: Bearer ${key}" 2>/dev/null); then
    unset key
    return 1
  fi
  unset key
  jq -e '(.mounts | type) == "array"' <<<"$resp" >/dev/null 2>&1 || return 1
  jq -r 'first(.mounts[]? | select(.mount_path == "") | .slug) // empty' \
    <<<"$resp" 2>/dev/null
}

dhm_hn_bind_root() {  # dhm_hn_bind_root <domain> <slug>
  local domain=$1 slug=$2 key resp bound

  if ! bound=$(dhm_hn_root_link_slug "$domain"); then
    dhm_error "could not read the current root mount for ${domain}; refusing to modify it"
    return 1
  fi
  if [[ "$bound" == "$slug" ]]; then
    dhm_ok "${domain} is already mounted to ${slug}"
    return 0
  fi
  if [[ -n "$bound" ]]; then
    dhm_warn "${domain} is currently mounted to '${bound}', not '${slug}'"
    dhm_confirm_yes "re-point ${domain} to ${slug}?" || return 1
  fi

  if dhm_dry "mount ${slug} at the root of ${domain}"; then return 0; fi

  key=$(dhm_hn_key) || return 1
  resp=$(curl -fsS --max-time 30 "${DHM_HN_API}/api/v1/links" \
    -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
    -d "$(jq -nc --arg s "$slug" --arg d "$domain" '{location:"", slug:$s, domain:$d}')" 2>&1)
  local rc=$?
  unset key
  if (( rc != 0 )); then
    dhm_error "here.now refused the root link: $(print -r -- "$resp" | dhm_redact)"
    return 1
  fi

  if ! bound=$(dhm_hn_root_link_slug "$domain"); then
    dhm_error "root link readback failed: could not read ${domain} after mount"
    return 1
  fi
  if [[ "$bound" != "$slug" ]]; then
    dhm_error "root link readback failed: ${domain} reports '${bound:-none}', expected '${slug}'"
    return 1
  fi
  dhm_ok "mounted ${slug} at the root of ${domain}"
}
