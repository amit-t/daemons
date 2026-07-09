#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
dag="${script_dir}/../bin/dag"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/bin"

# Fake security: always miss, so env vars drive key resolution.
cat > "${tmpdir}/bin/security" <<'EOF'
#!/usr/bin/env zsh
exit 44
EOF
chmod +x "${tmpdir}/bin/security"

# Fake curl: echo an HTTP code chosen by the endpoint URL (last arg).
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env zsh
url=""
for a in "$@"; do url="$a"; done
case "$url" in
  *consumption/cycles*)        print -rn -- "${FAKE_CYCLES:-200}" ;;
  *v3beta1/enterprise/organizations/org-dag-doctor-probe/consumption/acu-limits*) print -rn -- "${FAKE_LIMIT_WRITE:-404}" ;;
  *v3beta1/enterprise/users/consumption/acu-limits*) print -rn -- "${FAKE_LIMIT_READ:-200}" ;;
  *enterprise/organizations*)  print -rn -- "${FAKE_ORGS:-200}" ;;
  *members/idp-users*)         print -rn -- "${FAKE_IDP_ROSTER:-200}" ;;
  *members/users*)             print -rn -- "${FAKE_ROSTER:-200}" ;;
  *metrics/usage*)             print -rn -- "${FAKE_METRICS:-200}" ;;
  *UserPageAnalytics*)         print -rn -- "${FAKE_TEAMS:-200}" ;;
  *analytics/consumption*)     print -rn -- "${FAKE_ANALYTICS:-200}" ;;
  *)                           print -rn -- "000" ;;
esac
EOF
chmod +x "${tmpdir}/bin/curl"

run_doctor() {  # env overrides via FAKE_* assignments prefixed to the call
  PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=cogk DEVIN_SERVICE_KEY=wsk \
  FAKE_CYCLES="${FAKE_CYCLES:-200}" FAKE_LIMIT_WRITE="${FAKE_LIMIT_WRITE:-404}" \
  FAKE_LIMIT_READ="${FAKE_LIMIT_READ:-200}" FAKE_ORGS="${FAKE_ORGS:-200}" FAKE_ROSTER="${FAKE_ROSTER:-200}" \
  FAKE_IDP_ROSTER="${FAKE_IDP_ROSTER:-200}" FAKE_METRICS="${FAKE_METRICS:-200}" FAKE_TEAMS="${FAKE_TEAMS:-200}" \
  FAKE_ANALYTICS="${FAKE_ANALYTICS:-200}" \
  zsh "$dag" doctor 2>&1
}

# 1. Everything present.
out=$(run_doctor); rc=$?
assert_exit "all rc" 0 $rc
assert_contains "all summary" "$out" "All capabilities present"
assert_contains "consumption line" "$out" "Consumption Read"
assert_contains "limit read line" "$out" "ACU Limit Read"
assert_contains "limit write line" "$out" "ACU Limit Write"
assert_contains "idp roster line" "$out" "IDP Group Read"
assert_contains "write noop note" "$out" "mutates nothing"

# 2. Required v3 capability missing (consumption 403) -> exit 3.
out=$(FAKE_CYCLES=403 run_doctor); rc=$?
assert_exit "v3 missing rc" 3 $rc
assert_contains "v3 missing word" "$out" "missing"
assert_contains "v3 missing hint" "$out" "app.devin.ai"

# 3. IDP group read missing -> exit 3 with membership-permission hint.
out=$(FAKE_IDP_ROSTER=403 run_doctor); rc=$?
assert_exit "idp missing rc" 3 $rc
assert_contains "idp missing word" "$out" "IDP Group Read"
assert_contains "idp missing hint" "$out" "ViewAccountMembership"

# 4. ACU-limit write probe: 403 = inconclusive (API may mask unknown orgs) -> warn, exit 0.
out=$(FAKE_LIMIT_WRITE=403 run_doctor); rc=$?
assert_exit "limit write inconclusive rc" 0 $rc
assert_contains "limit write inconclusive word" "$out" "inconclusive"

# 5. Windsurf capability missing -> exit 0 with degradation warning.
out=$(FAKE_TEAMS=403 run_doctor); rc=$?
assert_exit "ws missing rc" 0 $rc
assert_contains "ws degraded" "$out" "degrades per-model/IDE breakdown"

# 6. Analytics rate-limited (429) -> optional, still exit 0 but flagged.
out=$(FAKE_ANALYTICS=429 run_doctor); rc=$?
assert_exit "an 429 rc" 0 $rc
assert_contains "an 429 word" "$out" "rate-limited"

# 7. Skip analytics probe (avoid burning the 10/hr budget).
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=cogk DEVIN_SERVICE_KEY=wsk DAG_DOCTOR_SKIP_ANALYTICS=1 \
  zsh "$dag" doctor 2>&1); rc=$?
assert_exit "skip rc" 0 $rc
assert_contains "skip word" "$out" "skipped"

# 8. No Windsurf key at all -> exit 0, notes unavailability.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY=cogk DEVIN_SERVICE_KEY="" zsh "$dag" doctor 2>&1); rc=$?
assert_exit "no ws key rc" 0 $rc
assert_contains "no ws key word" "$out" "no Windsurf service key"

# 9. No cog key -> exit 1.
out=$(PATH="${tmpdir}/bin:$PATH" DEVIN_COG_KEY="" DEVIN_SERVICE_KEY=wsk zsh "$dag" doctor 2>&1); rc=$?
assert_exit "nokey rc" 1 $rc
assert_contains "nokey word" "$out" "no Devin API v3 service-user key"

# 10. Keys never leak into doctor output.
out=$(run_doctor)
if [[ "$out" == *"Bearer cogk"* || "$out" == *"Bearer wsk"* || "$out" == *"key=cogk"* ]]; then
  _fail "key leaked into doctor output"
else
  _ok
fi

report
