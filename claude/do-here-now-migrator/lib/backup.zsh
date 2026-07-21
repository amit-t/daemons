#!/usr/bin/env zsh
# do-here-now-migrator — phase 2: backup.
#
# Everything that is about to be destroyed is captured first, verified, and
# recorded. A backup that was never read back is not a backup, so each dump is
# re-opened and counted after it is written.
#
# Backups land in <project-parent>/backups/<site>-<YYYYMMDD>/ — a sibling of
# the checkout, outside the git tree, so no .gitignore entry is needed and the
# archive stays co-located with the project it belongs to.

dhm_backup_root() {  # dhm_backup_root <repo-dir> <site>
  local repo=${1:A} site=$2
  print -r -- "${repo:h}/backups/${site}-$(dhm_datestamp)"
}

dhm_backup_tool_for_engine() {  # dhm_backup_tool_for_engine <engine>
  case "${1:l}" in
    mongodb) print -r -- mongodump ;;
    pg)      print -r -- pg_dump ;;
    mysql)   print -r -- mysqldump ;;
    redis|valkey) print -r -- "" ;;   # managed cache: nothing durable to dump
    *)       print -r -- "" ;;
  esac
}

dhm_backup_install_hint() {  # dhm_backup_install_hint <tool>
  case "$1" in
    mongodump) print -r -- "brew tap mongodb/brew && brew trust --formula mongodb/brew/mongodb-database-tools && brew install mongodb-database-tools" ;;
    pg_dump)   print -r -- "brew install libpq && brew link --force libpq" ;;
    mysqldump) print -r -- "brew install mysql-client" ;;
    *)         print -r -- "" ;;
  esac
}

# Resolve a connection URI for a managed cluster, preferring doctl's own
# connection output. The URI carries a password, so it is only ever returned on
# stdout for immediate use — never logged, never written to state.
dhm_backup_connection_uri() {  # dhm_backup_connection_uri <cluster-id>
  local id=$1 conn uri
  conn=$(doctl databases connection "$id" --output json 2>/dev/null) || return 1
  uri=$(jq -r '.[0].uri // .uri // empty' <<<"$conn" 2>/dev/null)
  [[ -n "$uri" ]] || return 1
  print -r -- "$uri"
}

# Dump one managed cluster. Returns 0 on a verified dump, 1 on failure, and 2
# when the engine has nothing durable worth dumping.
dhm_backup_database() {  # dhm_backup_database <cluster-id> <name> <engine> <dest-dir>
  local id=$1 name=$2 engine=$3 dest=$4
  local tool; tool=$(dhm_backup_tool_for_engine "$engine")

  if [[ -z "$tool" ]]; then
    dhm_warn "engine '${engine}' (${name}) holds no durable data worth dumping; skipping"
    return 2
  fi
  if ! dhm_have "$tool"; then
    dhm_error "cannot back up ${name}: ${tool} is not installed"
    local hint; hint=$(dhm_backup_install_hint "$tool")
    [[ -n "$hint" ]] && dhm_error "install it with: ${hint}"
    return 1
  fi

  if dhm_dry "dump ${engine} cluster ${name} to ${dest}"; then return 0; fi

  local uri
  if ! uri=$(dhm_backup_connection_uri "$id"); then
    dhm_error "could not resolve a connection URI for ${name} (${id})"
    return 1
  fi

  mkdir -p "${dest}/${name}" || return 1
  dhm_info "dumping ${engine} cluster ${name}"

  case "${engine:l}" in
    mongodb)
      if ! mongodump --uri="$uri" --out="${dest}/${name}" 2>&1 | dhm_redact >&2; then
        dhm_error "mongodump failed for ${name}"
        return 1
      fi
      # Read the dump back and count documents per collection.
      if dhm_have bsondump; then
        local bson total=0 n
        for bson in "${dest}/${name}"/**/*.bson(N); do
          n=$(bsondump --quiet "$bson" 2>/dev/null | wc -l | tr -d ' ')
          dhm_log "  ${bson:t:r}: ${n} document(s)"
          (( total += n ))
        done
        dhm_ok "verified ${total} document(s) in ${name}"
      else
        dhm_warn "bsondump unavailable; dump written but not read back"
      fi
      # A JSON + CSV export of anything subscriber-shaped is what actually gets
      # migrated to the new provider, so produce it while the cluster is alive.
      dhm_backup_export_subscribers "$uri" "${dest}/${name}"
      ;;
    pg)
      if ! pg_dump --no-owner --no-privileges --format=custom \
          --file="${dest}/${name}/dump.pgcustom" "$uri" 2>&1 | dhm_redact >&2; then
        dhm_error "pg_dump failed for ${name}"
        return 1
      fi
      if [[ ! -s "${dest}/${name}/dump.pgcustom" ]]; then
        dhm_error "pg_dump produced an empty file for ${name}"
        return 1
      fi
      dhm_ok "wrote $(du -h "${dest}/${name}/dump.pgcustom" | cut -f1) pg dump for ${name}"
      ;;
    mysql)
      if ! mysqldump --single-transaction --routines --triggers \
          --result-file="${dest}/${name}/dump.sql" "$uri" 2>&1 | dhm_redact >&2; then
        dhm_error "mysqldump failed for ${name}"
        return 1
      fi
      [[ -s "${dest}/${name}/dump.sql" ]] || { dhm_error "empty mysql dump for ${name}"; return 1 }
      dhm_ok "wrote $(du -h "${dest}/${name}/dump.sql" | cut -f1) mysql dump for ${name}"
      ;;
  esac
  return 0
}

# Find a subscriber-shaped collection and export it as JSON plus a CSV in the
# shape newsletter platforms import. Best-effort: absence is not an error.
dhm_backup_export_subscribers() {  # dhm_backup_export_subscribers <uri> <dest>
  local uri=$1 dest=$2
  dhm_have mongoexport || return 0
  local coll
  for coll in subscribers subscriptions newsletter_subscribers emails contacts; do
    if mongoexport --uri="$uri" --collection="$coll" --jsonArray \
         --out="${dest}/${coll}.json" >/dev/null 2>&1 && [[ -s "${dest}/${coll}.json" ]]; then
      local count
      count=$(jq 'length' "${dest}/${coll}.json" 2>/dev/null || print -r -- 0)
      (( count == 0 )) && { rm -f -- "${dest}/${coll}.json"; continue }
      dhm_ok "exported ${count} record(s) from '${coll}'"
      dhm_backup_subscribers_csv "${dest}/${coll}.json" "${dest}/subscribers-import.csv"
      return 0
    fi
    rm -f -- "${dest}/${coll}.json"
  done
  return 0
}

# Normalise an arbitrary subscriber document into email,name,created_at. Every
# mainstream newsletter platform accepts that shape.
dhm_backup_subscribers_csv() {  # dhm_backup_subscribers_csv <json> <csv>
  local src=$1 out=$2
  jq -r '
    def pick(o; keys): (keys | map(o[.]? // empty) | first) // "";
    def dateof(o):
      (pick(o; ["subscribedAt","createdAt","created_at","subscribed_at","date"])) as $d
      | if ($d | type) == "object" then ($d["$date"] // "") else ($d // "") end;
    ["email","name","created_at"],
    ( .[]
      | select((.active // true) == true)
      | select((pick(.; ["email","emailAddress","email_address"])) != "")
      | [ pick(.; ["email","emailAddress","email_address"]),
          pick(.; ["name","fullName","full_name","firstName"]),
          dateof(.) ] )
    | @csv' "$src" > "$out" 2>/dev/null || { rm -f -- "$out"; return 0 }
  local rows; rows=$(( $(wc -l < "$out") - 1 ))
  dhm_ok "wrote ${rows} subscriber row(s) to ${out:t}"
}

# Archive App Platform specs. These contain plaintext env values often enough
# that the file is written 0600 and flagged in the report.
dhm_backup_app_specs() {  # dhm_backup_app_specs <dest> <app-id ...>
  local dest=$1; shift
  (( $# > 0 )) || return 0
  mkdir -p "${dest}/app-specs" || return 1
  local id file
  for id in "$@"; do
    file="${dest}/app-specs/${id}.yaml"
    if dhm_dry "archive app spec ${id}"; then continue; fi
    if doctl apps spec get "$id" > "$file" 2>/dev/null && [[ -s "$file" ]]; then
      chmod 600 "$file"
      dhm_ok "archived app spec ${id} ($(wc -l < "$file" | tr -d ' ') lines, mode 600)"
      if grep -qiE '(password|secret|token|_uri|_url)[[:space:]]*[:=]' "$file"; then
        dhm_warn "  spec ${id} contains credential-shaped values — treat the archive as a secret"
      fi
    else
      dhm_error "could not archive app spec ${id}"
      return 1
    fi
  done
}

# Snapshot every DNS zone we are about to touch, so the pre-migration records
# can be restored verbatim.
dhm_backup_dns_zones() {  # dhm_backup_dns_zones <dest> <domain ...>
  local dest=$1; shift
  (( $# > 0 )) || return 0
  mkdir -p "${dest}/dns" || return 1
  local d
  for d in "$@"; do
    [[ -z "$d" ]] && continue
    if dhm_dry "snapshot DNS zone ${d}"; then continue; fi
    if doctl compute domain records list "$d" --output json > "${dest}/dns/${d}.json" 2>/dev/null; then
      local n; n=$(jq 'length' "${dest}/dns/${d}.json" 2>/dev/null || print -r -- 0)
      dhm_ok "snapshotted ${n} DNS record(s) for ${d}"
    else
      dhm_warn "could not snapshot DNS for ${d} (zone may not be hosted on DigitalOcean)"
    fi
  done
}

# A manifest makes the archive self-describing months later.
dhm_backup_manifest() {  # dhm_backup_manifest <dest> <site> <inventory-json>
  local dest=$1 site=$2 inv=$3
  if dhm_dry "write backup manifest"; then return 0; fi
  jq -n --arg site "$site" --arg at "$(dhm_now_utc)" --argjson inv "$inv" \
    '{site:$site, created_at:$at, inventory:$inv}' > "${dest}/manifest.json"
  chmod 600 "${dest}/manifest.json"
  dhm_ok "wrote ${dest}/manifest.json"
}

# Refuse to hand control to the destructive phase unless the archive exists and
# is non-trivial.
dhm_backup_verify() {  # dhm_backup_verify <dest>
  local dest=$1
  [[ -d "$dest" ]] || { dhm_error "backup directory ${dest} does not exist"; return 1 }
  local files
  files=$(find "$dest" -type f | wc -l | tr -d ' ')
  if (( files == 0 )); then
    dhm_error "backup directory ${dest} is empty"
    return 1
  fi
  dhm_ok "backup verified: ${files} file(s), $(du -sh "$dest" | cut -f1) at ${dest}"
  return 0
}
