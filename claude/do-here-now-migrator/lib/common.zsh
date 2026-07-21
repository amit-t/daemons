#!/usr/bin/env zsh
# do-here-now-migrator — shared helpers: logging, state, confirmation, JSON.
# Sourced by bin/dhm and every lib/*.zsh. Defines no top-level side effects
# beyond function and colour definitions.

# ---------------------------------------------------------------- output ----

typeset -g DHM_C_RESET='' DHM_C_DIM='' DHM_C_RED='' DHM_C_GREEN='' \
  DHM_C_YELLOW='' DHM_C_BLUE='' DHM_C_BOLD=''

dhm_init_colors() {
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    DHM_C_RESET=$'\e[0m'; DHM_C_DIM=$'\e[2m'; DHM_C_RED=$'\e[31m'
    DHM_C_GREEN=$'\e[32m'; DHM_C_YELLOW=$'\e[33m'; DHM_C_BLUE=$'\e[34m'
    DHM_C_BOLD=$'\e[1m'
  fi
}

dhm_log()   { print -ru2 -- "${DHM_C_DIM}[dhm]${DHM_C_RESET} $*" }
dhm_info()  { print -ru2 -- "${DHM_C_BLUE}[dhm]${DHM_C_RESET} $*" }
dhm_ok()    { print -ru2 -- "${DHM_C_GREEN}[dhm] ok${DHM_C_RESET} $*" }
dhm_warn()  { print -ru2 -- "${DHM_C_YELLOW}[dhm] warn${DHM_C_RESET} $*" }
dhm_error() { print -ru2 -- "${DHM_C_RED}[dhm] error${DHM_C_RESET} $*" }

dhm_die() {  # dhm_die <exit-code> <message ...>
  local code=$1; shift
  dhm_error "$*"
  exit "$code"
}

dhm_phase_banner() {  # dhm_phase_banner <phase> <description>
  print -ru2 -- ""
  print -ru2 -- "${DHM_C_BOLD}══ phase: $1${DHM_C_RESET} ${DHM_C_DIM}$2${DHM_C_RESET}"
}

# Emit a line only when DHM_DRY_RUN is set; returns 0 when the caller should
# skip the real action.
dhm_dry() {  # dhm_dry <description ...>
  if [[ -n "${DHM_DRY_RUN:-}" ]]; then
    print -ru2 -- "${DHM_C_YELLOW}[dry-run]${DHM_C_RESET} $*"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------ timestamps ----

dhm_now_utc()   { date -u +%Y-%m-%dT%H:%M:%SZ }
dhm_datestamp() { date +%Y%m%d }

# ----------------------------------------------------------- confirmation ----

# Require the user to type an exact phrase. Refuses in non-interactive mode
# unless DHM_ASSUME_YES is set, because destructive steps must never proceed
# on an unattended stdin.
dhm_confirm_phrase() {  # dhm_confirm_phrase <phrase> <prompt ...>
  local phrase=$1; shift
  if [[ -n "${DHM_ASSUME_YES:-}" ]]; then
    dhm_warn "auto-confirming (--yes): $*"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    dhm_error "refusing to continue: '$*' needs confirmation but stdin is not a terminal"
    dhm_error "re-run interactively, or pass --yes if this is genuinely unattended"
    return 1
  fi
  print -ru2 -- ""
  print -ru2 -- "${DHM_C_BOLD}$*${DHM_C_RESET}"
  print -rnu2 -- "Type ${DHM_C_BOLD}${phrase}${DHM_C_RESET} to proceed: "
  local answer
  IFS= read -r answer || answer=""
  if [[ "$answer" != "$phrase" ]]; then
    dhm_warn "got '${answer}', expected '${phrase}' — aborting"
    return 1
  fi
  return 0
}

dhm_confirm_yes() {  # dhm_confirm_yes <prompt ...>
  if [[ -n "${DHM_ASSUME_YES:-}" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    dhm_error "refusing to continue: '$*' needs confirmation but stdin is not a terminal"
    return 1
  fi
  print -rnu2 -- "$* [y/N] "
  local answer
  IFS= read -r answer || answer=""
  [[ "${answer:l}" == y || "${answer:l}" == yes ]]
}

dhm_prompt_value() {  # dhm_prompt_value <label> ; prints answer on stdout
  local label=$1 answer
  if [[ ! -t 0 ]]; then
    dhm_error "need a value for '${label}' but stdin is not a terminal"
    return 1
  fi
  print -rnu2 -- "${label}: "
  IFS= read -r answer || answer=""
  print -r -- "$answer"
}

# ------------------------------------------------------------- utilities ----

dhm_have() {  # dhm_have <command>
  (( $+commands[$1] ))
}

dhm_require_cmds() {  # dhm_require_cmds <cmd ...> ; returns 1 and reports misses
  local cmd missing=()
  for cmd in "$@"; do
    dhm_have "$cmd" || missing+=("$cmd")
  done
  if (( ${#missing} > 0 )); then
    dhm_error "missing required commands: ${missing[*]}"
    return 1
  fi
  return 0
}

# Redact anything that looks like a credential before it reaches a log.
dhm_redact() {  # reads stdin, writes redacted stdout
  sed -E \
    -e 's/(Bearer )[A-Za-z0-9._-]+/\1***/g' \
    -e 's#(mongodb(\+srv)?://[^:]+:)[^@]+@#\1***@#g' \
    -e 's#(postgres(ql)?://[^:]+:)[^@]+@#\1***@#g' \
    -e 's#(mysql://[^:]+:)[^@]+@#\1***@#g' \
    -e 's/(dop_v1_)[A-Za-z0-9]+/\1***/g' \
    -e 's/(gh[pousr]_)[A-Za-z0-9]+/\1***/g'
}

# Slugify an arbitrary string into a safe identifier for paths and state keys.
dhm_slugify() {  # dhm_slugify <text>
  print -r -- "${1}" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

dhm_is_valid_slug() {  # dhm_is_valid_slug <slug>
  [[ "$1" =~ '^[a-z0-9]+(-[a-z0-9]+)*$' ]]
}

dhm_is_valid_domain() {  # dhm_is_valid_domain <domain>
  [[ "$1" =~ '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' ]]
}

# ----------------------------------------------------------------- state ----
#
# One JSON document per migration, at
#   ${DHM_STATE_DIR}/<site>/state.json
# Phases record status so `dhm resume` can restart at the first incomplete one.

dhm_state_dir() {
  print -r -- "${DHM_STATE_DIR:-${HOME}/.local/state/do-here-now-migrator}"
}

dhm_state_file() {  # dhm_state_file <site>
  print -r -- "$(dhm_state_dir)/${1}/state.json"
}

dhm_state_init() {  # dhm_state_init <site> <repo> <agent>
  local site=$1 repo=$2 agent=$3
  local file; file=$(dhm_state_file "$site")
  mkdir -p "${file:h}" || return 1
  if [[ -s "$file" ]]; then
    dhm_log "resuming existing state at ${file}"
    return 0
  fi
  jq -n \
    --arg site "$site" --arg repo "$repo" --arg agent "$agent" \
    --arg created "$(dhm_now_utc)" \
    '{site:$site, repo:$repo, agent:$agent, created_at:$created,
      phases:{}, facts:{}, config:{}}' > "$file" || return 1
  chmod 600 "$file"
  dhm_log "created state at ${file}"
}

# Apply a jq expression to the state document, atomically.
dhm_state_edit() {  # dhm_state_edit <site> <jq-expr> [--arg k v ...]
  local site=$1 expr=$2; shift 2
  local file tmp
  file=$(dhm_state_file "$site")
  [[ -s "$file" ]] || { dhm_error "no state for site '${site}'"; return 1 }
  tmp="${file}.tmp.$$"
  if ! jq "$@" "$expr" "$file" > "$tmp"; then
    rm -f -- "$tmp"
    dhm_error "state update failed for site '${site}'"
    return 1
  fi
  mv -f -- "$tmp" "$file"
  chmod 600 "$file"
}

dhm_state_get() {  # dhm_state_get <site> <jq-path> ; prints raw value or empty
  local file; file=$(dhm_state_file "$1")
  [[ -s "$file" ]] || return 1
  jq -r "${2} // empty" "$file"
}

dhm_fact_set() {  # dhm_fact_set <site> <key> <value>
  dhm_state_edit "$1" '.facts[$k] = $v' --arg k "$2" --arg v "$3"
}

dhm_fact_get() {  # dhm_fact_get <site> <key>
  dhm_state_get "$1" ".facts[\"${2}\"]"
}

dhm_phase_status() {  # dhm_phase_status <site> <phase>
  local phase_status
  phase_status=$(dhm_state_get "$1" ".phases[\"${2}\"].status") || return 1
  print -r -- "${phase_status:-pending}"
}

dhm_phase_mark() {  # dhm_phase_mark <site> <phase> <status>
  dhm_state_edit "$1" \
    '.phases[$p] = {status:$s, at:$at}' \
    --arg p "$2" --arg s "$3" --arg at "$(dhm_now_utc)"
}

dhm_phase_is_done() {  # dhm_phase_is_done <site> <phase>
  [[ "$(dhm_phase_status "$1" "$2")" == done ]]
}

# ------------------------------------------------------------ http helper ----

# curl with sane migration defaults. Never follows cross-host redirects
# silently and always verifies TLS.
dhm_http_status() {  # dhm_http_status <url> [extra curl args ...]
  local url=$1; shift
  curl -sS -o /dev/null -w '%{http_code}' --max-time "${DHM_HTTP_TIMEOUT:-30}" \
    "$@" -- "$url" 2>/dev/null || print -r -- "000"
}

dhm_http_get() {  # dhm_http_get <url> [extra curl args ...]
  local url=$1; shift
  curl -fsS --max-time "${DHM_HTTP_TIMEOUT:-30}" "$@" -- "$url"
}
