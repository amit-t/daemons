#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log" GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
# Hermetic: stub gh (empty-token mode) so ghw_token_for's gh-primary path
# never shells out to a real gh binary — forces the env-var fallback this
# test already relies on.
export GHW_GH="zsh ${script_dir}/fixtures/gh-stub.zsh" GHW_GH_STUB_TOKEN=""
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["ORG1"]}}}' > "$GHW_ACCOUNTS_FILE"
export T_I="tok"
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */orgs/ORG1/members\?*role=admin*|*/orgs/ORG1/members\?*filter=2fa_disabled*) : ;;
  esac
  case "$2" in
    */orgs/ORG1/teams/t1/members*) RESP_STATUS=200; RESP_BODY='[{"login":"alice"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/teams*) RESP_STATUS=200; RESP_BODY='[{"slug":"t1"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/members*role=admin*) RESP_STATUS=200; RESP_BODY='[{"login":"alice"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/members*2fa_disabled*) RESP_STATUS=200; RESP_BODY='[{"login":"bob"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/members*) RESP_STATUS=200; RESP_BODY='[{"login":"alice"},{"login":"bob"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1/outside_collaborators*) RESP_STATUS=200; RESP_BODY='[{"login":"contractor1"}]'; RESP_HEADERS='' ;;
    */orgs/ORG1) RESP_STATUS=200; RESP_BODY='{"login":"ORG1","public_repos":3,"total_private_repos":5,"plan":{"name":"free"}}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF

out=$(zsh "$ghw_bin" status --org ORG1 2>&1); rc=$?
assert_exit "status ok" 0 $rc
assert_contains "status line" "$out" "org ORG1: repos=8 members=2 teams=1 plan=free"

csv_out="${work}/members.csv"
out=$(zsh "$ghw_bin" members --org ORG1 --csv "$csv_out" 2>&1); rc=$?
assert_exit "members ok" 0 $rc
body=$(<"$csv_out")
assert_contains "members header" "$body" "login,org_role,teams,twofa_disabled,outside_collaborator"
assert_contains "admin row with team" "$body" "alice,admin,t1,false,false"
assert_contains "2fa flag" "$body" "bob,member,,true,false"
assert_contains "outside collab" "$body" "contractor1,,,false,true"
assert_not_contains "read-only" "$(<$GHW_STUB_LOG)" "PUT "

rm -rf "$work"
report
