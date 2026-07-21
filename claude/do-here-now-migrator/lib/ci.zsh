#!/usr/bin/env zsh
# do-here-now-migrator — phase 9: continuous deployment.
#
# Destroying the App Platform app also destroys its deploy-on-push integration.
# Something has to replace it or the site silently stops tracking main. This
# phase writes a GitHub Actions workflow, and wires the two settings it needs.
#
# The workflow is written to fail loudly rather than deploy something wrong:
# a missing secret, an empty export, or a publisher that fell back to anonymous
# mode all stop the run before it can replace a working site.

dhm_ci_repo_slug() {  # dhm_ci_repo_slug <repo-dir>
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  # git@host:owner/repo.git | https://host/owner/repo.git | ssh://...
  url=${url%.git}
  url=${url##*:}
  url=${url##*/github.com/}
  # Reduce any remaining path to the final two segments.
  print -r -- "${url}" | awk -F/ '{ if (NF>=2) print $(NF-1)"/"$NF; else print $0 }'
}

# actions/setup-node only understands npm, yarn, and pnpm. Anything else must
# leave the key empty rather than pass a value the action rejects.
dhm_ci_node_cache() {  # dhm_ci_node_cache <package-manager>
  case "$1" in
    npm|yarn|pnpm) print -r -- "\"$1\"" ;;
    *)             print -r -- "" ;;
  esac
}

# An empty `run:` is invalid YAML, so a project with no install or build step
# gets an explicit no-op instead of a blank line.
dhm_ci_step_command() {  # dhm_ci_step_command <command> <label>
  if [[ -n "$1" ]]; then
    print -r -- "$1"
  else
    print -r -- "echo 'no ${2} step for this project'"
  fi
}

dhm_ci_render_workflow() {  # dhm_ci_render_workflow <template> <vars-json>
  local template=$1 vars=$2 text key value
  [[ -r "$template" ]] || { dhm_error "missing workflow template ${template}"; return 1 }
  text=$(<"$template")
  for key in ${(f)"$(jq -r 'keys[]' <<<"$vars")"}; do
    value=$(jq -r --arg k "$key" '.[$k] // ""' <<<"$vars")
    text=${text//\{\{${key}\}\}/${value}}
  done
  print -r -- "$text"
}

dhm_ci_write_workflow() {  # dhm_ci_write_workflow <repo> <content>
  local repo=$1 content=$2 dir="${1}/.github/workflows" file
  file="${dir}/deploy-here-now.yml"
  if dhm_dry "write ${file}"; then return 0; fi
  mkdir -p "$dir" || return 1
  print -r -- "$content" > "$file" || return 1
  dhm_ok "wrote ${file}"

  # Validate the YAML if a parser is available. A workflow that does not parse
  # is invisible to GitHub — it simply never runs.
  if dhm_have python3; then
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>/dev/null; then
      dhm_ok "workflow YAML parses"
    else
      dhm_error "workflow YAML failed to parse"
      return 1
    fi
  fi
  print -r -- "$file"
}

# Set the repository secret and variable the workflow reads. Both are set
# through gh so the key never lands in a file inside the repository.
dhm_ci_configure_github() {  # dhm_ci_configure_github <repo-slug> <slug>
  local repo=$1 slug=$2

  dhm_have gh || { dhm_warn "gh not installed; set HERENOW_API_KEY and HERENOW_SLUG manually"; return 2 }
  if ! gh api "repos/${repo}" --jq '.full_name' >/dev/null 2>&1; then
    dhm_error "the active gh account cannot access ${repo}"
    dhm_error "  switch accounts with: gh auth switch -u <user>"
    return 1
  fi

  if dhm_dry "set repository variable HERENOW_SLUG=${slug} and secret HERENOW_API_KEY on ${repo}"; then
    return 0
  fi

  if gh variable set HERENOW_SLUG --repo "$repo" --body "$slug" >/dev/null 2>&1; then
    dhm_ok "set repository variable HERENOW_SLUG=${slug}"
  else
    dhm_error "could not set HERENOW_SLUG on ${repo}"
    return 1
  fi

  local key
  key=$(dhm_hn_key) || { dhm_error "no here.now credentials to publish as a secret"; return 1 }
  if print -r -- "$key" | gh secret set HERENOW_API_KEY --repo "$repo" >/dev/null 2>&1; then
    unset key
    dhm_ok "set repository secret HERENOW_API_KEY"
  else
    unset key
    dhm_error "could not set HERENOW_API_KEY on ${repo}"
    return 1
  fi
  return 0
}

# Report anything the old DigitalOcean integration did that the new workflow
# does not, so the difference is a decision rather than a surprise.
dhm_ci_report_gaps() {  # dhm_ci_report_gaps <app-spec-file>
  local spec=$1
  [[ -r "$spec" ]] || return 0
  print -r -- ""
  dhm_info "differences from the retired DigitalOcean deploy integration:"
  if grep -q 'deploy_on_push: true' "$spec" 2>/dev/null; then
    dhm_log "  deploy-on-push: replaced by the GitHub Actions workflow"
  fi
  if grep -qE '^\s*envs:' "$spec" 2>/dev/null; then
    dhm_log "  runtime environment variables: a static site has no runtime, so these are gone."
    dhm_log "    Build-time values must be re-declared in the workflow if the build needs them."
  fi
  if grep -qE '^\s*jobs:' "$spec" 2>/dev/null; then
    dhm_warn "  the app defined pre/post-deploy jobs — these have no replacement and are NOT migrated"
  fi
  if grep -qE '^\s*alerts:' "$spec" 2>/dev/null; then
    dhm_log "  DEPLOYMENT_FAILED / DOMAIN_FAILED alerts: replaced by GitHub Actions run failures"
  fi
  print -r -- ""
}
