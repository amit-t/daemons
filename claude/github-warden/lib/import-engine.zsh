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

fetch_org_members() { ghw_api_paged "/orgs/${org}/members" }
fetch_team_members() { ghw_api_paged "/orgs/${org}/teams/${team}/members" }

typeset -A in_org in_team
# ADAPTATION: brief said `local u` — again top-level script body, not a
# function; `local` would error/be meaningless there. Use `typeset`.
typeset u lu

# Import spec §4: "Read-then-diff-then-write. Never blind-write." Guard the
# pre-write reads explicitly — ghw_api_paged's underlying `ghw_api GET` can
# fail (5xx retries exhausted, network, etc.); an unguarded failure here
# would leave in_org/in_team empty, and every CSV login — including
# existing Owners/maintainers — would then look "new" and get upsert-PUT'd:
# the exact silent-demotion scenario §4.2's set-difference exists to
# prevent. `var=$(func)` propagates func's own $? via command substitution
# (GHW_LAST_STATUS isn't needed here, just pass/fail), so fetch and parse
# are split into two separate steps rather than a `fetch | jq` pipeline — a
# pipeline's $? reflects only the last stage (jq) by default in zsh, which
# would silently mask a failed fetch.
org_json=$(fetch_org_members) || { print -ru2 -- "MEMBER_LIST_READ_FAILED: could not read org member list for ${org}"; exit 1; }
org_logins=$(print -r -- "$org_json" | jq -r '.[].login') || { print -ru2 -- "MEMBER_LIST_READ_FAILED: could not parse org member list for ${org}"; exit 1; }
for u in ${(f)org_logins}; do in_org[${(L)u}]=1; done
org_before=${#in_org}

# Cheap invariant: the authenticated login (already confirmed an org admin
# by ghw_precheck) must appear in the org member list we just read. Catches
# a silently-empty or truncated read that a bare non-2xx check would miss.
me_login=$(ghw_profile_login "$profile")
if [[ -z "${in_org[${(L)me_login}]:-}" ]]; then
  print -ru2 -- "MEMBER_LIST_READ_FAILED: authenticated login '${me_login}' not found in org member list for ${org} — refusing to write against a possibly-truncated read"
  exit 1
fi

team_before=0
if [[ -n "$team" ]]; then
  team_json=$(fetch_team_members) || { print -ru2 -- "MEMBER_LIST_READ_FAILED: could not read team member list for ${org}/${team}"; exit 1; }
  team_logins=$(print -r -- "$team_json" | jq -r '.[].login') || { print -ru2 -- "MEMBER_LIST_READ_FAILED: could not parse team member list for ${org}/${team}"; exit 1; }
  for u in ${(f)team_logins}; do in_team[${(L)u}]=1; done
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
#
# Case normalization: GitHub logins are case-insensitive but zsh associative
# array keys are not, so every membership-map key/lookup uses `${(L)u}`
# (`lu`) below and throughout the write/verify phases. `logins`/`add_org`/
# `add_team` keep the ORIGINAL CSV casing — that's what's written to report
# rows and used in PUT URLs.
for u in "${logins[@]}"; do
  lu=${(L)u}
  if [[ -n "${in_org[$lu]:-}" ]]; then
    ghw_report_row "$u" org skipped active "" "already a member"
  else
    add_org+=("$u")
  fi
done
if [[ -n "$team" ]]; then
  for u in "${logins[@]}"; do
    lu=${(L)u}
    if [[ -n "${in_team[$lu]:-}" ]]; then
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

typeset -A org_failed team_failed   # phase-1/phase-2 failures — excluded from later phases/verify
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
  lu=${(L)u}
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
      org_failed[$lu]=1; (( errors++ )) || true
      ;;
    *)
      ghw_report_row "$u" org failed "" "" "HTTP ${GHW_LAST_STATUS}: $(print -r -- "$body" | jq -r '.message // ""' 2>/dev/null)"
      org_failed[$lu]=1; (( errors++ )) || true
      ;;
  esac
done

# Phase 2: team membership.
if [[ -n "$team" ]]; then
  for u in "${add_team[@]}"; do
    lu=${(L)u}
    [[ -n "${org_failed[$lu]:-}" ]] && continue
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
        team_failed[$lu]=1; (( errors++ )) || true
        ;;
      *)
        ghw_report_row "$u" team failed "" "" "HTTP ${GHW_LAST_STATUS}: $(print -r -- "$body" | jq -r '.message // ""' 2>/dev/null)"
        team_failed[$lu]=1; (( errors++ )) || true
        ;;
    esac
  done
fi
rm -f "$tmp"

# §4 step 8: verify against LIVE state, membership not role equality (§7).
# Post-write reads are guarded too, but unlike the pre-write reads above we
# do NOT abort on failure here — the writes already landed, so aborting
# would just hide a (partially) successful import behind a crash instead of
# reporting it. A read failure means we can't confirm ANY membership, so
# every still-relevant login gets an explicit `verify failed` row rather
# than a silent gap, and the run still ends up `completed_with_errors`.
typeset -A org_after_map team_after_map
org_after_ok=1
if org_after_json=$(fetch_org_members) && org_after_logins=$(print -r -- "$org_after_json" | jq -r '.[].login'); then
  for u in ${(f)org_after_logins}; do org_after_map[${(L)u}]=1; done
else
  org_after_ok=0
fi
org_after=${#org_after_map}

team_after=0
team_after_ok=1
if [[ -n "$team" ]]; then
  if team_after_json=$(fetch_team_members) && team_after_logins=$(print -r -- "$team_after_json" | jq -r '.[].login'); then
    for u in ${(f)team_after_logins}; do team_after_map[${(L)u}]=1; done
    team_after=${#team_after_map}
  else
    team_after_ok=0
  fi
fi
for u in "${logins[@]}"; do
  lu=${(L)u}
  [[ -n "${org_failed[$lu]:-}" ]] && continue
  if (( ! org_after_ok )); then
    ghw_report_row "$u" verify failed "" "" "org member list unreadable post-write — cannot verify"
    (( errors++ )) || true
  elif [[ -z "${org_after_map[$lu]:-}" ]]; then
    ghw_report_row "$u" verify failed "" "" "not in live org member list after import"
    (( errors++ )) || true
  fi
  # Skip the team-membership verify check for logins that already failed in
  # phase 2 (team_failed) — they already have an explicit team failed/
  # not_found row from that phase; a generic "not in live team list" verify
  # row on top would just duplicate the same fact under a different label.
  # The org check above still runs for them regardless.
  if [[ -n "$team" && -z "${team_failed[$lu]:-}" ]]; then
    if (( ! team_after_ok )); then
      ghw_report_row "$u" verify failed "" "" "team member list unreadable post-write — cannot verify"
      (( errors++ )) || true
    elif [[ -z "${team_after_map[$lu]:-}" ]]; then
      ghw_report_row "$u" verify failed "" "" "not in live team member list after import"
      (( errors++ )) || true
    fi
  fi
done

summary="org: ${org_before} -> ${org_after} (+$(( org_after - org_before )))"
[[ -n "$team" ]] && summary+=$'\n'"team: ${team_before} -> ${team_after} (+$(( team_after - team_before )))"
rdir=$(ghw_report_finish "$summary")
print -r -- "$summary"
print -r -- "report: $rdir"
(( errors > 0 )) && exit 1
exit 0
