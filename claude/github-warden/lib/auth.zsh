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
