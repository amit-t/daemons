#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/api.zsh"
source "${daemon_dir}/lib/auth.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log"
export GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_TOKEN="testtoken" GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
fixture="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$fixture"
export GHW_ACCOUNTS_FILE="$fixture"

all_good_routes() {
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' ;;
    */orgs/INVENCO-GROUP/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin","state":"active"}'; RESP_HEADERS='' ;;
    */orgs/INVENCO-GROUP/teams/ai-workbench-ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ai-workbench-ppna"}'; RESP_HEADERS='' ;;
    */orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
}

all_good_routes
out=$(ghw_precheck inv INVENCO-GROUP ai-workbench-ppna 2>&1); rc=$?
assert_exit "all preconditions pass" 0 $rc

# A5: classic PAT without admin:org — refuse, zero writes
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: repo, read:org' ;;
    *) RESP_STATUS=200; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
: > "$GHW_STUB_LOG"
out=$(ghw_precheck inv INVENCO-GROUP 2>&1); rc=$?
assert_exit "scope missing refuses" 5 $rc
assert_contains "scope failure named" "$out" "SCOPE_MISSING"
assert_not_contains "zero writes on refusal" "$(<$GHW_STUB_LOG)" "PUT "

# wrong login
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=200; RESP_BODY='{"login":"someone-else"}'; RESP_HEADERS='x-oauth-scopes: admin:org' }
EOF
out=$(ghw_precheck inv INVENCO-GROUP 2>&1); rc=$?
assert_exit "login mismatch refuses" 5 $rc
assert_contains "auth failure named" "$out" "AUTH_INVALID"

# not org admin (fine-grained: no scopes header → P3 is authority)
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='' ;;
    */memberships/*) RESP_STATUS=200; RESP_BODY='{"role":"member","state":"active"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(ghw_precheck inv INVENCO-GROUP 2>&1); rc=$?
assert_exit "non-admin refuses" 5 $rc
assert_contains "admin failure named" "$out" "NOT_ORG_ADMIN"

# missing team
all_good_routes
cat >> "$GHW_STUB_ROUTES" <<'EOF'
old_stub_route=$functions[stub_route]
stub_route() {
  if [[ "$2" == */teams/ghost-team ]]; then RESP_STATUS=404; RESP_BODY='{"message":"Not Found"}'; RESP_HEADERS=''
  else eval "$old_stub_route"; fi
}
EOF
out=$(ghw_precheck inv INVENCO-GROUP ghost-team 2>&1); rc=$?
assert_exit "missing team refuses" 5 $rc
assert_contains "team failure named" "$out" "TEAM_NOT_FOUND"

rm -rf "$work"
report
