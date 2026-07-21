#!/usr/bin/env zsh
# Agent selection: every launcher the user asked to support must resolve, by
# both its logical name and its raw command name.
set -u
source "${0:A:h}/harness.zsh"
dhm_test_lib common transform

# ---- launcher resolution -----------------------------------------------------

assert_eq "claude -> co"        "co"    "$(dhm_agent_launcher claude)"
assert_eq "co -> co"            "co"    "$(dhm_agent_launcher co)"
assert_eq "opus -> co"          "co"    "$(dhm_agent_launcher opus)"
assert_eq "cf -> cf"            "cf"    "$(dhm_agent_launcher cf)"
assert_eq "claude-fable -> cf"  "cf"    "$(dhm_agent_launcher claude-fable)"
assert_eq "fable -> cf"         "cf"    "$(dhm_agent_launcher fable)"
assert_eq "codex -> cxscb"      "cxscb" "$(dhm_agent_launcher codex)"
assert_eq "cxscb -> cxscb"      "cxscb" "$(dhm_agent_launcher cxscb)"
assert_eq "devin -> dey"        "dey"   "$(dhm_agent_launcher devin)"
assert_eq "dey -> dey"          "dey"   "$(dhm_agent_launcher dey)"
assert_eq "empty defaults to co" "co"   "$(dhm_agent_launcher '')"

# Case folding, because a user typing --agent Codex should not get an error.
assert_eq "CODEX folds"         "cxscb" "$(dhm_agent_launcher CODEX)"

# An unknown agent must fail loudly rather than silently defaulting.
assert_fails "unknown agent rejected" dhm_agent_launcher gpt5
local out
out=$(dhm_agent_launcher nonsense 2>&1)
assert_contains "unknown agent lists valid options" "$out" "codex (cxscb)"

# ---- canonical names ---------------------------------------------------------

assert_eq "canonical co"    "claude"       "$(dhm_agent_canonical co)"
assert_eq "canonical cf"    "claude-fable" "$(dhm_agent_canonical cf)"
assert_eq "canonical cxscb" "codex"        "$(dhm_agent_canonical cxscb)"
assert_eq "canonical dey"   "devin"        "$(dhm_agent_canonical dey)"
assert_fails "canonical rejects unknown"   dhm_agent_canonical bogus

# ---- environment overrides ---------------------------------------------------

DHM_LAUNCHER_CODEX="my-codex --flag"
assert_eq "codex override honoured" "my-codex --flag" "$(dhm_agent_launcher codex)"
unset DHM_LAUNCHER_CODEX

DHM_LAUNCHER="custom-default"
assert_eq "default override honoured" "custom-default" "$(dhm_agent_launcher '')"
unset DHM_LAUNCHER

# ---- prompt rendering --------------------------------------------------------

local vars rendered
vars=$(jq -n '{REPO:"/tmp/example", SITE:"example", DOMAIN:"example.com",
               BRANCH:"migrate/here-now", FRAMEWORK:"nextjs", PACKAGE_MANAGER:"pnpm",
               OUTPUT_DIR:"out", STATIC_RECIPE:"set output export",
               SERVER_COUPLING:"  - dependency:mongoose",
               SUBSCRIBE_CANDIDATES:"  - src/Footer.tsx",
               SUBSCRIBE_PROVIDER:"substack",
               SUBSCRIBE_URL:"https://example.substack.com/subscribe",
               INSTALL_COMMAND:"pnpm install", BUILD_COMMAND:"pnpm build"}')
rendered=$(dhm_transform_render_prompt "$(dhm_test_daemon_dir)" "$vars")

assert_contains "prompt has domain"    "$rendered" "example.com"
assert_contains "prompt has outdir"    "$rendered" "out"
assert_contains "prompt has provider"  "$rendered" "substack"
assert_contains "prompt has sub url"   "$rendered" "https://example.substack.com/subscribe"
assert_contains "prompt has coupling"  "$rendered" "dependency:mongoose"
assert_contains "prompt has handback"  "$rendered" "dhm continue --site example"
assert_contains "prompt includes common rules" "$rendered" "Do not, under any circumstances"

# Every placeholder must be substituted; a leftover {{VAR}} means the agent is
# reading a template instead of instructions.
assert_not_contains "no leftover placeholders" "$rendered" "{{"

# The boundary the agent must not cross has to survive template rendering.
assert_contains "forbids doctl deletes"  "$rendered" "doctl databases delete"
assert_contains "forbids link creation"  "$rendered" "POST /api/v1/links"
assert_contains "forbids credential read" "$rendered" "~/.herenow/credentials"

# ---- launch is inspectable without executing ---------------------------------

DHM_PRINT_LAUNCHER=1
assert_eq "launch prints launcher" "co" "$(dhm_transform_launch co 'prompt text')"
unset DHM_PRINT_LAUNCHER

DHM_PRINT_PROMPT=1
assert_eq "launch prints prompt" "prompt text" "$(dhm_transform_launch co 'prompt text')"
unset DHM_PRINT_PROMPT

report
