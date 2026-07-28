#!/usr/bin/env zsh
# ghw auth — profile resolution + token loading. Precondition gate added in a
# later section of this file. Requires jq. Sourced by bin/ghw and engines.

ghw_accounts_file() {
  print -r -- "${GHW_ACCOUNTS_FILE:-${daemon_dir}/config/accounts.json}"
}

ghw_resolve_profile() {  # $1 explicit account or "", $2 target org/owner or ""
  local explicit="$1" org="$2" file
  file=$(ghw_accounts_file)
  if [[ ! -f "$file" ]]; then
    print -ru2 -- "ghw: accounts file not found: $file"
    return 2
  fi
  if [[ -n "$explicit" ]]; then
    if jq -e --arg p "$explicit" '.profiles[$p]' "$file" >/dev/null; then
      print -r -- "$explicit"
      return 0
    fi
    print -ru2 -- "ghw: unknown account profile: $explicit ($(jq -r '.profiles | keys | join(", ")' "$file"))"
    return 2
  fi
  if [[ -n "$org" ]]; then
    local match
    match=$(jq -r --arg o "$org" '.profiles | to_entries[] | select(.value.orgs | index($o)) | .key' "$file" | head -1)
    if [[ -n "$match" ]]; then
      print -r -- "$match"
      return 0
    fi
    print -ru2 -- "ghw: org '$org' not mapped to any profile. Known orgs: $(jq -r '[.profiles[].orgs[]] | join(", ")' "$file"). Use --account or add it to config/accounts.json."
    return 2
  fi
  print -ru2 -- "ghw: cannot resolve account — pass --account or a target org"
  return 2
}

ghw_profile_field() {  # $1 profile, $2 field
  jq -r --arg p "$1" --arg f "$2" '.profiles[$p][$f]' "$(ghw_accounts_file)"
}

ghw_profile_login() { ghw_profile_field "$1" login }

ghw_token_for() {  # $1 profile — exports GHW_TOKEN, GHW_TOKEN_ENV_NAME
  local env_name
  env_name=$(ghw_profile_field "$1" token_env)
  if [[ -z "${(P)env_name:-}" ]]; then
    print -ru2 -- "ghw: token env var ${env_name} is empty — export it for profile '$1'"
    return 2
  fi
  typeset -gx GHW_TOKEN="${(P)env_name}" GHW_TOKEN_ENV_NAME="$env_name"
}

# ---- precondition gate (import spec §3) ------------------------------------
# All-or-nothing, runs before any write. Named failures, return 5.

ghw_precheck() {  # $1 profile, $2 org, $3 optional team slug
  local profile="$1" org="$2" team="${3:-}"
  local me expected scopes body rc
  local tmp; tmp=$(mktemp)

  # P1 token authenticates + login matches profile
  # NOTE: ghw_api's response is captured via `>"$tmp"` + `$(<"$tmp")`, not
  # `body=$(ghw_api ...)`. zsh forks a subshell for command substitution, so
  # `typeset -g GHW_LAST_STATUS`/`GHW_LAST_HEADERS` set inside ghw_api would
  # never reach this caller (same pitfall documented in test/api.test.zsh).
  ghw_api GET /user >"$tmp"; rc=$?
  body=$(<"$tmp")
  if (( rc != 0 )); then
    print -ru2 -- "AUTH_INVALID: GET /user failed (HTTP ${GHW_LAST_STATUS}). Check \$${GHW_TOKEN_ENV_NAME:-GHW_TOKEN}."
    rm -f "$tmp"
    return 5
  fi
  me=$(print -r -- "$body" | jq -r .login)
  expected=$(ghw_profile_login "$profile")
  if [[ "$me" != "$expected" ]]; then
    print -ru2 -- "AUTH_INVALID: token authenticates as '${me}', profile '${profile}' expects '${expected}'."
    rm -f "$tmp"
    return 5
  fi

  # P2 scopes — classic PAT lists them in x-oauth-scopes; fine-grained PATs
  # send no header, in which case P3 (org admin) is the real authority.
  scopes=$(print -r -- "$GHW_LAST_HEADERS" | awk 'tolower($1)=="x-oauth-scopes:" { $1=""; gsub("\r",""); print; exit }')
  if [[ -n "${scopes// /}" && ",${scopes// /}," != *,admin:org,* ]]; then
    print -ru2 -- "SCOPE_MISSING: token scopes (${scopes## }) lack admin:org. Re-issue the PAT with admin:org (or a fine-grained PAT with Organization Members: read & write). ghw never self-elevates."
    rm -f "$tmp"
    return 5
  fi

  # P4 org exists
  ghw_api GET "/orgs/${org}" >/dev/null; rc=$?
  if (( rc != 0 )); then
    print -ru2 -- "ORG_NOT_FOUND: /orgs/${org} → HTTP ${GHW_LAST_STATUS}."
    rm -f "$tmp"
    return 5
  fi

  # P3 caller is org admin
  ghw_api GET "/orgs/${org}/memberships/${me}" >"$tmp"; rc=$?
  body=$(<"$tmp")
  if (( rc != 0 )) || [[ "$(print -r -- "$body" | jq -r .role)" != "admin" ]]; then
    print -ru2 -- "NOT_ORG_ADMIN: ${me} role in ${org} is '$(print -r -- "$body" | jq -r .role 2>/dev/null)' (need admin)."
    rm -f "$tmp"
    return 5
  fi

  # P5 team exists (when targeted)
  if [[ -n "$team" ]]; then
    ghw_api GET "/orgs/${org}/teams/${team}" >/dev/null; rc=$?
    if (( rc != 0 )); then
      print -ru2 -- "TEAM_NOT_FOUND: /orgs/${org}/teams/${team} → HTTP ${GHW_LAST_STATUS}."
      rm -f "$tmp"
      return 5
    fi
  fi
  rm -f "$tmp"
  return 0
}
