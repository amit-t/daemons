#!/usr/bin/env zsh
# ghw audit — read-only settings/protection drift vs a reference repo.

typeset -ga _GHW_AUDIT_FIELDS
_GHW_AUDIT_FIELDS=(private has_issues has_projects has_wiki has_discussions
  allow_squash_merge allow_merge_commit allow_rebase_merge delete_branch_on_merge
  allow_update_branch web_commit_signoff_required)
typeset -ga _GHW_SEC_FIELDS
_GHW_SEC_FIELDS=(advanced_security secret_scanning secret_scanning_push_protection dependabot_security_updates)

_ghw_protection_state() {  # $1 owner/repo, $2 branch — prints protected|unprotected|unknown
  ghw_api GET "/repos/$1/branches/$2/protection" >/dev/null
  case $? in
    0) print -r -- protected ;;
    4) print -r -- unprotected ;;
    *) print -r -- "unknown(HTTP ${GHW_LAST_STATUS})" ;;
  esac
}

ghw_audit() {  # $1 account, remaining flags
  local account="$1"; shift
  local org="" ref=""
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      --ref) ref="${2:?}"; shift 2 ;;
      *) print -ru2 -- "ghw audit: unknown flag: $1"; return 2 ;;
    esac
  done
  [[ -z "$org" || -z "$ref" ]] && { print -ru2 -- "ghw audit: --org and --ref <owner/repo> required"; return 2 }
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  ghw_token_for "$profile" || return 2

  local ref_json ref_branch ref_prot repo repo_json branch prot f exp got rc
  local -i repos=0 drift=0
  # NOTE (adaptation, not in brief's literal listing): `ref_json=$(ghw_api ...)
  # || { ... $GHW_LAST_STATUS ... }` would fork a subshell for the command
  # substitution, so `typeset -g GHW_LAST_STATUS` set inside ghw_api never
  # reaches this caller and the error message would report a stale value.
  # Same pitfall documented in lib/doctor.zsh — use the temp-file idiom so
  # both the body and GHW_LAST_STATUS survive the call.
  local tmp; tmp=$(mktemp)
  ghw_api GET "/repos/${ref}" >"$tmp"; rc=$?
  ref_json=$(<"$tmp")
  rm -f "$tmp"
  if (( rc != 0 )); then
    print -ru2 -- "ghw audit: reference /repos/${ref} → HTTP ${GHW_LAST_STATUS}"
    return 1
  fi
  ref_branch=$(print -r -- "$ref_json" | jq -r .default_branch)
  ref_prot=$(_ghw_protection_state "$ref" "$ref_branch")

  for repo in ${(f)"$(ghw_api_paged "/orgs/${org}/repos" | jq -r '.[].name')"}; do
    [[ "${org}/${repo}" == "$ref" ]] && continue
    (( repos++ ))
    repo_json=$(ghw_api GET "/repos/${org}/${repo}") || continue
    for f in "${_GHW_AUDIT_FIELDS[@]}"; do
      exp=$(print -r -- "$ref_json" | jq -r --arg f "$f" '.[$f]')
      got=$(print -r -- "$repo_json" | jq -r --arg f "$f" '.[$f]')
      if [[ "$exp" != "$got" ]]; then
        print -r -- "${repo}"$'\t'"${f}"$'\t'"${exp}"$'\t'"${got}"
        (( drift++ ))
      fi
    done
    for f in "${_GHW_SEC_FIELDS[@]}"; do
      exp=$(print -r -- "$ref_json" | jq -r --arg f "$f" '.security_and_analysis[$f].status // "unset"')
      got=$(print -r -- "$repo_json" | jq -r --arg f "$f" '.security_and_analysis[$f].status // "unset"')
      if [[ "$exp" != "$got" ]]; then
        print -r -- "${repo}"$'\t'"${f}"$'\t'"${exp}"$'\t'"${got}"
        (( drift++ ))
      fi
    done
    branch=$(print -r -- "$repo_json" | jq -r .default_branch)
    prot=$(_ghw_protection_state "${org}/${repo}" "$branch")
    if [[ "$prot" != "$ref_prot" ]]; then
      print -r -- "${repo}"$'\t'"branch_protection"$'\t'"${ref_prot}"$'\t'"${prot}"
      (( drift++ ))
    fi
  done
  print -r -- "${repos} repos audited, ${drift} drift lines (reference: ${ref})"
}
