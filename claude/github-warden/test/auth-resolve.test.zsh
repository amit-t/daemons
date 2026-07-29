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

# ---- ghw_token_for: gh keyring primary, env fallback ----------------------
gh_stub="${script_dir}/fixtures/gh-stub.zsh"
gh_log=$(mktemp)
export GHW_GH="zsh ${gh_stub}"
export GHW_GH_STUB_LOG="$gh_log"

# gh stub returns a token -> GHW_TOKEN set from gh, source starts "gh:"
export T_I="tok123"
unset GHW_TOKEN GHW_TOKEN_ENV_NAME GHW_TOKEN_SOURCE 2>/dev/null
export GHW_GH_STUB_TOKEN="ghtok456"
: > "$gh_log"
ghw_token_for "inv"; rc=$?
assert_exit "gh-sourced token resolves" 0 $rc
assert_eq "token exported from gh" "ghtok456" "${GHW_TOKEN:-}"
assert_eq "token env name still recorded" "T_I" "${GHW_TOKEN_ENV_NAME:-}"
assert_contains "token source is gh:<login>" "${GHW_TOKEN_SOURCE:-}" "gh:"
assert_contains "gh stub received --user <login>" "$(<$gh_log)" "--user amit_vnt"

# gh stub returns empty AND env var set -> falls back to env, source env:
unset GHW_TOKEN GHW_TOKEN_ENV_NAME GHW_TOKEN_SOURCE 2>/dev/null
export GHW_GH_STUB_TOKEN=""
ghw_token_for "inv"; rc=$?
assert_exit "env-fallback token resolves" 0 $rc
assert_eq "token exported from env" "tok123" "${GHW_TOKEN:-}"
assert_eq "token env name recorded" "T_I" "${GHW_TOKEN_ENV_NAME:-}"
assert_eq "token source is env:<VAR>" "env:T_I" "${GHW_TOKEN_SOURCE:-}"

# gh stub empty and no env -> rc 2, message names both remediations
unset T_P GHW_TOKEN GHW_TOKEN_ENV_NAME GHW_TOKEN_SOURCE 2>/dev/null
export GHW_GH_STUB_TOKEN=""
out=$(ghw_token_for "personal" 2>&1); rc=$?
assert_exit "no credential fails" 2 $rc
assert_contains "no-credential message suggests gh auth login" "$out" "gh auth login"
assert_contains "no-credential message names env var" "$out" "T_P"

# no gh on PATH at all (override points at a nonexistent path) -> env fallback
unset GHW_TOKEN GHW_TOKEN_ENV_NAME GHW_TOKEN_SOURCE 2>/dev/null
export T_P="tokp789"
export GHW_GH="/no/such/gh-binary-anywhere"
ghw_token_for "personal"; rc=$?
assert_exit "no gh on path falls back to env" 0 $rc
assert_eq "token exported from env when gh absent" "tokp789" "${GHW_TOKEN:-}"
assert_eq "token source is env: when gh absent" "env:T_P" "${GHW_TOKEN_SOURCE:-}"
unset GHW_GH GHW_GH_STUB_LOG GHW_GH_STUB_TOKEN

out=$(ghw_profile_login "inv")
assert_eq "login lookup" "amit_vnt" "$out"

rm -f "$fixture" "$gh_log"
report
