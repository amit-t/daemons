#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
engine="${daemon_dir}/lib/import-engine.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log"
export GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_STATE_DIR="${work}/state"
export GHW_API_ROOT="https://api.github.example" GHW_SLEEP=":"
export T_I="tok"
export GHW_ACCOUNTS_FILE="${work}/accounts.json"
print -r -- '{"profiles":{"inv":{"token_env":"T_I","login":"amit_vnt","orgs":["INVENCO-GROUP"]}}}' > "$GHW_ACCOUNTS_FILE"

csv="${work}/src.csv"

# Routes: org has amit_vnt (the caller — required by the engine's post-fetch
# invariant: the authenticated login must appear in the org member list)
# +owner1+existing1; team has maint1. PUTs echo membership JSON. ghost_vnt
# 404s on org PUT. Org/team member lists re-read includes adds (stub keeps
# it simple: after any PUT for login X, member lists include X via state file).
base_routes() {
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  local added="${work}/added"
  case "\$1 \$2" in
    "GET "*/user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org' ;;
    "GET "*/orgs/INVENCO-GROUP/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna/members*)
      local extra=""
      [[ -f "\$added" ]] && extra=\$(awk '/^team /{printf ",{\"login\":\"%s\"}", \$2}' "\$added")
      RESP_STATUS=200; RESP_BODY="[{\"login\":\"maint1_vnt\"}\${extra}]"; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ppna"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/members*)
      local extra=""
      [[ -f "\$added" ]] && extra=\$(awk '/^org /{printf ",{\"login\":\"%s\"}", \$2}' "\$added")
      RESP_STATUS=200; RESP_BODY="[{\"login\":\"amit_vnt\"},{\"login\":\"owner1_vnt\"},{\"login\":\"existing1_vnt\"}\${extra}]"; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    "PUT "*/orgs/INVENCO-GROUP/memberships/ghost_vnt) RESP_STATUS=404; RESP_BODY='{"message":"Not Found"}'; RESP_HEADERS='' ;;
    "PUT "*/orgs/INVENCO-GROUP/memberships/*)
      print -r -- "org \${2##*/}" >> "\$added"
      RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member"}'; RESP_HEADERS='' ;;
    "PUT "*/orgs/INVENCO-GROUP/teams/ppna/memberships/*)
      print -r -- "team \${2##*/}" >> "\$added"
      RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
}

# A6 dry-run: zero writes, would_add rows
base_routes; : > "$GHW_STUB_LOG"; rm -f "${work}/added"
print -rl -- "login" "newuser_vnt" "owner1_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" --dry-run 2>&1); rc=$?
assert_exit "A6 dry-run exit" 0 $rc
assert_not_contains "A6 zero writes" "$(<$GHW_STUB_LOG)" "PUT "
rdir=$(print -r -- "$out" | awk '/^report: /{print $2}')
assert_contains "A6 would_add row" "$(<${rdir}/report.csv)" "newuser_vnt,org,would_add"

# A2+A3+A7+A4: live run — owner/maintainer untouched, phases ordered, 404 continues
base_routes; : > "$GHW_STUB_LOG"; rm -f "${work}/added"
print -rl -- "login" "newuser_vnt" "owner1_vnt" "maint1_vnt" "ghost_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "live run completed_with_errors (ghost)" 1 $rc
log=$(<$GHW_STUB_LOG)
assert_not_contains "A2 no org PUT for owner" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/memberships/owner1_vnt"
assert_contains "owner still gets team PUT" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/teams/ppna/memberships/owner1_vnt"
assert_not_contains "A3 no team PUT for maintainer" "$log" "teams/ppna/memberships/maint1_vnt"
assert_contains "new user org PUT" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/memberships/newuser_vnt"
assert_contains "new user team PUT" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/teams/ppna/memberships/newuser_vnt"
org_line=$(grep -n "PUT .*memberships/newuser_vnt" <<< "$log" | grep -v teams | cut -d: -f1 | head -1)
team_line=$(grep -n "PUT .*teams/ppna/memberships/newuser_vnt" <<< "$log" | cut -d: -f1 | head -1)
if (( org_line < team_line )); then _ok; else _fail "A7: org PUT must precede team PUT"; fi
rdir=$(print -r -- "$out" | awk '/^report: /{print $2}')
rcsv=$(<${rdir}/report.csv)
assert_contains "A4 ghost not_found" "$rcsv" "ghost_vnt,org,not_found"
assert_contains "A4 batch continued" "$rcsv" "newuser_vnt,org,added"
assert_contains "owner skipped row" "$rcsv" "owner1_vnt,org,skipped"
assert_contains "summary counts" "$out" "org: 3 -> 5 (+2)"

# A1 idempotent re-run: everyone already present → zero PUTs, all skipped, exit 0
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$1 $2" in
    "GET "*/user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org' ;;
    "GET "*/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    "GET "*/teams/ppna/members*) RESP_STATUS=200; RESP_BODY='[{"login":"newuser_vnt"},{"login":"maint1_vnt"}]'; RESP_HEADERS='' ;;
    "GET "*/teams/ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ppna"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/members*) RESP_STATUS=200; RESP_BODY='[{"login":"amit_vnt"},{"login":"newuser_vnt"},{"login":"maint1_vnt"}]'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
: > "$GHW_STUB_LOG"
print -rl -- "login" "newuser_vnt" "maint1_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
assert_exit "A1 re-run exit 0" 0 $rc
assert_not_contains "A1 zero writes" "$(<$GHW_STUB_LOG)" "PUT "

# Guarded read: org members GET 500s (retries exhausted) → engine must
# refuse to write anything rather than treat an unreadable list as "empty,
# everyone is new". Zero PUTs, non-zero exit.
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$1 $2" in
    "GET "*/user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org' ;;
    "GET "*/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ppna"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/members*) RESP_STATUS=500; RESP_BODY='{"message":"boom"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
: > "$GHW_STUB_LOG"
print -rl -- "login" "newuser_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "member-list read failure: expected non-zero exit, got 0"; fi
assert_not_contains "member-list read failure zero writes" "$(<$GHW_STUB_LOG)" "PUT "

# Guarded read variant: TEAM members GET returns 200 with a malformed
# (non-array) body. ghw_api_paged must propagate this as a failure rather
# than returning rc 0 with empty output, or the team-phase set-difference
# would treat every CSV login as new and upsert-PUT existing maintainers.
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$1 $2" in
    "GET "*/user) RESP_STATUS=200; RESP_BODY='{"login":"amit_vnt"}'; RESP_HEADERS='x-oauth-scopes: admin:org' ;;
    "GET "*/memberships/amit_vnt) RESP_STATUS=200; RESP_BODY='{"role":"admin"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna/members*) RESP_STATUS=200; RESP_BODY='{"not":"an array"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/teams/ppna) RESP_STATUS=200; RESP_BODY='{"slug":"ppna"}'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP/members*) RESP_STATUS=200; RESP_BODY='[{"login":"amit_vnt"}]'; RESP_HEADERS='' ;;
    "GET "*/orgs/INVENCO-GROUP) RESP_STATUS=200; RESP_BODY='{"login":"INVENCO-GROUP"}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
: > "$GHW_STUB_LOG"
print -rl -- "login" "newuser_vnt" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --team ppna --csv "$csv" 2>&1); rc=$?
if (( rc != 0 )); then _ok; else _fail "malformed team-list body: expected non-zero exit, got 0"; fi
assert_not_contains "malformed team-list body zero writes" "$(<$GHW_STUB_LOG)" "PUT "

# Case-insensitive membership matching: CSV login differs only in case from
# an already-existing org member. GitHub logins are case-insensitive; the
# set-difference must still recognize the login as already present and
# refuse to write, or the safety mechanism can be defeated by casing alone.
base_routes; : > "$GHW_STUB_LOG"; rm -f "${work}/added"
print -rl -- "login" "OWNER1_VNT" > "$csv"
out=$(zsh "$engine" --account inv --org INVENCO-GROUP --csv "$csv" 2>&1); rc=$?
assert_exit "case-insensitive skip exit 0" 0 $rc
log=$(<$GHW_STUB_LOG)
assert_not_contains "case-insensitive no PUT (CSV casing)" "$log" "memberships/OWNER1_VNT"
assert_not_contains "case-insensitive no PUT (org casing)" "$log" "PUT https://api.github.example/orgs/INVENCO-GROUP/memberships/owner1_vnt"
rdir=$(print -r -- "$out" | awk '/^report: /{print $2}')
assert_contains "case-insensitive skipped row" "$(<${rdir}/report.csv)" "OWNER1_VNT,org,skipped"

rm -rf "$work"
report
