#!/usr/bin/env zsh
# do-here-now-migrator — phase 8: verify.
#
# The gate that stands between a migration and an irreversible deletion.
#
# The subtle failure this phase exists to catch: a verified custom domain with
# no Site mounted returns HTTP 200 serving here.now's empty-domain placeholder.
# Every naive health check passes while the site is, in fact, gone. The
# authoritative test is therefore not "does the apex return 200" but "does the
# apex return the same bytes as the published Site".

typeset -g DHM_VERIFY_FAILURES=0

dhm_vf_fail() { dhm_error "$*"; (( DHM_VERIFY_FAILURES++ )) || true }
dhm_vf_pass() { dhm_ok "$*" }

dhm_verify_reset() { DHM_VERIFY_FAILURES=0 }

# Derive the route list from the built output rather than guessing. Every
# directory holding an index.html is a route the live site must serve.
dhm_verify_routes_from_output() {  # dhm_verify_routes_from_output <out-dir> [limit]
  local out=${1:A} limit=${2:-25} f rel
  [[ -d "$out" ]] || { print -r -- "/"; return 0 }
  print -r -- "/"
  for f in "$out"/*/index.html(N) "$out"/*/*/index.html(N); do
    rel=${f#$out/}
    rel=${rel%/index.html}
    [[ "$rel" == _next* || "$rel" == .* ]] && continue
    print -r -- "/${rel}/"
  done | sort -u | head -n "$limit"
}

dhm_verify_route() {  # dhm_verify_route <base-url> <path>
  local base=${1%/} route_path=$2 code
  code=$(dhm_http_status "${base}${route_path}")
  if [[ "$code" == 200 ]]; then
    dhm_vf_pass "200 ${route_path}"
    return 0
  fi
  dhm_vf_fail "${code} ${route_path}"
  return 1
}

# The placeholder test. Compares the apex homepage against the published Site's
# own homepage; a mismatch means the domain is not actually serving the Site.
dhm_verify_domain_serves_site() {  # dhm_verify_domain_serves_site <domain> <slug>
  local domain=$1 slug=$2 apex_file site_file apex_sum site_sum apex_size

  apex_file=$(mktemp) site_file=$(mktemp) || return 1
  {
    if ! curl -fsS --max-time 30 "https://${domain}/" -o "$apex_file" 2>/dev/null; then
      dhm_vf_fail "https://${domain}/ did not return a document"
      rm -f -- "$apex_file" "$site_file"
      return 1
    fi
    if ! curl -fsS --max-time 30 "https://${slug}.here.now/" -o "$site_file" 2>/dev/null; then
      dhm_vf_fail "https://${slug}.here.now/ did not return a document"
      rm -f -- "$apex_file" "$site_file"
      return 1
    fi
  }

  apex_sum=$(shasum -a 256 < "$apex_file" | cut -d' ' -f1)
  site_sum=$(shasum -a 256 < "$site_file" | cut -d' ' -f1)
  apex_size=$(wc -c < "$apex_file" | tr -d ' ')

  if [[ "$apex_sum" == "$site_sum" ]]; then
    dhm_vf_pass "https://${domain}/ serves the published Site byte-for-byte (${apex_size} bytes)"
    rm -f -- "$apex_file" "$site_file"
    return 0
  fi

  # Not identical. Distinguish "placeholder" from "different but plausible".
  local title
  title=$(grep -o '<title>[^<]*</title>' "$apex_file" 2>/dev/null | head -1 | sed 's/<[^>]*>//g')
  if [[ "$title" == "$domain" ]] || (( apex_size < 4096 )); then
    dhm_vf_fail "https://${domain}/ is serving here.now's empty-domain placeholder, not the Site"
    dhm_vf_fail "  the domain is verified but no Site is mounted at its root"
    dhm_vf_fail "  fix: dhm bind-domain --site <site>   (POST /api/v1/links with location \"\")"
  else
    dhm_vf_fail "https://${domain}/ (${apex_size} bytes, title '${title}') differs from the published Site"
    dhm_vf_fail "  the domain may be mounted to a different slug"
  fi
  rm -f -- "$apex_file" "$site_file"
  return 1
}

dhm_verify_root_link() {  # dhm_verify_root_link <domain> <slug>
  local bound
  bound=$(dhm_hn_root_link_slug "$1" 2>/dev/null)
  if [[ "$bound" == "$2" ]]; then
    dhm_vf_pass "root link: ${1} -> ${2}"
    return 0
  fi
  dhm_vf_fail "root link for ${1} is '${bound:-none}', expected '${2}'"
  return 1
}

dhm_verify_www_redirect() {  # dhm_verify_www_redirect <domain>
  local domain=$1 code location
  code=$(dhm_http_status "https://www.${domain}/")
  location=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 30 "https://www.${domain}/" 2>/dev/null)
  case "$code" in
    301|302|307|308)
      if [[ "$location" == "https://${domain}/"* ]]; then
        dhm_vf_pass "www redirects ${code} -> ${location}"
        return 0
      fi
      dhm_vf_fail "www redirects ${code} to '${location}', expected https://${domain}/"
      ;;
    200) dhm_vf_pass "www serves 200 directly (no redirect configured)" ; return 0 ;;
    *)   dhm_vf_fail "https://www.${domain}/ returned ${code}" ;;
  esac
  return 1
}

dhm_verify_tls() {  # dhm_verify_tls <domain>
  local result
  result=$(curl -sS -o /dev/null -w '%{ssl_verify_result}' --max-time 30 "https://${1}/" 2>/dev/null)
  if [[ "$result" == 0 ]]; then
    dhm_vf_pass "TLS certificate for ${1} verifies"
    return 0
  fi
  dhm_vf_fail "TLS verification for ${1} failed (code ${result:-unknown})"
  return 1
}

# The subscribe CTA is the one piece of user-facing behaviour the transform is
# responsible for, so it is checked on the live site rather than in the source.
dhm_verify_subscribe() {  # dhm_verify_subscribe <domain> <provider> <url>
  local domain=$1 provider=$2 url=$3 body host
  [[ "$provider" == none || -z "$provider" ]] && { dhm_log "no subscribe provider configured; skipping CTA check"; return 0 }
  [[ -n "$url" ]] || { dhm_vf_fail "subscribe provider '${provider}' has no URL recorded"; return 1 }

  body=$(curl -fsS --max-time 30 "https://${domain}/" 2>/dev/null)
  host=${url#https://}; host=${host%%/*}
  if print -r -- "$body" | grep -qF -- "$host"; then
    dhm_vf_pass "subscribe CTA points at ${host}"
    return 0
  fi
  dhm_vf_fail "no link to ${host} found on https://${domain}/"
  return 1
}

# Nothing that used to run server-side should still be referenced publicly.
dhm_verify_no_stale_origin() {  # dhm_verify_no_stale_origin <domain> <origin-host>
  local domain=$1 origin=$2 body
  [[ -n "$origin" ]] || return 0
  body=$(curl -fsS --max-time 30 "https://${domain}/" 2>/dev/null)
  if print -r -- "$body" | grep -qF -- "$origin"; then
    dhm_vf_fail "the live homepage still references the old origin ${origin}"
    return 1
  fi
  dhm_vf_pass "no reference to the old origin ${origin}"
  return 0
}

# Full gate. Returns non-zero if anything failed, which blocks decommission.
dhm_verify_all() {  # dhm_verify_all <domain> <slug> <out-dir> <provider> <sub-url> <old-origin>
  local domain=$1 slug=$2 out=$3 provider=$4 suburl=$5 origin=$6

  dhm_verify_reset
  if dhm_dry "run the full production verification for ${domain}"; then return 0; fi

  dhm_info "verifying https://${domain} against Site ${slug}"

  dhm_verify_tls "$domain"
  dhm_verify_root_link "$domain" "$slug"
  dhm_verify_domain_serves_site "$domain" "$slug"

  local -a routes
  routes=(${(f)"$(dhm_verify_routes_from_output "$out")"})
  dhm_info "checking ${#routes} route(s)"
  local r
  for r in "${routes[@]}"; do
    dhm_verify_route "https://${domain}" "$r"
  done

  dhm_verify_www_redirect "$domain"
  dhm_verify_subscribe "$domain" "$provider" "$suburl"
  dhm_verify_no_stale_origin "$domain" "$origin"

  if (( DHM_VERIFY_FAILURES > 0 )); then
    dhm_error "verification failed with ${DHM_VERIFY_FAILURES} problem(s)"
    dhm_error "nothing will be decommissioned while verification is failing"
    return 1
  fi
  dhm_ok "verification passed: ${#routes} route(s), TLS, www, mount, and CTA all good"
  return 0
}
