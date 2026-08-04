#!/usr/bin/env zsh
# hivemind doctor: environment health. Exit 0 = ready to sync.

hive_doctor() {
  local rc=0

  _check() {  # $1 label, $2 status(0=ok), $3 detail
    local mark
    (( $2 == 0 )) && mark="ok " || mark="FAIL"
    printf '[%s] %-34s %s\n' "$mark" "$1" "${3:-}"
  }

  # jq + shasum
  local s
  (( $+commands[jq] )); s=$?; (( s )) && rc=1
  _check "jq installed" $s "$(whence jq 2>/dev/null)"
  (( $+commands[shasum] )); s=$?; (( s )) && rc=1
  _check "shasum installed" $s "$(whence shasum 2>/dev/null)"

  # Profiles repo
  [[ -d "$HIVE_PROFILES_DIR" ]] && git -C "$HIVE_PROFILES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
  s=$?; (( s )) && rc=1
  _check "Profiles git repo" $s "$HIVE_PROFILES_DIR"

  if (( s == 0 )); then
    local email remote
    email=$(git -C "$HIVE_PROFILES_DIR" config user.email 2>/dev/null)
    remote=$(git -C "$HIVE_PROFILES_DIR" remote get-url origin 2>/dev/null)
    local remote_status=0
    [[ -z "$remote" ]] && remote_status=1
    _check "Profiles remote" $remote_status "${remote:-none — snapshots stay local-only}"
    if [[ "$remote" == *Invenco* || "$remote" == *github.com-atv* ]]; then
      _check "identity vs remote" 1 "Profiles remote looks like a COMPANY repo — hivemind must not push global memories there"
      rc=1
    else
      _check "git identity" 0 "${email:-unset}"
    fi
  fi

  # Surfaces
  local spec id kind live_rel live
  for spec in "${HIVE_SURFACES[@]}"; do
    id="${spec%%|*}"
    kind="${${spec#*|}%%|*}"
    live_rel="${${spec#*|*|}%%|*}"
    live="${HIVE_HOME}/${live_rel}"
    if [[ ( "$kind" == file && -f "$live" ) || ( "$kind" == dir-md && -d "$live" ) ]]; then
      _check "surface ${id}" 0 "$live"
    else
      _check "surface ${id}" 0 "ABSENT on this machine (recorded in manifest, not an error)"
    fi
  done

  # Ledger
  if [[ -d "$HIVE_SYNC_DIR" ]]; then
    _check "ledger" 0 "$(hive_hosts | wc -l | tr -d ' ') host snapshot(s), golden $( [[ -f ${HIVE_GOLDEN_DIR}/manifest.json ]] && print -rn present || print -rn absent )"
  else
    _check "ledger" 0 "not initialized yet — first 'hive snapshot' creates it"
  fi

  return $rc
}
