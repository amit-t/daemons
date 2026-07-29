#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
ghw_bin="${script_dir}/../bin/ghw"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log" GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","orgs":["amit-t"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}
JSON
export T_P="tokp"; unset T_I 2>/dev/null
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit-t"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' ;;
    */orgs/amit-t/memberships/amit-t) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=404; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" doctor 2>&1); rc=$?
assert_exit "doctor exit 1 when a profile is broken" 1 $rc
assert_contains "healthy token" "$out" "profile personal: token=ok"
assert_contains "healthy role" "$out" "org amit-t: role=admin"
assert_contains "missing token flagged" "$out" "profile inv: token=MISSING"
assert_not_contains "no writes" "$(<$GHW_STUB_LOG)" "PUT "

rm -rf "$work"
report
