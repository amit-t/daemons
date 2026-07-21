#!/usr/bin/env zsh
# do-here-now-migrator — phase 0: preflight.
# Verifies tooling, credentials, and repository hygiene before anything is
# inventoried, backed up, transformed, or destroyed. Reports every problem it
# finds rather than stopping at the first, so one pass fixes the whole list.

typeset -g DHM_PREFLIGHT_PROBLEMS=0

dhm_pf_fail() {
  dhm_error "$*"
  (( DHM_PREFLIGHT_PROBLEMS++ )) || true
}

dhm_pf_pass() { dhm_ok "$*" }

# Required regardless of configuration.
dhm_preflight_core_tools() {
  local cmd
  for cmd in curl jq git; do
    if dhm_have "$cmd"; then
      dhm_pf_pass "found ${cmd}"
    else
      dhm_pf_fail "missing ${cmd} — required for every phase"
    fi
  done
  # file(1) is required by the here.now publisher for content-type sniffing.
  if dhm_have file; then
    dhm_pf_pass "found file"
  else
    dhm_pf_fail "missing file — the here.now publisher needs it"
  fi
}

# DigitalOcean is optional: a site may already be hosted elsewhere. Only
# demand doctl when the run intends to inventory or decommission DO.
dhm_preflight_digitalocean() {  # dhm_preflight_digitalocean <required:0|1>
  local required=$1
  if ! dhm_have doctl; then
    if (( required )); then
      dhm_pf_fail "missing doctl — install with 'brew install doctl', or pass --no-digitalocean"
    else
      dhm_warn "doctl not installed; DigitalOcean phases will be skipped"
    fi
    return 0
  fi
  dhm_pf_pass "found doctl"
  local account
  if account=$(doctl account get --format Email --no-header 2>/dev/null) && [[ -n "$account" ]]; then
    dhm_pf_pass "doctl authenticated as ${account}"
    print -r -- "$account"
  else
    if (( required )); then
      dhm_pf_fail "doctl is not authenticated — run 'doctl auth init'"
    else
      dhm_warn "doctl is not authenticated; DigitalOcean phases will be skipped"
    fi
  fi
}

# GitHub CLI is only needed for the CI phase.
dhm_preflight_github() {  # dhm_preflight_github <repo-slug> <required:0|1>
  local repo=$1 required=$2
  if ! dhm_have gh; then
    if (( required )); then
      dhm_pf_fail "missing gh — install with 'brew install gh', or pass --no-ci"
    else
      dhm_warn "gh not installed; the CI phase will be skipped"
    fi
    return 0
  fi
  dhm_pf_pass "found gh"

  local active
  active=$(gh auth status --active 2>/dev/null | sed -n 's/.*account \([A-Za-z0-9_-]*\).*/\1/p' | head -1)
  [[ -n "$active" ]] && dhm_log "gh active account: ${active}"

  # The single most common failure in a multi-account setup: the active gh
  # account cannot see the repository at all. Detect it here, not at push time.
  if [[ -n "$repo" ]]; then
    if gh api "repos/${repo}" --jq '.full_name' >/dev/null 2>&1; then
      dhm_pf_pass "gh can access ${repo}"
    else
      local msg="gh account '${active:-unknown}' cannot access ${repo}"
      msg+=" — switch with 'gh auth switch -u <user>'"
      if (( required )); then dhm_pf_fail "$msg"; else dhm_warn "$msg"; fi
    fi
  fi
}

# Node toolchain, resolved from the detected package manager.
dhm_preflight_node() {  # dhm_preflight_node <package-manager>
  local pm=$1
  if dhm_have node; then
    dhm_pf_pass "found node $(node --version 2>/dev/null)"
  else
    dhm_pf_fail "missing node"
  fi
  case "$pm" in
    pnpm|npm|yarn|bun)
      if dhm_have "$pm"; then
        dhm_pf_pass "found ${pm}"
      else
        dhm_pf_fail "missing ${pm} — the repository's lockfile requires it"
      fi
      ;;
    *) dhm_warn "unrecognised package manager '${pm}'; build phase may need --build-command" ;;
  esac
}

# The transform phase rewrites source files. A dirty tree makes its diff
# impossible to review and its rollback impossible to trust.
dhm_preflight_repo() {  # dhm_preflight_repo <repo-dir>
  local repo=$1
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    dhm_pf_fail "${repo} is not a git repository"
    return 0
  fi
  dhm_pf_pass "git repository at ${repo}"

  local dirty
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$dirty" != 0 ]]; then
    dhm_pf_fail "working tree has ${dirty} uncommitted change(s) — commit or stash first"
    git -C "$repo" status --short 2>/dev/null | head -10 >&2
  else
    dhm_pf_pass "working tree is clean"
  fi

  local branch
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  dhm_log "current branch: ${branch}"

  # A personal-vs-company identity mismatch must never be discovered after a
  # commit has already been authored.
  local email remote
  email=$(git -C "$repo" config user.email 2>/dev/null)
  remote=$(git -C "$repo" remote get-url origin 2>/dev/null)
  if [[ -n "$email" ]]; then
    dhm_log "git identity: ${email}"
  else
    dhm_pf_fail "git user.email is unset in ${repo}"
  fi
  [[ -n "$remote" ]] && dhm_log "origin: ${remote}"
}

# The agent launcher is a zsh function or alias in the user's interactive
# shell, so it can only be probed through an interactive shell.
dhm_preflight_launcher() {  # dhm_preflight_launcher <launcher-command>
  local launcher=$1 head=${1%% *}
  if [[ -z "$launcher" ]]; then
    dhm_pf_fail "no agent launcher resolved"
    return 0
  fi
  if zsh -ic "whence -w ${(q)head}" >/dev/null 2>&1; then
    dhm_pf_pass "agent launcher '${head}' is available"
  else
    dhm_pf_fail "agent launcher '${head}' not found in an interactive zsh — check your shell config"
  fi
}

dhm_preflight_report() {
  if (( DHM_PREFLIGHT_PROBLEMS > 0 )); then
    dhm_error "preflight found ${DHM_PREFLIGHT_PROBLEMS} problem(s); nothing has been changed"
    return 1
  fi
  dhm_ok "preflight clean"
  return 0
}
