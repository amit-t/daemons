#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$GHW_ACCOUNTS_FILE"
# Token value must never appear in any assembled prompt. Keep it distinctive:
# a generic value like "tok" false-positives on prose that mentions "token".
export T_I="hushp4ss" GHW_DRY_LAUNCH=1
# Hermetic: stub gh (empty-token mode) so ghw_token_for's gh-primary path
# never shells out to a real gh binary — forces the env-var fallback this
# test already relies on.
export GHW_GH="zsh ${script_dir}/fixtures/gh-stub.zsh" GHW_GH_STUB_TOKEN=""

csv="${work}/s.csv"; print -rl -- "login" "a_vnt" > "$csv"
out=$(zsh "$ghw_bin" import --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "import dry launch ok" 0 $rc
assert_contains "common policy included" "$out" "github-warden common policy"
assert_contains "import playbook included" "$out" "ghw import playbook"
assert_contains "engine command in context" "$out" "import-engine.zsh --org INVENCO-GROUP --team ppna"
assert_not_contains "token never in prompt" "$out" "hushp4ss"

out=$(zsh "$ghw_bin" mirror INVENCO-GROUP/some-repo 2>&1); rc=$?
assert_exit "mirror dry launch ok" 0 $rc
assert_contains "mirror playbook included" "$out" "ghw mirror playbook"
assert_contains "target in context" "$out" "INVENCO-GROUP/some-repo"

# SSH-form explicit target: owner resolution + downstream normalization must
# strip git@github.com: and .git, not just the https:// prefix. Check the
# specific "reference target:" run-context line (the playbook body itself
# legitimately mentions git@github.com: as SSH-remote example text, so a
# whole-output substring check would false-positive on that).
out=$(zsh "$ghw_bin" mirror git@github.com:INVENCO-GROUP/some-repo.git 2>&1); rc=$?
assert_exit "mirror ssh-form dry launch ok" 0 $rc
assert_contains "ssh-form target normalized in context" "$out" "reference target: INVENCO-GROUP/some-repo"
assert_not_contains "ssh-form context line has no git@ prefix" "$out" "reference target: git@"
assert_not_contains "ssh-form context line has no .git suffix" "$out" "reference target: INVENCO-GROUP/some-repo.git"

# https-form explicit target with a .git suffix: also normalized.
out=$(zsh "$ghw_bin" mirror https://github.com/INVENCO-GROUP/some-repo.git 2>&1); rc=$?
assert_exit "mirror https-form dry launch ok" 0 $rc
assert_contains "https-form target normalized in context" "$out" "reference target: INVENCO-GROUP/some-repo"
assert_not_contains "https-form context line has no .git suffix" "$out" "reference target: INVENCO-GROUP/some-repo.git"

# Missing --csv (agent mode): launches an interview playbook instead of failing.
out=$(zsh "$ghw_bin" import --org INVENCO-GROUP 2>&1); rc=$?
assert_exit "import without csv launches interview" 0 $rc
assert_contains "interview names missing csv" "$out" "missing inputs: --csv"
assert_contains "interview keeps resolved profile" "$out" "account profile: inv"
assert_contains "interview has engine template" "$out" "bin/ghw import --org <org> --csv <file>"
assert_not_contains "interview never leaks token" "$out" "hushp4ss"

# Bare import (no flags): interview must cover org + csv, no token resolved yet.
out=$(zsh "$ghw_bin" import 2>&1); rc=$?
assert_exit "bare import launches interview" 0 $rc
assert_contains "interview names missing org and csv" "$out" "missing inputs: --org --csv"
assert_contains "interview defers credential to re-entry" "$out" "credential: not resolved yet"

# --script bypasses the agent, so it still hard-requires org + csv.
out=$(zsh "$ghw_bin" import --org INVENCO-GROUP --script 2>&1); rc=$?
assert_exit "import --script without csv exits 2" 2 $rc
assert_contains "import --script names requirement" "$out" "--org and --csv are required"

# Default launcher is co (interactive function, resolved via zsh -ic at exec).
out=$(GHW_PRINT_LAUNCHER=1 zsh "$ghw_bin" import --org INVENCO-GROUP --csv "$csv" 2>&1); rc=$?
assert_exit "print-launcher ok" 0 $rc
assert_eq "default launcher is co" "co" "$out"
out=$(GHW_PRINT_LAUNCHER=1 GHW_LAUNCHER=cf zsh "$ghw_bin" import --org INVENCO-GROUP --csv "$csv" 2>&1); rc=$?
assert_eq "GHW_LAUNCHER override wins" "cf" "$out"

# --org as the trailing arg with no value must exit 2 immediately, not loop
# forever on a `shift 2` with only 1 arg left (zsh errors without shifting).
out=$(zsh "$ghw_bin" import --org 2>&1); rc=$?
assert_exit "import trailing --org exits 2 (no hang)" 2 $rc
assert_contains "import trailing --org names the flag" "$out" "--org requires a value"

# --script must export GH_TOKEN/GITHUB_TOKEN before handing off to the
# gh-repo-mirror skill script, which authenticates via the gh CLI reading
# those env vars — separate from the GHW_DRY_LAUNCH prompt assertions above.
fake_home=$(mktemp -d)
mkdir -p "${fake_home}/.claude/skills/gh-repo-mirror/scripts"
cat > "${fake_home}/.claude/skills/gh-repo-mirror/scripts/mirror-repo.zsh" <<'EOF'
#!/usr/bin/env zsh
print -r -- "GH_TOKEN=${GH_TOKEN:-} GITHUB_TOKEN=${GITHUB_TOKEN:-} ARGS=$*"
exit 0
EOF

out=$(HOME="$fake_home" zsh "$ghw_bin" mirror INVENCO-GROUP/some-repo --script --new-repo X 2>&1); rc=$?
assert_exit "mirror --script launch ok" 0 $rc
assert_contains "mirror --script exports GH_TOKEN" "$out" "GH_TOKEN=hushp4ss"
assert_contains "mirror --script exports GITHUB_TOKEN" "$out" "GITHUB_TOKEN=hushp4ss"
assert_contains "mirror --script passes ref-repo" "$out" "--ref-repo INVENCO-GROUP/some-repo"

# A trailing boolean passthrough flag (no value after it) must not hang the
# arg loop (zsh's `shift 2` errors without shifting when only 1 arg is left).
out=$(HOME="$fake_home" zsh "$ghw_bin" mirror INVENCO-GROUP/some-repo --script --lone-flag 2>&1); rc=$?
assert_exit "mirror trailing lone flag completes (no hang)" 0 $rc
assert_contains "mirror trailing lone flag reaches ARGS" "$out" "--lone-flag"

rm -rf "$work" "$fake_home"
report
