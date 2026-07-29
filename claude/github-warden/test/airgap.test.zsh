#!/usr/bin/env zsh
# ghw airgap — Change 1 (cross-account guard), Change 2 (user_namespace
# resolution), Change 3 (config-overlap invariant). Hermetic: stubbed gh +
# curl, no network.
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
ghw_bin="${daemon_dir}/bin/ghw"
source "${daemon_dir}/lib/auth.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log" GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
export GHW_GH="zsh ${script_dir}/fixtures/gh-stub.zsh"
export GHW_GH_STUB_TOKEN="" GHW_GH_STUB_LOG="${work}/gh-log"
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{
  "personal":{"token_env":"T_P","login":"amit-t","user_namespace":"amit-t","orgs":["PersonalOrg"]},
  "inv":{"token_env":"T_I","login":"amit_vnt","user_namespace":"amit_vnt_ns","orgs":["INVENCO-GROUP"]}
}}
JSON
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=200; RESP_BODY='{}'; RESP_HEADERS=''; }
EOF
export T_P="tokp" T_I="toki"

# ---- Change 1: explicit account + cross-account target is a hard local refusal
out=$(ghw_resolve_profile "personal" "INVENCO-GROUP" 2>&1); rc=$?
assert_exit "cross-account org refused" 2 $rc
assert_contains "message is ACCOUNT_MISMATCH" "$out" "ACCOUNT_MISMATCH"
assert_contains "message names owning profile inv" "$out" "belongs to profile 'inv'"
assert_contains "message names explicit profile" "$out" "not 'personal'"
assert_contains "message suggests rerun" "$out" "rerun with --account inv"

out=$(ghw_resolve_profile "personal" "PersonalOrg" 2>&1); rc=$?
assert_exit "same-account target allowed" 0 $rc
assert_eq "resolves to personal" "personal" "$out"

out=$(ghw_resolve_profile "personal" "" 2>&1); rc=$?
assert_exit "explicit account with no target still works" 0 $rc
assert_eq "resolves to personal (no target)" "personal" "$out"

out=$(ghw_resolve_profile "personal" "no-such-org" 2>&1); rc=$?
assert_exit "unmapped target under explicit account refused" 2 $rc
assert_contains "unmapped message is ACCOUNT_MISMATCH" "$out" "ACCOUNT_MISMATCH"
assert_contains "unmapped message names no profile" "$out" "not mapped to profile 'personal' (or any profile)"

# ---- Change 2: user_namespace is matched like orgs[], both directions
out=$(ghw_resolve_profile "" "amit-t" 2>&1); rc=$?
assert_exit "user_namespace auto-maps" 0 $rc
assert_eq "auto-maps to personal via user_namespace" "personal" "$out"

out=$(ghw_resolve_profile "inv" "amit_vnt_ns" 2>&1); rc=$?
assert_exit "explicit + own user_namespace allowed" 0 $rc
assert_eq "resolves to inv" "inv" "$out"

out=$(ghw_resolve_profile "personal" "amit_vnt_ns" 2>&1); rc=$?
assert_exit "explicit + other profile's user_namespace refused" 2 $rc
assert_contains "user_namespace clash names inv" "$out" "belongs to profile 'inv'"

# ---- End-to-end via bin/ghw: guard fires before any network call ----------
: > "$GHW_STUB_LOG"
out=$(zsh "$ghw_bin" --account personal status --org INVENCO-GROUP 2>&1); rc=$?
assert_exit "cli refuses cross-account status" 2 $rc
assert_contains "cli message is ACCOUNT_MISMATCH" "$out" "ACCOUNT_MISMATCH"
assert_eq "zero API calls hit the network stub" "" "$(<$GHW_STUB_LOG)"

# ---- Change 3: config-overlap invariant ------------------------------------
overlap_file="${work}/overlap.json"
cat > "$overlap_file" <<'JSON'
{"profiles":{
  "personal":{"token_env":"T_P","login":"amit-t","orgs":["Shared","PersonalOnly"]},
  "inv":{"token_env":"T_I","login":"amit_vnt","orgs":["Shared"]}
}}
JSON
export GHW_ACCOUNTS_FILE="$overlap_file"
out=$(ghw_check_airgap 2>&1); rc=$?
assert_exit "ghw_check_airgap fails on overlap" 2 $rc
assert_contains "overlap message tag" "$out" "ACCOUNT_OVERLAP"
assert_contains "overlap names the org" "$out" "'Shared'"
assert_contains "overlap names both profiles" "$out" "profiles personal and inv"

out=$(ghw_resolve_profile "" "PersonalOnly" 2>&1); rc=$?
assert_exit "resolve_profile refuses on any overlap, even unrelated target" 2 $rc
assert_contains "resolve_profile surfaces overlap message" "$out" "ACCOUNT_OVERLAP"

rm -rf "$work"
report
