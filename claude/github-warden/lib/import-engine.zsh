#!/usr/bin/env zsh
# ghw import engine — deterministic org/team membership reconciliation.
# Implements SPEC-org-import-daemon §3–§8. THE ONLY CODE PATH THAT WRITES
# MEMBERSHIPS. Read-then-diff-then-write; never PUTs an existing member (§4.2);
# org phase completes before team phase (§4.1); verifies against live state.
set -u
script_path=${0:A}
daemon_dir=${script_path:h:h}

source "${daemon_dir}/lib/api.zsh"
source "${daemon_dir}/lib/auth.zsh"
source "${daemon_dir}/lib/report.zsh"

usage() {
  print -ru2 -- "usage: import-engine.zsh --org <org> [--team <slug>] --csv <file> [--column login] [--role member|maintainer] [--org-role member|admin] [--account <profile>] [--dry-run]"
  exit 2
}

org="" team="" csv="" column="login" role="member" org_role="member" account="" dry_run=0
while (( $# )); do
  case "$1" in
    --org) org="${2:?}"; shift 2 ;;
    --team) team="${2:?}"; shift 2 ;;
    --csv) csv="${2:?}"; shift 2 ;;
    --column) column="${2:?}"; shift 2 ;;
    --role) role="${2:?}"; shift 2 ;;
    --org-role) org_role="${2:?}"; shift 2 ;;
    --account) account="${2:?}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done
[[ -z "$org" || -z "$csv" ]] && usage
[[ "$role" != (member|maintainer) ]] && usage
[[ "$org_role" != (member|admin) ]] && usage

: ${GHW_STATE_DIR:=${HOME}/.local/state/github-warden}

profile=$(ghw_resolve_profile "$account" "$org") || exit 2
ghw_token_for "$profile" || exit 2

# P6 first (cheap, local), then API preconditions P1–P5.
logins_raw=$(ghw_parse_source "$csv" "$column") || exit 6
# ADAPTATION: brief said `local -a logins` — this is top-level script body,
# not inside a function, so `local` has no enclosing function scope to bind
# to. Use `typeset -a` instead (same effect at script scope).
typeset -a logins; logins=("${(@f)logins_raw}")
ghw_precheck "$profile" "$org" "$team" || exit 5

job_id="$(date +%Y%m%dT%H%M%S)-${org}${team:+-${team}}"
ghw_report_init "$job_id"

fetch_org_members() { ghw_api_paged "/orgs/${org}/members" | jq -r '.[].login' }
fetch_team_members() { ghw_api_paged "/orgs/${org}/teams/${team}/members" | jq -r '.[].login' }

typeset -A in_org in_team
# ADAPTATION: brief said `local u` — again top-level script body, not a
# function; `local` would error/be meaningless there. Use `typeset`.
typeset u
for u in ${(f)"$(fetch_org_members)"}; do in_org[$u]=1; done
org_before=${#in_org}
team_before=0
if [[ -n "$team" ]]; then
  for u in ${(f)"$(fetch_team_members)"}; do in_team[$u]=1; done
  team_before=${#in_team}
fi

# §4 steps 4–5: set difference IS the safety mechanism (§4.2).
# ADAPTATION: brief said `local -a add_org add_team` — top-level script body
# again; use `typeset -a`.
typeset -a add_org add_team
add_org=(); add_team=()
# Per-phase set difference, independently: skip the org PUT iff already an
# org member; skip the team PUT iff already a team member. An existing org
# Owner who isn't yet on the target team MUST still receive a team PUT
# (GitHub auto-elevates org Owners added to a team to maintainer — reported
# via the "org owner auto-elevated" note below, not suppressed as an error).
# This is also the daemon's primary use case: adding EXISTING org members to
# a team. Cross-phase exclusion was tried and reverted — it broke that case.
for u in "${logins[@]}"; do
  if [[ -n "${in_org[$u]:-}" ]]; then
    ghw_report_row "$u" org skipped active "" "already a member"
  else
    add_org+=("$u")
  fi
done
if [[ -n "$team" ]]; then
  for u in "${logins[@]}"; do
    if [[ -n "${in_team[$u]:-}" ]]; then
      ghw_report_row "$u" team skipped active "" "already a member"
    else
      add_team+=("$u")
    fi
  done
fi

if (( dry_run )); then
  for u in "${add_org[@]}"; do ghw_report_row "$u" org would_add "" "$org_role" ""; done
  for u in "${add_team[@]}"; do ghw_report_row "$u" team would_add "" "$role" ""; done
  rdir=$(ghw_report_finish "dry_run: org +${#add_org}, team +${#add_team}, zero writes")
  print -r -- "dry-run: would add ${#add_org} to org, ${#add_team} to team ${team:-'(none)'}"
  print -r -- "report: $rdir"
  exit 0
fi

typeset -A org_failed   # logins that failed/404'd in phase 1 — excluded from phase 2
errors=0

# Phase 1: org membership (fully completes before team phase — §4.1). Serial.
# ADAPTATION: brief said `body=$(ghw_api PUT ...)`. `var=$(func)` forks a
# subshell for the command substitution, so `typeset -g GHW_LAST_STATUS`/
# `GHW_LAST_HEADERS` set inside ghw_api are lost to this caller (same pitfall
# documented in ghw_precheck / test/api.test.zsh). We need both the response
# body AND GHW_LAST_STATUS (used in the failed-row detail message below), so
# use the established idiom: redirect to a temp file, then read it back.
tmp=$(mktemp)
for u in "${add_org[@]}"; do
  ghw_api PUT "/orgs/${org}/memberships/${u}" "{\"role\":\"${org_role}\"}" >"$tmp"; rc=$?
  body=$(<"$tmp")
  case $rc in
    0)
      state=$(print -r -- "$body" | jq -r '.state // ""')
      got_role=$(print -r -- "$body" | jq -r '.role // ""')
      ghw_report_row "$u" org added "$state" "$got_role" ""
      print -r -- "org + ${u} (${state})"
      ;;
    4)
      ghw_report_row "$u" org not_found "" "" "account does not exist on github.com"
      org_failed[$u]=1; (( errors++ )) || true
      ;;
    *)
      ghw_report_row "$u" org failed "" "" "HTTP ${GHW_LAST_STATUS}: $(print -r -- "$body" | jq -r '.message // ""' 2>/dev/null)"
      org_failed[$u]=1; (( errors++ )) || true
      ;;
  esac
done

# Phase 2: team membership.
if [[ -n "$team" ]]; then
  for u in "${add_team[@]}"; do
    [[ -n "${org_failed[$u]:-}" ]] && continue
    # ADAPTATION: same tmp-file idiom as phase 1, for the same reason.
    ghw_api PUT "/orgs/${org}/teams/${team}/memberships/${u}" "{\"role\":\"${role}\"}" >"$tmp"; rc=$?
    body=$(<"$tmp")
    case $rc in
      0)
        state=$(print -r -- "$body" | jq -r '.state // ""')
        got_role=$(print -r -- "$body" | jq -r '.role // ""')
        note=""
        [[ "$got_role" == maintainer && "$role" == member ]] && note="org owner auto-elevated"
        ghw_report_row "$u" team added "$state" "$got_role" "$note"
        print -r -- "team + ${u} (${state})"
        ;;
      4)
        ghw_report_row "$u" team not_found "" "" "account does not exist on github.com"
        (( errors++ )) || true
        ;;
      *)
        ghw_report_row "$u" team failed "" "" "HTTP ${GHW_LAST_STATUS}: $(print -r -- "$body" | jq -r '.message // ""' 2>/dev/null)"
        (( errors++ )) || true
        ;;
    esac
  done
fi
rm -f "$tmp"

# §4 step 8: verify against LIVE state, membership not role equality (§7).
typeset -A org_after_map team_after_map
for u in ${(f)"$(fetch_org_members)"}; do org_after_map[$u]=1; done
org_after=${#org_after_map}
team_after=0
if [[ -n "$team" ]]; then
  for u in ${(f)"$(fetch_team_members)"}; do team_after_map[$u]=1; done
  team_after=${#team_after_map}
fi
for u in "${logins[@]}"; do
  [[ -n "${org_failed[$u]:-}" ]] && continue
  if [[ -z "${org_after_map[$u]:-}" ]]; then
    ghw_report_row "$u" verify failed "" "" "not in live org member list after import"
    (( errors++ )) || true
  fi
  if [[ -n "$team" && -z "${team_after_map[$u]:-}" ]]; then
    ghw_report_row "$u" verify failed "" "" "not in live team member list after import"
    (( errors++ )) || true
  fi
done

summary="org: ${org_before} -> ${org_after} (+$(( org_after - org_before )))"
[[ -n "$team" ]] && summary+=$'\n'"team: ${team_before} -> ${team_after} (+$(( team_after - team_before )))"
rdir=$(ghw_report_finish "$summary")
print -r -- "$summary"
print -r -- "report: $rdir"
(( errors > 0 )) && exit 1
exit 0
