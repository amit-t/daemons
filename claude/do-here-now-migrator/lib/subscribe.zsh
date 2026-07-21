#!/usr/bin/env zsh
# do-here-now-migrator — subscribe provider resolution.
#
# A database-backed subscribe form cannot survive a static export: there is no
# runtime left to accept the POST. Something must replace it, and this module
# decides what. Substack is the default suggestion, never an assumption — the
# provider is chosen explicitly, may be any hosted form, and may be "none".
#
# Nothing here contacts a provider's API or assumes an account exists. The only
# external check is an unauthenticated reachability probe of the URL the user
# supplies, so a typo is caught before the agent wires it into the site.

typeset -ga DHM_SUBSCRIBE_PROVIDERS=(
  substack buttondown convertkit mailchimp beehiiv ghost custom none
)

dhm_subscribe_is_provider() {  # dhm_subscribe_is_provider <name>
  local p
  for p in "${DHM_SUBSCRIBE_PROVIDERS[@]}"; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

# Human-readable description used in help output and the interactive prompt.
dhm_subscribe_describe() {  # dhm_subscribe_describe <provider>
  case "$1" in
    substack)   print -r -- "Substack publication — link out to its /subscribe page" ;;
    buttondown) print -r -- "Buttondown — link out to the public subscribe page" ;;
    convertkit) print -r -- "ConvertKit/Kit — link out to a hosted landing page or form" ;;
    mailchimp)  print -r -- "Mailchimp — link out to a hosted signup form" ;;
    beehiiv)    print -r -- "beehiiv — link out to the publication subscribe page" ;;
    ghost)      print -r -- "Ghost — link out to the /#/portal/signup route" ;;
    custom)     print -r -- "Any other hosted form — you supply the full URL" ;;
    none)       print -r -- "No subscribe CTA — remove the form and add nothing" ;;
    *)          print -r -- "unknown provider" ;;
  esac
}

# The canonical URL shape for a provider, given a handle. Used only to build a
# suggestion; the user's explicit --subscribe-url always wins.
dhm_subscribe_url_for_handle() {  # dhm_subscribe_url_for_handle <provider> <handle>
  local provider=$1 handle=$2
  [[ -n "$handle" ]] || return 1
  case "$provider" in
    substack)   print -r -- "https://${handle}.substack.com/subscribe" ;;
    buttondown) print -r -- "https://buttondown.com/${handle}" ;;
    beehiiv)    print -r -- "https://${handle}.beehiiv.com/subscribe" ;;
    convertkit) print -r -- "https://${handle}.kit.com" ;;
    ghost)      print -r -- "https://${handle}/#/portal/signup" ;;
    *)          return 1 ;;
  esac
}

# Probe a subscribe URL without following it into a different host silently.
# A provider that answers 2xx/3xx is good enough; we deliberately do not treat
# 403/405 as fatal because some hosted forms reject HEAD from a bare client.
dhm_subscribe_probe() {  # dhm_subscribe_probe <url>
  local url=$1 code
  code=$(dhm_http_status "$url" -I -L --max-redirs 5)
  if [[ "$code" == 000 ]]; then
    code=$(dhm_http_status "$url" -L --max-redirs 5)
  fi
  print -r -- "$code"
  case "$code" in
    2??|3??) return 0 ;;
    403|405) dhm_warn "subscribe URL answered ${code}; treating as reachable (host rejects bare probes)"; return 0 ;;
    *)       return 1 ;;
  esac
}

# Resolve provider + URL into the final pair, prompting only when a value is
# genuinely missing and a terminal is attached. In non-interactive runs with no
# provider supplied the answer is "none" — silently linking a subscribe button
# to a guessed URL would be worse than shipping no button.
dhm_subscribe_resolve() {  # dhm_subscribe_resolve <provider> <url> <handle>
  local provider=$1 url=$2 handle=$3

  if [[ -z "$provider" ]]; then
    if [[ -t 0 && -z "${DHM_ASSUME_YES:-}" ]]; then
      print -ru2 -- ""
      print -ru2 -- "The existing subscribe form cannot work on a static site."
      print -ru2 -- "Choose what replaces it:"
      local p
      for p in "${DHM_SUBSCRIBE_PROVIDERS[@]}"; do
        printf '  %-11s %s\n' "$p" "$(dhm_subscribe_describe "$p")" >&2
      done
      provider=$(dhm_prompt_value "provider") || return 1
      provider=${provider:-none}
    else
      dhm_warn "no --subscribe provider given and no terminal attached; defaulting to 'none'"
      provider=none
    fi
  fi

  if ! dhm_subscribe_is_provider "$provider"; then
    dhm_error "unknown subscribe provider '${provider}'"
    dhm_error "valid: ${DHM_SUBSCRIBE_PROVIDERS[*]}"
    return 1
  fi

  if [[ "$provider" == none ]]; then
    jq -n '{provider:"none", url:null, verified:false, status:null}'
    return 0
  fi

  if [[ -z "$url" && -n "$handle" ]]; then
    url=$(dhm_subscribe_url_for_handle "$provider" "$handle") || url=""
    [[ -n "$url" ]] && dhm_log "derived subscribe URL from handle: ${url}"
  fi

  if [[ -z "$url" ]]; then
    if [[ -t 0 && -z "${DHM_ASSUME_YES:-}" ]]; then
      url=$(dhm_prompt_value "full ${provider} subscribe URL") || return 1
    else
      dhm_error "provider '${provider}' needs --subscribe-url (or --subscribe-handle) in a non-interactive run"
      return 1
    fi
  fi

  if [[ "$url" != https://* ]]; then
    dhm_error "subscribe URL must be https:// — got '${url}'"
    return 1
  fi

  # `status` is a read-only special in zsh, so the probe result needs its own name.
  local probe_status verified=false
  if [[ -n "${DHM_SKIP_SUBSCRIBE_PROBE:-}" ]]; then
    dhm_warn "skipping subscribe URL probe (DHM_SKIP_SUBSCRIBE_PROBE set)"
    probe_status=skipped
  elif probe_status=$(dhm_subscribe_probe "$url"); then
    dhm_ok "subscribe URL reachable (${probe_status}): ${url}"
    verified=true
  else
    dhm_error "subscribe URL ${url} answered ${probe_status}"
    dhm_error "fix the URL, or pass DHM_SKIP_SUBSCRIBE_PROBE=1 to accept it unverified"
    return 1
  fi

  jq -n --arg p "$provider" --arg u "$url" --arg s "$probe_status" --argjson v "$verified" \
    '{provider:$p, url:$u, verified:$v, status:$s}'
}
