#!/usr/bin/env zsh
# do-here-now-migrator — repository detection.
# Works out the package manager, framework, static output directory, and the
# server-side coupling that has to be removed before the site can be exported.
# Every result is a best guess that the CLI can override with a flag.

dhm_detect_package_manager() {  # dhm_detect_package_manager <repo>
  local repo=$1
  if [[ -f "${repo}/pnpm-lock.yaml" ]]; then print -r -- pnpm; return; fi
  if [[ -f "${repo}/bun.lockb" || -f "${repo}/bun.lock" ]]; then print -r -- bun; return; fi
  if [[ -f "${repo}/yarn.lock" ]]; then print -r -- yarn; return; fi
  if [[ -f "${repo}/package-lock.json" ]]; then print -r -- npm; return; fi
  # Fall back to the packageManager field when no lockfile is committed.
  if [[ -f "${repo}/package.json" ]] && dhm_have jq; then
    local pm
    pm=$(jq -r '.packageManager // empty' "${repo}/package.json" 2>/dev/null)
    [[ -n "$pm" ]] && { print -r -- "${pm%%@*}"; return }
  fi
  print -r -- npm
}

dhm_detect_framework() {  # dhm_detect_framework <repo>
  # zsh declares every name in a `local` before assigning any of them, so a
  # later initialiser cannot reference an earlier one under `set -u`.
  local repo=$1 pkg
  pkg="${repo}/package.json"
  if [[ ! -f "$pkg" ]]; then
    # Non-Node static generators.
    [[ -f "${repo}/config.toml" || -f "${repo}/hugo.toml" ]] && { print -r -- hugo; return }
    [[ -f "${repo}/_config.yml" ]] && { print -r -- jekyll; return }
    [[ -f "${repo}/mkdocs.yml" ]] && { print -r -- mkdocs; return }
    [[ -f "${repo}/index.html" ]] && { print -r -- plain-html; return }
    print -r -- unknown
    return
  fi
  local deps
  deps=$(jq -r '[(.dependencies // {}), (.devDependencies // {})] | add | keys[]' "$pkg" 2>/dev/null)
  local name
  for name in next nuxt astro gatsby @docusaurus/core @sveltejs/kit vite react-scripts remix; do
    if print -r -- "$deps" | grep -qx -- "$name"; then
      case "$name" in
        next)               print -r -- nextjs ;;
        nuxt)               print -r -- nuxt ;;
        astro)              print -r -- astro ;;
        gatsby)             print -r -- gatsby ;;
        '@docusaurus/core') print -r -- docusaurus ;;
        '@sveltejs/kit')    print -r -- sveltekit ;;
        remix)              print -r -- remix ;;
        vite)               print -r -- vite ;;
        react-scripts)      print -r -- cra ;;
      esac
      return
    fi
  done
  print -r -- unknown
}

# Directory each framework writes its static export to. The build phase
# asserts an index.html actually lands here.
dhm_detect_output_dir() {  # dhm_detect_output_dir <framework>
  case "$1" in
    nextjs)     print -r -- out ;;
    nuxt)       print -r -- .output/public ;;
    astro)      print -r -- dist ;;
    gatsby)     print -r -- public ;;
    docusaurus) print -r -- build ;;
    sveltekit)  print -r -- build ;;
    vite)       print -r -- dist ;;
    cra)        print -r -- build ;;
    remix)      print -r -- build/client ;;
    hugo)       print -r -- public ;;
    jekyll)     print -r -- _site ;;
    mkdocs)     print -r -- site ;;
    plain-html) print -r -- . ;;
    *)          print -r -- dist ;;
  esac
}

# Whether the framework can produce a fully static export at all, and what it
# takes. Consumed by the transform prompt so the agent is told the specific
# change rather than asked to work it out.
dhm_detect_static_recipe() {  # dhm_detect_static_recipe <framework>
  case "$1" in
    nextjs)     print -r -- "set output: 'export' plus trailingSlash: true and images.unoptimized: true in next.config; remove route handlers, server actions, middleware, and dynamic API routes" ;;
    nuxt)       print -r -- "run 'nuxt generate' (ssr: false or full prerender); remove server/api routes and nitro server handlers" ;;
    astro)      print -r -- "set output: 'static' in astro.config; remove server endpoints and any adapter integration" ;;
    gatsby)     print -r -- "gatsby build already emits static output; remove Gatsby Functions in src/api" ;;
    docusaurus) print -r -- "docusaurus build is already static; no framework change needed" ;;
    sveltekit)  print -r -- "swap the adapter for @sveltejs/adapter-static and add a prerender entry; remove +server.ts endpoints" ;;
    vite|cra)   print -r -- "the build is already static; remove any co-located server code" ;;
    remix)      print -r -- "Remix needs a server runtime; migrating to static requires prerendering or a framework change — expect substantial work" ;;
    hugo|jekyll|mkdocs|plain-html) print -r -- "already a static generator; no framework change needed" ;;
    *)          print -r -- "framework not recognised; the agent must determine the static export path itself" ;;
  esac
}

# Server-side coupling that blocks a static export. Returned as a newline
# separated report used both for the plan and for the agent prompt.
dhm_detect_server_coupling() {  # dhm_detect_server_coupling <repo>
  local repo=$1 pkg found=()
  pkg="${repo}/package.json"
  if [[ -f "$pkg" ]]; then
    local deps
    deps=$(jq -r '[(.dependencies // {}), (.devDependencies // {})] | add | keys[]' "$pkg" 2>/dev/null)
    local dep
    for dep in mongoose mongodb pg mysql2 prisma @prisma/client drizzle-orm redis ioredis \
               next-auth @auth/core bcrypt bcryptjs nodemailer stripe; do
      print -r -- "$deps" | grep -qx -- "$dep" && found+=("dependency:${dep}")
    done
  fi
  # Directory-level signals, scoped to source roots so node_modules is never walked.
  local dir
  for dir in app/api pages/api src/app/api src/pages/api server src/server functions netlify/functions; do
    [[ -d "${repo}/${dir}" ]] && found+=("server-routes:${dir}")
  done
  local f
  for f in middleware.ts middleware.js src/middleware.ts src/middleware.js \
           docker-compose.yml docker-compose.yaml Dockerfile Procfile; do
    [[ -f "${repo}/${f}" ]] && found+=("server-artifact:${f}")
  done
  [[ -f "${repo}/prisma/schema.prisma" ]] && found+=("schema:prisma/schema.prisma")
  print -rl -- "${found[@]}"
}

# Locate an existing subscribe/newsletter form so the transform prompt can
# name the file instead of asking the agent to hunt for it.
dhm_detect_subscribe_sites() {  # dhm_detect_subscribe_sites <repo>
  local repo=$1
  if ! dhm_have rg; then
    grep -rlEi 'subscribe|newsletter|subscriber' \
      --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
      --include='*.vue' --include='*.svelte' --include='*.astro' \
      "$repo" 2>/dev/null \
      | grep -v node_modules | head -20
    return
  fi
  rg -l -i -e 'subscribe' -e 'newsletter' -e 'subscriber' \
    --glob '!node_modules' --glob '!.git' --glob '!*.lock' --glob '!out/**' \
    --glob '!dist/**' --glob '!build/**' --glob '!.next/**' \
    "$repo" 2>/dev/null | head -20
}

# Full detection as one JSON object, stored in state and fed to the prompt.
dhm_detect_all() {  # dhm_detect_all <repo>
  local repo=$1 pm framework outdir recipe coupling subs
  pm=$(dhm_detect_package_manager "$repo")
  framework=$(dhm_detect_framework "$repo")
  outdir=$(dhm_detect_output_dir "$framework")
  recipe=$(dhm_detect_static_recipe "$framework")
  coupling=$(dhm_detect_server_coupling "$repo")
  subs=$(dhm_detect_subscribe_sites "$repo")
  jq -n \
    --arg pm "$pm" --arg fw "$framework" --arg out "$outdir" --arg recipe "$recipe" \
    --arg coupling "$coupling" --arg subs "$subs" \
    '{package_manager:$pm, framework:$fw, output_dir:$out, static_recipe:$recipe,
      server_coupling: ($coupling | split("\n") | map(select(length>0))),
      subscribe_candidates: ($subs | split("\n") | map(select(length>0)))}'
}
