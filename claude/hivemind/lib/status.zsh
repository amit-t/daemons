#!/usr/bin/env zsh
# hivemind status + diff: read-only visibility into the sync ledger.

hive_status() {
  hive_require_profiles
  print -r -- "hivemind — ledger: ${HIVE_SYNC_DIR}"
  print -r -- "this host: ${HIVE_HOST}   freshness window: ${HIVE_MAX_AGE_HOURS}h"
  print -r -- ""

  local h m epoch age files fp
  local -A fps
  fps=()
  for h in $(hive_hosts); do
    m=$(hive_manifest "$h")
    epoch=$(hive_manifest_epoch "$m")
    age=$(hive_age_hours "$epoch")
    files=$(jq -r '.files | length' "$m")
    fp=$(hive_fingerprint "${HIVE_MACHINES_DIR}/${h}")
    fps[$h]="$fp"
    printf '%-24s %3sh old  %3s files  %s%s\n' "$h" "$age" "$files" "${fp:0:12}" \
      "$( (( age > HIVE_MAX_AGE_HOURS )) && print -r -- '  [STALE]' )"
  done
  (( ${#fps} == 0 )) && print -r -- "(no machine snapshots yet — run 'hive snapshot')"

  print -r -- ""
  if [[ -f "${HIVE_GOLDEN_DIR}/manifest.json" ]]; then
    print -r -- "golden: created $(jq -r '.created_iso' "${HIVE_GOLDEN_DIR}/manifest.json") from $(jq -r '.source_hosts | join(",")' "${HIVE_GOLDEN_DIR}/manifest.json")  $(hive_fingerprint "$HIVE_GOLDEN_DIR" | cut -c1-12)"
    local golden_epoch applied
    golden_epoch=$(hive_state_get '.golden.created_at')
    for h in ${(k)fps}; do
      applied=$(hive_state_get ".applied[\"${h}\"].golden_created_at")
      if [[ "$applied" == "$golden_epoch" ]]; then
        print -r -- "  ${h}: applied"
      else
        print -r -- "  ${h}: PENDING apply"
      fi
    done
  else
    print -r -- "golden: none yet"
  fi

  print -r -- ""
  if (( ${#fps} >= 2 )); then
    local -a uniq_fps
    uniq_fps=(${(u)${(v)fps}})
    if (( ${#uniq_fps} == 1 )); then
      print -r -- "machines: IN SYNC"
    else
      print -r -- "machines: DIVERGED — run 'hive' to reconcile"
    fi
  fi
}

hive_diff() {  # [--golden] | [hostA hostB]; default: this host vs the other one
  hive_require_profiles
  local a="" b=""
  if [[ "${1:-}" == --golden ]]; then
    a="$HIVE_GOLDEN_DIR"; b="${HIVE_MACHINES_DIR}/${HIVE_HOST}"
  elif (( $# >= 2 )); then
    a="${HIVE_MACHINES_DIR}/$1"; b="${HIVE_MACHINES_DIR}/$2"
  else
    local -a others
    others=()
    local h
    for h in $(hive_hosts); do [[ "$h" != "$HIVE_HOST" ]] && others+=("$h"); done
    (( ${#others} == 1 )) || hive_die "diff: specify two hosts (found: $(hive_hosts | tr '\n' ' '))"
    a="${HIVE_MACHINES_DIR}/${HIVE_HOST}"; b="${HIVE_MACHINES_DIR}/${others[1]}"
  fi
  [[ -d "$a" && -d "$b" ]] || hive_die "diff: missing snapshot dir (${a:t} or ${b:t})"
  diff -ru --exclude=manifest.json "$a" "$b"
}
