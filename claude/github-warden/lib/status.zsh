#!/usr/bin/env zsh
# ghw status — read-only org overview.

ghw_status() {  # $1 account (may be ""), remaining flags
  local account="$1"; shift
  local org=""
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      *) print -ru2 -- "ghw status: unknown flag: $1"; return 2 ;;
    esac
  done
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  if [[ -z "$org" ]]; then
    org=$(jq -r --arg p "$profile" '.profiles[$p].orgs[0]' "$(ghw_accounts_file)")
  fi
  ghw_token_for "$profile" || return 2
  local body repos members teams plan rc members_json teams_json
  # NOTE (pitfall): `body=$(ghw_api ...)` forks a subshell, so the `typeset -g
  # GHW_LAST_STATUS` ghw_api sets never reaches this caller (same issue
  # documented in lib/auth.zsh's ghw_precheck and lib/doctor.zsh). The error
  # message below needs GHW_LAST_STATUS, so use the temp-file idiom instead
  # of a bare command substitution.
  local tmp; tmp=$(mktemp)
  ghw_api GET "/orgs/${org}" >"$tmp"; rc=$?
  body=$(<"$tmp")
  rm -f "$tmp"
  if (( rc != 0 )); then
    print -ru2 -- "ghw status: /orgs/${org} → HTTP ${GHW_LAST_STATUS}"
    return 1
  fi
  repos=$(print -r -- "$body" | jq '(.public_repos // 0) + (.total_private_repos // 0)')
  plan=$(print -r -- "$body" | jq -r '.plan.name // "?"')
  # Fetch and parse are split into separate statements (not a `ghw_api_paged
  # | jq` pipeline) deliberately: a pipeline's `$?` in plain zsh (no
  # `pipefail` set anywhere in this codebase) reflects only its LAST stage.
  # `ghw_api_paged` prints nothing on failure, so `jq` would see empty stdin
  # and exit 0 — masking the read failure behind `|| return 1` and letting
  # this command print a summary line as if the count were complete. Same
  # pitfall the `lib/import-engine.zsh` pre-write reads are already guarded
  # against, for the same reason. GHW_LAST_STATUS is not used in the error
  # messages below: like `body=$(ghw_api ...)` above, it is set inside a
  # subshell `ghw_api_paged` forks internally and does not survive back to
  # this caller, so quoting it here would print a stale/unrelated value.
  members_json=$(ghw_api_paged "/orgs/${org}/members") || { print -ru2 -- "ghw status: /orgs/${org}/members read failed"; return 1 }
  members=$(print -r -- "$members_json" | jq 'length') || { print -ru2 -- "ghw status: /orgs/${org}/members list did not parse"; return 1 }
  teams_json=$(ghw_api_paged "/orgs/${org}/teams") || { print -ru2 -- "ghw status: /orgs/${org}/teams read failed"; return 1 }
  teams=$(print -r -- "$teams_json" | jq 'length') || { print -ru2 -- "ghw status: /orgs/${org}/teams list did not parse"; return 1 }
  print -r -- "org ${org}: repos=${repos} members=${members} teams=${teams} plan=${plan}"
}
