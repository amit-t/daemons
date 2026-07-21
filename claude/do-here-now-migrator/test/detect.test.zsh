#!/usr/bin/env zsh
# Repository detection, exercised against synthesised project trees.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common detect

local tmp; tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmp"' EXIT

mkproject() {  # mkproject <name> <package.json contents>
  local dir="${tmp}/${1}"
  mkdir -p "$dir"
  print -r -- "$2" > "${dir}/package.json"
  print -r -- "$dir"
}

# ---- package manager ---------------------------------------------------------

local d
d=$(mkproject pnpmproj '{"name":"x"}'); touch "${d}/pnpm-lock.yaml"
assert_eq "pnpm from lockfile" "pnpm" "$(dhm_detect_package_manager "$d")"

d=$(mkproject yarnproj '{"name":"x"}'); touch "${d}/yarn.lock"
assert_eq "yarn from lockfile" "yarn" "$(dhm_detect_package_manager "$d")"

d=$(mkproject npmproj '{"name":"x"}'); touch "${d}/package-lock.json"
assert_eq "npm from lockfile" "npm" "$(dhm_detect_package_manager "$d")"

d=$(mkproject bunproj '{"name":"x"}'); touch "${d}/bun.lock"
assert_eq "bun from lockfile" "bun" "$(dhm_detect_package_manager "$d")"

# packageManager field is the fallback when no lockfile is committed.
d=$(mkproject pmfield '{"name":"x","packageManager":"pnpm@10.13.1"}')
assert_eq "pnpm from packageManager field" "pnpm" "$(dhm_detect_package_manager "$d")"

# Lockfile beats the field, because the lockfile is what CI must honour.
d=$(mkproject bothpm '{"name":"x","packageManager":"npm@10"}'); touch "${d}/pnpm-lock.yaml"
assert_eq "lockfile wins over field" "pnpm" "$(dhm_detect_package_manager "$d")"

d=$(mkproject nothing '{"name":"x"}')
assert_eq "npm is the default" "npm" "$(dhm_detect_package_manager "$d")"

# ---- framework ---------------------------------------------------------------

d=$(mkproject nextproj '{"dependencies":{"next":"15.3.1","react":"19"}}')
assert_eq "nextjs detected" "nextjs" "$(dhm_detect_framework "$d")"
assert_eq "nextjs output dir" "out" "$(dhm_detect_output_dir nextjs)"

d=$(mkproject astroproj '{"dependencies":{"astro":"4"}}')
assert_eq "astro detected" "astro" "$(dhm_detect_framework "$d")"
assert_eq "astro output dir" "dist" "$(dhm_detect_output_dir astro)"

d=$(mkproject gatsbyproj '{"dependencies":{"gatsby":"5"}}')
assert_eq "gatsby detected" "gatsby" "$(dhm_detect_framework "$d")"
assert_eq "gatsby output dir" "public" "$(dhm_detect_output_dir gatsby)"

d=$(mkproject sk '{"devDependencies":{"@sveltejs/kit":"2"}}')
assert_eq "sveltekit detected" "sveltekit" "$(dhm_detect_framework "$d")"

d=$(mkproject docu '{"dependencies":{"@docusaurus/core":"3"}}')
assert_eq "docusaurus detected" "docusaurus" "$(dhm_detect_framework "$d")"

d=$(mkproject viteproj '{"devDependencies":{"vite":"5"}}')
assert_eq "vite detected" "vite" "$(dhm_detect_framework "$d")"

# Non-Node generators, which have no package.json at all.
mkdir -p "${tmp}/hugoproj"; touch "${tmp}/hugoproj/hugo.toml"
assert_eq "hugo detected" "hugo" "$(dhm_detect_framework "${tmp}/hugoproj")"
assert_eq "hugo output dir" "public" "$(dhm_detect_output_dir hugo)"

mkdir -p "${tmp}/jekyllproj"; touch "${tmp}/jekyllproj/_config.yml"
assert_eq "jekyll detected" "jekyll" "$(dhm_detect_framework "${tmp}/jekyllproj")"

mkdir -p "${tmp}/plainproj"; touch "${tmp}/plainproj/index.html"
assert_eq "plain html detected" "plain-html" "$(dhm_detect_framework "${tmp}/plainproj")"

mkdir -p "${tmp}/mystery"
assert_eq "unknown framework" "unknown" "$(dhm_detect_framework "${tmp}/mystery")"

# Next takes priority over a bare vite/react dependency, because a Next app
# that also lists vite must still be treated as Next.
d=$(mkproject nextvite '{"dependencies":{"next":"15"},"devDependencies":{"vite":"5"}}')
assert_eq "next wins over vite" "nextjs" "$(dhm_detect_framework "$d")"

# ---- static recipes ----------------------------------------------------------

assert_contains "next recipe names the config flag" "$(dhm_detect_static_recipe nextjs)" "output: 'export'"
assert_contains "sveltekit recipe names the adapter" "$(dhm_detect_static_recipe sveltekit)" "adapter-static"
assert_contains "remix recipe warns" "$(dhm_detect_static_recipe remix)" "substantial work"
assert_contains "hugo needs no change" "$(dhm_detect_static_recipe hugo)" "already a static generator"

# ---- server coupling ---------------------------------------------------------

d=$(mkproject coupled '{"dependencies":{"mongoose":"8","next-auth":"4","nodemailer":"6"}}')
mkdir -p "${d}/app/api/subscribe"
touch "${d}/middleware.ts" "${d}/Dockerfile" "${d}/docker-compose.yml"

local coupling
coupling=$(dhm_detect_server_coupling "$d")
assert_contains "mongoose flagged"    "$coupling" "dependency:mongoose"
assert_contains "next-auth flagged"   "$coupling" "dependency:next-auth"
assert_contains "nodemailer flagged"  "$coupling" "dependency:nodemailer"
assert_contains "api routes flagged"  "$coupling" "server-routes:app/api"
assert_contains "middleware flagged"  "$coupling" "server-artifact:middleware.ts"
assert_contains "dockerfile flagged"  "$coupling" "server-artifact:Dockerfile"

# A clean static project must produce no findings at all — a detector that
# always fires teaches the operator to ignore it.
d=$(mkproject clean '{"dependencies":{"astro":"4"}}')
assert_eq "clean project has no coupling" "" "$(dhm_detect_server_coupling "$d")"

# ---- the full detection document --------------------------------------------

d=$(mkproject full '{"dependencies":{"next":"15","mongoose":"8"}}')
touch "${d}/pnpm-lock.yaml"
local doc; doc=$(dhm_detect_all "$d")
assert_ok "detect_all emits valid JSON" jq -e '.' <<<"$doc"
assert_eq "doc framework" "nextjs" "$(jq -r '.framework' <<<"$doc")"
assert_eq "doc package manager" "pnpm" "$(jq -r '.package_manager' <<<"$doc")"
assert_eq "doc output dir" "out" "$(jq -r '.output_dir' <<<"$doc")"
assert_eq "doc coupling is an array" "array" "$(jq -r '.server_coupling | type' <<<"$doc")"
assert_eq "doc coupling found mongoose" "1" \
  "$(jq '[.server_coupling[] | select(. == "dependency:mongoose")] | length' <<<"$doc")"

report
