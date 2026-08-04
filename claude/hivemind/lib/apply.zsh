#!/usr/bin/env zsh
# hivemind apply engine: overwrite this machine's live global surfaces from the
# golden set. Everything it overwrites or removes is backed up first under
# HIVE_STATE_DIR/backups/<timestamp>/. Ends by re-snapshotting so the ledger
# shows this host converged.

hive_live_for_rel() {  # $1 snapshot-relative path → live abs path (empty if unmapped)
  local spec kind live_rel snap_rel rest
  for spec in "${HIVE_SURFACES[@]}"; do
    rest="${spec#*|}"
    kind="${rest%%|*}"; rest="${rest#*|}"
    live_rel="${rest%%|*}"; snap_rel="${rest#*|}"
    if [[ "$kind" == file && "$1" == "$snap_rel" ]]; then
      print -r -- "${HIVE_HOME}/${live_rel}"
      return 0
    elif [[ "$kind" == dir-md && "$1" == "$snap_rel"/*.md && "${1#${snap_rel}/}" == "${1:t}" ]]; then
      print -r -- "${HIVE_HOME}/${live_rel}/${1:t}"
      return 0
    fi
  done
  return 1
}

hive_apply() {
  hive_require_profiles
  [[ -f "${HIVE_GOLDEN_DIR}/manifest.json" ]] || hive_die "no golden set — nothing to apply"
  local golden_epoch
  golden_epoch=$(jq -r '.created_at' "${HIVE_GOLDEN_DIR}/manifest.json")

  local backup_dir="${HIVE_STATE_DIR}/backups/$(date -r "$(hive_now)" -u +%Y%m%dT%H%M%SZ)-${HIVE_HOST}"
  mkdir -p "$backup_dir"

  local -a written removed
  written=() removed=()
  local rel live f

  # Overwrite live surfaces from golden.
  for rel in $(jq -r '.files[].path' "${HIVE_GOLDEN_DIR}/manifest.json"); do
    live=$(hive_live_for_rel "$rel") || { print -ru2 -- "hive: warning: unmapped golden path ${rel} — skipped"; continue }
    if [[ -f "$live" ]] && cmp -s "$live" "${HIVE_GOLDEN_DIR}/${rel}"; then
      continue
    fi
    if [[ -f "$live" ]]; then
      mkdir -p "${backup_dir}/${rel:h}"
      cp "$live" "${backup_dir}/${rel}"
    fi
    mkdir -p "${live:h}"
    cp "${HIVE_GOLDEN_DIR}/${rel}" "$live"
    written+=("$rel")
  done

  # Remove live dir-md files the golden set dropped (backed up first).
  local spec kind live_rel snap_rel rest
  for spec in "${HIVE_SURFACES[@]}"; do
    rest="${spec#*|}"
    kind="${rest%%|*}"; rest="${rest#*|}"
    live_rel="${rest%%|*}"; snap_rel="${rest#*|}"
    [[ "$kind" == dir-md && -d "${HIVE_HOME}/${live_rel}" ]] || continue
    for f in "${HIVE_HOME}/${live_rel}"/*.md(N.); do
      if [[ ! -f "${HIVE_GOLDEN_DIR}/${snap_rel}/${f:t}" ]]; then
        mkdir -p "${backup_dir}/${snap_rel}"
        mv "$f" "${backup_dir}/${snap_rel}/${f:t}"
        removed+=("${snap_rel}/${f:t}")
      fi
    done
  done

  hive_state_merge "{\"applied\": {\"${HIVE_HOST}\": {\"golden_created_at\": ${golden_epoch}, \"applied_at\": $(hive_now)}}}"

  # Re-snapshot: the ledger must show this host now matches golden.
  hive_snapshot >/dev/null

  print -r -- "applied golden (created_at ${golden_epoch}) on ${HIVE_HOST}"
  print -r -- "  overwritten: ${#written} file(s)${written:+ — ${(j:, :)written}}"
  print -r -- "  removed:     ${#removed} file(s)${removed:+ — ${(j:, :)removed}}"
  print -r -- "  backup:      ${backup_dir}"
}
