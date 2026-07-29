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
# Hermetic: point GHW_GH at a stub so doctor never shells out to a real gh.
export GHW_GH="zsh ${script_dir}/fixtures/gh-stub.zsh"
export GHW_GH_STUB_TOKEN="" GHW_GH_STUB_LOG="${work}/gh-log"

# ---- Block A: a broken profile (missing token) fails doctor, credential-side.
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","user_namespace":"amit-t","orgs":["amit-t-org"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}
JSON
export T_P="tokp"; unset T_I 2>/dev/null
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */user) RESP_STATUS=200; RESP_BODY='{"login":"amit-t"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' ;;
    */orgs/amit-t-org/memberships/amit-t) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=404; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" doctor 2>&1); rc=$?
assert_exit "doctor exit 1 when a profile is broken" 1 $rc
assert_contains "healthy token names source" "$out" "profile personal: token=ok(env:T_P)"
assert_contains "healthy role" "$out" "org amit-t-org: role=admin"
assert_contains "missing token flagged" "$out" "profile inv: token=MISSING (gh auth login, or export T_I)"
assert_contains "user_namespace line printed, not probed as an org" "$out" "  user amit-t: own namespace"
assert_not_contains "user_namespace never probed as an org" "$out" "org amit-t: role="
assert_contains "personal summary line" "$out" "summary: admin on 1/1 orgs"
assert_not_contains "no writes" "$(<$GHW_STUB_LOG)" "PUT "

# ---- Block B: both profiles fully healthy, one org member-only (not admin).
# Doctor is credential-only by default: member-only orgs are informational,
# so this must exit 0. --strict additionally requires org-admin everywhere,
# so it must exit 1 on the same fixture.
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","orgs":["OrgAdmin","OrgMember"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}
JSON
export T_P="tokp" T_I="toki"
# The curl stub routes purely on URL (it doesn't parse the Authorization
# header), and both profiles hit the same `/user` endpoint — so distinguish
# calls with a stateful counter: doctor iterates `jq keys`, which sorts
# alphabetically ("inv" before "personal"), so the first /user call is inv's.
call_count_file="${work}/user_call_count"
print -rn -- "0" > "$call_count_file"
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  case "\$2" in
    */user)
      n=\$(<"$call_count_file")
      if (( n == 0 )); then
        RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo'
      else
        RESP_STATUS=200; RESP_BODY='{"login":"amit-t"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo'
      fi
      print -rn -- \$((n+1)) > "$call_count_file"
      ;;
    */orgs/INVENCO-GROUP/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    */orgs/OrgAdmin/memberships/amit-t) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    */orgs/OrgMember/memberships/amit-t) RESP_STATUS=200; RESP_BODY='{"role":"member"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=404; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" doctor 2>&1); rc=$?
assert_exit "doctor exits 0 with a healthy member-only org present" 0 $rc
assert_contains "member-only org still reported" "$out" "org OrgMember: role=member"
assert_contains "summary line shows partial admin + member-only list" "$out" "summary: admin on 1/2 orgs (member-only: OrgMember)"

print -rn -- "0" > "$call_count_file"
out=$(zsh "$ghw_bin" doctor --strict 2>&1); rc=$?
assert_exit "doctor --strict fails on the same member-only fixture" 1 $rc

# ---- Block C: config overlap always fails doctor, both modes.
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{"personal":{"token_env":"T_P","login":"amit-t","orgs":["Shared"]},
"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["Shared"]}}}
JSON
out=$(zsh "$ghw_bin" doctor 2>&1); rc=$?
assert_exit "doctor exits 1 on overlapping config" 1 $rc
assert_contains "overlap message surfaced in doctor" "$out" "ACCOUNT_OVERLAP"

out=$(zsh "$ghw_bin" doctor --strict 2>&1); rc=$?
assert_exit "doctor --strict also exits 1 on overlapping config" 1 $rc
assert_contains "overlap message surfaced in doctor --strict" "$out" "ACCOUNT_OVERLAP"


# ---- Block D: zsh loop-body-local regression guard.
# Two profiles, BOTH with a `user_namespace` set and at least one member-only
# org each — this exercises the profile for-loop and its inner org for-loop
# across MORE THAN ONE iteration with non-empty prior values in scope. A bare
# `local var` (no assignment on the same statement) re-executed on a later
# iteration, with the variable already holding a value from a prior
# iteration, makes zsh print `var=<value>` to stdout as a side effect of the
# redeclaration — this is exactly what happened with `user_ns` before it was
# hoisted out of the loop body in lib/doctor.zsh. Assert the full output is
# pristine: no such line anywhere, for either variable that was hoisted.
cat > "$GHW_ACCOUNTS_FILE" <<'JSON'
{"profiles":{"aaa":{"token_env":"T_A","login":"userA","user_namespace":"nsA","orgs":["OrgA1","OrgA2"]},
"bbb":{"token_env":"T_B","login":"userB","user_namespace":"nsB","orgs":["OrgB1"]}}}
JSON
export T_A="toka" T_B="tokb"
# jq keys sorts alphabetically, so "aaa" is the first /user call, "bbb" the second.
call_count_file="${work}/user_call_count_d"
print -rn -- "0" > "$call_count_file"
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  case "\$2" in
    */user)
      n=\$(<"$call_count_file")
      if (( n == 0 )); then
        RESP_STATUS=200; RESP_BODY='{"login":"userA"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo'
      else
        RESP_STATUS=200; RESP_BODY='{"login":"userB"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo'
      fi
      print -rn -- \$((n+1)) > "$call_count_file"
      ;;
    */orgs/OrgA1/memberships/userA) RESP_STATUS=200; RESP_BODY='{"role":"member"}'; RESP_HEADERS='' ;;
    */orgs/OrgA2/memberships/userA) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    */orgs/OrgB1/memberships/userB) RESP_STATUS=200; RESP_BODY='{"role":"member"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=404; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" doctor 2>&1); rc=$?
assert_exit "Block D: both profiles credential-healthy, member-only informational -> exit 0" 0 $rc
assert_contains "Block D: both user_namespace lines present" "$out" "  user nsA: own namespace"
assert_contains "Block D: both user_namespace lines present (bbb)" "$out" "  user nsB: own namespace"
assert_contains "Block D: aaa summary correct" "$out" "summary: admin on 1/2 orgs (member-only: OrgA1)"
assert_contains "Block D: bbb summary correct" "$out" "summary: admin on 0/1 orgs (member-only: OrgB1)"
assert_not_contains "Block D: no zsh bare-local user_ns leak anywhere in output" "$out" "user_ns="
assert_not_contains "Block D: no zsh bare-local member_only leak anywhere in output" "$out" "member_only="

rm -rf "$work"
report
