#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/auth.zsh"

fixture=$(mktemp)
cat > "$fixture" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","orgs":["amit-t"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP","Invenco-Cloud-Systems-ICS"]}}}
JSON
export GHW_ACCOUNTS_FILE="$fixture"

out=$(ghw_resolve_profile "inv" ""); rc=$?
assert_exit "explicit account ok" 0 $rc
assert_eq "explicit account wins" "inv" "$out"

out=$(ghw_resolve_profile "" "INVENCO-GROUP"); rc=$?
assert_exit "org map ok" 0 $rc
assert_eq "org maps to inv" "inv" "$out"

out=$(ghw_resolve_profile "" "amit-t"); rc=$?
assert_eq "owner maps to personal" "personal" "$out"

out=$(ghw_resolve_profile "" "unknown-org" 2>&1); rc=$?
assert_exit "unmapped org fails" 2 $rc
assert_contains "unmapped names orgs" "$out" "INVENCO-GROUP"

out=$(ghw_resolve_profile "nope" "" 2>&1); rc=$?
assert_exit "unknown profile fails" 2 $rc

export T_I="tok123"
unset GHW_TOKEN GHW_TOKEN_ENV_NAME 2>/dev/null
ghw_token_for "inv"; rc=$?
assert_exit "token resolves" 0 $rc
assert_eq "token exported" "tok123" "${GHW_TOKEN:-}"
assert_eq "token env name recorded" "T_I" "${GHW_TOKEN_ENV_NAME:-}"

unset T_P
out=$(ghw_token_for "personal" 2>&1); rc=$?
assert_exit "missing token fails" 2 $rc
assert_contains "missing token names env var" "$out" "T_P"

out=$(ghw_profile_login "inv")
assert_eq "login lookup" "amit_vnt" "$out"

rm -f "$fixture"
report
