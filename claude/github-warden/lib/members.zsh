#!/usr/bin/env zsh
# ghw members — read-only membership report. CSV round-trips into ghw import.

ghw_members() {  # $1 account, remaining flags
  local account="$1"; shift
  local org="" csv_out="" json_mode=0
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      --csv) csv_out="${2:?}"; shift 2 ;;
      --json) json_mode=1; shift ;;
      *) print -ru2 -- "ghw members: unknown flag: $1"; return 2 ;;
    esac
  done
  [[ -z "$org" ]] && { print -ru2 -- "ghw members: --org required"; return 2 }
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  ghw_token_for "$profile" || return 2

  local members admins twofa teams team outside u
  members=$(ghw_api_paged "/orgs/${org}/members") || return 1
  admins=$(ghw_api_paged "/orgs/${org}/members?role=admin") || return 1
  twofa=$(ghw_api_paged "/orgs/${org}/members?filter=2fa_disabled") || return 1
  outside=$(ghw_api_paged "/orgs/${org}/outside_collaborators") || return 1
  teams=$(ghw_api_paged "/orgs/${org}/teams" | jq -r '.[].slug') || return 1

  typeset -A team_of is_admin no2fa
  for u in ${(f)"$(print -r -- "$admins" | jq -r '.[].login')"}; do is_admin[$u]=1; done
  for u in ${(f)"$(print -r -- "$twofa" | jq -r '.[].login')"}; do no2fa[$u]=1; done
  for team in ${(f)teams}; do
    for u in ${(f)"$(ghw_api_paged "/orgs/${org}/teams/${team}/members" | jq -r '.[].login')"}; do
      team_of[$u]="${team_of[$u]:+${team_of[$u]};}${team}"
    done
  done

  local -a rows
  local role_disp twofa_disp
  rows=("login,org_role,teams,twofa_disabled,outside_collaborator")
  for u in ${(f)"$(print -r -- "$members" | jq -r '.[].login')"}; do
    role_disp=member; [[ -n "${is_admin[$u]:-}" ]] && role_disp=admin
    twofa_disp=false; [[ -n "${no2fa[$u]:-}" ]] && twofa_disp=true
    rows+=("${u},${role_disp},${team_of[$u]:-},${twofa_disp},false")
  done
  for u in ${(f)"$(print -r -- "$outside" | jq -r '.[].login')"}; do
    rows+=("${u},,,false,true")
  done

  if [[ -n "$csv_out" ]]; then
    print -rl -- "${rows[@]}" > "$csv_out"
    print -r -- "wrote ${#rows[@]} lines to ${csv_out}"
  elif (( json_mode )); then
    print -rl -- "${rows[@]}" | jq -R -s 'split("\n") | map(select(length>0)) | .[1:] | map(split(",") | {login: .[0], org_role: .[1], teams: .[2], twofa_disabled: .[3], outside_collaborator: .[4]})'
  else
    print -rl -- "${rows[@]}" | column -t -s,
  fi
}
