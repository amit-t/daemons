#!/usr/bin/env zsh
# hivemind shared helpers: paths, host identity, manifest access, git plumbing.
# Every engine sources this first. All paths are absolute; engines never rely on cwd.

: ${HIVE_HOME:=$HOME}                                  # surfaces root (overridable for tests)
: ${HIVE_PROFILES_DIR:=$HOME/Profiles}                 # the Profiles repo — sync ledger
: ${HIVE_STATE_DIR:=$HOME/.local/state/hivemind}       # backups + local scratch
: ${HIVE_MAX_AGE_HOURS:=24}                            # other-machine snapshot freshness window
: ${HIVE_HOST:=$(hostname -s)}                         # machine identity
typeset -gx HIVE_HOME HIVE_PROFILES_DIR HIVE_STATE_DIR HIVE_MAX_AGE_HOURS HIVE_HOST

HIVE_SYNC_DIR="${HIVE_PROFILES_DIR}/agent-sync"
HIVE_MACHINES_DIR="${HIVE_SYNC_DIR}/machines"
HIVE_GOLDEN_DIR="${HIVE_SYNC_DIR}/golden"
HIVE_STATE_JSON="${HIVE_SYNC_DIR}/state.json"

hive_now() { print -r -- "${HIVE_NOW:-$(date +%s)}" }  # HIVE_NOW override for tests

hive_die() { print -ru2 -- "hive: $*"; exit 1 }

hive_require_profiles() {
  [[ -d "$HIVE_PROFILES_DIR" ]] || hive_die "Profiles dir missing: $HIVE_PROFILES_DIR"
  git -C "$HIVE_PROFILES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || hive_die "not a git repo: $HIVE_PROFILES_DIR"
}

hive_sha() { shasum -a 256 "$1" | cut -d' ' -f1 }

# Secret guard: refuse to snapshot a file that looks like it carries a credential.
hive_has_secret() {
  grep -qE 'sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[bap]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$1"
}

# --- manifest access -------------------------------------------------------

hive_manifest() { print -r -- "${HIVE_MACHINES_DIR}/$1/manifest.json" }

hive_manifest_epoch() {  # $1 manifest path → captured_at epoch, empty if missing
  [[ -f "$1" ]] && jq -r '.captured_at // empty' "$1"
}

hive_age_hours() {  # $1 epoch → integer hours since
  local now epoch="$1"
  now=$(hive_now)
  print -r -- $(( (now - epoch) / 3600 ))
}

hive_hosts() {  # all snapshotted hosts
  [[ -d "$HIVE_MACHINES_DIR" ]] || return 0
  local d
  for d in "$HIVE_MACHINES_DIR"/*(N/); print -r -- "${d:t}"
}

# Content fingerprint of a snapshot tree (machine dir or golden dir): the sorted
# rel-path+sha list from its manifest. Two trees with equal fingerprints are
# byte-identical for every synced surface.
hive_fingerprint() {  # $1 dir containing manifest.json
  local m="$1/manifest.json"
  [[ -f "$m" ]] || return 1
  jq -r '.files | sort_by(.path) | .[] | "\(.path) \(.sha256)"' "$m" | shasum -a 256 | cut -d' ' -f1
}

# --- state.json ------------------------------------------------------------

hive_state_get() {  # $1 jq filter → raw value or empty
  [[ -f "$HIVE_STATE_JSON" ]] && jq -r "$1 // empty" "$HIVE_STATE_JSON"
}

hive_state_merge() {  # $1 jq object fragment merged into state.json
  local tmp="${HIVE_STATE_JSON}.tmp"
  if [[ -f "$HIVE_STATE_JSON" ]]; then
    jq ". * $1" "$HIVE_STATE_JSON" > "$tmp"
  else
    mkdir -p "${HIVE_STATE_JSON:h}"
    jq -n "$1" > "$tmp"
  fi
  mv "$tmp" "$HIVE_STATE_JSON"
}

# --- git plumbing ----------------------------------------------------------

hive_git() { git -C "$HIVE_PROFILES_DIR" "$@" }

hive_git_pull() {
  [[ -n "${HIVE_NO_GIT:-}" ]] && return 0
  hive_git remote get-url origin >/dev/null 2>&1 || return 0
  hive_git pull --rebase --autostash --quiet origin 2>/dev/null \
    || print -ru2 -- "hive: warning: git pull failed (offline?) — continuing with local state"
}

hive_git_commit_push() {  # $1 commit message; commits agent-sync/ only, pushes if remote
  [[ -n "${HIVE_NO_GIT:-}" ]] && return 0
  hive_git add -A "$HIVE_SYNC_DIR"
  if hive_git diff --cached --quiet -- "$HIVE_SYNC_DIR"; then
    return 0
  fi
  hive_git commit --quiet -m "$1" -- "$HIVE_SYNC_DIR"
  if hive_git remote get-url origin >/dev/null 2>&1; then
    hive_git push --quiet origin 2>/dev/null \
      || print -ru2 -- "hive: warning: git push failed (offline?) — commit is local, push later"
  fi
}
