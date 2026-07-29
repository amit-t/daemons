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

  local members admins twofa teams team outside u teams_json team_json
  # Every fetch below names the exact endpoint on failure — these four are
  # not masked-pipe cases (no `| jq` before the check), but a bare
  # `|| return 1` still exits with zero stderr output, leaving an operator
  # to guess which of five possible reads failed. Same reasoning as the
  # teams-list/per-team messages below: this command's output is documented
  # to round-trip into `ghw import`, so a silent failure here is not
  # acceptable even where it isn't also a data-corruption risk.
  members=$(ghw_api_paged "/orgs/${org}/members") || { print -ru2 -- "ghw members: /orgs/${org}/members read failed"; return 1 }
  admins=$(ghw_api_paged "/orgs/${org}/members?role=admin") || { print -ru2 -- "ghw members: /orgs/${org}/members?role=admin read failed"; return 1 }
  twofa=$(ghw_api_paged "/orgs/${org}/members?filter=2fa_disabled") || { print -ru2 -- "ghw members: /orgs/${org}/members?filter=2fa_disabled read failed"; return 1 }
  outside=$(ghw_api_paged "/orgs/${org}/outside_collaborators") || { print -ru2 -- "ghw members: /orgs/${org}/outside_collaborators read failed"; return 1 }
  # Fetch and parse are split into separate statements (not a `ghw_api_paged
  # | jq` pipeline) deliberately: a pipeline's `$?` in plain zsh (no
  # `pipefail` set anywhere in this codebase) reflects only its LAST stage.
  # `ghw_api_paged` prints nothing on failure, so `jq` would see empty stdin
  # and exit 0 — masking the read failure behind `|| return 1` and letting
  # the report below silently treat "no teams" as "org has no teams" instead
  # of "teams list unreadable". Same pitfall `lib/import-engine.zsh`'s
  # pre-write reads are already guarded against, for the same reason.
  teams_json=$(ghw_api_paged "/orgs/${org}/teams") || { print -ru2 -- "ghw members: /orgs/${org}/teams read failed"; return 1 }
  teams=$(print -r -- "$teams_json" | jq -r '.[].slug') || { print -ru2 -- "ghw members: /orgs/${org}/teams list did not parse"; return 1 }

  typeset -A team_of is_admin no2fa
  for u in ${(f)"$(print -r -- "$admins" | jq -r '.[].login')"}; do is_admin[$u]=1; done
  for u in ${(f)"$(print -r -- "$twofa" | jq -r '.[].login')"}; do no2fa[$u]=1; done
  for team in ${(f)teams}; do
    # Same split-then-check as above, plus: this fetch previously had NO
    # guard at all (not even a masked one) — a failure here silently left
    # that one team's members out of `team_of`, so every login in that team
    # would report as belonging to no team in the CSV/JSON/table output,
    # rather than aborting the run. `ghw members --csv` output is documented
    # to round-trip into `ghw import`, so a silently-incomplete team column
    # here could drive a write from incomplete data — abort instead.
    team_json=$(ghw_api_paged "/orgs/${org}/teams/${team}/members") || { print -ru2 -- "ghw members: /orgs/${org}/teams/${team}/members read failed"; return 1 }
    for u in ${(f)"$(print -r -- "$team_json" | jq -r '.[].login')"}; do
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
