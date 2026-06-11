#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

cat > "${tmpdir}/bin/security" <<'EOFSEC'
#!/usr/bin/env zsh
exit 44
EOFSEC
chmod +x "${tmpdir}/bin/security"

cat > "${tmpdir}/bin/curl" <<'EOFCURL'
#!/usr/bin/env zsh
method="GET"
data=""
url=""
prev=""
for a in "$@"; do
  case "$prev" in
    -X) method="$a" ;;
    --data|-d) data="$a" ;;
  esac
  prev="$a"
done
url="${@: -1}"
{
  print -r -- "method=${method}"
  print -r -- "url=${url}"
  [[ -n "$data" ]] && print -r -- "data=${data}"
  print -r -- "---"
} >> "${CURL_LOG}"
emit() { print -rn -- "${1}"; print -rn -- $'\n'"${2}"; }
default_orgs='{"items":[{"org_id":"org-one","name":"OneTier"}]}'
default_verify='{"local_agent":{"cycle_acu_limit":2400}}'
case "$url" in
  */v3/enterprise/organizations)
    emit "${FAKE_ORGS_BODY:-$default_orgs}" "${FAKE_ORGS_CODE:-200}" ;;
  */v3beta1/enterprise/organizations/*/consumption/acu-limits)
    if [[ "$method" == "PATCH" ]]; then
      if [[ "$data" != '{"local_agent":{"cycle_acu_limit":2400}}' && "$data" != '{"local_agent":{"cycle_acu_limit":0}}' ]]; then
        emit "{\"detail\":\"bad body $data\"}" "400"
      else
        emit "${FAKE_PATCH_BODY:-}" "${FAKE_PATCH_CODE:-204}"
      fi
    else
      emit "${FAKE_VERIFY_BODY:-$default_verify}" "${FAKE_VERIFY_CODE:-200}"
    fi ;;
  *) emit '{"detail":"unexpected endpoint"}' 404 ;;
esac
EOFCURL
chmod +x "${tmpdir}/bin/curl"

run_global() {
  PATH="${tmpdir}/bin:$PATH" CURL_LOG="${tmpdir}/curl.log" DEVIN_COG_KEY="secret-cog-key" \
  DAG_API_BASE_V3="https://api.devin.ai" zsh "$dag" "$@" 2>&1
}

: > "${tmpdir}/curl.log"
out=$(run_global set limit global 2400); rc=$?
assert_exit "set limit global rc" 0 $rc
assert_contains "confirmed amount" "$out" "confirmed local_agent.cycle_acu_limit=2400"
assert_contains "ui instruction" "$out" "Enterprise Settings > Consumption"
assert_contains "api managed note" "$out" "Limits themselves are API-managed"
assert_contains "patch endpoint" "$(cat "${tmpdir}/curl.log")" "/v3beta1/enterprise/organizations/org-one/consumption/acu-limits"
assert_contains "patch body" "$(cat "${tmpdir}/curl.log")" '{"local_agent":{"cycle_acu_limit":2400}}'
if [[ "$out" == *secret-cog-key* ]]; then _fail "global command leaked key"; else _ok; fi

: > "${tmpdir}/curl.log"
out=$(run_global set-limit global 2400 org-one); rc=$?
assert_exit "set-limit alias rc" 0 $rc
assert_contains "selector ok" "$out" "org-one"

: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY='{"items":[{"org_id":"org-a","name":"A"},{"org_id":"org-b","name":"B"}]}' run_global set limit global 2400 2>&1); rc=$?
assert_exit "multiple orgs rc" 2 $rc
assert_contains "multiple orgs lists a" "$out" "org-a"
assert_contains "multiple orgs asks selector" "$out" "Pass org_id or name"
if grep -q "PATCH" "${tmpdir}/curl.log"; then _fail "patched despite ambiguous org"; else _ok; fi

out=$(run_global set limit global banana 2>&1); rc=$?
assert_exit "bad amount rc" 2 $rc
assert_contains "bad amount msg" "$out" "non-negative integer"

out=$(FAKE_PATCH_CODE=500 FAKE_PATCH_BODY='{"detail":"patch exploded"}' run_global set limit global 2400 2>&1); rc=$?
assert_exit "patch fail rc" 1 $rc
assert_contains "patch body quoted" "$out" '{"detail":"patch exploded"}'

out=$(FAKE_VERIFY_BODY='{"local_agent":{"cycle_acu_limit":2300}}' run_global set limit global 2400 2>&1); rc=$?
assert_exit "verify mismatch rc" 1 $rc
assert_contains "verify mismatch" "$out" "verification failed"

out=$(FAKE_VERIFY_BODY='{}' run_global set limit global 0 2>&1); rc=$?
assert_exit "zero mismatch rc" 1 $rc
assert_contains "zero allowed attempted" "$out" "verification failed"

report
