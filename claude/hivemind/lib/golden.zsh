#!/usr/bin/env zsh
# hivemind golden engine: build + finalize the reconciled truth set.
# Flow: `hive golden init --from <host>` seeds golden/ from that host's snapshot,
# the reconciling agent edits files under golden/ (merge, dedupe, drop),
# `hive golden finalize --hosts A,B` stamps the manifest + state and pushes.

hive_surface_for_rel() {  # $1 snapshot-relative path → surface id
  local spec snap_rel
  for spec in "${HIVE_SURFACES[@]}"; do
    snap_rel="${spec##*|}"
    if [[ "$1" == "$snap_rel" || "$1" == "$snap_rel"/* ]]; then
      print -r -- "${spec%%|*}"
      return 0
    fi
  done
  print -r -- "unknown"
}

hive_golden_init() {  # --from <host>
  hive_require_profiles
  local from=""
  while (( $# )); do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      *) hive_die "golden init: unknown flag $1" ;;
    esac
  done
  [[ -n "$from" ]] || hive_die "golden init: --from <host> required"
  local src="${HIVE_MACHINES_DIR}/${from}"
  [[ -f "${src}/manifest.json" ]] || hive_die "golden init: no snapshot for ${from}"
  rm -rf "$HIVE_GOLDEN_DIR"
  mkdir -p "$HIVE_GOLDEN_DIR"
  local f rel
  for f in "$src"/**/*(N.); do
    rel="${f#${src}/}"
    [[ "$rel" == manifest.json ]] && continue
    mkdir -p "${HIVE_GOLDEN_DIR}/${rel:h}"
    cp "$f" "${HIVE_GOLDEN_DIR}/${rel}"
  done
  print -r -- "golden seeded from ${from} at ${HIVE_GOLDEN_DIR} — edit files, then 'hive golden finalize --hosts ...'"
}

hive_golden_finalize() {  # --hosts A,B
  hive_require_profiles
  local hosts=""
  while (( $# )); do
    case "$1" in
      --hosts) hosts="${2:-}"; shift 2 ;;
      *) hive_die "golden finalize: unknown flag $1" ;;
    esac
  done
  [[ -n "$hosts" ]] || hive_die "golden finalize: --hosts <A,B> required"
  [[ -d "$HIVE_GOLDEN_DIR" ]] || hive_die "golden finalize: no golden dir — run 'hive golden init' first"

  local -a entries
  entries=()
  local f rel
  for f in "$HIVE_GOLDEN_DIR"/**/*(N.); do
    rel="${f#${HIVE_GOLDEN_DIR}/}"
    [[ "$rel" == manifest.json ]] && continue
    hive_has_secret "$f" && hive_die "golden finalize: secret-like content in ${rel} — remove it"
    entries+=("$(jq -n --arg surface "$(hive_surface_for_rel "$rel")" --arg path "$rel" \
        --arg sha "$(hive_sha "$f")" --argjson size "$(stat -f %z "$f")" --argjson mtime "$(stat -f %m "$f")" \
        '{surface:$surface, path:$path, sha256:$sha, size:$size, mtime:$mtime}')")
  done
  (( ${#entries} > 0 )) || hive_die "golden finalize: golden dir is empty"

  local now iso
  now=$(hive_now)
  iso=$(date -r "$now" -u +%Y-%m-%dT%H:%M:%SZ)
  print -rl -- "${entries[@]}" | jq -s \
    --argjson now "$now" --arg iso "$iso" --arg hosts "$hosts" \
    '{created_at:$now, created_iso:$iso, source_hosts:($hosts|split(",")), files:.}' \
    > "${HIVE_GOLDEN_DIR}/manifest.json"

  hive_state_merge "{\"golden\": {\"created_at\": ${now}, \"created_iso\": \"${iso}\", \"source_hosts\": \"${hosts}\"}}"
  hive_git_commit_push "hive: golden set ${iso} (from ${hosts})"
  print -r -- "golden finalized: ${#entries} files, created ${iso} — run 'hive apply' on each machine"
}
