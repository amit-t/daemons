#!/usr/bin/env zsh
# do-here-now-migrator — phase 5: build.
#
# Deterministic. The agent may have changed the build configuration, so this
# phase re-derives nothing and simply proves that the repository now produces a
# real static site: an index.html plus enough sibling files that a truncated or
# half-written export cannot pass.

dhm_build_install_command() {  # dhm_build_install_command <package-manager>
  case "$1" in
    pnpm) print -r -- "pnpm install --frozen-lockfile" ;;
    npm)  print -r -- "npm ci" ;;
    yarn) print -r -- "yarn install --frozen-lockfile" ;;
    bun)  print -r -- "bun install --frozen-lockfile" ;;
    *)    print -r -- "" ;;
  esac
}

dhm_build_build_command() {  # dhm_build_build_command <package-manager> <framework>
  case "$2" in
    hugo)   print -r -- "hugo --minify" ; return ;;
    jekyll) print -r -- "bundle exec jekyll build" ; return ;;
    mkdocs) print -r -- "mkdocs build" ; return ;;
    plain-html) print -r -- "" ; return ;;
  esac
  case "$1" in
    pnpm) print -r -- "pnpm build" ;;
    npm)  print -r -- "npm run build" ;;
    yarn) print -r -- "yarn build" ;;
    bun)  print -r -- "bun run build" ;;
    *)    print -r -- "" ;;
  esac
}

dhm_build_run() {  # dhm_build_run <repo> <install-cmd> <build-cmd>
  local repo=$1 install=$2 build=$3

  if [[ -n "$install" ]]; then
    if dhm_dry "run '${install}' in ${repo}"; then
      :
    else
      dhm_info "installing dependencies: ${install}"
      if ! ( cd "$repo" && eval "$install" ) >&2; then
        dhm_error "dependency install failed"
        return 1
      fi
    fi
  fi

  if [[ -n "$build" ]]; then
    if dhm_dry "run '${build}' in ${repo}"; then
      :
    else
      dhm_info "building: ${build}"
      if ! ( cd "$repo" && eval "$build" ) >&2; then
        dhm_error "build failed"
        return 1
      fi
    fi
  else
    dhm_log "no build command for this project; treating the source tree as already static"
  fi
  return 0
}

# Prove the export is real before anything is published or destroyed.
dhm_build_verify_output() {  # dhm_build_verify_output <repo> <output-dir>
  local repo=$1 out="${1}/${2}"
  out=${out:A}

  if dhm_dry "verify static output in ${out}"; then return 0; fi

  if [[ ! -d "$out" ]]; then
    dhm_error "static output directory ${out} does not exist"
    dhm_error "  the framework is probably still configured for a server runtime"
    return 1
  fi
  if [[ ! -f "${out}/index.html" ]]; then
    dhm_error "${out}/index.html is missing — this is not a servable static site"
    return 1
  fi

  local files html
  files=$(find "$out" -type f | wc -l | tr -d ' ')
  html=$(find "$out" -type f -name '*.html' | wc -l | tr -d ' ')
  if (( files < 2 )); then
    dhm_error "${out} contains only ${files} file(s); refusing to treat that as a built site"
    return 1
  fi

  dhm_ok "static output verified: ${files} file(s), ${html} HTML page(s), $(du -sh "$out" | cut -f1)"

  # A static export must not carry server-only artefacts into the published
  # bundle. These leak configuration and occasionally credentials.
  local leaked=()
  local pattern
  for pattern in .env .env.local .env.production node_modules; do
    [[ -e "${out}/${pattern}" ]] && leaked+=("$pattern")
  done
  if (( ${#leaked} > 0 )); then
    dhm_error "the export contains files that must never be published: ${leaked[*]}"
    return 1
  fi

  # Credential-shaped strings in a static bundle are public the moment it ships.
  if grep -rlE '(mongodb(\+srv)?://[^ "]*:[^ "]*@|postgres(ql)?://[^ "]*:[^ "]*@|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
       "$out" >/dev/null 2>&1; then
    dhm_error "the export contains connection strings or private keys — refusing to publish"
    grep -rlE '(mongodb(\+srv)?://[^ "]*:[^ "]*@|postgres(ql)?://[^ "]*:[^ "]*@|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
      "$out" 2>/dev/null | head -5 >&2
    return 1
  fi
  dhm_ok "no credential-shaped strings found in the export"
  return 0
}
