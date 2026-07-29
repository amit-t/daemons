#!/usr/bin/env zsh
# ghw stale — read-only archive-candidate report. Prints commands, never runs them.

ghw_stale() {  # $1 account, remaining flags
  local account="$1"; shift
  local org="" months=6
  while (( $# )); do
    case "$1" in
      --org) org="${2:?}"; shift 2 ;;
      --months) months="${2:?}"; shift 2 ;;
      *) print -ru2 -- "ghw stale: unknown flag: $1"; return 2 ;;
    esac
  done
  [[ -z "$org" ]] && { print -ru2 -- "ghw stale: --org required"; return 2 }
  local profile
  profile=$(ghw_resolve_profile "$account" "$org") || return 2
  ghw_token_for "$profile" || return 2

  # pushed_epoch is declared here, once, rather than as a bare `local` inside
  # the repo loop below: a BARE `local var` (no assignment in the same
  # statement) that re-executes on a later loop iteration, with the variable
  # already holding a value from a prior iteration, makes zsh print
  # `var=<value>` to stdout as a side effect of the redeclaration — and this
  # command's stdout IS the archive-candidate report. Only ASSIGN it inside
  # the loop, never re-declare.
  local cutoff repos line name pushed size is_fork reason pushed_epoch
  cutoff=$(date -v-"${months}"m +%s 2>/dev/null || date -d "-${months} months" +%s)
  repos=$(ghw_api_paged "/orgs/${org}/repos") || return 1
  local -i count=0
  while IFS=$'\t' read -r name pushed size is_fork; do
    reason=""
    if [[ "$size" == 0 || "$pushed" == null ]]; then
      reason="empty"
    else
      pushed_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed" +%s 2>/dev/null || date -d "$pushed" +%s)
      if (( pushed_epoch < cutoff )); then
        reason="inactive >${months}mo (last push ${pushed%T*})"
      fi
    fi
    [[ "$is_fork" == true && -n "$reason" ]] && reason+=", fork"
    if [[ -n "$reason" ]]; then
      (( count++ ))
      print -r -- "${name}"$'\t'"${pushed}"$'\t'"${reason}"
      print -r -- "  gh repo archive ${org}/${name} --yes"
    fi
  done < <(print -r -- "$repos" | jq -r '.[] | [.name, (.pushed_at // "null"), .size, .fork] | @tsv')
  print -r -- "${count} archive candidate(s) in ${org} (nothing archived — commands above are for you to run)"
}
