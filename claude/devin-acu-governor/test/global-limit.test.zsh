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
      if [[ "$data" == '{"local_agent":{"cycle_acu_limit":'<->'}}' || "$data" == '{"cloud_agent":{"cycle_acu_limit":'<->'}}' ]]; then
        emit "${FAKE_PATCH_BODY:-}" "${FAKE_PATCH_CODE:-204}"
      else
        emit "{\"detail\":\"bad body $data\"}" "400"
      fi
    else
      # Stateful verify: replay the last PATCH body recorded for this org's URL,
      # so reconciliation reads see what the run just wrote. Env override wins.
      last_patch=""
      if [[ -z "${FAKE_VERIFY_BODY:-}" && -f "${CURL_LOG}" ]]; then
        last_patch=$(awk -v u="url=${url}" '
          /^method=/ {m=$0}
          /^url=/ {cu=$0}
          /^data=/ {if (m == "method=PATCH" && cu == u) body=substr($0, 6)}
          END {print body}
        ' "${CURL_LOG}")
      fi
      if [[ -n "$last_patch" ]]; then
        emit "$last_patch" "200"
      else
        emit "${FAKE_VERIFY_BODY:-$default_verify}" "${FAKE_VERIFY_CODE:-200}"
      fi
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
assert_exit "multiple orgs rc" 0 $rc
assert_contains "multiple orgs all mode" "$out" "No org selector passed; applying to all 2 organizations"
assert_contains "multiple orgs confirms a" "$out" "confirmed local_agent.cycle_acu_limit=2400 for org-a"
assert_contains "multiple orgs confirms b" "$out" "confirmed local_agent.cycle_acu_limit=2400 for org-b"
log=$(cat "${tmpdir}/curl.log")
assert_contains "patched org a" "$log" "/v3beta1/enterprise/organizations/org-a/consumption/acu-limits"
assert_contains "patched org b" "$log" "/v3beta1/enterprise/organizations/org-b/consumption/acu-limits"

# --- gate selector: cloud ---
: > "${tmpdir}/curl.log"
out=$(FAKE_VERIFY_BODY='{"cloud_agent":{"cycle_acu_limit":0}}' run_global set limit global cloud 0); rc=$?
assert_exit "cloud gate rc" 0 $rc
assert_contains "cloud gate confirmed" "$out" "confirmed cloud_agent.cycle_acu_limit=0"
assert_contains "cloud gate names gate" "$out" "cloud_agent.cycle_acu_limit=0 ACUs"
log=$(cat "${tmpdir}/curl.log")
assert_contains "cloud gate patch body" "$log" '{"cloud_agent":{"cycle_acu_limit":0}}'
if [[ "$log" == *'"local_agent"'* ]]; then _fail "cloud gate touched local_agent"; else _ok; fi

# --- gate selector: explicit local ---
: > "${tmpdir}/curl.log"
out=$(run_global set limit global local 2400 org-one); rc=$?
assert_exit "explicit local rc" 0 $rc
assert_contains "explicit local confirmed" "$out" "confirmed local_agent.cycle_acu_limit=2400"
assert_contains "explicit local patch body" "$(cat "${tmpdir}/curl.log")" '{"local_agent":{"cycle_acu_limit":2400}}'

# --- gate selector on aliases ---
: > "${tmpdir}/curl.log"
out=$(FAKE_VERIFY_BODY='{"cloud_agent":{"cycle_acu_limit":0}}' run_global set-limit global cloud 0 org-one); rc=$?
assert_exit "set-limit cloud alias rc" 0 $rc
assert_contains "set-limit cloud alias body" "$(cat "${tmpdir}/curl.log")" '{"cloud_agent":{"cycle_acu_limit":0}}'

# --- shorthands: slgl (local) / slgc (cloud) ---
: > "${tmpdir}/curl.log"
out=$(run_global slgl 2400 org-one); rc=$?
assert_exit "slgl rc" 0 $rc
assert_contains "slgl confirmed" "$out" "confirmed local_agent.cycle_acu_limit=2400"
assert_contains "slgl patch body" "$(cat "${tmpdir}/curl.log")" '{"local_agent":{"cycle_acu_limit":2400}}'

: > "${tmpdir}/curl.log"
out=$(FAKE_VERIFY_BODY='{"cloud_agent":{"cycle_acu_limit":0}}' run_global slgc 0 org-one); rc=$?
assert_exit "slgc rc" 0 $rc
assert_contains "slgc confirmed" "$out" "confirmed cloud_agent.cycle_acu_limit=0"
assert_contains "slgc patch body" "$(cat "${tmpdir}/curl.log")" '{"cloud_agent":{"cycle_acu_limit":0}}'

out=$(run_global slgc 2>&1); rc=$?
assert_exit "slgc no amount rc" 2 $rc
assert_contains "slgc usage" "$out" "non-negative integer"

# --- cloud verify mismatch ---
out=$(FAKE_VERIFY_BODY='{"cloud_agent":{"cycle_acu_limit":500}}' run_global set limit global cloud 0 2>&1); rc=$?
assert_exit "cloud verify mismatch rc" 1 $rc
assert_contains "cloud verify mismatch msg" "$out" "expected cloud_agent.cycle_acu_limit=0"

# --- bad gate word ---
out=$(run_global set limit global hybrid 2400 2>&1); rc=$?
assert_exit "bad gate rc" 2 $rc
assert_contains "bad gate usage" "$out" "[local|cloud]"

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

# --- org ceiling: Σ org caps (local + cloud, every org incl. the umbrella org) ---
three_orgs='{"items":[{"org_id":"org-vnt","name":"Vontier"},{"org_id":"org-a","name":"A"},{"org_id":"org-b","name":"B"}]}'

# Umbrella org is an ordinary org: all-mode writes every org the same amount,
# no parent reconciliation write.
: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY="$three_orgs" FAKE_VERIFY_BODY='{"local_agent":{"cycle_acu_limit":100}}' run_global set limit global 100); rc=$?
assert_exit "umbrella all-mode rc" 0 $rc
assert_contains "umbrella all-mode all three" "$out" "applying to all 3 organizations"
assert_contains "umbrella all-mode vontier" "$out" "confirmed local_agent.cycle_acu_limit=100 for org-vnt"
assert_contains "ceiling line" "$out" "Σ org caps (local + cloud, every org) 300 → 300 ACUs; ceiling 24000"
if [[ "$out" == *"non-parent"* || "$out" == *"reconcil"* ]]; then _fail "parent rule still active"; else _ok; fi
log=$(cat "${tmpdir}/curl.log")
assert_eq "three PATCHes only" 3 "$(grep -c '^method=PATCH' <<<"$log")"

# Growth past the ceiling is refused before any PATCH (3 × 9000 = 27000 > 24000).
: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY="$three_orgs" FAKE_VERIFY_BODY='{"local_agent":{"cycle_acu_limit":100}}' run_global set limit global 9000 2>&1); rc=$?
assert_exit "ceiling refuse rc" 3 $rc
assert_contains "ceiling refuse msg" "$out" "refused — Σ org caps would rise to 27000 ACUs, above the 24000 ACU ceiling"
if grep -q '^method=PATCH' "${tmpdir}/curl.log"; then _fail "refused run still PATCHed"; else _ok; fi

# Single-org raise that tips Σ over the ceiling is refused; cloud caps count.
: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY="$three_orgs" FAKE_VERIFY_BODY='{"local_agent":{"cycle_acu_limit":8000},"cloud_agent":{"cycle_acu_limit":100}}' run_global set limit global 8200 org-a 2>&1); rc=$?
assert_exit "single raise refuse rc" 3 $rc
assert_contains "single raise sums" "$out" "24300 → 24500"
if grep -q '^method=PATCH' "${tmpdir}/curl.log"; then _fail "single refused run PATCHed"; else _ok; fi

# Custom pool is the ceiling.
: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY="$three_orgs" FAKE_VERIFY_BODY='{"local_agent":{"cycle_acu_limit":100}}' DAG_MONTHLY_ACU_POOL=250 run_global set limit global 150 org-a 2>&1); rc=$?
assert_exit "custom pool refuse rc" 3 $rc
assert_contains "custom pool ceiling" "$out" "ceiling 250"

# Already-over layer (default fake caps 3 × 2400 = 7200 > pool 5000): shrinking writes are allowed.
: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY="$three_orgs" DAG_MONTHLY_ACU_POOL=5000 run_global set limit global 1000 Vontier 2>&1); rc=$?
assert_exit "shrink over layer rc" 0 $rc
assert_contains "shrink over layer sums" "$out" "7200 → 5800"
assert_contains "shrink over layer note" "$out" "over the ceiling by 800 ACUs after this write — allowed because it does not grow the layer"
log=$(cat "${tmpdir}/curl.log")
assert_eq "shrink wrote only vontier" 1 "$(grep -c '^method=PATCH' <<<"$log")"

# Uncapped org: warned as unenforceable; cloud-zeroing still allowed.
: > "${tmpdir}/curl.log"
out=$(FAKE_ORGS_BODY="$three_orgs" FAKE_VERIFY_BODY='{"cloud_agent":{"cycle_acu_limit":0}}' run_global set limit global cloud 0 2>&1); rc=$?
assert_exit "uncapped cloud zero rc" 0 $rc
assert_contains "uncapped warning" "$out" "ceiling is unenforceable until capped: Vontier, A, B"

# Layer GET failure aborts before any PATCH.
: > "${tmpdir}/curl.log"
out=$(FAKE_VERIFY_CODE=500 FAKE_VERIFY_BODY='{"detail":"limits read exploded"}' run_global set limit global 100 2>&1); rc=$?
assert_exit "layer read fail rc" 1 $rc
assert_contains "layer read fail quoted" "$out" 'limits read exploded'
if grep -q '^method=PATCH' "${tmpdir}/curl.log"; then _fail "layer read fail PATCHed"; else _ok; fi

report
