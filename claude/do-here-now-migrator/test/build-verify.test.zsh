#!/usr/bin/env zsh
# Build output guards and route derivation. These are the checks that stop a
# broken or secret-bearing export from being published.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common build verify ci

local tmp; tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmp"' EXIT

# ---- build and install commands ---------------------------------------------

assert_eq "pnpm install" "pnpm install --frozen-lockfile" "$(dhm_build_install_command pnpm)"
assert_eq "npm install"  "npm ci"                          "$(dhm_build_install_command npm)"
assert_eq "yarn install" "yarn install --frozen-lockfile"  "$(dhm_build_install_command yarn)"
assert_eq "unknown pm has no install" "" "$(dhm_build_install_command cargo)"

assert_eq "pnpm build"   "pnpm build"        "$(dhm_build_build_command pnpm nextjs)"
assert_eq "npm build"    "npm run build"     "$(dhm_build_build_command npm astro)"
assert_eq "hugo build"   "hugo --minify"     "$(dhm_build_build_command npm hugo)"
assert_eq "plain html has no build" ""       "$(dhm_build_build_command npm plain-html)"

# ---- output verification -----------------------------------------------------

# A missing directory must fail.
assert_fails "missing output dir rejected" dhm_build_verify_output "$tmp" nowhere

# An empty directory must fail.
mkdir -p "${tmp}/empty"
assert_fails "empty output dir rejected" dhm_build_verify_output "$tmp" empty

# A directory with no index.html must fail, even if it has other files.
mkdir -p "${tmp}/noindex"; print -r -- "x" > "${tmp}/noindex/about.html"
assert_fails "output without index.html rejected" dhm_build_verify_output "$tmp" noindex

# A single lonely index.html is not a built site.
mkdir -p "${tmp}/lonely"; print -r -- "<html></html>" > "${tmp}/lonely/index.html"
assert_fails "single-file output rejected" dhm_build_verify_output "$tmp" lonely

# A real-shaped export passes.
mkdir -p "${tmp}/good/about" "${tmp}/good/_next/static"
print -r -- "<html><body>home</body></html>" > "${tmp}/good/index.html"
print -r -- "<html><body>about</body></html>" > "${tmp}/good/about/index.html"
print -r -- "body{}" > "${tmp}/good/_next/static/app.css"
assert_ok "valid export accepted" dhm_build_verify_output "$tmp" good

# Server-only artefacts must never ship.
cp -R "${tmp}/good" "${tmp}/leaky-env"
print -r -- "SECRET=1" > "${tmp}/leaky-env/.env"
assert_fails "export containing .env rejected" dhm_build_verify_output "$tmp" leaky-env

cp -R "${tmp}/good" "${tmp}/leaky-modules"
mkdir -p "${tmp}/leaky-modules/node_modules"
assert_fails "export containing node_modules rejected" dhm_build_verify_output "$tmp" leaky-modules

# Credential-shaped strings in the bundle are public the moment it ships.
# The fake URI is assembled from parts so secret scanners don't flag this file.
cp -R "${tmp}/good" "${tmp}/leaky-uri"
print -r -- 'const u="mongodb+srv://admin:''hunter2@''cluster.mongodb.net/db";' \
  > "${tmp}/leaky-uri/_next/static/app.js"
assert_fails "export with a mongo URI rejected" dhm_build_verify_output "$tmp" leaky-uri

cp -R "${tmp}/good" "${tmp}/leaky-key"
print -r -- '-----BEGIN RSA PRIVATE KEY-----' > "${tmp}/leaky-key/_next/static/key.txt"
assert_fails "export with a private key rejected" dhm_build_verify_output "$tmp" leaky-key

# A URL without embedded credentials is fine and must not trip the check.
cp -R "${tmp}/good" "${tmp}/clean-url"
print -r -- 'const docs="https://www.mongodb.com/docs";' > "${tmp}/clean-url/_next/static/app.js"
assert_ok "credential-free URL accepted" dhm_build_verify_output "$tmp" clean-url

# ---- route derivation --------------------------------------------------------

mkdir -p "${tmp}/routes/about" "${tmp}/routes/blog" "${tmp}/routes/blog/post-one" \
         "${tmp}/routes/_next/static"
local p
for p in "" /about /blog /blog/post-one; do
  print -r -- "<html></html>" > "${tmp}/routes${p}/index.html"
done
print -r -- "x" > "${tmp}/routes/_next/static/index.html"

local routes
routes=$(dhm_verify_routes_from_output "${tmp}/routes")
assert_contains "root route derived"    "$routes" "/"
assert_contains "about route derived"   "$routes" "/about/"
assert_contains "blog route derived"    "$routes" "/blog/"
assert_contains "nested route derived"  "$routes" "/blog/post-one/"
assert_not_contains "_next excluded"    "$routes" "_next"

# An empty or missing output directory still yields the root, so verification
# degrades to a single check rather than silently checking nothing.
assert_eq "missing output yields root only" "/" "$(dhm_verify_routes_from_output "${tmp}/nope")"

# `path` is a special zsh parameter tied to PATH. Route verification must not
# localize it, or curl becomes unresolvable and every healthy route reports 000.
local route_fake_bin route_old_path
route_fake_bin=$(mktemp -d)
route_old_path=$PATH
cat > "${route_fake_bin}/curl" <<'ZSH'
#!/usr/bin/env zsh
print -n -- 200
ZSH
chmod +x "${route_fake_bin}/curl"
PATH="${route_fake_bin}:$PATH"
dhm_verify_reset
assert_ok "route verification preserves executable PATH" \
  dhm_verify_route https://example.com /about/
PATH=$route_old_path
rm -rf -- "$route_fake_bin"

# ---- CI helpers --------------------------------------------------------------

assert_eq "pnpm cache" '"pnpm"' "$(dhm_ci_node_cache pnpm)"
assert_eq "npm cache"  '"npm"'  "$(dhm_ci_node_cache npm)"
assert_eq "bun has no setup-node cache" "" "$(dhm_ci_node_cache bun)"
assert_eq "unknown pm has no cache"     "" "$(dhm_ci_node_cache cargo)"

assert_eq "command passed through" "pnpm build" "$(dhm_ci_step_command 'pnpm build' build)"
assert_contains "empty command becomes a no-op" "$(dhm_ci_step_command '' build)" "no build step"

# ---- repo slug parsing -------------------------------------------------------

local repo; repo="${tmp}/slugrepo"
mkdir -p "$repo" && git -C "$repo" init -q 2>/dev/null

git -C "$repo" remote add origin 'git@github.com:amit-t/amittiwari-me.git' 2>/dev/null
assert_eq "ssh remote" "amit-t/amittiwari-me" "$(dhm_ci_repo_slug "$repo")"

git -C "$repo" remote set-url origin 'git@github.com-at:amit-t/amittiwari-me.git'
assert_eq "ssh host alias remote" "amit-t/amittiwari-me" "$(dhm_ci_repo_slug "$repo")"

git -C "$repo" remote set-url origin 'https://github.com/amit-t/amittiwari-me.git'
assert_eq "https remote" "amit-t/amittiwari-me" "$(dhm_ci_repo_slug "$repo")"

git -C "$repo" remote set-url origin 'https://github.com/amit-t/amittiwari-me'
assert_eq "https remote without .git" "amit-t/amittiwari-me" "$(dhm_ci_repo_slug "$repo")"

# ---- generated workflow: the publisher install must be non-interactive -------
# Regression: the first real deployment run failed with "publish.sh not found"
# because `npx skills add` without --yes/--global prompts for target agents,
# and a runner has no TTY to answer with.

local tpl
tpl=$(<"$(dhm_test_daemon_dir)/templates/deploy-here-now.yml")
assert_contains "installer passes --yes"    "$tpl" "--yes --global"
assert_contains "install step asserts the publisher exists" "$tpl" "publisher missing at"

# The bare form must not survive anywhere in the template.
local bare
bare=$(print -r -- "$tpl" | grep -c 'skills add heredotnow/skill --skill here-now$' || true)
assert_eq "no bare interactive install remains" "0" "$bare"

report
