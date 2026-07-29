#!/usr/bin/env zsh
# ghw doctor — per-profile credential/role health. Read-only.

ghw_doctor() {
  local file profile env_name expected me scopes org role body rc
  local -i broken=0
  local tmp; tmp=$(mktemp)
  file=$(ghw_accounts_file)
  for profile in ${(f)"$(jq -r '.profiles | keys[]' "$file")"}; do
    env_name=$(ghw_profile_field "$profile" token_env)
    if ! ghw_token_for "$profile" >/dev/null 2>/dev/null; then
      print -r -- "profile ${profile}: token=MISSING (gh auth login, or export ${env_name})"
      (( broken++ )); continue
    fi
    expected=$(ghw_profile_login "$profile")
    # NOTE: `body=$(ghw_api ...)` would fork a subshell, losing the
    # `typeset -g GHW_LAST_STATUS`/`GHW_LAST_HEADERS` ghw_api sets — same
    # pitfall documented in lib/auth.zsh's ghw_precheck. Use the temp-file
    # idiom instead so both the body and GHW_LAST_* survive the call.
    ghw_api GET /user >"$tmp"; rc=$?
    body=$(<"$tmp")
    if (( rc != 0 )); then
      print -r -- "profile ${profile}: token=INVALID (HTTP ${GHW_LAST_STATUS})"
      (( broken++ )); continue
    fi
    me=$(print -r -- "$body" | jq -r .login)
    scopes=$(print -r -- "$GHW_LAST_HEADERS" | awk 'tolower($1)=="x-oauth-scopes:" { $1=""; gsub("\r",""); sub(/^ /,""); print; exit }')
    local login_disp="ok"
    if [[ "$me" != "$expected" ]]; then login_disp="MISMATCH(${me})"; (( broken++ )); fi
    print -r -- "profile ${profile}: token=ok(${GHW_TOKEN_SOURCE:-unknown}) login=${login_disp} scopes=${scopes:-fine-grained}"
    for org in ${(f)"$(jq -r --arg p "$profile" '.profiles[$p].orgs[]' "$file")"}; do
      ghw_api GET "/orgs/${org}/memberships/${me}" >"$tmp"; rc=$?
      body=$(<"$tmp")
      if (( rc == 0 )); then
        role=$(print -r -- "$body" | jq -r .role)
      elif (( rc == 4 )); then
        role="none"
      else
        role="error(HTTP ${GHW_LAST_STATUS})"
      fi
      print -r -- "  org ${org}: role=${role}"
      [[ "$role" != admin ]] && (( broken++ ))
    done
  done
  rm -f "$tmp"
  (( broken == 0 ))
}
