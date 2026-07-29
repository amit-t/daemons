#!/usr/bin/env zsh
# ghw doctor — per-profile credential/role health. Read-only.
#
# Exit semantics: exits 0 when every profile's CREDENTIAL health is good
# (token resolved, login matches, scopes OK) and the air-gap invariant
# holds. Org roles are informational — member-not-admin on someone else's
# org is not a doctor failure. `--strict` additionally requires admin on
# every listed org, exiting 1 otherwise. An air-gap/overlap violation
# always fails doctor, in both modes.

ghw_doctor() {  # $1 optional --strict
  local strict=0
  [[ "${1:-}" == "--strict" ]] && strict=1

  local file profile env_name expected me scopes org role body rc user_ns
  local -i broken=0
  local -a member_only
  local tmp; tmp=$(mktemp)
  file=$(ghw_accounts_file)

  ghw_check_airgap || (( broken++ ))

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

    # user_ns/member_only are declared once at the top of the function, not
    # here: a BARE `local var` (no assignment in the same statement) that
    # re-executes on a later loop iteration, with the variable already
    # holding a value from a prior iteration, makes zsh print `var=<value>`
    # to stdout as a side effect of the redeclaration — corrupting this
    # command's output on the second+ profile. Declarations that assign a
    # value on the same statement (`local login_disp="ok"`, `local -i
    # org_total=0 org_admin=0`) don't trigger this; only bare ones do. Only
    # ASSIGN here, never re-declare.
    user_ns=$(jq -r --arg p "$profile" '.profiles[$p].user_namespace // ""' "$file")
    [[ -n "$user_ns" ]] && print -r -- "  user ${user_ns}: own namespace"

    local -i org_total=0 org_admin=0
    member_only=()
    for org in ${(f)"$(jq -r --arg p "$profile" '.profiles[$p].orgs[]?' "$file")"}; do
      (( org_total++ ))
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
      if [[ "$role" == admin ]]; then
        (( org_admin++ ))
      else
        member_only+=("$org")
        if (( strict )); then (( broken++ )) || true; fi
      fi
    done
    if (( org_total > 0 )); then
      local summary_line="  summary: admin on ${org_admin}/${org_total} orgs"
      (( org_admin < org_total )) && summary_line+=" (member-only: ${(j:, :)member_only})"
      print -r -- "$summary_line"
    fi
  done
  rm -f "$tmp"
  (( broken == 0 ))
}
