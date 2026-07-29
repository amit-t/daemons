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

# ---- Case-insensitive target matching (GitHub org/user names are
# case-insensitive; comparisons must ignore case, but every message /
# returned value / downstream target keeps the caller's ORIGINAL casing).
out=$(ghw_resolve_profile "inv" "invenco-group" 2>&1); rc=$?
assert_exit "lowercase target resolves under its owning explicit account" 0 $rc
assert_eq "resolves to inv" "inv" "$out"

out=$(ghw_resolve_profile "personal" "INVENCO-group" 2>&1); rc=$?
assert_exit "mixed-case cross-account target still refused" 2 $rc
assert_contains "mismatch message keeps caller's original casing" "$out" "'INVENCO-group' belongs to profile 'inv'"

out=$(ghw_resolve_profile "" "iNvEnCo-GrOuP" 2>&1); rc=$?
assert_exit "auto-map is case-insensitive" 0 $rc
assert_eq "auto-map resolves to inv regardless of case" "inv" "$out"

out=$(ghw_resolve_profile "" "AMIT-T" 2>&1); rc=$?
assert_exit "user_namespace auto-map is case-insensitive" 0 $rc
assert_eq "resolves to personal via uppercase user_namespace" "personal" "$out"

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
assert_contains "overlap names both profiles (uniform join)" "$out" "profiles personal, inv"

out=$(ghw_resolve_profile "" "PersonalOnly" 2>&1); rc=$?
assert_exit "resolve_profile refuses on any overlap, even unrelated target" 2 $rc
assert_contains "resolve_profile surfaces overlap message" "$out" "ACCOUNT_OVERLAP"

# 3+-profile overlap: the join must list every profile, not just the first two.
overlap3_file="${work}/overlap3.json"
cat > "$overlap3_file" <<'JSON'
{"profiles":{
  "p1":{"token_env":"T1","login":"l1","orgs":["Shared3"]},
  "p2":{"token_env":"T2","login":"l2","orgs":["Shared3"]},
  "p3":{"token_env":"T3","login":"l3","orgs":["Shared3"]}
}}
JSON
export GHW_ACCOUNTS_FILE="$overlap3_file"
out=$(ghw_check_airgap 2>&1); rc=$?
assert_exit "ghw_check_airgap fails on 3-way overlap" 2 $rc
assert_contains "3-way overlap names all three profiles uniformly" "$out" "profiles p1, p2, p3"

# Case-variant collision (same org under two profiles differing only in
# case) IS an air-gap violation — the check must be case-insensitive too.
overlap_case_file="${work}/overlap-case.json"
cat > "$overlap_case_file" <<'JSON'
{"profiles":{
  "personal":{"token_env":"T_P","login":"amit-t","orgs":["CaseOrg"]},
  "inv":{"token_env":"T_I","login":"amit_vnt","orgs":["CASEORG"]}
}}
JSON
export GHW_ACCOUNTS_FILE="$overlap_case_file"
out=$(ghw_check_airgap 2>&1); rc=$?
assert_exit "case-variant collision is caught as an overlap" 2 $rc
assert_contains "case-variant overlap message tagged" "$out" "ACCOUNT_OVERLAP"

rm -rf "$work"
report
