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

repo_json() {  # $1 name, $2 has_wiki, $3 secret_scanning status
  jq -nc --arg n "$1" --argjson w "$2" --arg ss "$3" '{
    name: $n, private: true, has_issues: true, has_projects: false, has_wiki: $w,
    has_discussions: false, allow_squash_merge: true, allow_merge_commit: false,
    allow_rebase_merge: true, delete_branch_on_merge: true, allow_update_branch: true,
    web_commit_signoff_required: false, default_branch: "main",
    security_and_analysis: {secret_scanning: {status: $ss}}}'
}
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  case "\$2" in
    */repos/ORG1/ref-repo/branches/main/protection|*/repos/ORG1/good/branches/main/protection)
      RESP_STATUS=200; RESP_BODY='{"required_pull_request_reviews":{}}'; RESP_HEADERS='' ;;
    */repos/ORG1/drifty/branches/main/protection)
      RESP_STATUS=404; RESP_BODY='{"message":"Branch not protected"}'; RESP_HEADERS='' ;;
    */repos/ORG1/ref-repo) RESP_STATUS=200; RESP_BODY='$(repo_json ref-repo true enabled)'; RESP_HEADERS='' ;;
    */repos/ORG1/good) RESP_STATUS=200; RESP_BODY='$(repo_json good true enabled)'; RESP_HEADERS='' ;;
    */repos/ORG1/drifty) RESP_STATUS=200; RESP_BODY='$(repo_json drifty false disabled)'; RESP_HEADERS='' ;;
    */orgs/ORG1/repos*)
      RESP_STATUS=200; RESP_BODY='[{"name":"good","pushed_at":"2026-07-01T00:00:00Z","size":10,"fork":false},{"name":"drifty","pushed_at":"2020-01-01T00:00:00Z","size":10,"fork":false},{"name":"emptyrepo","pushed_at":null,"size":0,"fork":false}]'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF

out=$(zsh "$ghw_bin" audit --org ORG1 --ref ORG1/ref-repo 2>&1); rc=$?
assert_exit "audit ok" 0 $rc
assert_contains "wiki drift" "$out" $'drifty\thas_wiki\ttrue\tfalse'
assert_contains "secret scanning drift" "$out" $'drifty\tsecret_scanning\tenabled\tdisabled'
assert_contains "protection drift" "$out" $'drifty\tbranch_protection\tprotected\tunprotected'
assert_not_contains "good repo clean" "$out" $'good\thas_wiki'

out=$(zsh "$ghw_bin" stale --org ORG1 --months 6 2>&1); rc=$?
assert_exit "stale ok" 0 $rc
assert_contains "inactive flagged" "$out" "drifty"
assert_contains "empty flagged" "$out" "emptyrepo"
assert_not_contains "active excluded" "$out" $'good\t'
assert_contains "archive command printed" "$out" "gh repo archive ORG1/drifty --yes"
assert_not_contains "read-only" "$(<$GHW_STUB_LOG)" "PUT "
assert_not_contains "no deletes" "$(<$GHW_STUB_LOG)" "DELETE "
# Regression guard for hoisting `pushed_epoch` out of the repo loop: "good"
# and "drifty" above both have a non-zero size and a non-null pushed_at, so
# both take the epoch-parsing branch — "good" first, "drifty" second. A bare
# `local pushed_epoch` inside that branch used to make zsh print
# `pushed_epoch=<value>` to stdout on the SECOND repo that reached it,
# corrupting this command's actual report output. Assert the output is
# pristine and every expected report row still made it through untouched.
assert_not_contains "no zsh bare-local pushed_epoch leak" "$out" "pushed_epoch="
assert_contains "report row for drifty intact" "$out" $'drifty\t2020-01-01T00:00:00Z\tinactive >6mo (last push 2020-01-01)'
assert_contains "report row for emptyrepo intact" "$out" $'emptyrepo\tnull\tempty'

# --- Regression guard: masked paged-fetch failure must not degrade
# silently. Same class as the status/members fixes: `ghw_api_paged | jq`'s
# `$?` reflects only jq's exit status in plain zsh (no `pipefail` set
# anywhere in this codebase), and `ghw_api_paged` prints nothing on
# failure, so jq sees empty stdin and exits 0 — the repo loop below would
# then simply not execute, printing "0 repos audited, 0 drift lines" as if
# the org genuinely had no other repos rather than surfacing a failed read.
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  case "\$2" in
    */orgs/ORG1/repos*) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
    */repos/ORG1/ref-repo/branches/main/protection) RESP_STATUS=200; RESP_BODY='{"required_pull_request_reviews":{}}'; RESP_HEADERS='' ;;
    */repos/ORG1/ref-repo) RESP_STATUS=200; RESP_BODY='$(repo_json ref-repo true enabled)'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" audit --org ORG1 --ref ORG1/ref-repo 2>&1); rc=$?
assert_exit "audit: repos fetch failure is non-zero" 1 $rc
assert_contains "audit: repos fetch failure named" "$out" "ghw audit: /orgs/ORG1/repos read failed"
assert_not_contains "audit: no summary line on repos fetch failure" "$out" "repos audited"

# stale: org repos fetch fails. Not a masked-pipe case (no `| jq` before the
# check — the jq parse runs later, inside the `while read` construct, only
# after this read already succeeded), but the bare `|| return 1` still
# exited with zero stderr output.
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    */orgs/ORG1/repos*) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='{}'; RESP_HEADERS='' ;;
  esac
}
EOF
out=$(zsh "$ghw_bin" stale --org ORG1 --months 6 2>&1); rc=$?
assert_exit "stale: repos fetch failure is non-zero" 1 $rc
assert_contains "stale: repos fetch failure named" "$out" "ghw stale: /orgs/ORG1/repos read failed"
assert_not_contains "stale: no candidate count line on repos fetch failure" "$out" "archive candidate(s)"

rm -rf "$work"
report
