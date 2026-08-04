#!/usr/bin/env zsh
# hivemind collect engine: snapshot this machine's live global surfaces into
# agent-sync/machines/<host>/ with a manifest, then commit + push.

hive_collect_copy() {  # $1 live abs path, $2 dest abs path, $3 surface id → manifest line on stdout
  if hive_has_secret "$1"; then
    print -ru2 -- "hive: SKIPPED (secret-like content): $1"
    return 1
  fi
  mkdir -p "${2:h}"
  cp "$1" "$2"
  local rel="${2#${snapshot_dir}/}"
  jq -n --arg surface "$3" --arg path "$rel" --arg sha "$(hive_sha "$2")" \
        --argjson size "$(stat -f %z "$1")" --argjson mtime "$(stat -f %m "$1")" \
        '{surface:$surface, path:$path, sha256:$sha, size:$size, mtime:$mtime}'
}

hive_snapshot() {
  hive_require_profiles
  hive_git_pull
  local snapshot_dir="${HIVE_MACHINES_DIR}/${HIVE_HOST}"
  rm -rf "$snapshot_dir"
  mkdir -p "$snapshot_dir"

  local -a entries missing
  entries=() missing=()
  local spec id kind live_rel snap_rel live f entry
  for spec in "${HIVE_SURFACES[@]}"; do
    id="${spec%%|*}"; spec="${spec#*|}"
    kind="${spec%%|*}"; spec="${spec#*|}"
    live_rel="${spec%%|*}"; snap_rel="${spec#*|}"
    live="${HIVE_HOME}/${live_rel}"
    case "$kind" in
      file)
        if [[ -f "$live" ]]; then
          entry=$(hive_collect_copy "$live" "${snapshot_dir}/${snap_rel}" "$id") && entries+=("$entry")
        else
          missing+=("$id")
        fi
        ;;
      dir-md)
        if [[ -d "$live" ]]; then
          for f in "$live"/*.md(N.); do
            entry=$(hive_collect_copy "$f" "${snapshot_dir}/${snap_rel}/${f:t}" "$id") && entries+=("$entry")
          done
        else
          missing+=("$id")
        fi
        ;;
      *) hive_die "unknown surface kind '$kind' for $id" ;;
    esac
  done

  local now
  now=$(hive_now)
  print -rl -- "${entries[@]}" | jq -s \
    --arg host "$HIVE_HOST" --argjson now "$now" \
    --arg iso "$(date -r "$now" -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg missing "${(j:,:)missing}" \
    '{host:$host, captured_at:$now, captured_iso:$iso,
      missing_surfaces:($missing|split(",")|map(select(length>0))), files:.}' \
    > "${snapshot_dir}/manifest.json"

  hive_git_commit_push "hive: snapshot ${HIVE_HOST} $(date -r "$now" -u +%Y-%m-%dT%H:%M:%SZ)"
  print -r -- "snapshot: ${snapshot_dir} (${#entries} files, missing: ${missing:-none})"
}
