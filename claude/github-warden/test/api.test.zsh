#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
daemon_dir=${script_dir:h}
source "${daemon_dir}/lib/api.zsh"

work=$(mktemp -d)
export GHW_CURL="zsh ${script_dir}/fixtures/curl-stub.zsh"
export GHW_STUB_LOG="${work}/log"
export GHW_STUB_ROUTES="${work}/routes.zsh"
export GHW_TOKEN="testtoken"
export GHW_API_ROOT="https://api.github.example"
sleep_log="${work}/sleeps"
cat > "${work}/fake-sleep" <<EOF
#!/usr/bin/env zsh
print -r -- "\$1" >> "${sleep_log}"
EOF
chmod +x "${work}/fake-sleep"
export GHW_SLEEP="${work}/fake-sleep"

# Invoke directly (not via command substitution) and capture stdout to a file:
# ghw_api sets GHW_LAST_STATUS/GHW_LAST_HEADERS as globals in the calling shell,
# and `out=$(ghw_api ...)` would fork a subshell that loses those side effects.
out_file="${work}/out"

# happy path
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=200; RESP_BODY='{"login":"amit-t"}'; RESP_HEADERS='x-oauth-scopes: admin:org, repo' }
EOF
: > "$GHW_STUB_LOG"
ghw_api GET /user > "$out_file"; rc=$?
out=$(<"$out_file")
assert_exit "200 rc" 0 $rc
assert_contains "body passthrough" "$out" '"login":"amit-t"'
assert_contains "headers captured" "$GHW_LAST_HEADERS" "admin:org"

# plain 403 — no retry, rc 3
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=403; RESP_BODY='{"message":"Must be an admin"}'; RESP_HEADERS='x-ratelimit-remaining: 42' }
EOF
: > "$GHW_STUB_LOG"
ghw_api PUT /orgs/o/memberships/u '{"role":"member"}' > "$out_file"; rc=$?
out=$(<"$out_file")
assert_exit "plain 403 rc" 3 $rc
calls=$(wc -l < "$GHW_STUB_LOG")
assert_eq "plain 403 not retried" 1 "${calls// /}"

# 404 rc 4
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=404; RESP_BODY='{"message":"Not Found"}'; RESP_HEADERS='' }
EOF
ghw_api GET /users/ghost > "$out_file"; rc=$?
out=$(<"$out_file")
assert_exit "404 rc" 4 $rc

# secondary rate limit: 403+retry-after once, then 200 (A8 core)
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  local n_file="${work}/n"; local n=0
  [[ -f "\$n_file" ]] && n=\$(<"\$n_file")
  (( n++ )); print -rn -- \$n > "\$n_file"
  if (( n == 1 )); then
    RESP_STATUS=403; RESP_BODY='{"message":"secondary rate limit"}'; RESP_HEADERS='retry-after: 7'
  else
    RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member"}'; RESP_HEADERS=''
  fi
}
EOF
: > "$GHW_STUB_LOG"; : > "$sleep_log"; rm -f "${work}/n"
ghw_api PUT /orgs/o/memberships/u '{"role":"member"}' > "$out_file"; rc=$?
out=$(<"$out_file")
assert_exit "rate-limited then success" 0 $rc
assert_contains "slept retry-after" "$(<$sleep_log)" "7"
calls=$(wc -l < "$GHW_STUB_LOG")
assert_eq "retried once" 2 "${calls// /}"

# TWO consecutive secondary-rate-limit 403s then success. Regression guard
# for hoisting `remaining/retry_after/reset/now/wait` out of the 403 case
# arm: those were bare `local` declarations inside the retry loop, so a
# SECOND pass through the 403 branch used to make zsh print
# `remaining=<value>` etc. to stdout as a side effect of the redeclaration —
# and ghw_api's stdout IS the response body every caller captures. Proving
# the body is exactly the untouched 200 JSON (not just "doesn't contain a
# substring") is what actually proves the body is uncorrupted.
cat > "$GHW_STUB_ROUTES" <<EOF
stub_route() {
  local n_file="${work}/n2"; local n=0
  [[ -f "\$n_file" ]] && n=\$(<"\$n_file")
  (( n++ )); print -rn -- \$n > "\$n_file"
  if (( n <= 2 )); then
    RESP_STATUS=403; RESP_BODY='{"message":"secondary rate limit"}'; RESP_HEADERS='retry-after: 3'
  else
    RESP_STATUS=200; RESP_BODY='{"state":"active","role":"member","id":99}'; RESP_HEADERS=''
  fi
}
EOF
: > "$GHW_STUB_LOG"; : > "$sleep_log"; rm -f "${work}/n2"
ghw_api PUT /orgs/o/memberships/u '{"role":"member"}' > "$out_file"; rc=$?
out=$(<"$out_file")
assert_exit "two secondary rate limits then success" 0 $rc
assert_eq "captured body is exactly the 200 JSON, uncorrupted" '{"state":"active","role":"member","id":99}' "$out"
assert_not_contains "no leaked remaining=" "$out" "remaining="
assert_not_contains "no leaked retry_after=" "$out" "retry_after="
assert_not_contains "no leaked reset=" "$out" "reset="
print -r -- "$out" | jq -e . >/dev/null
assert_exit "captured body parses as JSON" 0 $?
calls=$(wc -l < "$GHW_STUB_LOG")
assert_eq "retried twice then succeeded" 3 "${calls// /}"

# pagination: 100-item page then 1-item page
# Note: page=2 must be matched before page=1 — every request also carries
# per_page=100, whose "page=1" substring would otherwise shadow the real
# &page=2 param under a naive *page=1* glob.
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() {
  case "$2" in
    *page=2*) RESP_STATUS=200; RESP_BODY='[{"login":"last"}]'; RESP_HEADERS='' ;;
    *page=1*) RESP_STATUS=200; RESP_BODY=$(jq -nc '[range(100) | {login: ("u\(.)")}]'); RESP_HEADERS='' ;;
    *) RESP_STATUS=500; RESP_BODY='[]'; RESP_HEADERS='' ;;
  esac
}
EOF
ghw_api_paged /orgs/o/members > "$out_file"; rc=$?
out=$(<"$out_file")
assert_exit "paged rc" 0 $rc
assert_eq "paged length" 101 "$(print -r -- "$out" | jq 'length')"

# malformed page body: 200 with a non-array object instead of a member array.
# Must not be treated as an empty-but-valid page (rc 0, empty output) — that
# would let a caller's MEMBER_LIST_READ_FAILED guard pass with an empty map.
cat > "$GHW_STUB_ROUTES" <<'EOF'
stub_route() { RESP_STATUS=200; RESP_BODY='{"not":"an array"}'; RESP_HEADERS='' }
EOF
ghw_api_paged /orgs/o/members > "$out_file"; rc=$?
assert_exit "paged malformed body rc" 1 $rc

rm -rf "$work"
report
