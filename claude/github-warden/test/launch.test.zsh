#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$GHW_ACCOUNTS_FILE"
export T_I="tok" GHW_DRY_LAUNCH=1

csv="${work}/s.csv"; print -rl -- "login" "a_vnt" > "$csv"
out=$(zsh "$ghw_bin" import --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "import dry launch ok" 0 $rc
assert_contains "common policy included" "$out" "github-warden common policy"
assert_contains "import playbook included" "$out" "ghw import playbook"
assert_contains "engine command in context" "$out" "import-engine.zsh --org INVENCO-GROUP --team ppna"
assert_not_contains "token never in prompt" "$out" "tok"

out=$(zsh "$ghw_bin" mirror INVENCO-GROUP/some-repo 2>&1); rc=$?
assert_exit "mirror dry launch ok" 0 $rc
assert_contains "mirror playbook included" "$out" "ghw mirror playbook"
assert_contains "target in context" "$out" "INVENCO-GROUP/some-repo"

out=$(zsh "$ghw_bin" import --org INVENCO-GROUP 2>&1); rc=$?
assert_exit "import without csv exits 2" 2 $rc

rm -rf "$work"
report
