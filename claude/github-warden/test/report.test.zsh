#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/report.zsh"

work=$(mktemp -d)
export GHW_STATE_DIR="$work"

ghw_report_init "20260728-test-job"
assert_eq "report dir" "${work}/reports/20260728-test-job" "$GHW_REPORT_DIR"
ghw_report_row "alice_vnt" org added active member ""
ghw_report_row "bob_vnt" org not_found "" "" "account does not exist, stale row"
out=$(ghw_report_finish "org: 2 -> 3 (+1)")
assert_contains "finish prints dir" "$out" "$GHW_REPORT_DIR"
csv=$(<"${GHW_REPORT_DIR}/report.csv")
assert_contains "csv header" "$csv" "login,phase,status,state,role,detail"
assert_contains "csv row" "$csv" "alice_vnt,org,added,active,member,"
assert_contains "csv quoted detail" "$csv" '"account does not exist, stale row"'
assert_eq "json rows" 2 "$(jq 'length' "${GHW_REPORT_DIR}/report.json")"
assert_eq "json field" "not_found" "$(jq -r '.[1].status' "${GHW_REPORT_DIR}/report.json")"
assert_contains "summary persisted" "$(<${GHW_REPORT_DIR}/summary.txt)" "+1"

csvfile="${work}/src.csv"
print -rl -- "name,login,email" "A,alice_vnt,a@x" "B,bob_vnt,b@x" "A2,alice_vnt,a@x" > "$csvfile"
out=$(ghw_parse_source "$csvfile" login 2>"${work}/err")
assert_eq "parsed logins" $'alice_vnt\nbob_vnt' "$out"
assert_contains "dup warned" "$(<${work}/err)" "duplicate"

out=$(ghw_parse_source "$csvfile" nope 2>&1); rc=$?
assert_exit "missing column rc" 6 $rc
assert_contains "missing column named" "$out" "SOURCE_INVALID"

print -r -- "login" > "$csvfile"
out=$(ghw_parse_source "$csvfile" login 2>&1); rc=$?
assert_exit "empty source rc" 6 $rc

rm -rf "$work"
report
