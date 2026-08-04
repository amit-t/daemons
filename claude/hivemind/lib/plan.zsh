#!/usr/bin/env zsh
# hivemind plan engine: read-only decision of what the sync flow should do next.
# Emits key=value lines the playbook (or a human) branches on. Never mutates.
#
# Actions, in precedence order:
#   NEED_OTHER_MACHINE  only this host has a snapshot
#   APPLY_GOLDEN        a golden set exists that this host has not applied yet
#   STALE_OTHER         some other host's snapshot is older than HIVE_MAX_AGE_HOURS
#                       (HIVE_FORCE=1 downgrades this to RECONCILE)
#   IN_SYNC             every host snapshot is byte-identical
#   RECONCILE           all snapshots fresh but content diverges → agent judgment

hive_plan() {
  hive_require_profiles
  local this="$HIVE_HOST"
  local this_manifest
  this_manifest=$(hive_manifest "$this")
  [[ -f "$this_manifest" ]] || hive_die "no snapshot for ${this} — run 'hive snapshot' first"

  print -r -- "this_host=${this}"
  print -r -- "this_age_hours=$(hive_age_hours "$(hive_manifest_epoch "$this_manifest")")"
  print -r -- "max_age_hours=${HIVE_MAX_AGE_HOURS}"

  local golden_epoch applied_epoch
  golden_epoch=$(hive_state_get '.golden.created_at')
  applied_epoch=$(hive_state_get ".applied[\"${this}\"].golden_created_at")
  print -r -- "golden=${golden_epoch:+present}"
  [[ -n "$golden_epoch" ]] && print -r -- "golden_created_at=${golden_epoch}"

  local -a others stale
  others=() stale=()
  local h age fp this_fp identical=1
  this_fp=$(hive_fingerprint "${HIVE_MACHINES_DIR}/${this}")
  for h in $(hive_hosts); do
    [[ "$h" == "$this" ]] && continue
    others+=("$h")
    age=$(hive_age_hours "$(hive_manifest_epoch "$(hive_manifest "$h")")")
    print -r -- "other_host=${h} age_hours=${age}"
    (( age > HIVE_MAX_AGE_HOURS )) && stale+=("$h")
    fp=$(hive_fingerprint "${HIVE_MACHINES_DIR}/${h}")
    [[ "$fp" == "$this_fp" ]] || identical=0
  done

  if (( ${#others} == 0 )); then
    print -r -- "action=NEED_OTHER_MACHINE"
    print -r -- "hint=run 'hive' on the other machine so its snapshot lands in agent-sync/machines/"
    return 0
  fi

  if [[ -n "$golden_epoch" && "$golden_epoch" != "${applied_epoch:-}" ]]; then
    print -r -- "action=APPLY_GOLDEN"
    print -r -- "hint=a reconciled golden set is waiting — 'hive apply' overwrites live surfaces from it"
    return 0
  fi

  if (( ${#stale} > 0 )) && [[ -z "${HIVE_FORCE:-}" ]]; then
    print -r -- "action=STALE_OTHER"
    print -r -- "stale_hosts=${(j:,:)stale}"
    print -r -- "hint=run 'hive' on the stale machine first (or HIVE_FORCE=1 to reconcile anyway)"
    return 0
  fi

  if (( identical )); then
    print -r -- "action=IN_SYNC"
    return 0
  fi

  print -r -- "action=RECONCILE"
  print -r -- "hint=snapshots diverge — build a golden set, then 'hive apply' on every machine"
}
